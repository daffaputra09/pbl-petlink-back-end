-- Wrap auth.uid() in (select auth.uid()) so Postgres evaluates it once per query (initplan).

DO $$
DECLARE
  r record;
  v_qual text;
  v_check text;
  v_sql text;
  v_to text;
  v_roles text;
BEGIN
  FOR r IN
    SELECT
      schemaname,
      tablename,
      policyname,
      cmd,
      qual,
      with_check,
      roles,
      permissive
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        qual LIKE '%auth.uid()%'
        OR with_check LIKE '%auth.uid()%'
      )
  LOOP
    v_qual := r.qual;
    v_check := r.with_check;

    IF v_qual IS NOT NULL THEN
      v_qual := replace(v_qual, 'auth.uid()', '(select auth.uid())');
    END IF;
    IF v_check IS NOT NULL THEN
      v_check := replace(v_check, 'auth.uid()', '(select auth.uid())');
    END IF;

    v_roles := array_to_string(r.roles, ', ');
    v_to := CASE
      WHEN v_roles <> '' THEN format(' TO %s', v_roles)
      ELSE ''
    END;

    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON %I.%I',
      r.policyname,
      r.schemaname,
      r.tablename
    );

    IF r.cmd = 'INSERT' THEN
      v_sql := format(
        'CREATE POLICY %I ON %I.%I AS %s FOR INSERT%s WITH CHECK (%s)',
        r.policyname,
        r.schemaname,
        r.tablename,
        r.permissive,
        v_to,
        v_check
      );
    ELSIF r.cmd = 'SELECT' THEN
      v_sql := format(
        'CREATE POLICY %I ON %I.%I AS %s FOR SELECT%s USING (%s)',
        r.policyname,
        r.schemaname,
        r.tablename,
        r.permissive,
        v_to,
        v_qual
      );
    ELSIF r.cmd = 'DELETE' THEN
      v_sql := format(
        'CREATE POLICY %I ON %I.%I AS %s FOR DELETE%s USING (%s)',
        r.policyname,
        r.schemaname,
        r.tablename,
        r.permissive,
        v_to,
        v_qual
      );
    ELSIF r.cmd = 'UPDATE' THEN
      v_sql := format(
        'CREATE POLICY %I ON %I.%I AS %s FOR UPDATE%s USING (%s) WITH CHECK (%s)',
        r.policyname,
        r.schemaname,
        r.tablename,
        r.permissive,
        v_to,
        v_qual,
        v_check
      );
  ELSE
      CONTINUE;
    END IF;

    EXECUTE v_sql;
  END LOOP;
END $$;
