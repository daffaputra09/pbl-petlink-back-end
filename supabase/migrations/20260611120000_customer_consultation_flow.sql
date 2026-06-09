-- Customer online consultation: slot discovery, create payment, finalize, retry.

-- ---------------------------------------------------------------------------
-- get_consultation_slots — slot 30 menit untuk dokter tertentu
-- ---------------------------------------------------------------------------
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
  v_step interval := interval '30 minutes';
  v_cursor time;
  v_close_time time;
  v_result jsonb := '[]'::jsonb;
  v_time_label text;
  v_available boolean;
BEGIN
  IF p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
    RAISE EXCEPTION 'duration_minutes must be positive';
  END IF;

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
    v_close_time := v_period.closes_at;

    WHILE v_cursor + (p_duration_minutes || ' minutes')::interval <= v_close_time LOOP
      v_slot_start := (p_date + v_cursor) AT TIME ZONE 'Asia/Jakarta';
      v_slot_end := v_slot_start + (p_duration_minutes || ' minutes')::interval;

      v_available := false;

      IF v_slot_start > v_now THEN
        v_available := EXISTS (
          SELECT 1
          FROM public.doctor_schedules AS ds
          WHERE ds.doctor_id = p_doctor_id
            AND ds.booking_id IS NULL
            AND ds.consultation_id IS NULL
            AND ds.starts_at <= v_slot_start
            AND ds.ends_at >= v_slot_end
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
            AND b.scheduled_start_at < v_slot_end
            AND b.scheduled_end_at > v_slot_start
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
            AND c.scheduled_start_at < v_slot_end
            AND c.scheduled_end_at > v_slot_start
        );
      END IF;

      IF v_available THEN
        v_time_label := to_char(v_cursor, 'HH24:MI');
        v_result := v_result || jsonb_build_array(
          jsonb_build_object(
            'start_at', v_slot_start,
            'end_at', v_slot_end,
            'time_label', v_time_label,
            'is_available', true
          )
        );
      END IF;

      v_cursor := v_cursor + v_step;
    END LOOP;
  END LOOP;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_consultation_slots(uuid, date, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_consultation_available_dates
-- ---------------------------------------------------------------------------
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
    IF jsonb_array_length(v_slots) > 0 THEN
      v_out := v_out || jsonb_build_array(to_char(v_d, 'YYYY-MM-DD'));
    END IF;
    v_d := v_d + 1;
  END LOOP;
  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_consultation_available_dates(uuid, date, date, integer)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- release_consultation_doctor_schedule
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_consultation_doctor_schedule(p_consultation_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.doctor_schedules
  SET consultation_id = NULL
  WHERE consultation_id = p_consultation_id;
$$;

-- ---------------------------------------------------------------------------
-- confirm / cancel after payment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_consultation_after_payment(p_payment_id uuid)
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
    AND reference_type = 'consultation'::public.payment_reference_type;

  IF v_ref IS NOT NULL THEN
    UPDATE public.consultations
    SET status = 'scheduled'::public.consultation_status
    WHERE id = v_ref
      AND status = 'pending_payment'::public.consultation_status;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_consultation_after_payment_failed(p_payment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ref uuid;
  v_thread_id uuid;
BEGIN
  SELECT reference_id INTO v_ref
  FROM public.payments
  WHERE id = p_payment_id
    AND reference_type = 'consultation'::public.payment_reference_type;

  IF v_ref IS NOT NULL THEN
    SELECT chat_thread_id INTO v_thread_id
    FROM public.consultations
    WHERE id = v_ref;

    UPDATE public.consultations
    SET status = 'cancelled'::public.consultation_status
    WHERE id = v_ref
      AND status = 'pending_payment'::public.consultation_status;

    PERFORM public.release_consultation_doctor_schedule(v_ref);

    IF v_thread_id IS NOT NULL THEN
      UPDATE public.chat_threads
      SET is_active = false
      WHERE id = v_thread_id;
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_consultation_payment(p_payment_id uuid)
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
    AND reference_type = 'consultation'::public.payment_reference_type
    AND status = 'pending'::public.payment_status;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM public.confirm_consultation_after_payment(p_payment_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.finalize_consultation_payment(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- create_consultation_payment
-- ---------------------------------------------------------------------------
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.doctor_schedules AS ds
    WHERE ds.doctor_id = v_doctor_id
      AND ds.booking_id IS NULL
      AND ds.consultation_id IS NULL
      AND ds.starts_at <= v_start
      AND ds.ends_at >= v_end
  ) THEN
    RAISE EXCEPTION 'doctor not available for selected slot';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bookings AS b
    WHERE b.doctor_id = v_doctor_id
      AND b.status IN ('pending', 'confirmed', 'in_progress')
      AND b.scheduled_start_at < v_end
      AND b.scheduled_end_at > v_start
  ) THEN
    RAISE EXCEPTION 'slot already booked';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.consultations AS c
    WHERE c.doctor_id = v_doctor_id
      AND c.status IN ('pending_payment', 'scheduled', 'in_progress')
      AND c.scheduled_start_at < v_end
      AND c.scheduled_end_at > v_start
  ) THEN
    RAISE EXCEPTION 'consultation slot already taken';
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

  UPDATE public.doctor_schedules
  SET consultation_id = v_consultation_id
  WHERE id = (
    SELECT ds.id
    FROM public.doctor_schedules AS ds
    WHERE ds.doctor_id = v_doctor_id
      AND ds.booking_id IS NULL
      AND ds.consultation_id IS NULL
      AND ds.starts_at <= v_start
      AND ds.ends_at >= v_end
    ORDER BY ds.starts_at
    LIMIT 1
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

GRANT EXECUTE ON FUNCTION public.create_consultation_payment(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- retry_consultation_payment
-- ---------------------------------------------------------------------------
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

  v_retry_suffix := to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');
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

GRANT EXECUTE ON FUNCTION public.retry_consultation_payment(uuid) TO authenticated;
