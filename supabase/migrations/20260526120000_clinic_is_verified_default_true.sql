-- New clinic registrations are verified by default (visible in customer discovery).
ALTER TABLE public.clinic_profiles
ALTER COLUMN is_verified SET DEFAULT true;

COMMENT ON COLUMN public.clinic_profiles.is_verified IS
  'When true, clinic is visible to customers in discovery and search. Defaults to true on insert.';
