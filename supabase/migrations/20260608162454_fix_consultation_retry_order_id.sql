-- Perbaiki order_id Midtrans saat bayar ulang konsultasi (maks. 50 karakter).
-- Format lama: PLK-{uuid32}-{YYYYMMDDHH24MISS} = 52 karakter → Midtrans 400.

CREATE OR REPLACE FUNCTION public.retry_consultation_payment(p_consultation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_consultation public.consultations%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_new_order_id text;
  v_retry_suffix text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT * INTO v_consultation
  FROM public.consultations
  WHERE id = p_consultation_id
    AND customer_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'konsultasi tidak ditemukan';
  END IF;

  IF v_consultation.status <> 'pending_payment'::public.consultation_status THEN
    RAISE EXCEPTION 'hanya konsultasi menunggu pembayaran yang dapat dibayar ulang';
  END IF;

  IF v_consultation.scheduled_start_at <= now() THEN
    RAISE EXCEPTION 'jadwal sudah lewat, tidak dapat melakukan pembayaran ulang';
  END IF;

  SELECT * INTO v_payment
  FROM public.payments
  WHERE reference_type = 'consultation'::public.payment_reference_type
    AND reference_id = p_consultation_id
    AND customer_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'data pembayaran tidak ditemukan';
  END IF;

  IF v_payment.status NOT IN (
    'pending'::public.payment_status,
    'failed'::public.payment_status,
    'expired'::public.payment_status
  ) THEN
    RAISE EXCEPTION 'status pembayaran tidak mendukung pembayaran ulang';
  END IF;

  -- MMDDHH24MISS (10) → PLK-{uuid32}-{suffix} = 48 karakter.
  v_retry_suffix := to_char(now() AT TIME ZONE 'UTC', 'MMDDHH24MISS');
  v_new_order_id :=
    'PLK-' || replace(p_consultation_id::text, '-', '') || '-' || v_retry_suffix;

  UPDATE public.payments
  SET
    status = 'pending'::public.payment_status,
    midtrans_order_id = v_new_order_id,
    midtrans_transaction_id = NULL,
    midtrans_payment_type = NULL,
    midtrans_raw_response = NULL,
    paid_at = NULL,
    payment_method = NULL,
    updated_at = now()
  WHERE id = v_payment.id;

  RETURN jsonb_build_object(
    'consultation_id', p_consultation_id,
    'payment_id', v_payment.id,
    'amount', v_payment.amount,
    'midtrans_order_id', v_new_order_id,
    'chat_thread_id', v_consultation.chat_thread_id
  );
END;
$$;
