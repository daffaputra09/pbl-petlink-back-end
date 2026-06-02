-- Total booking = jumlah layanan saja (tanpa consultation_fee dokter).

CREATE OR REPLACE FUNCTION public.create_booking_payment(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_clinic_id uuid := (p_payload->>'clinic_id')::uuid;
  v_pet_id uuid := (p_payload->>'pet_id')::uuid;
  v_doctor_id uuid := (p_payload->>'doctor_id')::uuid;
  v_channel text := p_payload->>'channel';
  v_start timestamptz := (p_payload->>'scheduled_start_at')::timestamptz;
  v_end timestamptz := (p_payload->>'scheduled_end_at')::timestamptz;
  v_notes text := nullif(trim(p_payload->>'notes'), '');
  v_service_ids uuid[];
  v_booking_id uuid;
  v_payment_id uuid;
  v_total numeric(14, 2) := 0;
  v_svc record;
  v_line_total numeric(14, 2);
  v_midtrans_order_id text;
  v_home_notes text;
  v_available uuid[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF v_channel NOT IN ('clinic', 'home') THEN
    RAISE EXCEPTION 'invalid channel';
  END IF;

  SELECT coalesce(array_agg(x::uuid), ARRAY[]::uuid[])
  INTO v_service_ids
  FROM jsonb_array_elements_text(p_payload->'service_ids') AS t(x);

  IF cardinality(v_service_ids) = 0 THEN
    RAISE EXCEPTION 'at least one service required';
  END IF;

  IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
    RAISE EXCEPTION 'invalid schedule';
  END IF;

  IF v_start <= now() THEN
    RAISE EXCEPTION 'schedule must be in the future';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.customer_pets cp
    WHERE cp.id = v_pet_id AND cp.customer_id = v_uid AND cp.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'invalid pet';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.doctor_profiles dp
    WHERE dp.id = v_doctor_id
      AND dp.clinic_id = v_clinic_id
      AND dp.is_active = true
  ) THEN
    RAISE EXCEPTION 'invalid doctor for clinic';
  END IF;

  FOR v_svc IN
    SELECT s.id, s.price, s.duration_minutes, s.is_home_service, s.is_clinic_service
    FROM public.services AS s
    WHERE s.id = ANY (v_service_ids)
      AND s.clinic_id = v_clinic_id
      AND s.is_active = true
  LOOP
    IF v_channel = 'clinic' AND v_svc.is_clinic_service IS NOT TRUE THEN
      RAISE EXCEPTION 'service not available for clinic visit';
    END IF;
    IF v_channel = 'home' AND v_svc.is_home_service IS NOT TRUE THEN
      RAISE EXCEPTION 'service not available for home visit';
    END IF;
    v_line_total := v_svc.price;
    v_total := v_total + v_line_total;
  END LOOP;

  IF (
    SELECT count(*)::int FROM public.services s
    WHERE s.id = ANY (v_service_ids) AND s.clinic_id = v_clinic_id AND s.is_active = true
  ) <> cardinality(v_service_ids) THEN
    RAISE EXCEPTION 'invalid service selection';
  END IF;

  IF v_channel = 'home' THEN
    v_home_notes := trim(coalesce(p_payload->>'customer_address', ''));
    IF v_home_notes <> '' THEN
      v_notes := coalesce(v_notes || E'\n', '') || 'Alamat kunjungan: ' || v_home_notes;
    END IF;
  END IF;

  v_available := public.doctors_available_for_booking(v_clinic_id, v_start, v_end);

  IF NOT (v_doctor_id = ANY (v_available)) THEN
    RAISE EXCEPTION 'doctor not available for selected slot';
  END IF;

  INSERT INTO public.bookings (
    customer_id,
    pet_id,
    clinic_id,
    doctor_id,
    channel,
    scheduled_start_at,
    scheduled_end_at,
    status,
    total_amount,
    notes
  ) VALUES (
    v_uid,
    v_pet_id,
    v_clinic_id,
    v_doctor_id,
    v_channel::public.booking_channel,
    v_start,
    v_end,
    'pending'::public.booking_status,
    v_total,
    v_notes
  )
  RETURNING id INTO v_booking_id;

  FOR v_svc IN
    SELECT s.id, s.price, s.duration_minutes
    FROM public.services AS s
    WHERE s.id = ANY (v_service_ids)
  LOOP
    v_line_total := v_svc.price;
    INSERT INTO public.booking_items (
      booking_id,
      service_id,
      quantity,
      unit_price,
      line_total,
      duration_minutes
    ) VALUES (
      v_booking_id,
      v_svc.id,
      1,
      v_svc.price,
      v_line_total,
      v_svc.duration_minutes
    );
  END LOOP;

  v_midtrans_order_id := 'PL-' || replace(v_booking_id::text, '-', '');

  INSERT INTO public.payments (
    customer_id,
    clinic_id,
    reference_type,
    reference_id,
    amount,
    status,
    midtrans_order_id
  ) VALUES (
    v_uid,
    v_clinic_id,
    'booking'::public.payment_reference_type,
    v_booking_id,
    v_total,
    'pending'::public.payment_status,
    v_midtrans_order_id
  )
  RETURNING id INTO v_payment_id;

  INSERT INTO public.doctor_schedules (
    doctor_id,
    starts_at,
    ends_at,
    booking_id
  ) VALUES (
    v_doctor_id,
    v_start,
    v_end,
    v_booking_id
  );

  RETURN jsonb_build_object(
    'booking_id', v_booking_id,
    'payment_id', v_payment_id,
    'amount', v_total,
    'midtrans_order_id', v_midtrans_order_id
  );
END;
$$;

-- Finalisasi pembayaran dari app setelah Midtrans sukses (tanpa edge function).
CREATE OR REPLACE FUNCTION public.finalize_booking_payment(p_payment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  UPDATE public.payments
  SET
    status = 'paid'::public.payment_status,
    paid_at = now()
  WHERE id = p_payment_id
    AND customer_id = auth.uid()
    AND status = 'pending'::public.payment_status;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM public.confirm_booking_after_payment(p_payment_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.finalize_booking_payment(uuid) TO authenticated;
