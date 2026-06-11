-- Fix infinite RLS recursion: doctor_profiles → clinic_profiles → doctor_profiles.
-- Use SECURITY DEFINER helpers so policy checks bypass RLS on joined tables.

CREATE OR REPLACE FUNCTION public.is_clinic_owner_active(p_clinic_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT p.is_active
      FROM public.profiles AS p
      WHERE p.id = p_clinic_id
        AND p.role = 'clinic'::public.user_role
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.clinic_is_customer_visible(p_clinic_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    WHERE cp.id = p_clinic_id
      AND cp.is_verified = true
      AND public.is_clinic_owner_active(cp.id)
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_clinic_owner_active(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clinic_is_customer_visible(uuid) TO anon, authenticated;

DROP POLICY IF EXISTS "clinic_profiles_select_verified_public" ON public.clinic_profiles;

CREATE POLICY "clinic_profiles_select_verified_public"
ON public.clinic_profiles
FOR SELECT
TO anon, authenticated
USING (
  is_verified = true
  AND public.is_clinic_owner_active(id)
);

DROP POLICY IF EXISTS "services_select_verified_active" ON public.services;

CREATE POLICY "services_select_verified_active"
ON public.services
FOR SELECT
TO authenticated, anon
USING (
  is_active = true
  AND public.clinic_is_customer_visible(clinic_id)
);

DROP POLICY IF EXISTS "doctor_profiles_select_customer_discovery" ON public.doctor_profiles;

CREATE POLICY "doctor_profiles_select_customer_discovery"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (
  is_active = true
  AND public.clinic_is_customer_visible(clinic_id)
);
