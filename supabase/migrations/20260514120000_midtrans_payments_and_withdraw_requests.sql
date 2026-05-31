-- Midtrans fields on payments and clinic withdraw requests.

ALTER TABLE public.payments
  ADD COLUMN midtrans_order_id character varying(255),
  ADD COLUMN midtrans_transaction_id character varying(255),
  ADD COLUMN midtrans_payment_type character varying(50),
  ADD COLUMN midtrans_raw_response jsonb;

COMMENT ON COLUMN public.payments.midtrans_order_id IS
  'Merchant order ID sent to Midtrans Snap (typically payment id or custom id).';

COMMENT ON COLUMN public.payments.midtrans_transaction_id IS
  'Midtrans transaction_id from payment notification or status API.';

COMMENT ON COLUMN public.payments.midtrans_payment_type IS
  'Midtrans payment_type (e.g. bank_transfer, qris, credit_card).';

COMMENT ON COLUMN public.payments.midtrans_raw_response IS
  'JSON payload(s) from Midtrans: snap token response, HTTP notification, status check, etc.';

CREATE UNIQUE INDEX payments_midtrans_order_id_unique
  ON public.payments USING btree (midtrans_order_id)
  WHERE midtrans_order_id IS NOT NULL;

CREATE INDEX payments_midtrans_transaction_id_idx
  ON public.payments USING btree (midtrans_transaction_id)
  WHERE midtrans_transaction_id IS NOT NULL;

CREATE TYPE public.withdraw_request_status AS ENUM (
  'pending',
  'approved',
  'rejected',
  'completed'
);

CREATE TABLE public.withdraw_requests (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE RESTRICT,
  amount numeric(14, 2) NOT NULL,
  status public.withdraw_request_status NOT NULL DEFAULT 'pending',
  -- Snapshot of clinic bank details at request time.
  bank_name character varying(255) NOT NULL,
  account_number character varying(255) NOT NULL,
  account_name character varying(255) NOT NULL,
  bank_code character varying(255),
  rejection_reason text,
  processed_at timestamp with time zone,
  processed_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT withdraw_requests_amount_positive CHECK (amount > 0),
  CONSTRAINT withdraw_requests_rejection_reason CHECK (
    status <> 'rejected'::public.withdraw_request_status
    OR rejection_reason IS NOT NULL
  ),
  CONSTRAINT withdraw_requests_processed_fields CHECK (
    status = 'pending'::public.withdraw_request_status
    OR (
      processed_at IS NOT NULL
      AND processed_by IS NOT NULL
    )
  )
);

CREATE INDEX withdraw_requests_clinic_id_idx
  ON public.withdraw_requests USING btree (clinic_id);

CREATE INDEX withdraw_requests_status_idx
  ON public.withdraw_requests USING btree (status);

CREATE INDEX withdraw_requests_clinic_status_idx
  ON public.withdraw_requests USING btree (clinic_id, status);

CREATE TRIGGER withdraw_requests_set_updated_at
BEFORE UPDATE ON public.withdraw_requests
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE OR REPLACE FUNCTION public.clinic_withdraw_reserved_amount(p_clinic_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(sum(wr.amount), 0)
  FROM public.withdraw_requests wr
  WHERE
    wr.clinic_id = p_clinic_id
    AND wr.status IN (
      'pending'::public.withdraw_request_status,
      'approved'::public.withdraw_request_status
    );
$$;

CREATE OR REPLACE FUNCTION public.withdraw_request_clinic_has_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  clinic_balance numeric(14, 2);
  reserved_amount numeric(14, 2);
  reserved_excluding_self numeric(14, 2);
BEGIN
  IF TG_OP = 'UPDATE'
    AND OLD.status IN (
      'pending'::public.withdraw_request_status,
      'approved'::public.withdraw_request_status
    )
    AND NEW.status NOT IN (
      'pending'::public.withdraw_request_status,
      'approved'::public.withdraw_request_status
    )
  THEN
    RETURN NEW;
  END IF;

  IF NEW.status NOT IN (
    'pending'::public.withdraw_request_status,
    'approved'::public.withdraw_request_status
  ) THEN
    RETURN NEW;
  END IF;

  SELECT balance INTO clinic_balance
  FROM public.clinic_profiles
  WHERE id = NEW.clinic_id;

  reserved_amount := public.clinic_withdraw_reserved_amount(NEW.clinic_id);

  IF TG_OP = 'UPDATE'
    AND OLD.status IN (
      'pending'::public.withdraw_request_status,
      'approved'::public.withdraw_request_status
    )
  THEN
    reserved_excluding_self := reserved_amount - OLD.amount;
  ELSE
    reserved_excluding_self := reserved_amount;
  END IF;

  IF NEW.amount > (clinic_balance - reserved_excluding_self) THEN
    RAISE EXCEPTION 'withdraw amount exceeds available clinic balance';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER withdraw_requests_clinic_balance_check
BEFORE INSERT OR UPDATE OF clinic_id, amount, status ON public.withdraw_requests
FOR EACH ROW
EXECUTE PROCEDURE public.withdraw_request_clinic_has_balance();

CREATE OR REPLACE FUNCTION public.withdraw_request_processed_by_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.processed_by IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE
      p.id = NEW.processed_by
      AND p.role = 'admin'::public.user_role
  ) THEN
    RAISE EXCEPTION 'processed_by must reference an admin profile';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER withdraw_requests_processed_by_admin_check
BEFORE INSERT OR UPDATE OF processed_by ON public.withdraw_requests
FOR EACH ROW
EXECUTE PROCEDURE public.withdraw_request_processed_by_admin();

CREATE OR REPLACE FUNCTION public.withdraw_request_deduct_clinic_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'completed'::public.withdraw_request_status
    AND OLD.status IS DISTINCT FROM 'completed'::public.withdraw_request_status
  THEN
    UPDATE public.clinic_profiles
    SET balance = balance - NEW.amount
    WHERE id = NEW.clinic_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'clinic not found for withdraw deduction';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER withdraw_requests_deduct_clinic_balance
AFTER UPDATE OF status ON public.withdraw_requests
FOR EACH ROW
EXECUTE PROCEDURE public.withdraw_request_deduct_clinic_balance();
