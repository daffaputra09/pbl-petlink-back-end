-- Services, chat, in-app notifications, and FCM device tokens.

CREATE TYPE public.chat_thread_type AS ENUM ('chat', 'consultation');

CREATE TYPE public.chat_message_type AS ENUM ('text', 'image');

CREATE TABLE public.services (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE CASCADE,
  name character varying(255) NOT NULL,
  description text,
  duration_minutes integer NOT NULL,
  price numeric(14, 2) NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  is_home_service boolean NOT NULL DEFAULT false,
  is_clinic_service boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT services_duration_positive CHECK (duration_minutes > 0),
  CONSTRAINT services_at_least_one_channel CHECK (
    is_home_service
    OR is_clinic_service
  )
);

CREATE INDEX services_clinic_id_idx ON public.services USING btree (clinic_id);

CREATE INDEX services_clinic_active_idx ON public.services USING btree (clinic_id, is_active);

CREATE TRIGGER services_set_updated_at
BEFORE UPDATE ON public.services
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE TABLE public.chat_threads (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  user_1_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  user_2_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  type public.chat_thread_type NOT NULL,
  last_message text,
  last_message_at timestamp with time zone,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT chat_threads_distinct_users CHECK (user_1_id <> user_2_id)
);

CREATE INDEX chat_threads_user_1_id_idx ON public.chat_threads USING btree (user_1_id);

CREATE INDEX chat_threads_user_2_id_idx ON public.chat_threads USING btree (user_2_id);

CREATE TRIGGER chat_threads_set_updated_at
BEFORE UPDATE ON public.chat_threads
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE TABLE public.chat_messages (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id uuid NOT NULL REFERENCES public.chat_threads (id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  message_type public.chat_message_type NOT NULL,
  message text,
  attachment_url text,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX chat_messages_thread_id_idx ON public.chat_messages USING btree (thread_id);

CREATE INDEX chat_messages_thread_created_idx ON public.chat_messages USING btree (thread_id, created_at);

CREATE TABLE public.notifications (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  title character varying(255) NOT NULL,
  body text,
  type character varying(255),
  reference_id uuid,
  reference_type character varying(255),
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  read_at timestamp with time zone
);

CREATE INDEX notifications_user_id_idx ON public.notifications USING btree (user_id);

CREATE INDEX notifications_user_unread_idx ON public.notifications USING btree (user_id, is_read);

CREATE TABLE public.user_fcm_tokens (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  fcm_token text NOT NULL,
  device_type character varying(50),
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT user_fcm_tokens_user_token_unique UNIQUE (user_id, fcm_token)
);

CREATE INDEX user_fcm_tokens_user_id_idx ON public.user_fcm_tokens USING btree (user_id);

CREATE TRIGGER user_fcm_tokens_set_updated_at
BEFORE UPDATE ON public.user_fcm_tokens
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();
