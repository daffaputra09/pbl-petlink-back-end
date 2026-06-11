-- Doctor-initiated follow-up chat on existing consultation threads (48h customer reply window).

ALTER TABLE public.chat_threads
  ADD COLUMN IF NOT EXISTS customer_reply_unlocked_until timestamp with time zone,
  ADD COLUMN IF NOT EXISTS follow_up_context jsonb;

COMMENT ON COLUMN public.chat_threads.customer_reply_unlocked_until IS
  'Customer may reply on inactive consultation threads until this timestamp (set when doctor sends outreach).';

COMMENT ON COLUMN public.chat_threads.follow_up_context IS
  'Optional metadata for follow-up outreach, e.g. {"booking_id":"...","source":"booking"}.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_thread_doctor_id(p_thread_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p.role = 'doctor'::public.user_role THEN p.id
    ELSE p_other.id
  END
  FROM public.chat_threads AS t
  JOIN public.profiles AS p ON p.id = t.user_1_id
  JOIN public.profiles AS p_other ON p_other.id = t.user_2_id
  WHERE t.id = p_thread_id
    AND t.type = 'consultation'::public.chat_thread_type
    AND (
      p.role = 'doctor'::public.user_role
      OR p_other.role = 'doctor'::public.user_role
    );
$$;

