-- RLS for customer mobile profile: pets, booking history, lookups.

-- Allow reading doctor/clinic display names on profiles (own row already covered).
CREATE POLICY "profiles_select_display_roles"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  id = auth.uid()
  OR role IN ('doctor'::public.user_role, 'clinic'::public.user_role)
);

ALTER TABLE public.customer_pets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customer_pets_select_own"
ON public.customer_pets
FOR SELECT
TO authenticated
USING (customer_id = auth.uid());

CREATE POLICY "customer_pets_insert_own"
ON public.customer_pets
FOR INSERT
TO authenticated
WITH CHECK (customer_id = auth.uid());

CREATE POLICY "customer_pets_update_own"
ON public.customer_pets
FOR UPDATE
TO authenticated
USING (customer_id = auth.uid())
WITH CHECK (customer_id = auth.uid());

CREATE POLICY "customer_pets_delete_own"
ON public.customer_pets
FOR DELETE
TO authenticated
USING (customer_id = auth.uid());

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "bookings_select_own"
ON public.bookings
FOR SELECT
TO authenticated
USING (customer_id = auth.uid());

ALTER TABLE public.consultations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "consultations_select_own"
ON public.consultations
FOR SELECT
TO authenticated
USING (customer_id = auth.uid());

ALTER TABLE public.pet_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pet_types_select_active"
ON public.pet_types
FOR SELECT
TO authenticated
USING (deleted_at IS NULL);

ALTER TABLE public.doctor_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "doctor_profiles_select_authenticated"
ON public.doctor_profiles
FOR SELECT
TO authenticated
USING (true);
