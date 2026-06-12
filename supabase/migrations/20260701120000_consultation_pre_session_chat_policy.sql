-- Pre-session consultation chat: customer may send one message before the
-- scheduled slot; after the doctor replies they may continue. Reused threads
-- must not inherit follow-up unlock or old-message permissions.

CREATE OR REPLACE FUNCTION public.consultation_thread_customer_can_send(
  p_thread_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_consultation public.consultations%ROWTYPE;
BEGIN
  IF public.chat_thread_customer_id(p_thread_id) IS DISTINCT FROM p_user_id THEN
    RETURN false;
  END IF;

  IF public.consultation_thread_customer_can_reply(p_thread_id, p_user_id) THEN
    RETURN true;
  END IF;

  SELECT *
  INTO v_consultation
  FROM public.consultations AS c
  WHERE c.chat_thread_id = p_thread_id
    AND c.status IN (
      'scheduled'::public.consultation_status,
      'in_progress'::public.consultation_status
    )
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_consultation.status = 'in_progress'::public.consultation_status
     AND now() < v_consultation.scheduled_end_at THEN
    RETURN true;
  END IF;

  IF v_consultation.status = 'scheduled'::public.consultation_status
     AND now() >= v_consultation.scheduled_start_at
     AND now() < v_consultation.scheduled_end_at THEN
    RETURN true;
  END IF;

  IF v_consultation.status = 'scheduled'::public.consultation_status
     AND now() < v_consultation.scheduled_start_at THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.chat_messages AS m
      WHERE m.thread_id = p_thread_id
        AND m.sender_id = p_user_id
        AND m.created_at >= v_consultation.created_at
    ) THEN
      RETURN true;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.chat_messages AS m
      WHERE m.thread_id = p_thread_id
        AND m.sender_id = v_consultation.doctor_id
        AND m.created_at >= v_consultation.created_at
    ) THEN
      RETURN true;
    END IF;

    RETURN false;
  END IF;

  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION public.consultation_thread_customer_can_send(uuid, uuid)
  TO authenticated;

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
        customer_reply_unlocked_until = NULL,
        follow_up_context = NULL,
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
        OR public.consultation_thread_customer_can_send(t.id, auth.uid())
        OR public.consultation_thread_doctor_can_send(t.id, auth.uid())
        OR public.consultation_thread_customer_can_reply(t.id, auth.uid())
      )
  )
);
