-- Online consultations (chat-based) and payments for bookings + consultations.
-- Bookings remain for in-person/home health services; consultations are a separate flow.

CREATE TYPE public.consultation_status AS ENUM (
  'pending_payment',
  'scheduled',
  'in_progress',
  'completed',
  'cancelled'
);

CREATE TYPE public.payment_reference_type AS ENUM ('booking', 'consultation');

CREATE TYPE public.payment_status AS ENUM (
  'pending',
  'paid',
  'failed',
  'refunded',
  'expired'
);

CREATE TABLE public.consultations (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customer_profiles (id) ON DELETE RESTRICT,
  doctor_id uuid NOT NULL REFERENCES public.doctor_profiles (id) ON DELETE RESTRICT,
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE RESTRICT,
  pet_id uuid REFERENCES public.customer_pets (id) ON DELETE SET NULL,
  chat_thread_id uuid REFERENCES public.chat_threads (id) ON DELETE SET NULL,
  status public.consultation_status NOT NULL DEFAULT 'pending_payment',
  scheduled_start_at timestamp with time zone NOT NULL,
  scheduled_end_at timestamp with time zone NOT NULL,
  -- Snapshot of doctor_profiles.consultation_fee at booking time.
  consultation_fee numeric(14, 2) NOT NULL,
  notes text,
  completed_at timestamp with time zone,
  completed_by uuid REFERENCES public.doctor_profiles (id) ON DELETE SET NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT consultations_time_order CHECK (scheduled_start_at < scheduled_end_at),
  CONSTRAINT consultations_fee_non_negative CHECK (consultation_fee >= 0),
  CONSTRAINT consultations_completed_fields CHECK (
    (
      status = 'completed'::public.consultation_status
      AND completed_at IS NOT NULL
      AND completed_by IS NOT NULL
    )
    OR status <> 'completed'::public.consultation_status
  ),
  CONSTRAINT consultations_chat_thread_unique UNIQUE (chat_thread_id)
);

CREATE INDEX consultations_customer_id_idx ON public.consultations USING btree (customer_id);

CREATE INDEX consultations_doctor_id_idx ON public.consultations USING btree (doctor_id);

CREATE INDEX consultations_clinic_id_idx ON public.consultations USING btree (clinic_id);

CREATE INDEX consultations_status_idx ON public.consultations USING btree (status);

CREATE INDEX consultations_clinic_doctor_status_idx
  ON public.consultations USING btree (clinic_id, doctor_id, status);

CREATE INDEX consultations_scheduled_start_idx
  ON public.consultations USING btree (scheduled_start_at);

CREATE TRIGGER consultations_set_updated_at
BEFORE UPDATE ON public.consultations
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE TABLE public.payments (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customer_profiles (id) ON DELETE RESTRICT,
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE RESTRICT,
  reference_type public.payment_reference_type NOT NULL,
  reference_id uuid NOT NULL,
  amount numeric(14, 2) NOT NULL,
  status public.payment_status NOT NULL DEFAULT 'pending',
  payment_method character varying(100),
  external_reference character varying(255),
  paid_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT payments_amount_non_negative CHECK (amount >= 0),
  CONSTRAINT payments_reference_unique UNIQUE (reference_type, reference_id)
);

CREATE INDEX payments_customer_id_idx ON public.payments USING btree (customer_id);

CREATE INDEX payments_clinic_id_idx ON public.payments USING btree (clinic_id);

CREATE INDEX payments_status_idx ON public.payments USING btree (status);

CREATE INDEX payments_reference_idx
  ON public.payments USING btree (reference_type, reference_id);

CREATE TRIGGER payments_set_updated_at
BEFORE UPDATE ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

-- Link doctor schedule slots to consultations (mirrors booking_id on doctor_schedules).
ALTER TABLE public.doctor_schedules
  ADD COLUMN consultation_id uuid REFERENCES public.consultations (id) ON DELETE SET NULL;

CREATE INDEX doctor_schedules_consultation_id_idx
  ON public.doctor_schedules USING btree (consultation_id)
  WHERE consultation_id IS NOT NULL;

ALTER TABLE public.doctor_schedules
  ADD CONSTRAINT doctor_schedules_single_reservation CHECK (
    NOT (
      booking_id IS NOT NULL
      AND consultation_id IS NOT NULL
    )
  );

-- --- Validation triggers ---

CREATE OR REPLACE FUNCTION public.consultation_pet_matches_customer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.pet_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_pets cp
    WHERE
      cp.id = NEW.pet_id
      AND cp.customer_id = NEW.customer_id
      AND cp.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'pet_id must reference an active pet owned by customer_id';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER consultations_pet_matches_customer_check
BEFORE INSERT OR UPDATE OF customer_id, pet_id ON public.consultations
FOR EACH ROW
EXECUTE PROCEDURE public.consultation_pet_matches_customer();

