-- Customer booking: slots RPC, create booking + payment, RLS, doctor_schedules read.

-- ---------------------------------------------------------------------------
-- doctor_schedules: customer read at verified clinics
-- ---------------------------------------------------------------------------
ALTER TABLE public.doctor_schedules ENABLE ROW LEVEL SECURITY;

CREATE POLICY "doctor_schedules_select_customer_discovery"
ON public.doctor_schedules
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    JOIN public.clinic_profiles AS cp ON cp.id = dp.clinic_id
    WHERE dp.id = doctor_schedules.doctor_id
      AND cp.is_verified = true
      AND dp.is_active = true
  )
);

-- ---------------------------------------------------------------------------
-- payments: customer read own
-- ---------------------------------------------------------------------------
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "payments_select_own"
ON public.payments
FOR SELECT
TO authenticated
USING (customer_id = auth.uid());

-- ---------------------------------------------------------------------------
-- get_booking_slots
-- p_date: calendar date (interpreted as Asia/Jakarta local date)
-- ---------------------------------------------------------------------------
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
  v_slot_end timestamptz;
  v_period record;
  v_step interval := interval '30 minutes';
  v_cursor time;
  v_close_time time;
  v_doctor_ids uuid[];
  v_result jsonb := '[]'::jsonb;
  v_time_label text;
BEGIN
  IF p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
    RAISE EXCEPTION 'duration_minutes must be positive';
  END IF;

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
    v_close_time := v_period.closes_at;

    WHILE v_cursor + (p_duration_minutes || ' minutes')::interval <= v_close_time LOOP
      v_slot_start := (p_date + v_cursor) AT TIME ZONE 'Asia/Jakarta';
      v_slot_end := v_slot_start + (p_duration_minutes || ' minutes')::interval;

      IF v_slot_start > v_now THEN
        SELECT coalesce(array_agg(DISTINCT ds.doctor_id), ARRAY[]::uuid[])
        INTO v_doctor_ids
        FROM public.doctor_profiles AS dp
        JOIN public.doctor_schedules AS ds ON ds.doctor_id = dp.id
        WHERE dp.clinic_id = p_clinic_id
          AND dp.is_active = true
          AND ds.booking_id IS NULL
          AND ds.consultation_id IS NULL
          AND ds.starts_at <= v_slot_start
          AND ds.ends_at >= v_slot_end
          AND NOT EXISTS (
            SELECT 1
            FROM public.bookings AS b
            WHERE b.doctor_id = dp.id
              AND b.status IN (
                'pending'::public.booking_status,
                'confirmed'::public.booking_status,
                'in_progress'::public.booking_status
              )
              AND b.scheduled_start_at < v_slot_end
              AND b.scheduled_end_at > v_slot_start
          );

        IF cardinality(v_doctor_ids) > 0 THEN
          v_time_label := to_char(v_cursor, 'HH24:MI');
          v_result := v_result || jsonb_build_array(
            jsonb_build_object(
              'start_at', v_slot_start,
              'end_at', v_slot_end,
              'time_label', v_time_label,
              'available_doctor_ids', to_jsonb(v_doctor_ids)
            )
          );
        END IF;
      END IF;

      v_cursor := v_cursor + v_step;
    END LOOP;
  END LOOP;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_slots(uuid, date, integer, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- create_booking_payment
-- ---------------------------------------------------------------------------
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
  v_schedule_id uuid := nullif(p_payload->>'doctor_schedule_id', '')::uuid;
  v_service_ids uuid[];
  v_booking_id uuid;
  v_payment_id uuid;
  v_total numeric(14, 2) := 0;
  v_consultation_fee numeric(14, 2) := 0;
  v_svc record;
  v_line_total numeric(14, 2);
  v_midtrans_order_id text;
  v_home_notes text;
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

  SELECT dp.consultation_fee INTO v_consultation_fee
  FROM public.doctor_profiles dp
  WHERE dp.id = v_doctor_id;

  v_total := v_total + coalesce(v_consultation_fee, 0);

  IF v_channel = 'home' THEN
    v_home_notes := trim(coalesce(p_payload->>'customer_address', ''));
    IF v_home_notes <> '' THEN
      v_notes := coalesce(v_notes || E'\n', '') || 'Alamat kunjungan: ' || v_home_notes;
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.doctor_schedules ds
    WHERE ds.doctor_id = v_doctor_id
      AND ds.booking_id IS NULL
      AND ds.consultation_id IS NULL
      AND ds.starts_at <= v_start
      AND ds.ends_at >= v_end
  ) THEN
    RAISE EXCEPTION 'doctor not available for selected slot';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.doctor_id = v_doctor_id
      AND b.status IN ('pending', 'confirmed', 'in_progress')
      AND b.scheduled_start_at < v_end
      AND b.scheduled_end_at > v_start
  ) THEN
    RAISE EXCEPTION 'slot already booked';
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

  IF v_schedule_id IS NOT NULL THEN
    UPDATE public.doctor_schedules
    SET booking_id = v_booking_id
    WHERE id = v_schedule_id
      AND doctor_id = v_doctor_id
      AND booking_id IS NULL
      AND consultation_id IS NULL
      AND starts_at <= v_start
      AND ends_at >= v_end;
  ELSE
    UPDATE public.doctor_schedules
    SET booking_id = v_booking_id
    WHERE id = (
      SELECT ds.id
      FROM public.doctor_schedules ds
      WHERE ds.doctor_id = v_doctor_id
        AND ds.booking_id IS NULL
        AND ds.consultation_id IS NULL
        AND ds.starts_at <= v_start
        AND ds.ends_at >= v_end
      ORDER BY ds.starts_at
      LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object(
    'booking_id', v_booking_id,
    'payment_id', v_payment_id,
    'amount', v_total,
    'midtrans_order_id', v_midtrans_order_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_booking_payment(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Release doctor schedule when booking cancelled (helper for webhook)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_booking_doctor_schedule(p_booking_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.doctor_schedules
  SET booking_id = NULL
  WHERE booking_id = p_booking_id;
$$;

-- ---------------------------------------------------------------------------
-- Confirm booking after payment (called from webhook via service role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_booking_after_payment(p_payment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ref uuid;
BEGIN
  SELECT reference_id INTO v_ref
  FROM public.payments
  WHERE id = p_payment_id
    AND reference_type = 'booking'::public.payment_reference_type;

  IF v_ref IS NOT NULL THEN
    UPDATE public.bookings
    SET status = 'confirmed'::public.booking_status
    WHERE id = v_ref AND status = 'pending'::public.booking_status;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_booking_after_payment_failed(p_payment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ref uuid;
BEGIN
  SELECT reference_id INTO v_ref
  FROM public.payments
  WHERE id = p_payment_id
    AND reference_type = 'booking'::public.payment_reference_type;

  IF v_ref IS NOT NULL THEN
    UPDATE public.bookings
    SET status = 'cancelled'::public.booking_status
    WHERE id = v_ref AND status = 'pending'::public.booking_status;

    PERFORM public.release_booking_doctor_schedule(v_ref);
  END IF;
END;
$$;