CREATE OR REPLACE FUNCTION public.chat_thread_customer_id(p_thread_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN cp.id IS NOT NULL THEN cp.id
    ELSE cp_other.id
  END
  FROM public.chat_threads AS t
  LEFT JOIN public.customer_profiles AS cp ON cp.id = t.user_1_id
  LEFT JOIN public.customer_profiles AS cp_other ON cp_other.id = t.user_2_id
  WHERE t.id = p_thread_id
    AND t.type = 'consultation'::public.chat_thread_type
    AND (cp.id IS NOT NULL OR cp_other.id IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION public.doctor_has_customer_relationship(
  p_doctor_id uuid,
  p_customer_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.consultations AS c
    WHERE c.doctor_id = p_doctor_id
      AND c.customer_id = p_customer_id
  )
  OR EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.doctor_id = p_doctor_id
      AND b.customer_id = p_customer_id
  );
$$;

CREATE OR REPLACE FUNCTION public.consultation_thread_session_open(p_thread_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = p_thread_id
      AND t.type = 'consultation'::public.chat_thread_type
      AND t.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION public.consultation_thread_customer_can_reply(
  p_thread_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = p_thread_id
      AND t.type = 'consultation'::public.chat_thread_type
      AND public.chat_thread_customer_id(p_thread_id) = p_user_id
      AND t.customer_reply_unlocked_until IS NOT NULL
      AND t.customer_reply_unlocked_until > now()
  );
$$;

CREATE OR REPLACE FUNCTION public.consultation_thread_doctor_can_send(
  p_thread_id uuid,
  p_sender_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_threads AS t
    WHERE t.id = p_thread_id
      AND t.type = 'consultation'::public.chat_thread_type
      AND public.chat_thread_doctor_id(p_thread_id) = p_sender_id
      AND public.doctor_has_customer_relationship(
        p_sender_id,
        public.chat_thread_customer_id(p_thread_id)
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- find_or_create with optional reactivate (payment vs follow-up outreach)
-- Drop legacy 2-arg overload to avoid ambiguity with DEFAULT on 3rd param.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.find_or_create_consultation_chat_thread(uuid, uuid);

CREATE OR REPLACE FUNCTION public.find_or_create_consultation_chat_thread(
  p_customer_id uuid,
  p_doctor_id uuid,
  p_reactivate boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_thread_id uuid;
BEGIN
  SELECT ct.id
  INTO v_thread_id
  FROM public.chat_threads AS ct
  WHERE ct.type = 'consultation'::public.chat_thread_type
    AND (
      (ct.user_1_id = p_customer_id AND ct.user_2_id = p_doctor_id)
      OR (ct.user_2_id = p_customer_id AND ct.user_1_id = p_doctor_id)
    )
  ORDER BY ct.updated_at DESC
  LIMIT 1;

  IF v_thread_id IS NOT NULL THEN
    IF p_reactivate THEN
      UPDATE public.chat_threads
      SET
        is_active = true,
        updated_at = now()
      WHERE id = v_thread_id;
    ELSE
      UPDATE public.chat_threads
      SET updated_at = now()
      WHERE id = v_thread_id;
    END IF;

    RETURN v_thread_id;
  END IF;

  INSERT INTO public.chat_threads (user_1_id, user_2_id, type, is_active)
  VALUES (
    p_customer_id,
    p_doctor_id,
    'consultation'::public.chat_thread_type,
    p_reactivate
  )
  RETURNING id INTO v_thread_id;

  RETURN v_thread_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.find_or_create_consultation_chat_thread(uuid, uuid, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Doctor follow-up RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.doctor_open_follow_up_chat(
  p_customer_id uuid,
  p_booking_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid := auth.uid();
  v_thread_id uuid;
  v_row public.chat_threads%ROWTYPE;
  v_source text := 'chat_list';
BEGIN
  IF v_doctor_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.doctor_profiles AS dp
    WHERE dp.id = v_doctor_id
      AND dp.is_active = true
  ) THEN
    RAISE EXCEPTION 'not an active doctor';
  END IF;

  IF p_booking_id IS NOT NULL THEN
    PERFORM public.assert_doctor_owns_booking(p_booking_id);

    IF NOT EXISTS (
      SELECT 1
      FROM public.bookings AS b
      WHERE b.id = p_booking_id
        AND b.customer_id = p_customer_id
        AND b.doctor_id = v_doctor_id
    ) THEN
      RAISE EXCEPTION 'booking does not match customer';
    END IF;

    v_source := 'booking';
  END IF;

  IF NOT public.doctor_has_customer_relationship(v_doctor_id, p_customer_id) THEN
    RAISE EXCEPTION 'no prior consultation or booking with this customer';
  END IF;

  v_thread_id := public.find_or_create_consultation_chat_thread(
    p_customer_id,
    v_doctor_id,
    false
  );

  UPDATE public.chat_threads
  SET
    follow_up_context = CASE
      WHEN p_booking_id IS NOT NULL THEN
        jsonb_build_object(
          'booking_id', p_booking_id::text,
          'source', v_source
        )
      ELSE follow_up_context
    END,
    updated_at = now()
  WHERE id = v_thread_id;

  SELECT * INTO v_row
  FROM public.chat_threads
  WHERE id = v_thread_id;

  RETURN jsonb_build_object(
    'thread_id', v_row.id,
    'customer_reply_unlocked_until', v_row.customer_reply_unlocked_until,
    'is_active', v_row.is_active
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.doctor_open_follow_up_for_booking(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer_id uuid;
BEGIN
  PERFORM public.assert_doctor_owns_booking(p_booking_id);

  SELECT b.customer_id INTO v_customer_id
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'booking not found';
  END IF;

  RETURN public.doctor_open_follow_up_chat(v_customer_id, p_booking_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.doctor_open_follow_up_chat(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.doctor_open_follow_up_for_booking(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Unlock customer reply window when doctor sends on inactive consultation thread
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_message_unlock_customer_follow_up()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_thread public.chat_threads%ROWTYPE;
  v_doctor_id uuid;
BEGIN
  SELECT * INTO v_thread
  FROM public.chat_threads
  WHERE id = NEW.thread_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_thread.type IS DISTINCT FROM 'consultation'::public.chat_thread_type THEN
    RETURN NEW;
  END IF;

  IF v_thread.is_active = true THEN
    RETURN NEW;
  END IF;

  v_doctor_id := public.chat_thread_doctor_id(NEW.thread_id);

  IF v_doctor_id IS NULL OR NEW.sender_id IS DISTINCT FROM v_doctor_id THEN
    RETURN NEW;
  END IF;

  UPDATE public.chat_threads
  SET
    customer_reply_unlocked_until = now() + interval '48 hours',
    updated_at = now()
  WHERE id = NEW.thread_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_unlock_customer_follow_up ON public.chat_messages;

CREATE TRIGGER chat_messages_unlock_customer_follow_up
AFTER INSERT ON public.chat_messages
FOR EACH ROW
EXECUTE PROCEDURE public.chat_message_unlock_customer_follow_up();

-- ---------------------------------------------------------------------------
-- RLS: consultation threads allow doctor outreach + timed customer reply
-- ---------------------------------------------------------------------------

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
        OR public.consultation_thread_session_open(t.id)
        OR public.consultation_thread_doctor_can_send(t.id, auth.uid())
        OR public.consultation_thread_customer_can_reply(t.id, auth.uid())
      )
  )
);
