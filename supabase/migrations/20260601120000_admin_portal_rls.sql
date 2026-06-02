-- Admin portal: helpers, RLS read policies, and SECURITY DEFINER RPCs.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role = 'admin'::public.user_role
      AND p.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION public.assert_is_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden: admin only';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin SELECT policies (mutations via RPC)
-- ---------------------------------------------------------------------------
CREATE POLICY "clinic_profiles_select_admin"
ON public.clinic_profiles
FOR SELECT
TO authenticated
USING (public.is_admin());

CREATE POLICY "profiles_select_admin"
ON public.profiles
FOR SELECT
TO authenticated
USING (public.is_admin());

CREATE POLICY "withdraw_requests_select_admin"
ON public.withdraw_requests
FOR SELECT
TO authenticated
USING (public.is_admin());

CREATE POLICY "payments_select_admin"
ON public.payments
FOR SELECT
TO authenticated
USING (public.is_admin());

CREATE POLICY "pet_types_select_admin"
ON public.pet_types
FOR SELECT
TO authenticated
USING (public.is_admin());

CREATE POLICY "pet_types_insert_admin"
ON public.pet_types
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin());

CREATE POLICY "pet_types_update_admin"
ON public.pet_types
FOR UPDATE
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------------
-- Dashboard stats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_dashboard_stats(p_year integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year integer;
  v_now timestamptz := now();
  v_month_start timestamptz;
  v_prev_month_start timestamptz;
  v_total_clinics bigint;
  v_total_users bigint;
  v_total_revenue numeric;
  v_revenue_this_month numeric;
  v_revenue_prev_month numeric;
  v_clinics_this_month bigint;
  v_users_this_month bigint;
  v_monthly jsonb;
BEGIN
  PERFORM public.assert_is_admin();

  v_year := COALESCE(p_year, EXTRACT(YEAR FROM v_now)::integer);
  v_month_start := date_trunc('month', v_now);
  v_prev_month_start := v_month_start - interval '1 month';

  SELECT COUNT(*) INTO v_total_clinics FROM public.clinic_profiles;

  SELECT COUNT(*) INTO v_total_users
  FROM public.profiles
  WHERE role IN ('customer'::public.user_role, 'clinic'::public.user_role);

  SELECT COALESCE(SUM(amount), 0) INTO v_total_revenue
  FROM public.payments
  WHERE status = 'paid'::public.payment_status;

  SELECT COALESCE(SUM(amount), 0) INTO v_revenue_this_month
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND paid_at >= v_month_start;

  SELECT COALESCE(SUM(amount), 0) INTO v_revenue_prev_month
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND paid_at >= v_prev_month_start
    AND paid_at < v_month_start;

  SELECT COUNT(*) INTO v_clinics_this_month
  FROM public.profiles p
  JOIN public.clinic_profiles cp ON cp.id = p.id
  WHERE p.role = 'clinic'::public.user_role
    AND p.created_at >= v_month_start;

  SELECT COUNT(*) INTO v_users_this_month
  FROM public.profiles
  WHERE role IN ('customer'::public.user_role, 'clinic'::public.user_role)
    AND created_at >= v_month_start;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'month', m.month_num,
        'label', m.month_label,
        'amount', COALESCE(s.amount, 0)
      )
      ORDER BY m.month_num
    ),
    '[]'::jsonb
  )
  INTO v_monthly
  FROM (
    SELECT
      gs AS month_num,
      to_char(make_date(v_year, gs, 1), 'Mon') AS month_label
    FROM generate_series(1, 12) AS gs
  ) AS m
  LEFT JOIN (
    SELECT
      EXTRACT(MONTH FROM paid_at)::integer AS month_num,
      SUM(amount) AS amount
    FROM public.payments
    WHERE status = 'paid'::public.payment_status
      AND paid_at IS NOT NULL
      AND EXTRACT(YEAR FROM paid_at) = v_year
    GROUP BY 1
  ) AS s ON s.month_num = m.month_num;

  RETURN jsonb_build_object(
    'total_clinics', v_total_clinics,
    'total_users', v_total_users,
    'total_revenue', v_total_revenue,
    'revenue_this_month', v_revenue_this_month,
    'revenue_prev_month', v_revenue_prev_month,
    'revenue_growth_percent',
      CASE
        WHEN v_revenue_prev_month > 0 THEN
          ROUND(((v_revenue_this_month - v_revenue_prev_month) / v_revenue_prev_month) * 100, 1)
        ELSE NULL
      END,
    'clinics_this_month', v_clinics_this_month,
    'users_this_month', v_users_this_month,
    'year', v_year,
    'monthly', v_monthly
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Recent activity feed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_recent_activity(p_limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_is_admin();

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.sort_at DESC)
      FROM (
        SELECT *
        FROM (
          SELECT
            wr.created_at AS sort_at,
            'withdraw_pending'::text AS kind,
            p.name AS title,
            format('Permohonan penarikan %s', wr.amount::text) AS subtitle,
            wr.id AS reference_id
          FROM public.withdraw_requests wr
          JOIN public.profiles p ON p.id = wr.clinic_id
          WHERE wr.status = 'pending'::public.withdraw_request_status

          UNION ALL

          SELECT
            p.created_at AS sort_at,
            'clinic_registered'::text AS kind,
            p.name AS title,
            'Klinik baru terdaftar' AS subtitle,
            cp.id AS reference_id
          FROM public.clinic_profiles cp
          JOIN public.profiles p ON p.id = cp.id
          WHERE p.role = 'clinic'::public.user_role

          UNION ALL

          SELECT
            COALESCE(wr.processed_at, wr.updated_at) AS sort_at,
            CASE
              WHEN wr.status = 'rejected'::public.withdraw_request_status THEN 'withdraw_rejected'
              ELSE 'withdraw_processed'
            END AS kind,
            p.name AS title,
            CASE
              WHEN wr.status = 'rejected'::public.withdraw_request_status THEN 'Penarikan ditolak'
              WHEN wr.status = 'completed'::public.withdraw_request_status THEN 'Penarikan diselesaikan'
              ELSE 'Penarikan disetujui'
            END AS subtitle,
            wr.id AS reference_id
          FROM public.withdraw_requests wr
          JOIN public.profiles p ON p.id = wr.clinic_id
          WHERE wr.status IN (
            'approved'::public.withdraw_request_status,
            'rejected'::public.withdraw_request_status,
            'completed'::public.withdraw_request_status
          )
        ) AS combined
        ORDER BY sort_at DESC
        LIMIT GREATEST(1, LEAST(p_limit, 50))
      ) AS t
    ),
    '[]'::jsonb
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Clinic management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_clinics(p_filter text DEFAULT 'all')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_is_admin();

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.registered_at DESC)
      FROM (
        SELECT
          cp.id,
          p.name AS clinic_name,
          p.name AS owner_name,
          cp.address,
          cp.is_verified,
          p.is_active,
          p.image_url,
          p.created_at AS registered_at
        FROM public.clinic_profiles cp
        JOIN public.profiles p ON p.id = cp.id
        WHERE p.role = 'clinic'::public.user_role
          AND (
            p_filter IS DISTINCT FROM 'inactive'
            OR p.is_active = false
          )
        ORDER BY p.created_at DESC
      ) AS x
    ),
    '[]'::jsonb
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_active(
  p_clinic_id uuid,
  p_active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_is_admin();

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = p_clinic_id
      AND p.role = 'clinic'::public.user_role
  ) THEN
    RAISE EXCEPTION 'clinic not found';
  END IF;

  UPDATE public.profiles
  SET is_active = p_active
  WHERE id = p_clinic_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Withdraw requests
