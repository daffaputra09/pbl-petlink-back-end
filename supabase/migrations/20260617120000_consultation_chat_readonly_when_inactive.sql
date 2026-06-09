-- Cegah kirim pesan baru pada thread konsultasi yang sudah tidak aktif.

DROP POLICY IF EXISTS "chat_messages_insert_sender" ON public.chat_messages;

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
      AND (
        t.type IS DISTINCT FROM 'consultation'::public.chat_thread_type
        OR t.is_active = true
      )
  )
);
