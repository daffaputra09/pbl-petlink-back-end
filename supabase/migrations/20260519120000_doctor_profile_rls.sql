-- RLS for doctor mobile profile: update own row, read affiliated clinic, count own bookings/consultations.

CREATE POLICY "doctor_profiles_update_own"
ON public.doctor_profiles
FOR UPDATE
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

CREATE POLICY "clinic_profiles_select_doctor_affiliated"
ON public.clinic_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.clinic_id = clinic_profiles.id
      AND dp.id = auth.uid()
  )
);

CREATE POLICY "bookings_select_own_doctor"
ON public.bookings
FOR SELECT
TO authenticated
USING (doctor_id = auth.uid());

CREATE POLICY "consultations_select_own_doctor"
ON public.consultations
FOR SELECT
TO authenticated
USING (doctor_id = auth.uid());
