-- Customer (and participants): chat threads and messages.

ALTER TABLE public.chat_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "chat_threads_select_participant"
ON public.chat_threads
FOR SELECT
TO authenticated
USING (user_1_id = auth.uid() OR user_2_id = auth.uid());

CREATE POLICY "chat_threads_insert_participant"
ON public.chat_threads
FOR INSERT
TO authenticated
WITH CHECK (
  user_1_id = auth.uid() OR user_2_id = auth.uid()
);

CREATE POLICY "chat_threads_update_participant"
ON public.chat_threads
FOR UPDATE
TO authenticated
USING (user_1_id = auth.uid() OR user_2_id = auth.uid())
WITH CHECK (user_1_id = auth.uid() OR user_2_id = auth.uid());

CREATE POLICY "chat_messages_select_participant"
ON public.chat_messages
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = chat_messages.thread_id
      AND (t.user_1_id = auth.uid() OR t.user_2_id = auth.uid())
  )
);

CREATE POLICY "chat_messages_insert_sender"
ON public.chat_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = chat_messages.thread_id
      AND (t.user_1_id = auth.uid() OR t.user_2_id = auth.uid())
  )
);

CREATE POLICY "chat_messages_update_participant"
ON public.chat_messages
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = chat_messages.thread_id
      AND (t.user_1_id = auth.uid() OR t.user_2_id = auth.uid())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = chat_messages.thread_id
      AND (t.user_1_id = auth.uid() OR t.user_2_id = auth.uid())
  )
);
