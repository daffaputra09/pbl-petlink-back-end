-- Platform fee 10%: customer pays gross amount; clinic receives 90% on payment settlement.

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS platform_fee_rate numeric(5, 4),
  ADD COLUMN IF NOT EXISTS platform_fee numeric(14, 2),
  ADD COLUMN IF NOT EXISTS clinic_net_amount numeric(14, 2);

COMMENT ON COLUMN public.payments.platform_fee_rate IS
  'Snapshot of platform fee rate applied when payment was created (default 10%).';
COMMENT ON COLUMN public.payments.platform_fee IS
  'Platform service fee deducted from gross amount.';
COMMENT ON COLUMN public.payments.clinic_net_amount IS
  'Amount credited to clinic balance after platform fee.';

CREATE OR REPLACE FUNCTION public.compute_platform_fee_split(
  p_gross numeric,
  p_rate numeric DEFAULT 0.10
)
RETURNS TABLE (
  platform_fee_rate numeric,
  platform_fee numeric,
  clinic_net_amount numeric
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_fee numeric(14, 2);
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN
    platform_fee_rate := round(COALESCE(p_rate, 0.10), 4);
    platform_fee := 0;
    clinic_net_amount := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  platform_fee_rate := round(COALESCE(p_rate, 0.10), 4);
  v_fee := round(p_gross * platform_fee_rate, 2);
  platform_fee := v_fee;
  clinic_net_amount := p_gross - v_fee;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.compute_platform_fee_split(numeric, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.payments_apply_platform_fee_split()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_split record;
BEGIN
  IF NEW.platform_fee IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.amount IS NULL OR NEW.amount <= 0 THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'paid'::public.payment_status THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_split
  FROM public.compute_platform_fee_split(NEW.amount);

  NEW.platform_fee_rate := v_split.platform_fee_rate;
  NEW.platform_fee := v_split.platform_fee;
  NEW.clinic_net_amount := v_split.clinic_net_amount;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS payments_apply_platform_fee_split ON public.payments;

CREATE TRIGGER payments_apply_platform_fee_split
BEFORE INSERT OR UPDATE ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.payments_apply_platform_fee_split();

CREATE OR REPLACE FUNCTION public.payment_credit_clinic_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'paid'::public.payment_status
    AND OLD.status IS DISTINCT FROM 'paid'::public.payment_status
  THEN
    UPDATE public.clinic_profiles
    SET balance = balance + COALESCE(NEW.clinic_net_amount, NEW.amount)
    WHERE id = NEW.clinic_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_platform_fee_stats(p_year integer DEFAULT NULL)
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
  v_total_gmv numeric;
  v_total_platform_fee numeric;
  v_platform_fee_this_month numeric;
  v_platform_fee_prev_month numeric;
  v_monthly jsonb;
BEGIN
  PERFORM public.assert_is_admin();

  v_year := COALESCE(p_year, EXTRACT(YEAR FROM v_now)::integer);
  v_month_start := date_trunc('month', v_now);
  v_prev_month_start := v_month_start - interval '1 month';

  SELECT COALESCE(SUM(amount), 0) INTO v_total_gmv
  FROM public.payments
  WHERE status = 'paid'::public.payment_status;

  SELECT COALESCE(SUM(platform_fee), 0) INTO v_total_platform_fee
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND platform_fee IS NOT NULL;

  SELECT COALESCE(SUM(platform_fee), 0) INTO v_platform_fee_this_month
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND platform_fee IS NOT NULL
    AND paid_at >= v_month_start;

  SELECT COALESCE(SUM(platform_fee), 0) INTO v_platform_fee_prev_month
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND platform_fee IS NOT NULL
    AND paid_at >= v_prev_month_start
    AND paid_at < v_month_start;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'month', m.month_num,
        'label', m.month_label,
        'gmv', COALESCE(s.gmv, 0),
        'platform_fee', COALESCE(s.platform_fee, 0)
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
      SUM(amount) AS gmv,
      SUM(platform_fee) AS platform_fee
    FROM public.payments
    WHERE status = 'paid'::public.payment_status
      AND paid_at IS NOT NULL
      AND EXTRACT(YEAR FROM paid_at) = v_year
    GROUP BY 1
  ) AS s ON s.month_num = m.month_num;

  RETURN jsonb_build_object(
    'total_gmv', v_total_gmv,
    'total_platform_fee', v_total_platform_fee,
    'platform_fee_this_month', v_platform_fee_this_month,
    'platform_fee_prev_month', v_platform_fee_prev_month,
    'platform_fee_growth_percent',
      CASE
        WHEN v_platform_fee_prev_month > 0 THEN
          ROUND(
            ((v_platform_fee_this_month - v_platform_fee_prev_month) / v_platform_fee_prev_month) * 100,
            1
          )
        ELSE NULL
      END,
    'year', v_year,
    'monthly', v_monthly
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_platform_fees(
  p_search text DEFAULT NULL,
  p_reference_type text DEFAULT NULL,
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
  v_reference_type text := NULLIF(trim(p_reference_type), '');
BEGIN
  PERFORM public.assert_is_admin();

  RETURN jsonb_build_object(
    'items',
    COALESCE(
      (
        SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.paid_at DESC)
        FROM (
          SELECT
            pay.id,
            pay.paid_at,
            pay.reference_type,
            pay.reference_id,
            pay.amount,
            pay.platform_fee,
            pay.clinic_net_amount,
            pay.payment_method,
            pay.midtrans_payment_type,
            clinic_profile.name AS clinic_name,
            customer_profile.name AS customer_name
          FROM public.payments AS pay
          JOIN public.profiles AS clinic_profile ON clinic_profile.id = pay.clinic_id
          JOIN public.profiles AS customer_profile ON customer_profile.id = pay.customer_id
          WHERE pay.status = 'paid'::public.payment_status
            AND pay.platform_fee IS NOT NULL
            AND (
              v_reference_type IS NULL
              OR pay.reference_type::text = v_reference_type
            )
            AND (
              v_search IS NULL
              OR clinic_profile.name ILIKE '%' || v_search || '%'
              OR customer_profile.name ILIKE '%' || v_search || '%'
            )
          ORDER BY pay.paid_at DESC NULLS LAST
          LIMIT v_limit
          OFFSET v_offset
        ) AS x
      ),
      '[]'::jsonb
    ),
    'total',
    (
      SELECT COUNT(*)
      FROM public.payments AS pay
      JOIN public.profiles AS clinic_profile ON clinic_profile.id = pay.clinic_id
      JOIN public.profiles AS customer_profile ON customer_profile.id = pay.customer_id
      WHERE pay.status = 'paid'::public.payment_status
        AND pay.platform_fee IS NOT NULL
        AND (
          v_reference_type IS NULL
          OR pay.reference_type::text = v_reference_type
        )
        AND (
          v_search IS NULL
          OR clinic_profile.name ILIKE '%' || v_search || '%'
          OR customer_profile.name ILIKE '%' || v_search || '%'
        )
    )
  );
END;
$$;

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
  v_total_platform_fee numeric;
  v_platform_fee_this_month numeric;
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

  SELECT COALESCE(SUM(platform_fee), 0) INTO v_total_platform_fee
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND platform_fee IS NOT NULL;

  SELECT COALESCE(SUM(platform_fee), 0) INTO v_platform_fee_this_month
  FROM public.payments
  WHERE status = 'paid'::public.payment_status
    AND platform_fee IS NOT NULL
    AND paid_at >= v_month_start;

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
    'total_platform_fee', v_total_platform_fee,
    'platform_fee_this_month', v_platform_fee_this_month,
    'clinics_this_month', v_clinics_this_month,
    'users_this_month', v_users_this_month,
    'year', v_year,
    'monthly', v_monthly
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_platform_fee_stats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_platform_fees(text, text, integer, integer) TO authenticated;
