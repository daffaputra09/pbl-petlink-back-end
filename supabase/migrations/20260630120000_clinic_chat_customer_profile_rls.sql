-- Clinic portal chat list joins customer profiles on chat_threads.
-- Pre-booking inquiries only create chat_threads (no bookings row), so
-- profiles_select_clinic_booking_customer hides the peer and the UI drops the thread.

CREATE POLICY "profiles_select_clinic_chat_customer"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  role = 'customer'::public.user_role
  AND EXISTS (
    SELECT 1
    FROM public.chat_threads AS ct
    WHERE (
      ct.user_1_id = (select auth.uid())
      AND ct.user_2_id = profiles.id
    )
    OR (
      ct.user_2_id = (select auth.uid())
      AND ct.user_1_id = profiles.id
    )
  )
);
