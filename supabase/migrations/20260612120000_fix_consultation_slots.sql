-- Perbaikan slot konsultasi: selaraskan dengan booking health service.
-- doctor_schedules = blok sibuk / booking / konsultasi. Tanpa overlap = dokter free.

CREATE OR REPLACE FUNCTION public.is_doctor_available_for_consultation(
  p_doctor_id uuid,
  p_start timestamptz,
  p_end timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    JOIN public.clinic_profiles AS cp ON cp.id = dp.clinic_id
    WHERE dp.id = p_doctor_id
      AND dp.is_active = true
      AND cp.is_verified = true
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.doctor_schedules AS ds
    WHERE ds.doctor_id = p_doctor_id
      AND ds.starts_at < p_end
      AND ds.ends_at > p_start
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = p_doctor_id
      AND b.status IN (
        'pending'::public.booking_status,
        'confirmed'::public.booking_status,
        'in_progress'::public.booking_status
      )
      AND b.scheduled_start_at < p_end
      AND b.scheduled_end_at > p_start
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.doctor_id = p_doctor_id
      AND c.status IN (
        'pending_payment'::public.consultation_status,
        'scheduled'::public.consultation_status,
        'in_progress'::public.consultation_status
      )
      AND c.scheduled_start_at < p_end
      AND c.scheduled_end_at > p_start
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_doctor_available_for_consultation(uuid, timestamptz, timestamptz)
  TO authenticated;

-- Kembalikan semua jam operasional + flag is_available (mirror get_booking_slots).
CREATE OR REPLACE FUNCTION public.get_consultation_slots(
  p_doctor_id uuid,
  p_date date,
  p_duration_minutes integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clinic_id uuid;
  v_day smallint;
  v_is_closed boolean;
  v_now timestamptz := now();
  v_slot_start timestamptz;
  v_slot_end timestamptz;
  v_period record;
  v_cursor time;
  v_result jsonb := '[]'::jsonb;
  v_duration int;
  v_is_available boolean;
BEGIN
  v_duration := greatest(coalesce(p_duration_minutes, 0), 1);

  SELECT dp.clinic_id INTO v_clinic_id
  FROM public.doctor_profiles AS dp
  JOIN public.clinic_profiles AS cp ON cp.id = dp.clinic_id
  WHERE dp.id = p_doctor_id
    AND dp.is_active = true
    AND cp.is_verified = true;

  IF v_clinic_id IS NULL THEN
    RAISE EXCEPTION 'doctor not found or inactive';
  END IF;

  v_day := EXTRACT(ISODOW FROM p_date)::smallint;

  SELECT coh.is_closed INTO v_is_closed
  FROM public.clinic_opening_hours AS coh
  WHERE coh.clinic_id = v_clinic_id AND coh.day_of_week = v_day;

  IF NOT FOUND OR v_is_closed THEN
    RETURN v_result;
  END IF;

  FOR v_period IN
    SELECT p.opens_at, p.closes_at
    FROM public.clinic_opening_hours AS coh
    JOIN public.clinic_opening_hour_periods AS p ON p.clinic_opening_hours_id = coh.id
    WHERE coh.clinic_id = v_clinic_id
      AND coh.day_of_week = v_day
      AND coh.is_closed = false
    ORDER BY p.sort_order, p.opens_at
  LOOP
    v_cursor := v_period.opens_at;

    WHILE v_cursor < v_period.closes_at LOOP
      v_slot_start := (p_date + v_cursor) AT TIME ZONE 'Asia/Jakarta';
      v_slot_end := v_slot_start + (v_duration || ' minutes')::interval;

      IF (p_date + v_period.closes_at) AT TIME ZONE 'Asia/Jakarta' < v_slot_end THEN
        EXIT;
      END IF;

      v_is_available :=
        v_slot_start > v_now
        AND public.is_doctor_available_for_consultation(
          p_doctor_id,
          v_slot_start,
          v_slot_end
        );

      v_result := v_result || jsonb_build_array(
        jsonb_build_object(
          'start_at', v_slot_start,
          'end_at', v_slot_end,
          'time_label', to_char(v_cursor, 'HH24:MI'),
          'is_available', v_is_available
        )
      );

      v_cursor := v_cursor + interval '1 hour';
    END LOOP;
  END LOOP;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_consultation_available_dates(
  p_doctor_id uuid,
  p_from date,
  p_to date,
  p_duration_minutes integer DEFAULT 30
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
    v_slots := public.get_consultation_slots(p_doctor_id, v_d, p_duration_minutes);
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

CREATE OR REPLACE FUNCTION public.release_consultation_doctor_schedule(p_consultation_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.doctor_schedules
  WHERE consultation_id = p_consultation_id;
$$;

CREATE OR REPLACE FUNCTION public.create_consultation_payment(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doctor_id uuid := (p_payload->>'doctor_id')::uuid;
  v_clinic_id uuid := (p_payload->>'clinic_id')::uuid;
  v_start timestamptz := (p_payload->>'scheduled_start_at')::timestamptz;
  v_end timestamptz := (p_payload->>'scheduled_end_at')::timestamptz;
  v_notes text := nullif(trim(p_payload->>'notes'), '');
  v_consultation_id uuid;
  v_payment_id uuid;
  v_thread_id uuid;
  v_fee numeric(14, 2);
  v_midtrans_order_id text;
  v_doctor_clinic uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
    RAISE EXCEPTION 'invalid schedule';
  END IF;

  IF v_start <= now() THEN
    RAISE EXCEPTION 'schedule must be in the future';
  END IF;

  SELECT dp.clinic_id, dp.consultation_fee
  INTO v_doctor_clinic, v_fee
  FROM public.doctor_profiles AS dp
  JOIN public.clinic_profiles AS cp ON cp.id = dp.clinic_id
  WHERE dp.id = v_doctor_id
    AND dp.is_active = true
    AND cp.is_verified = true
    AND cp.id = v_clinic_id;

  IF v_doctor_clinic IS NULL THEN
    RAISE EXCEPTION 'invalid doctor for clinic';
  END IF;

  IF coalesce(v_fee, 0) <= 0 THEN
    RAISE EXCEPTION 'consultation fee not configured';
  END IF;

  IF NOT public.is_doctor_available_for_consultation(v_doctor_id, v_start, v_end) THEN
    RAISE EXCEPTION 'doctor not available for selected slot';
  END IF;

  INSERT INTO public.chat_threads (user_1_id, user_2_id, type, is_active)
  VALUES (v_uid, v_doctor_id, 'consultation'::public.chat_thread_type, true)
  RETURNING id INTO v_thread_id;

  INSERT INTO public.consultations (
    customer_id,
    doctor_id,
    clinic_id,
    chat_thread_id,
    status,
    scheduled_start_at,
    scheduled_end_at,
    consultation_fee,
    notes
  ) VALUES (
    v_uid,
    v_doctor_id,
    v_clinic_id,
    v_thread_id,
    'pending_payment'::public.consultation_status,
    v_start,
    v_end,
    v_fee,
    v_notes
  )
  RETURNING id INTO v_consultation_id;

  v_midtrans_order_id := 'PLK-' || replace(v_consultation_id::text, '-', '');

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
    'consultation'::public.payment_reference_type,
    v_consultation_id,
    v_fee,
    'pending'::public.payment_status,
    v_midtrans_order_id
  )
  RETURNING id INTO v_payment_id;

  INSERT INTO public.doctor_schedules (
    doctor_id,
    starts_at,
    ends_at,
    consultation_id
  ) VALUES (
    v_doctor_id,
    v_start,
    v_end,
    v_consultation_id
  );

  RETURN jsonb_build_object(
    'consultation_id', v_consultation_id,
    'payment_id', v_payment_id,
    'chat_thread_id', v_thread_id,
    'amount', v_fee,
    'midtrans_order_id', v_midtrans_order_id
  );
END;
$$;
