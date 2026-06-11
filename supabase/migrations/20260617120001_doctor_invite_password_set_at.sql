-- Track when a user completes initial password setup (doctor invite flow).
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS password_set_at timestamptz;

COMMENT ON COLUMN public.profiles.password_set_at IS
  'Timestamp when the user finished setting their password (e.g. doctor invite link). NULL = pending setup.';

-- Existing doctors were created with a clinic-set password before invite flow existed.
UPDATE public.profiles
SET password_set_at = created_at
WHERE role = 'doctor'
  AND password_set_at IS NULL;