-- ---------------------------------------------------------------------------
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
  p_rejection_reason text DEFAULT NULL
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
    UPDATE public.withdraw_requests
    SET
      status = 'approved'::public.withdraw_request_status,
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
      processed_at = now(),
      processed_by = auth.uid()
    WHERE id = p_id;

  ELSIF v_action = 'complete' THEN
    IF v_row.status <> 'approved'::public.withdraw_request_status THEN
      RAISE EXCEPTION 'only approved requests can be completed';
    END IF;
    UPDATE public.withdraw_requests
    SET
      status = 'completed'::public.withdraw_request_status,
      processed_at = now(),
      processed_by = auth.uid()
    WHERE id = p_id;

  ELSE
    RAISE EXCEPTION 'invalid action: use approve, reject, or complete';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Pet types
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_pet_types()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_is_admin();

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.name)
      FROM (
        SELECT
          pt.id,
          pt.name,
          pt.created_at,
          (
            SELECT COUNT(DISTINCT b.clinic_id)
            FROM public.bookings b
            JOIN public.customer_pets cp ON cp.id = b.pet_id
            WHERE cp.pet_type_id = pt.id
              AND cp.deleted_at IS NULL
          ) AS clinic_count
        FROM public.pet_types pt
        WHERE pt.deleted_at IS NULL
        ORDER BY pt.name
      ) AS x
    ),
    '[]'::jsonb
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_pet_type(
  p_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text := trim(p_name);
BEGIN
  PERFORM public.assert_is_admin();

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'name is required';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE public.pet_types
    SET name = v_name, deleted_at = NULL, updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'pet type not found';
    END IF;
  ELSE
    INSERT INTO public.pet_types (name)
    VALUES (v_name)
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_soft_delete_pet_type(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.assert_is_admin();

  UPDATE public.pet_types
  SET deleted_at = now(), updated_at = now()
  WHERE id = p_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pet type not found or already deleted';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_recent_activity(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_active(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_withdraw_requests(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_process_withdraw_request(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_pet_types() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_pet_type(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_soft_delete_pet_type(uuid) TO authenticated;
