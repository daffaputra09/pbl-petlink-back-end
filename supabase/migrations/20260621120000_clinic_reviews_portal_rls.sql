-- Portal klinik & admin: baca ulasan/rating.

CREATE POLICY "clinic_reviews_select_clinic_own"
ON public.clinic_reviews
FOR SELECT
TO authenticated
USING (clinic_id = (select auth.uid()));

CREATE POLICY "clinic_reviews_select_admin"
ON public.clinic_reviews
FOR SELECT
TO authenticated
USING (public.is_admin());
