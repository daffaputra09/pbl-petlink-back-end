-- Chat push: DB trigger → NestJS webhook → Firebase Cloud Messaging.
-- Update internal_webhook_config.secret to match CHAT_WEBHOOK_SECRET on the API host.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

ALTER TABLE public.user_fcm_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_fcm_tokens_select_own"
ON public.user_fcm_tokens
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "user_fcm_tokens_insert_own"
ON public.user_fcm_tokens
FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());

CREATE POLICY "user_fcm_tokens_update_own"
ON public.user_fcm_tokens
FOR UPDATE
TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

CREATE POLICY "user_fcm_tokens_delete_own"
ON public.user_fcm_tokens
FOR DELETE
TO authenticated
USING (user_id = auth.uid());

CREATE TABLE public.internal_webhook_config (
  id text NOT NULL PRIMARY KEY,
  url text NOT NULL,
  secret text NOT NULL,
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE public.internal_webhook_config ENABLE ROW LEVEL SECURITY;

INSERT INTO public.internal_webhook_config (id, url, secret)
VALUES (
  'chat_push',
  'https://api-petlink.vercel.app/webhooks/chat-message',
  'pbl-petlink-chat-webhook-secret'
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.trigger_chat_message_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  cfg record;
BEGIN
  SELECT url, secret INTO cfg
  FROM public.internal_webhook_config
  WHERE id = 'chat_push'
  LIMIT 1;

  IF cfg.url IS NULL OR cfg.url = '' THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := cfg.url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', cfg.secret
    ),
    body := jsonb_build_object(
      'record', jsonb_build_object(
        'id', NEW.id,
        'thread_id', NEW.thread_id,
        'sender_id', NEW.sender_id,
        'message_type', NEW.message_type,
        'message', NEW.message,
        'attachment_url', NEW.attachment_url
      )
    )
  );

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_after_insert_push ON public.chat_messages;

CREATE TRIGGER chat_messages_after_insert_push
AFTER INSERT ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.trigger_chat_message_push();
