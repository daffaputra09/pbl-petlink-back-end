-- Allow customers to read opening hours for verified clinics (discovery embed).

ALTER TABLE public.clinic_opening_hours ENABLE ROW LEVEL SECURITY;

CREATE POLICY "clinic_opening_hours_select_verified_clinic"
ON public.clinic_opening_hours
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.clinic_profiles AS cp
    WHERE cp.id = clinic_opening_hours.clinic_id
      AND cp.is_verified = true
  )
);

ALTER TABLE public.clinic_opening_hour_periods ENABLE ROW LEVEL SECURITY;

CREATE POLICY "clinic_opening_hour_periods_select_verified_clinic"
ON public.clinic_opening_hour_periods
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.clinic_opening_hours AS coh
    JOIN public.clinic_profiles AS cp ON cp.id = coh.clinic_id
    WHERE coh.id = clinic_opening_hour_periods.clinic_opening_hours_id
      AND cp.is_verified = true
  )
);
