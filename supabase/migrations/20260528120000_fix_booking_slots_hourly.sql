-- Perbaikan booking slots (setelah 20260527120000):
-- - Slot per jam sesuai jam buka klinik; kembalikan semua jam + flag is_available.
-- - doctor_schedules = acara/blok waktu dokter (sibuk). Tanpa baris overlap = dokter free.

CREATE OR REPLACE FUNCTION public.doctors_available_for_booking(
  p_clinic_id uuid,
  p_start timestamptz,
  p_end timestamptz
)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(DISTINCT dp.id), ARRAY[]::uuid[])
  FROM public.doctor_profiles AS dp
  WHERE dp.clinic_id = p_clinic_id
    AND dp.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.doctor_schedules AS ds
      WHERE ds.doctor_id = dp.id
        AND ds.starts_at < p_end
        AND ds.ends_at > p_start
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.bookings AS b
      WHERE b.doctor_id = dp.id
        AND b.status IN (
          'pending'::public.booking_status,
          'confirmed'::public.booking_status,
          'in_progress'::public.booking_status
        )
        AND b.scheduled_start_at < p_end
        AND b.scheduled_end_at > p_start
    );
$$;

CREATE OR REPLACE FUNCTION public.get_booking_slots(
  p_clinic_id uuid,
  p_date date,
  p_duration_minutes integer,
  p_channel text DEFAULT 'clinic'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day smallint;
  v_is_closed boolean;
  v_now timestamptz := now();
  v_slot_start timestamptz;
  v_service_end timestamptz;
  v_period record;
  v_cursor time;
  v_doctor_ids uuid[];
  v_result jsonb := '[]'::jsonb;
  v_duration int;
  v_is_available boolean;
BEGIN
  v_duration := greatest(coalesce(p_duration_minutes, 0), 1);

  IF p_channel NOT IN ('clinic', 'home') THEN
    RAISE EXCEPTION 'invalid channel';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.clinic_profiles cp
    WHERE cp.id = p_clinic_id AND cp.is_verified = true
  ) THEN
    RAISE EXCEPTION 'clinic not found or not verified';
  END IF;

  v_day := EXTRACT(ISODOW FROM p_date)::smallint;

  SELECT coh.is_closed INTO v_is_closed
  FROM public.clinic_opening_hours AS coh
  WHERE coh.clinic_id = p_clinic_id AND coh.day_of_week = v_day;

  IF NOT FOUND OR v_is_closed THEN
    RETURN v_result;
  END IF;

  FOR v_period IN
    SELECT p.opens_at, p.closes_at
    FROM public.clinic_opening_hours AS coh
    JOIN public.clinic_opening_hour_periods AS p ON p.clinic_opening_hours_id = coh.id
    WHERE coh.clinic_id = p_clinic_id
      AND coh.day_of_week = v_day
      AND coh.is_closed = false
    ORDER BY p.sort_order, p.opens_at
  LOOP
    v_cursor := v_period.opens_at;

    WHILE v_cursor < v_period.closes_at LOOP
      v_slot_start := (p_date + v_cursor) AT TIME ZONE 'Asia/Jakarta';
      v_service_end := v_slot_start + (v_duration || ' minutes')::interval;

      IF (p_date + v_period.closes_at) AT TIME ZONE 'Asia/Jakarta' < v_service_end THEN
        EXIT;
      END IF;

      v_doctor_ids := public.doctors_available_for_booking(
        p_clinic_id,
        v_slot_start,
        v_service_end
      );

      v_is_available := cardinality(v_doctor_ids) > 0 AND v_slot_start > v_now;

      v_result := v_result || jsonb_build_array(
        jsonb_build_object(
          'start_at', v_slot_start,
          'end_at', v_service_end,
          'time_label', to_char(v_cursor, 'HH24:MI'),
          'is_available', v_is_available,
          'available_doctor_ids', to_jsonb(
            CASE WHEN v_is_available THEN v_doctor_ids ELSE ARRAY[]::uuid[] END
          )
        )
      );

      v_cursor := v_cursor + interval '1 hour';
    END LOOP;
  END LOOP;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_booking_available_dates(
  p_clinic_id uuid,
  p_from date,
  p_to date,
  p_duration_minutes integer,
  p_channel text DEFAULT 'clinic'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_d date;
  v_slots jsonb;
  v_out jsonb := '[]'::jsonb;
BEGIN
  v_d := p_from;
  WHILE v_d <= p_to LOOP
    v_slots := public.get_booking_slots(
      p_clinic_id, v_d, p_duration_minutes, p_channel
    );
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_slots) AS elem
      WHERE (elem->>'is_available')::boolean = true
    ) THEN
      v_out := v_out || jsonb_build_array(to_char(v_d, 'YYYY-MM-DD'));
    END IF;
    v_d := v_d + 1;
  END LOOP;

  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_available_dates(uuid, date, date, integer, text)
  TO authenticated;

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

CREATE OR REPLACE FUNCTION public.release_booking_doctor_schedule(p_booking_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.doctor_schedules
  WHERE booking_id = p_booking_id;
$$;
