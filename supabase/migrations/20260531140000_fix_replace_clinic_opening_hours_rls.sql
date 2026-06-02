-- replace_clinic_opening_hours deletes/inserts rows but RLS only had SELECT policies.
-- Run as SECURITY DEFINER after verifying the caller owns the clinic.

CREATE OR REPLACE FUNCTION public.replace_clinic_opening_hours(
  p_clinic_id uuid,
  p_days jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  day_entry jsonb;
  period_entry jsonb;
  hours_id uuid;
  sort_idx smallint;
  day_num smallint;
  is_day_closed boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_clinic_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'forbidden: clinic_id must match authenticated user';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.clinic_profiles WHERE id = p_clinic_id
  ) THEN
    RAISE EXCEPTION 'clinic profile not found';
  END IF;

  IF p_days IS NULL OR jsonb_typeof(p_days) <> 'array' THEN
    RAISE EXCEPTION 'p_days must be a JSON array';
  END IF;

  DELETE FROM public.clinic_opening_hour_periods
  WHERE clinic_opening_hours_id IN (
    SELECT id FROM public.clinic_opening_hours WHERE clinic_id = p_clinic_id
  );

  DELETE FROM public.clinic_opening_hours WHERE clinic_id = p_clinic_id;

  FOR day_entry IN SELECT value FROM jsonb_array_elements(p_days)
  LOOP
    day_num := (day_entry->>'day_of_week')::smallint;
    IF NOT public.day_of_week_is_valid(day_num) THEN
      RAISE EXCEPTION 'day_of_week must be between 1 and 7';
    END IF;

    is_day_closed := COALESCE((day_entry->>'is_closed')::boolean, false);

    INSERT INTO public.clinic_opening_hours (clinic_id, day_of_week, is_closed)
    VALUES (p_clinic_id, day_num, is_day_closed)
    RETURNING id INTO hours_id;

    IF is_day_closed THEN
      IF jsonb_array_length(COALESCE(day_entry->'periods', '[]'::jsonb)) > 0 THEN
        RAISE EXCEPTION 'closed day % cannot have opening periods', day_num;
      END IF;
    ELSE
      sort_idx := 0;
      FOR period_entry IN
        SELECT value FROM jsonb_array_elements(COALESCE(day_entry->'periods', '[]'::jsonb))
      LOOP
        INSERT INTO public.clinic_opening_hour_periods (
          clinic_opening_hours_id,
          opens_at,
          closes_at,
          sort_order
        ) VALUES (
          hours_id,
          (period_entry->>'opens_at')::time without time zone,
          (period_entry->>'closes_at')::time without time zone,
          sort_idx
        );
        sort_idx := sort_idx + 1;
      END LOOP;

      IF sort_idx = 0 THEN
        RAISE EXCEPTION 'open day % must have at least one opening period', day_num;
      END IF;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.replace_clinic_opening_hours(uuid, jsonb) TO authenticated;
