-- Dokter dapat menutup window balasan customer secara manual.
-- Jika dokter mengirim pesan lagi setelah ditutup, trigger unlock akan membuka window 48 jam baru.

CREATE OR REPLACE FUNCTION public.doctor_close_follow_up_chat(p_thread_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doctor_id uuid := auth.uid();
  v_thread public.chat_threads%ROWTYPE;
BEGIN
  IF v_doctor_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT * INTO v_thread
  FROM public.chat_threads
  WHERE id = p_thread_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat thread not found';
  END IF;

  IF v_thread.type IS DISTINCT FROM 'consultation'::public.chat_thread_type THEN
    RAISE EXCEPTION 'not a consultation chat thread';
  END IF;

  IF public.chat_thread_doctor_id(p_thread_id) IS DISTINCT FROM v_doctor_id THEN
    RAISE EXCEPTION 'not the doctor for this thread';
  END IF;

  IF v_thread.is_active = true THEN
    RAISE EXCEPTION 'use end consultation session while consultation is live';
  END IF;

  UPDATE public.chat_threads
  SET
    customer_reply_unlocked_until = NULL,
    updated_at = now()
  WHERE id = p_thread_id;

  SELECT * INTO v_thread
  FROM public.chat_threads
  WHERE id = p_thread_id;

  RETURN jsonb_build_object(
    'thread_id', v_thread.id,
    'customer_reply_unlocked_until', v_thread.customer_reply_unlocked_until,
    'is_active', v_thread.is_active
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.doctor_close_follow_up_chat(uuid) TO authenticated;
