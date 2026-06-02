-- Allow customers to read clinic/doctor names and booking line items for their own bookings.

CREATE POLICY "clinic_profiles_select_customer_booking"
ON public.clinic_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.clinic_id = clinic_profiles.id
      AND b.customer_id = auth.uid()
  )
);

CREATE POLICY "doctor_profiles_select_customer_booking"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = doctor_profiles.id
      AND b.customer_id = auth.uid()
  )
);

ALTER TABLE public.booking_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "booking_items_select_own_booking"
ON public.booking_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.id = booking_items.booking_id
      AND b.customer_id = auth.uid()
  )
);

ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

CREATE POLICY "services_select_customer_booking"
ON public.services
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.booking_items AS bi
    INNER JOIN public.bookings AS b ON b.id = bi.booking_id
    WHERE bi.service_id = services.id
      AND b.customer_id = auth.uid()
  )
);
