-- Remove optional pet link from consultations (schema only).
-- Bookings still require pet_id; online consultations do not use customer_pets.
-- pet_types data: `npm run seed:pet-types`

DROP TRIGGER IF EXISTS consultations_pet_matches_customer_check ON public.consultations;

DROP FUNCTION IF EXISTS public.consultation_pet_matches_customer ();

ALTER TABLE public.consultations
DROP COLUMN IF EXISTS pet_id;
