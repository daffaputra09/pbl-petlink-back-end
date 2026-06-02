-- Clinic portal: RLS for clinic owners + operational RPCs.

-- ---------------------------------------------------------------------------
-- Profiles: clinic reads customers with bookings at their clinic
-- ---------------------------------------------------------------------------
CREATE POLICY "profiles_select_clinic_booking_customer"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  role = 'customer'::public.user_role
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.clinic_id = auth.uid()
      AND b.customer_id = profiles.id
  )
);

-- ---------------------------------------------------------------------------
-- Customer data for clinic booking management
-- ---------------------------------------------------------------------------
CREATE POLICY "customer_profiles_select_clinic_booking"
ON public.customer_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.clinic_id = auth.uid()
      AND b.customer_id = customer_profiles.id
  )
);

CREATE POLICY "customer_pets_select_clinic_booking"
ON public.customer_pets
FOR SELECT
TO authenticated
USING (
  deleted_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.clinic_id = auth.uid()
      AND b.pet_id = customer_pets.id
  )
);

CREATE POLICY "customer_pets_select_clinic_owned"
ON public.customer_pets
FOR SELECT
TO authenticated
USING (
  deleted_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.clinic_id = auth.uid()
      AND b.customer_id = customer_pets.customer_id
  )
);

-- ---------------------------------------------------------------------------
-- Bookings
-- ---------------------------------------------------------------------------
CREATE POLICY "bookings_select_clinic_own"
ON public.bookings
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

CREATE POLICY "bookings_update_clinic_own"
ON public.bookings
FOR UPDATE
TO authenticated
USING (clinic_id = auth.uid())
WITH CHECK (clinic_id = auth.uid());

CREATE POLICY "booking_items_select_clinic_own"
ON public.booking_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.id = booking_items.booking_id
      AND b.clinic_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- Payments (clinic sees payments for their clinic)
-- ---------------------------------------------------------------------------
CREATE POLICY "payments_select_clinic_own"
ON public.payments
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Services (clinic CRUD own rows)
-- ---------------------------------------------------------------------------
CREATE POLICY "services_select_clinic_own"
ON public.services
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

CREATE POLICY "services_insert_clinic_own"
ON public.services
FOR INSERT
TO authenticated
WITH CHECK (clinic_id = auth.uid());

CREATE POLICY "services_update_clinic_own"
ON public.services
FOR UPDATE
TO authenticated
USING (clinic_id = auth.uid())
WITH CHECK (clinic_id = auth.uid());

CREATE POLICY "services_delete_clinic_own"
ON public.services
FOR DELETE
TO authenticated
USING (clinic_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Doctors affiliated with clinic
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_profiles_select_clinic_own"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

CREATE POLICY "doctor_profiles_update_clinic_own"
ON public.doctor_profiles
FOR UPDATE
TO authenticated
USING (clinic_id = auth.uid())
WITH CHECK (clinic_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Doctor schedules for clinic doctors
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_schedules_select_clinic_own"
ON public.doctor_schedules
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = doctor_schedules.doctor_id
      AND dp.clinic_id = auth.uid()
  )
);

CREATE POLICY "doctor_schedules_insert_clinic_own"
ON public.doctor_schedules
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = doctor_schedules.doctor_id
      AND dp.clinic_id = auth.uid()
  )
);

CREATE POLICY "doctor_schedules_update_clinic_own"
ON public.doctor_schedules
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = doctor_schedules.doctor_id
      AND dp.clinic_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = doctor_schedules.doctor_id
      AND dp.clinic_id = auth.uid()
  )
);

CREATE POLICY "doctor_schedules_delete_clinic_own"
ON public.doctor_schedules
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = doctor_schedules.doctor_id
      AND dp.clinic_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- Opening hours (own clinic)
-- ---------------------------------------------------------------------------
CREATE POLICY "clinic_opening_hours_select_own"
ON public.clinic_opening_hours
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

CREATE POLICY "clinic_opening_hour_periods_select_own"
ON public.clinic_opening_hour_periods
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.clinic_opening_hours AS coh
    WHERE coh.id = clinic_opening_hour_periods.clinic_opening_hours_id
      AND coh.clinic_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- Withdraw requests
-- ---------------------------------------------------------------------------
ALTER TABLE public.withdraw_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "withdraw_requests_select_clinic_own"
ON public.withdraw_requests
FOR SELECT
TO authenticated
USING (clinic_id = auth.uid());

