-- Bukti transfer wajib saat admin menyetujui penarikan.

ALTER TABLE public.withdraw_requests
  ADD COLUMN IF NOT EXISTS transfer_proof_url text;

COMMENT ON COLUMN public.withdraw_requests.transfer_proof_url IS
  'Public URL bukti transfer bank (Supabase Storage) diunggah admin saat approve.';

-- Penarikan approved/completed sebelum fitur bukti transfer tidak punya URL.
UPDATE public.withdraw_requests
SET transfer_proof_url = 'legacy:no-transfer-proof'
WHERE status IN (
  'approved'::public.withdraw_request_status,
  'completed'::public.withdraw_request_status
)
AND (
  transfer_proof_url IS NULL
  OR btrim(transfer_proof_url) = ''
);

ALTER TABLE public.withdraw_requests
  DROP CONSTRAINT IF EXISTS withdraw_requests_transfer_proof;

ALTER TABLE public.withdraw_requests
  ADD CONSTRAINT withdraw_requests_transfer_proof CHECK (
    status <> 'approved'::public.withdraw_request_status
    OR (
      transfer_proof_url IS NOT NULL
      AND trim(transfer_proof_url) <> ''
    )
  );

CREATE OR REPLACE FUNCTION public.admin_list_withdraw_requests(
  p_status text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
  v_offset integer := GREATEST(0, COALESCE(p_offset, 0));
  v_search text := NULLIF(trim(p_search), '');
BEGIN
  PERFORM public.assert_is_admin();

  RETURN jsonb_build_object(
    'items',
    COALESCE(
      (
        SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
        FROM (
          SELECT
            wr.id,
            wr.clinic_id,
            p.name AS clinic_name,
            wr.amount,
            wr.status,
            wr.bank_name,
            wr.account_number,
            wr.account_name,
            wr.bank_code,
            wr.rejection_reason,
            wr.transfer_proof_url,
            wr.created_at,
            wr.processed_at,
            wr.processed_by
          FROM public.withdraw_requests wr
          JOIN public.profiles p ON p.id = wr.clinic_id
          WHERE (
            p_status IS NULL
            OR trim(p_status) = ''
            OR wr.status::text = trim(p_status)
          )
          AND (
            v_search IS NULL
            OR p.name ILIKE '%' || v_search || '%'
          )
          ORDER BY wr.created_at DESC
          LIMIT v_limit
          OFFSET v_offset
        ) AS x
      ),
      '[]'::jsonb
    ),
    'total',
    (
      SELECT COUNT(*)
      FROM public.withdraw_requests wr
      JOIN public.profiles p ON p.id = wr.clinic_id
      WHERE (
        p_status IS NULL
        OR trim(p_status) = ''
        OR wr.status::text = trim(p_status)
      )
      AND (
        v_search IS NULL
        OR p.name ILIKE '%' || v_search || '%'
      )
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_process_withdraw_request(
  p_id uuid,
  p_action text,
  p_rejection_reason text DEFAULT NULL,
  p_transfer_proof_url text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.withdraw_requests%ROWTYPE;
  v_action text := lower(trim(p_action));
BEGIN
  PERFORM public.assert_is_admin();

  SELECT * INTO v_row
  FROM public.withdraw_requests
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'withdraw request not found';
  END IF;

  IF v_action = 'approve' THEN
    IF v_row.status <> 'pending'::public.withdraw_request_status THEN
      RAISE EXCEPTION 'only pending requests can be approved';
    END IF;
    IF p_transfer_proof_url IS NULL OR trim(p_transfer_proof_url) = '' THEN
      RAISE EXCEPTION 'transfer proof url is required when approving';
    END IF;
    UPDATE public.withdraw_requests
    SET
      status = 'approved'::public.withdraw_request_status,
      transfer_proof_url = trim(p_transfer_proof_url),
      processed_at = now(),
      processed_by = auth.uid(),
      rejection_reason = NULL
    WHERE id = p_id;

  ELSIF v_action = 'reject' THEN
    IF v_row.status <> 'pending'::public.withdraw_request_status THEN
      RAISE EXCEPTION 'only pending requests can be rejected';
    END IF;
    IF p_rejection_reason IS NULL OR trim(p_rejection_reason) = '' THEN
      RAISE EXCEPTION 'rejection reason is required';
    END IF;
    UPDATE public.withdraw_requests
    SET
      status = 'rejected'::public.withdraw_request_status,
      rejection_reason = trim(p_rejection_reason),
      transfer_proof_url = NULL,
      processed_at = now(),
      processed_by = auth.uid()
    WHERE id = p_id;

  ELSE
    RAISE EXCEPTION 'invalid action: use approve or reject';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_process_withdraw_request(uuid, text, text, text) TO authenticated;
