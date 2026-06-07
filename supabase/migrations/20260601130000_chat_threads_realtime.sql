-- Realtime for chat list: thread metadata (last_message, new threads).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_threads'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_threads;
  END IF;
END $$;