CREATE OR REPLACE FUNCTION public.consultation_clinic_matches_doctor()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  doctor_clinic_id uuid;
BEGIN
  SELECT clinic_id INTO doctor_clinic_id
  FROM public.doctor_profiles
  WHERE id = NEW.doctor_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'doctor not found';
  END IF;

  IF NEW.clinic_id IS DISTINCT FROM doctor_clinic_id THEN
    RAISE EXCEPTION 'clinic_id must match the doctor''s clinic';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER consultations_clinic_matches_doctor_check
BEFORE INSERT OR UPDATE OF doctor_id, clinic_id ON public.consultations
FOR EACH ROW
EXECUTE PROCEDURE public.consultation_clinic_matches_doctor();

CREATE OR REPLACE FUNCTION public.consultation_chat_thread_valid()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  thread public.chat_threads%ROWTYPE;
BEGIN
  IF NEW.chat_thread_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO thread
  FROM public.chat_threads
  WHERE id = NEW.chat_thread_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat thread not found';
  END IF;

  IF thread.type IS DISTINCT FROM 'consultation'::public.chat_thread_type THEN
    RAISE EXCEPTION 'consultation chat_thread must have type consultation';
  END IF;

  IF NOT thread.is_active AND NEW.status NOT IN (
    'completed'::public.consultation_status,
    'cancelled'::public.consultation_status
  ) THEN
    RAISE EXCEPTION 'inactive chat thread requires consultation status completed or cancelled';
  END IF;

  IF (
    (thread.user_1_id = NEW.customer_id AND thread.user_2_id = NEW.doctor_id)
    OR (thread.user_2_id = NEW.customer_id AND thread.user_1_id = NEW.doctor_id)
  ) IS FALSE THEN
    RAISE EXCEPTION 'chat thread participants must be the consultation customer and doctor';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER consultations_chat_thread_valid_check
BEFORE INSERT OR UPDATE OF chat_thread_id, customer_id, doctor_id, status
  ON public.consultations
FOR EACH ROW
EXECUTE PROCEDURE public.consultation_chat_thread_valid();

CREATE OR REPLACE FUNCTION public.payment_reference_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.reference_type = 'booking'::public.payment_reference_type THEN
    IF NOT EXISTS (SELECT 1 FROM public.bookings WHERE id = NEW.reference_id) THEN
      RAISE EXCEPTION 'payment reference booking not found';
    END IF;
  ELSIF NEW.reference_type = 'consultation'::public.payment_reference_type THEN
    IF NOT EXISTS (SELECT 1 FROM public.consultations WHERE id = NEW.reference_id) THEN
      RAISE EXCEPTION 'payment reference consultation not found';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER payments_reference_exists_check
BEFORE INSERT OR UPDATE OF reference_type, reference_id ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.payment_reference_exists();

CREATE OR REPLACE FUNCTION public.payment_clinic_matches_reference()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  ref_clinic_id uuid;
BEGIN
  IF NEW.reference_type = 'booking'::public.payment_reference_type THEN
    SELECT clinic_id INTO ref_clinic_id
    FROM public.bookings
    WHERE id = NEW.reference_id;
  ELSE
    SELECT clinic_id INTO ref_clinic_id
    FROM public.consultations
    WHERE id = NEW.reference_id;
  END IF;

  IF ref_clinic_id IS NULL THEN
    RAISE EXCEPTION 'payment reference not found for clinic validation';
  END IF;

  IF NEW.clinic_id IS DISTINCT FROM ref_clinic_id THEN
    RAISE EXCEPTION 'payment clinic_id must match the referenced booking or consultation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER payments_clinic_matches_reference_check
BEFORE INSERT OR UPDATE OF reference_type, reference_id, clinic_id ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.payment_clinic_matches_reference();

-- When a consultation is marked completed, close the chat thread.
CREATE OR REPLACE FUNCTION public.consultation_close_chat_on_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'completed'::public.consultation_status
    AND OLD.status IS DISTINCT FROM 'completed'::public.consultation_status
  THEN
    IF NEW.chat_thread_id IS NOT NULL THEN
      UPDATE public.chat_threads
      SET is_active = false
      WHERE id = NEW.chat_thread_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER consultations_close_chat_on_complete
AFTER UPDATE OF status ON public.consultations
FOR EACH ROW
EXECUTE PROCEDURE public.consultation_close_chat_on_complete();

-- Credit clinic balance when payment is marked paid.
CREATE OR REPLACE FUNCTION public.payment_credit_clinic_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'paid'::public.payment_status
    AND OLD.status IS DISTINCT FROM 'paid'::public.payment_status
  THEN
    UPDATE public.clinic_profiles
    SET balance = balance + NEW.amount
    WHERE id = NEW.clinic_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER payments_credit_clinic_balance
AFTER UPDATE OF status ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.payment_credit_clinic_balance();
