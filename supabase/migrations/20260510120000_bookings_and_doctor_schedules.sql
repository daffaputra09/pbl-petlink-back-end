-- Bookings, line items (services), and doctor schedule blocks (admin calendar).
-- doctor_schedules.booking_id is optional (NULL = unlinked / availability block).

CREATE TYPE public.booking_status AS ENUM (
  'pending',
  'confirmed',
  'in_progress',
  'completed',
  'cancelled'
);

CREATE TYPE public.booking_channel AS ENUM ('clinic', 'home');

CREATE TABLE public.bookings (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customer_profiles (id) ON DELETE RESTRICT,
  pet_id uuid NOT NULL REFERENCES public.customer_pets (id) ON DELETE RESTRICT,
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE RESTRICT,
  doctor_id uuid REFERENCES public.doctor_profiles (id) ON DELETE SET NULL,
  channel public.booking_channel NOT NULL,
  scheduled_start_at timestamp with time zone NOT NULL,
  scheduled_end_at timestamp with time zone NOT NULL,
  status public.booking_status NOT NULL DEFAULT 'pending',
  total_amount numeric(14, 2) NOT NULL DEFAULT 0,
  notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT bookings_time_order CHECK (scheduled_start_at < scheduled_end_at),
  CONSTRAINT bookings_total_non_negative CHECK (total_amount >= 0)
);

CREATE INDEX bookings_customer_id_idx ON public.bookings USING btree (customer_id);

CREATE INDEX bookings_clinic_id_idx ON public.bookings USING btree (clinic_id);

CREATE INDEX bookings_doctor_id_idx ON public.bookings USING btree (doctor_id);

CREATE INDEX bookings_pet_id_idx ON public.bookings USING btree (pet_id);

CREATE INDEX bookings_scheduled_start_idx ON public.bookings USING btree (scheduled_start_at);

CREATE INDEX bookings_status_idx ON public.bookings USING btree (status);

CREATE TRIGGER bookings_set_updated_at
BEFORE UPDATE ON public.bookings
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE OR REPLACE FUNCTION public.booking_pet_matches_customer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
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

CREATE TRIGGER bookings_pet_matches_customer_check
BEFORE INSERT
OR UPDATE OF customer_id, pet_id ON public.bookings
FOR EACH ROW
EXECUTE PROCEDURE public.booking_pet_matches_customer();

CREATE TABLE public.booking_items (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings (id) ON DELETE CASCADE,
  service_id uuid NOT NULL REFERENCES public.services (id) ON DELETE RESTRICT,
  quantity integer NOT NULL DEFAULT 1,
  unit_price numeric(14, 2) NOT NULL,
  line_total numeric(14, 2) NOT NULL,
  duration_minutes integer NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT booking_items_quantity_positive CHECK (quantity > 0),
  CONSTRAINT booking_items_prices_non_negative CHECK (
    unit_price >= 0
    AND line_total >= 0
  ),
  CONSTRAINT booking_items_duration_positive CHECK (duration_minutes > 0)
);

CREATE INDEX booking_items_booking_id_idx ON public.booking_items USING btree (booking_id);

CREATE INDEX booking_items_service_id_idx ON public.booking_items USING btree (service_id);

-- Doctor availability / blocks for admin calendar. No status column.
-- booking_id NULL = not tied to a booking; set when linking a reserved slot.
CREATE TABLE public.doctor_schedules (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id uuid NOT NULL REFERENCES public.doctor_profiles (id) ON DELETE CASCADE,
  starts_at timestamp with time zone NOT NULL,
  ends_at timestamp with time zone NOT NULL,
  booking_id uuid REFERENCES public.bookings (id) ON DELETE SET NULL,
  notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT doctor_schedules_time_order CHECK (starts_at < ends_at)
);

CREATE INDEX doctor_schedules_doctor_id_idx ON public.doctor_schedules USING btree (doctor_id);

CREATE INDEX doctor_schedules_starts_at_idx ON public.doctor_schedules USING btree (starts_at);

CREATE INDEX doctor_schedules_booking_id_idx ON public.doctor_schedules USING btree (booking_id)
WHERE
  booking_id IS NOT NULL;

CREATE TRIGGER doctor_schedules_set_updated_at
BEFORE UPDATE ON public.doctor_schedules
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();
