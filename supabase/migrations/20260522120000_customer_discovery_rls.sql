-- Customer discovery: browse services and read reviews on verified clinics.

CREATE POLICY "services_select_verified_active"
ON public.services
FOR SELECT
TO authenticated, anon
USING (
  is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    WHERE cp.id = services.clinic_id
      AND cp.is_verified = true
  )
);

ALTER TABLE public.clinic_reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "clinic_reviews_select_verified_clinic"
ON public.clinic_reviews
FOR SELECT
TO authenticated, anon
USING (
  EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    WHERE cp.id = clinic_reviews.clinic_id
      AND cp.is_verified = true
  )
);
