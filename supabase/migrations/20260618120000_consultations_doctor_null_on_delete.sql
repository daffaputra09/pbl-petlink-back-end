-- Allow removing doctor accounts while keeping consultation history.
ALTER TABLE public.consultations
  DROP CONSTRAINT IF EXISTS consultations_doctor_id_fkey;

ALTER TABLE public.consultations
  ALTER COLUMN doctor_id DROP NOT NULL;

ALTER TABLE public.consultations
  ADD CONSTRAINT consultations_doctor_id_fkey
  FOREIGN KEY (doctor_id)
  REFERENCES public.doctor_profiles (id)
  ON DELETE SET NULL;
