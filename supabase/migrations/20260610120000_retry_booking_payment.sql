-- Customer: retry Midtrans payment for unpaid / failed / expired bookings.

CREATE OR REPLACE FUNCTION public.retry_booking_payment(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_new_order_id text;
  v_retry_suffix text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
    AND customer_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pemesanan tidak ditemukan';
  END IF;

  IF v_booking.status <> 'pending'::public.booking_status THEN
    RAISE EXCEPTION 'hanya pemesanan menunggu pembayaran yang dapat dibayar ulang';
  END IF;

  IF v_booking.scheduled_start_at <= now() THEN
    RAISE EXCEPTION 'jadwal sudah lewat, tidak dapat melakukan pembayaran ulang';
  END IF;

  SELECT * INTO v_payment
  FROM public.payments
  WHERE reference_type = 'booking'::public.payment_reference_type
    AND reference_id = p_booking_id
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

  v_retry_suffix := to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');
  v_new_order_id :=
    'PL-' || replace(p_booking_id::text, '-', '') || '-' || v_retry_suffix;

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
    'booking_id', p_booking_id,
    'payment_id', v_payment.id,
    'amount', v_payment.amount,
    'midtrans_order_id', v_new_order_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.retry_booking_payment(uuid) TO authenticated;