CREATE POLICY "withdraw_requests_insert_clinic_own"
ON public.withdraw_requests
FOR INSERT
TO authenticated
WITH CHECK (clinic_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Helper: ensure caller is clinic owner of booking
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_clinic_owns_booking(p_booking_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.bookings b
    WHERE b.id = p_booking_id
      AND b.clinic_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'booking not found or forbidden';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_clinic_owns_booking(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Update booking status (clinic)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clinic_update_booking_status(
  p_booking_id uuid,
  p_status public.booking_status
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_clinic_owns_booking(p_booking_id);

  UPDATE public.bookings
  SET status = p_status
  WHERE id = p_booking_id
    AND clinic_id = auth.uid();

  IF p_status = 'cancelled'::public.booking_status THEN
    PERFORM public.release_booking_doctor_schedule(p_booking_id);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clinic_update_booking_status(uuid, public.booking_status) TO authenticated;

-- ---------------------------------------------------------------------------
-- Reschedule booking (clinic)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clinic_reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start_at timestamp with time zone,
  p_scheduled_end_at timestamp with time zone,
  p_doctor_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid;
BEGIN
  PERFORM public.assert_clinic_owns_booking(p_booking_id);

  IF p_scheduled_start_at >= p_scheduled_end_at THEN
    RAISE EXCEPTION 'invalid time range';
  END IF;

  SELECT COALESCE(p_doctor_id, doctor_id) INTO v_doctor_id
  FROM public.bookings
  WHERE id = p_booking_id;

  IF v_doctor_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.doctor_profiles dp
    WHERE dp.id = v_doctor_id AND dp.clinic_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'invalid doctor for clinic';
  END IF;

  PERFORM public.release_booking_doctor_schedule(p_booking_id);

  UPDATE public.bookings
  SET
    scheduled_start_at = p_scheduled_start_at,
    scheduled_end_at = p_scheduled_end_at,
    doctor_id = v_doctor_id
  WHERE id = p_booking_id
    AND clinic_id = auth.uid();

  IF v_doctor_id IS NOT NULL THEN
    INSERT INTO public.doctor_schedules (
      doctor_id,
      starts_at,
      ends_at,
      booking_id
    ) VALUES (
      v_doctor_id,
      p_scheduled_start_at,
      p_scheduled_end_at,
      p_booking_id
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clinic_reschedule_booking(uuid, timestamptz, timestamptz, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Manual booking created by clinic (walk-in / phone)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_clinic_manual_booking(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clinic_id uuid := auth.uid();
  v_customer_id uuid := (p_payload->>'customer_id')::uuid;
  v_pet_id uuid := (p_payload->>'pet_id')::uuid;
  v_doctor_id uuid := NULLIF(p_payload->>'doctor_id', '')::uuid;
  v_start timestamptz := (p_payload->>'scheduled_start_at')::timestamptz;
  v_end timestamptz := (p_payload->>'scheduled_end_at')::timestamptz;
  v_channel public.booking_channel := COALESCE(
    (p_payload->>'channel')::public.booking_channel,
    'clinic'::public.booking_channel
  );
  v_notes text := NULLIF(trim(p_payload->>'notes'), '');
  v_service_ids uuid[];
  v_booking_id uuid;
  v_total numeric(14, 2) := 0;
  v_svc record;
BEGIN
  IF v_clinic_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.clinic_profiles cp WHERE cp.id = v_clinic_id
  ) THEN
    RAISE EXCEPTION 'clinic profile required';
  END IF;

  SELECT array_agg(x::uuid)
  INTO v_service_ids
  FROM jsonb_array_elements_text(p_payload->'service_ids') AS t(x);

  IF v_service_ids IS NULL OR cardinality(v_service_ids) < 1 THEN
    RAISE EXCEPTION 'at least one service required';
  END IF;

  IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
    RAISE EXCEPTION 'invalid schedule';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.customer_profiles cp WHERE cp.id = v_customer_id
  ) THEN
    RAISE EXCEPTION 'customer not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.customer_pets p
    WHERE p.id = v_pet_id
      AND p.customer_id = v_customer_id
      AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'pet not found for customer';
  END IF;

  IF v_doctor_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.doctor_profiles dp
    WHERE dp.id = v_doctor_id AND dp.clinic_id = v_clinic_id
  ) THEN
    RAISE EXCEPTION 'invalid doctor for clinic';
  END IF;

  SELECT COALESCE(sum(s.price), 0)
  INTO v_total
  FROM public.services s
  WHERE s.id = ANY (v_service_ids)
    AND s.clinic_id = v_clinic_id
    AND s.is_active = true;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'invalid services';
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
    v_customer_id,
    v_pet_id,
    v_clinic_id,
    v_doctor_id,
    v_channel,
    v_start,
    v_end,
    'confirmed'::public.booking_status,
    v_total,
    v_notes
  )
  RETURNING id INTO v_booking_id;

  FOR v_svc IN
    SELECT s.id, s.price, s.duration_minutes
    FROM public.services s
    WHERE s.id = ANY (v_service_ids)
  LOOP
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
      v_svc.price,
      v_svc.duration_minutes
    );
  END LOOP;

  IF v_doctor_id IS NOT NULL THEN
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
  END IF;

  RETURN jsonb_build_object('booking_id', v_booking_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_clinic_manual_booking(jsonb) TO authenticated;
