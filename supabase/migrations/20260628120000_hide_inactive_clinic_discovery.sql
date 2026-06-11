-- Customer discovery: hide clinics whose owner profile is inactive (admin nonaktifkan klinik).

DROP POLICY IF EXISTS "clinic_profiles_select_verified_public" ON public.clinic_profiles;

CREATE POLICY "clinic_profiles_select_verified_public"
ON public.clinic_profiles
FOR SELECT
TO anon, authenticated
USING (
  is_verified = true
  AND EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = clinic_profiles.id
      AND p.role = 'clinic'::public.user_role
      AND p.is_active = true
  )
);

DROP POLICY IF EXISTS "services_select_verified_active" ON public.services;

CREATE POLICY "services_select_verified_active"
ON public.services
FOR SELECT
TO authenticated, anon
USING (
  is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    JOIN public.profiles AS p ON p.id = cp.id
    WHERE cp.id = services.clinic_id
      AND cp.is_verified = true
      AND p.is_active = true
  )
);

DROP POLICY IF EXISTS "doctor_profiles_select_authenticated" ON public.doctor_profiles;

CREATE POLICY "doctor_profiles_select_own"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());

CREATE POLICY "doctor_profiles_select_customer_discovery"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (
  is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    JOIN public.profiles AS p ON p.id = cp.id
    WHERE cp.id = doctor_profiles.clinic_id
      AND cp.is_verified = true
      AND p.is_active = true
  )
);
