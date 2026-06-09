-- Doctor mobile: read schedule-related data and update booking/consultation status.

-- ---------------------------------------------------------------------------
-- SELECT policies for doctor-owned bookings / consultations
-- ---------------------------------------------------------------------------

CREATE POLICY "booking_items_select_doctor_own"
ON public.booking_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.id = booking_items.booking_id
      AND b.doctor_id = auth.uid()
  )
);

CREATE POLICY "customer_pets_select_doctor_booking"
ON public.customer_pets
FOR SELECT
TO authenticated
USING (
  deleted_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = auth.uid()
      AND b.pet_id = customer_pets.id
  )
);

CREATE POLICY "customer_profiles_select_doctor_booking"
ON public.customer_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = auth.uid()
      AND b.customer_id = customer_profiles.id
  )
);

CREATE POLICY "customer_profiles_select_doctor_consultation"
ON public.customer_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.doctor_id = auth.uid()
      AND c.customer_id = customer_profiles.id
  )
);

CREATE POLICY "profiles_select_doctor_booking_customer"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  role = 'customer'::public.user_role
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = auth.uid()
      AND b.customer_id = profiles.id
  )
);

CREATE POLICY "profiles_select_doctor_consultation_customer"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  role = 'customer'::public.user_role
  AND EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.doctor_id = auth.uid()
      AND c.customer_id = profiles.id
  )
);

CREATE POLICY "payments_select_doctor_booking"
ON public.payments
FOR SELECT
TO authenticated
USING (
  reference_type = 'booking'::public.payment_reference_type
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.id = payments.reference_id
      AND b.doctor_id = auth.uid()
  )
);

CREATE POLICY "payments_select_doctor_consultation"
ON public.payments
FOR SELECT
TO authenticated
USING (
  reference_type = 'consultation'::public.payment_reference_type
  AND EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.id = payments.reference_id
      AND c.doctor_id = auth.uid()
  )
);

CREATE POLICY "doctor_schedules_select_own_doctor"
ON public.doctor_schedules
FOR SELECT
TO authenticated
USING (doctor_id = auth.uid());

CREATE POLICY "services_select_doctor_booking"
ON public.services
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.booking_items AS bi
    INNER JOIN public.bookings AS b ON b.id = bi.booking_id
    WHERE bi.service_id = services.id
      AND b.doctor_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- Doctor update booking status
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_doctor_owns_booking(p_booking_id uuid)
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
    FROM public.bookings AS b
    WHERE b.id = p_booking_id
      AND b.doctor_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'booking not found or forbidden';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_doctor_owns_booking(uuid) TO authenticated;

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
BEGIN
  PERFORM public.assert_doctor_owns_booking(p_booking_id);

  SELECT status INTO v_current
  FROM public.bookings
  WHERE id = p_booking_id;

  IF v_current = 'cancelled'::public.booking_status
     OR v_current = 'completed'::public.booking_status THEN
    RAISE EXCEPTION 'booking status cannot be changed';
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

GRANT EXECUTE ON FUNCTION public.doctor_update_booking_status(uuid, public.booking_status) TO authenticated;

-- ---------------------------------------------------------------------------
-- Doctor update consultation status
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_doctor_owns_consultation(p_consultation_id uuid)
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
    FROM public.consultations AS c
    WHERE c.id = p_consultation_id
      AND c.doctor_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'consultation not found or forbidden';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_doctor_owns_consultation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.doctor_update_consultation_status(
  p_consultation_id uuid,
  p_status public.consultation_status
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current public.consultation_status;
BEGIN
  PERFORM public.assert_doctor_owns_consultation(p_consultation_id);

  SELECT status INTO v_current
  FROM public.consultations
  WHERE id = p_consultation_id;

  IF v_current = 'cancelled'::public.consultation_status
     OR v_current = 'completed'::public.consultation_status THEN
    RAISE EXCEPTION 'consultation status cannot be changed';
  END IF;

  IF p_status = 'cancelled'::public.consultation_status THEN
    IF v_current NOT IN (
      'pending_payment'::public.consultation_status,
      'scheduled'::public.consultation_status
    ) THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'scheduled'::public.consultation_status THEN
    IF v_current <> 'pending_payment'::public.consultation_status THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'in_progress'::public.consultation_status THEN
    IF v_current <> 'scheduled'::public.consultation_status THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSIF p_status = 'completed'::public.consultation_status THEN
    IF v_current NOT IN (
      'scheduled'::public.consultation_status,
      'in_progress'::public.consultation_status
    ) THEN
      RAISE EXCEPTION 'invalid status transition';
    END IF;
  ELSE
    RAISE EXCEPTION 'invalid target status';
  END IF;

  UPDATE public.consultations
  SET
    status = p_status,
    completed_at = CASE
      WHEN p_status = 'completed'::public.consultation_status THEN now()
      ELSE completed_at
    END,
    completed_by = CASE
      WHEN p_status = 'completed'::public.consultation_status THEN auth.uid()
      ELSE completed_by
    END
  WHERE id = p_consultation_id
    AND doctor_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.doctor_update_consultation_status(uuid, public.consultation_status) TO authenticated;
