-- Per-day clinic opening hours with multiple periods per day (Google Maps style).
-- Replaces clinic_profiles.open_time, close_time, and open_days.

CREATE OR REPLACE FUNCTION public.day_of_week_is_valid(day smallint)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT day >= 1 AND day <= 7;
$$;

CREATE TABLE public.clinic_opening_hours (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE CASCADE,
  -- ISO weekday: 1 = Monday … 7 = Sunday (consistent with legacy open_days).
  day_of_week smallint NOT NULL,
  is_closed boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT clinic_opening_hours_day_valid CHECK (public.day_of_week_is_valid(day_of_week)),
  CONSTRAINT clinic_opening_hours_clinic_day_unique UNIQUE (clinic_id, day_of_week)
);

CREATE INDEX clinic_opening_hours_clinic_id_idx
  ON public.clinic_opening_hours USING btree (clinic_id);

CREATE TABLE public.clinic_opening_hour_periods (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_opening_hours_id uuid NOT NULL REFERENCES public.clinic_opening_hours (id) ON DELETE CASCADE,
  opens_at time without time zone NOT NULL,
  closes_at time without time zone NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT clinic_opening_hour_periods_time_order CHECK (opens_at < closes_at)
);

CREATE INDEX clinic_opening_hour_periods_hours_id_idx
  ON public.clinic_opening_hour_periods USING btree (clinic_opening_hours_id);

CREATE INDEX clinic_opening_hour_periods_hours_sort_idx
  ON public.clinic_opening_hour_periods USING btree (clinic_opening_hours_id, sort_order);

CREATE TRIGGER clinic_opening_hours_set_updated_at
BEFORE UPDATE ON public.clinic_opening_hours
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE OR REPLACE FUNCTION public.clinic_opening_hour_periods_no_overlap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.clinic_opening_hour_periods p
    WHERE
      p.clinic_opening_hours_id = NEW.clinic_opening_hours_id
      AND p.id IS DISTINCT FROM NEW.id
      AND NEW.opens_at < p.closes_at
      AND NEW.closes_at > p.opens_at
  ) THEN
    RAISE EXCEPTION 'opening periods on the same day cannot overlap';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER clinic_opening_hour_periods_no_overlap_check
BEFORE INSERT OR UPDATE ON public.clinic_opening_hour_periods
FOR EACH ROW
EXECUTE PROCEDURE public.clinic_opening_hour_periods_no_overlap();

-- Atomically replace a clinic's weekly schedule.
-- p_days JSON array:
-- [{ "day_of_week": 1, "is_closed": false, "periods": [{ "opens_at": "08:00", "closes_at": "17:00" }] }, ...]
CREATE OR REPLACE FUNCTION public.replace_clinic_opening_hours(
  p_clinic_id uuid,
  p_days jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  day_entry jsonb;
  period_entry jsonb;
  hours_id uuid;
  sort_idx smallint;
  day_num smallint;
  is_day_closed boolean;
BEGIN
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

-- Migrate legacy single-slot hours into per-day schedules.
INSERT INTO public.clinic_opening_hours (clinic_id, day_of_week, is_closed)
SELECT
  cp.id,
  d.day_of_week,
  NOT (
    cp.open_time IS NOT NULL
    AND cp.close_time IS NOT NULL
    AND d.day_of_week = ANY (cp.open_days)
  )
FROM public.clinic_profiles cp
CROSS JOIN generate_series(1, 7) AS d(day_of_week);

INSERT INTO public.clinic_opening_hour_periods (
  clinic_opening_hours_id,
  opens_at,
  closes_at,
  sort_order
)
SELECT
  coh.id,
  cp.open_time,
  cp.close_time,
  0
FROM public.clinic_opening_hours coh
JOIN public.clinic_profiles cp ON cp.id = coh.clinic_id
WHERE
  NOT coh.is_closed
  AND cp.open_time IS NOT NULL
  AND cp.close_time IS NOT NULL;

ALTER TABLE public.clinic_profiles
  DROP CONSTRAINT clinic_open_days_valid,
  DROP COLUMN open_time,
  DROP COLUMN close_time,
  DROP COLUMN open_days;

DROP FUNCTION public.open_days_are_valid(smallint[]);
