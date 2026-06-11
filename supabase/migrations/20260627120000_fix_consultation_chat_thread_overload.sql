-- Fix ambiguous find_or_create_consultation_chat_thread(uuid, uuid) when the
-- 3-arg version (with DEFAULT) also exists — caused booking consultation to fail.

DROP FUNCTION IF EXISTS public.find_or_create_consultation_chat_thread(uuid, uuid);

REVOKE ALL ON FUNCTION public.find_or_create_consultation_chat_thread(uuid, uuid, boolean)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.find_or_create_consultation_chat_thread(uuid, uuid, boolean)
  TO authenticated;

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

  IF EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.customer_id = v_uid
      AND c.doctor_id = v_doctor_id
      AND c.status IN (
        'pending_payment'::public.consultation_status,
        'scheduled'::public.consultation_status,
        'in_progress'::public.consultation_status
      )
  ) THEN
    RAISE EXCEPTION 'active consultation exists with this doctor';
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

  v_thread_id := public.find_or_create_consultation_chat_thread(
    v_uid,
    v_doctor_id,
    true
  );

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

GRANT EXECUTE ON FUNCTION public.create_consultation_payment(jsonb) TO authenticated;
