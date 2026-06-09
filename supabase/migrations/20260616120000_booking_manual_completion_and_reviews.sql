-- Booking: selesai hanya lewat dokter (tanpa auto in_progress berdasarkan waktu).
-- Review klinik: customer dapat mengirim ulasan setelah booking completed.

CREATE OR REPLACE FUNCTION public.sync_clinic_bookings_in_progress()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Tidak lagi mengubah status otomatis; dokter memulai & menyelesaikan manual.
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_clinic_review_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clinic_id uuid;
BEGIN
  v_clinic_id := COALESCE(NEW.clinic_id, OLD.clinic_id);

  UPDATE public.clinic_profiles AS cp
  SET
    total_reviews = (
      SELECT count(*)::integer
      FROM public.clinic_reviews AS cr
      WHERE cr.clinic_id = v_clinic_id
    ),
    average_rating = COALESCE((
      SELECT round(avg(cr.rating)::numeric, 2)
      FROM public.clinic_reviews AS cr
      WHERE cr.clinic_id = v_clinic_id
    ), 0)
  WHERE cp.id = v_clinic_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS clinic_reviews_refresh_stats ON public.clinic_reviews;

CREATE TRIGGER clinic_reviews_refresh_stats
AFTER INSERT OR UPDATE OR DELETE ON public.clinic_reviews
FOR EACH ROW
EXECUTE PROCEDURE public.refresh_clinic_review_stats();

CREATE POLICY "clinic_reviews_insert_own_completed_booking"
ON public.clinic_reviews
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE b.id = clinic_reviews.booking_id
      AND b.customer_id = auth.uid()
      AND b.status = 'completed'::public.booking_status
      AND b.clinic_id = clinic_reviews.clinic_id
  )
);

CREATE OR REPLACE FUNCTION public.submit_clinic_review(
  p_booking_id uuid,
  p_rating smallint,
  p_comment text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_booking public.bookings%ROWTYPE;
  v_review_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'rating harus antara 1 dan 5';
  END IF;

  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
    AND customer_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pemesanan tidak ditemukan';
  END IF;

  IF v_booking.status IS DISTINCT FROM 'completed'::public.booking_status THEN
    RAISE EXCEPTION 'ulasan hanya dapat diberikan setelah pemesanan selesai';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.clinic_reviews AS cr
    WHERE cr.booking_id = p_booking_id
  ) THEN
    RAISE EXCEPTION 'ulasan untuk pemesanan ini sudah pernah dikirim';
  END IF;

  INSERT INTO public.clinic_reviews (
    booking_id,
    user_id,
    clinic_id,
    rating,
    comment
  ) VALUES (
    p_booking_id,
    v_uid,
    v_booking.clinic_id,
    p_rating,
    nullif(trim(p_comment), '')
  )
  RETURNING id INTO v_review_id;

  RETURN v_review_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_clinic_review(uuid, smallint, text)
  TO authenticated;

-- Sinkronkan statistik klinik untuk ulasan yang sudah ada.
UPDATE public.clinic_profiles AS cp
SET
  total_reviews = stats.review_count,
  average_rating = stats.avg_rating
FROM (
  SELECT
    cr.clinic_id,
    count(*)::integer AS review_count,
    COALESCE(round(avg(cr.rating)::numeric, 2), 0) AS avg_rating
  FROM public.clinic_reviews AS cr
  GROUP BY cr.clinic_id
) AS stats
WHERE cp.id = stats.clinic_id;
