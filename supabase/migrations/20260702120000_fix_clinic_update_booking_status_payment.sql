-- Fix payment lookup (reference_type + reference_id, not booking_id).
-- Paid bookings cannot be cancelled from the clinic portal.

CREATE OR REPLACE FUNCTION public.clinic_update_booking_status(
  p_booking_id uuid,
  p_status public.booking_status
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current public.booking_status;
  v_channel public.booking_channel;
  v_payment_status text;
BEGIN
  PERFORM public.assert_clinic_owns_booking(p_booking_id);

  SELECT b.status, b.channel, pay.status
  INTO v_current, v_channel, v_payment_status
  FROM public.bookings b
  LEFT JOIN LATERAL (
    SELECT p.status::text AS status
    FROM public.payments p
    WHERE p.reference_type = 'booking'::public.payment_reference_type
      AND p.reference_id = b.id
    ORDER BY p.created_at DESC
    LIMIT 1
  ) pay ON true
  WHERE b.id = p_booking_id;

  IF v_current = 'cancelled'::public.booking_status
     OR v_current = 'completed'::public.booking_status THEN
    RAISE EXCEPTION 'booking status cannot be changed';
  END IF;

  IF p_status = v_current THEN
    RETURN;
  END IF;

  IF p_status = 'in_progress'::public.booking_status
     AND v_channel = 'home'::public.booking_channel THEN
    RAISE EXCEPTION 'gunakan check-in di lokasi untuk layanan ke rumah';
  END IF;

  IF p_status = 'cancelled'::public.booking_status THEN
    IF v_current NOT IN (
      'pending'::public.booking_status,
      'confirmed'::public.booking_status
    ) THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
    IF v_payment_status = 'paid' THEN
      RAISE EXCEPTION 'booking sudah dibayar, tidak dapat dibatalkan';
    END IF;
  ELSIF p_status = 'confirmed'::public.booking_status THEN
    IF v_current <> 'pending'::public.booking_status THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
    IF v_payment_status IS NOT NULL AND v_payment_status <> 'paid' THEN
      RAISE EXCEPTION 'pembayaran belum lunas';
    END IF;
  ELSIF p_status = 'in_progress'::public.booking_status THEN
    IF v_current <> 'confirmed'::public.booking_status
       OR v_channel <> 'clinic'::public.booking_channel THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'completed'::public.booking_status THEN
    IF v_current NOT IN (
      'confirmed'::public.booking_status,
      'in_progress'::public.booking_status
    ) THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'pending'::public.booking_status THEN
    RAISE EXCEPTION 'invalid target status';
  ELSE
    RAISE EXCEPTION 'invalid target status';
  END IF;

  UPDATE public.bookings
  SET status = p_status
  WHERE id = p_booking_id
    AND clinic_id = auth.uid();

  IF p_status = 'cancelled'::public.booking_status THEN
    PERFORM public.release_booking_doctor_schedule(p_booking_id);
  END IF;
END;
$$;
