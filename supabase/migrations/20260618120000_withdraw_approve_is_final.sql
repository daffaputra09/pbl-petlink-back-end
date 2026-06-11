-- Persetujuan admin = penarikan selesai. Saldo dipotong saat approved (bukan completed).

-- Backfill: approved yang belum pernah memotong saldo (trigger lama hanya pada completed).
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT wr.clinic_id, wr.amount
    FROM public.withdraw_requests wr
    WHERE wr.status = 'approved'::public.withdraw_request_status
  LOOP
    UPDATE public.clinic_profiles
    SET balance = balance - r.amount
    WHERE id = r.clinic_id;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.clinic_withdraw_reserved_amount(p_clinic_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(sum(wr.amount), 0)
  FROM public.withdraw_requests wr
  WHERE
    wr.clinic_id = p_clinic_id
    AND wr.status = 'pending'::public.withdraw_request_status;
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
  IF NEW.status <> 'pending'::public.withdraw_request_status THEN
    RETURN NEW;
  END IF;

  SELECT balance INTO clinic_balance
  FROM public.clinic_profiles
  WHERE id = NEW.clinic_id;

  reserved_amount := public.clinic_withdraw_reserved_amount(NEW.clinic_id);

  IF TG_OP = 'UPDATE'
    AND OLD.status = 'pending'::public.withdraw_request_status
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

CREATE OR REPLACE FUNCTION public.withdraw_request_deduct_clinic_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'approved'::public.withdraw_request_status
    AND OLD.status = 'pending'::public.withdraw_request_status
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

CREATE OR REPLACE FUNCTION public.admin_process_withdraw_request(
  p_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.withdraw_requests%ROWTYPE;
  v_action text := lower(trim(p_action));
BEGIN
  PERFORM public.assert_is_admin();

  SELECT * INTO v_row
  FROM public.withdraw_requests
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'withdraw request not found';
  END IF;

  IF v_action = 'approve' THEN
    IF v_row.status <> 'pending'::public.withdraw_request_status THEN
      RAISE EXCEPTION 'only pending requests can be approved';
    END IF;
    UPDATE public.withdraw_requests
    SET
      status = 'approved'::public.withdraw_request_status,
      processed_at = now(),
      processed_by = auth.uid(),
      rejection_reason = NULL
    WHERE id = p_id;

  ELSIF v_action = 'reject' THEN
    IF v_row.status <> 'pending'::public.withdraw_request_status THEN
      RAISE EXCEPTION 'only pending requests can be rejected';
    END IF;
    IF p_rejection_reason IS NULL OR trim(p_rejection_reason) = '' THEN
      RAISE EXCEPTION 'rejection reason is required';
    END IF;
    UPDATE public.withdraw_requests
    SET
      status = 'rejected'::public.withdraw_request_status,
      rejection_reason = trim(p_rejection_reason),
      processed_at = now(),
      processed_by = auth.uid()
    WHERE id = p_id;

  ELSE
    RAISE EXCEPTION 'invalid action: use approve or reject';
  END IF;
END;
$$;
