-- Home service: doctor GPS check-in → in_progress.
-- Clinic service: auto in_progress when scheduled window starts.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS visit_latitude double precision,
  ADD COLUMN IF NOT EXISTS visit_longitude double precision,
  ADD COLUMN IF NOT EXISTS checked_in_at timestamptz;

COMMENT ON COLUMN public.bookings.visit_latitude IS 'Home visit GPS lat (customer pin at booking time).';
COMMENT ON COLUMN public.bookings.visit_longitude IS 'Home visit GPS lng (customer pin at booking time).';
COMMENT ON COLUMN public.bookings.checked_in_at IS 'Doctor check-in timestamp for home service.';

-- Haversine distance in meters (WGS84).
CREATE OR REPLACE FUNCTION public.haversine_meters(
  lat1 double precision,
  lon1 double precision,
  lat2 double precision,
  lon2 double precision
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 6371000.0 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2))
    * power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

-- Auto-start clinic bookings when schedule window is active.
CREATE OR REPLACE FUNCTION public.sync_clinic_bookings_in_progress()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.bookings
  SET status = 'in_progress'::public.booking_status
  WHERE channel = 'clinic'::public.booking_channel
    AND status = 'confirmed'::public.booking_status
    AND scheduled_start_at <= now()
    AND scheduled_end_at > now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_clinic_bookings_in_progress() TO authenticated;

-- Doctor check-in at customer location (home service only).
CREATE OR REPLACE FUNCTION public.doctor_check_in_home_booking(
  p_booking_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_max_radius_meters double precision DEFAULT 200
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
  v_distance double precision;
BEGIN
  PERFORM public.assert_doctor_owns_booking(p_booking_id);

  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
    AND doctor_id = auth.uid();

  IF v_booking.channel IS DISTINCT FROM 'home'::public.booking_channel THEN
    RAISE EXCEPTION 'check-in hanya untuk layanan ke rumah';
  END IF;

  IF v_booking.status IS DISTINCT FROM 'confirmed'::public.booking_status THEN
    RAISE EXCEPTION 'booking tidak dapat di-check-in pada status ini';
  END IF;

  IF v_booking.visit_latitude IS NULL OR v_booking.visit_longitude IS NULL THEN
    RAISE EXCEPTION 'koordinat lokasi kunjungan tidak tersedia';
  END IF;

  IF p_latitude IS NULL OR p_longitude IS NULL THEN
    RAISE EXCEPTION 'koordinat dokter tidak valid';
  END IF;

  IF p_latitude < -90 OR p_latitude > 90 OR p_longitude < -180 OR p_longitude > 180 THEN
    RAISE EXCEPTION 'koordinat dokter tidak valid';
  END IF;

  -- Allow check-in from 30 minutes before start until end.
  IF now() < v_booking.scheduled_start_at - interval '30 minutes' THEN
    RAISE EXCEPTION 'check-in belum dibuka (maks. 30 menit sebelum jadwal)';
  END IF;

  IF now() >= v_booking.scheduled_end_at THEN
    RAISE EXCEPTION 'waktu kunjungan sudah berakhir';
  END IF;

  v_distance := public.haversine_meters(
    p_latitude,
    p_longitude,
    v_booking.visit_latitude,
    v_booking.visit_longitude
  );

  IF v_distance > p_max_radius_meters THEN
    RAISE EXCEPTION 'Anda belum berada di lokasi customer (jarak %.0f m, maks. %.0f m)',
      v_distance, p_max_radius_meters;
  END IF;

  UPDATE public.bookings
  SET
    status = 'in_progress'::public.booking_status,
    checked_in_at = now()
  WHERE id = p_booking_id
    AND doctor_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.doctor_check_in_home_booking(uuid, double precision, double precision, double precision) TO authenticated;

-- Store visit coordinates when creating home bookings.
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
  v_visit_lat double precision;
  v_visit_lng double precision;
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

    v_visit_lat := nullif(p_payload->>'visit_latitude', '')::double precision;
    v_visit_lng := nullif(p_payload->>'visit_longitude', '')::double precision;

    IF v_visit_lat IS NULL OR v_visit_lng IS NULL THEN
      RAISE EXCEPTION 'koordinat lokasi kunjungan wajib untuk layanan rumah';
    END IF;

    IF v_visit_lat < -90 OR v_visit_lat > 90
       OR v_visit_lng < -180 OR v_visit_lng > 180 THEN
      RAISE EXCEPTION 'koordinat lokasi kunjungan tidak valid';
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
    notes,
    visit_latitude,
    visit_longitude
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
    v_notes,
    v_visit_lat,
    v_visit_lng
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

-- Home bookings must use check-in RPC, not manual in_progress.
CREATE OR REPLACE FUNCTION public.doctor_update_booking_status(
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
BEGIN
  PERFORM public.assert_doctor_owns_booking(p_booking_id);

  SELECT status, channel INTO v_current, v_channel
  FROM public.bookings
  WHERE id = p_booking_id;

  IF v_current = 'cancelled'::public.booking_status
     OR v_current = 'completed'::public.booking_status THEN
    RAISE EXCEPTION 'booking status cannot be changed';
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
  ELSIF p_status = 'confirmed'::public.booking_status THEN
    IF v_current <> 'pending'::public.booking_status THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'in_progress'::public.booking_status THEN
    IF v_current <> 'confirmed'::public.booking_status THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'completed'::public.booking_status THEN
    IF v_current NOT IN (
      'confirmed'::public.booking_status,
      'in_progress'::public.booking_status
    ) THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSE
    RAISE EXCEPTION 'invalid target status';
  END IF;

  UPDATE public.bookings
  SET status = p_status
  WHERE id = p_booking_id
    AND doctor_id = auth.uid();

  IF p_status = 'cancelled'::public.booking_status THEN
    PERFORM public.release_booking_doctor_schedule(p_booking_id);
  END IF;
END;
$$;
