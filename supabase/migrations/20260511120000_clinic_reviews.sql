-- Customer reviews for clinics, tied to a completed booking.

CREATE TABLE public.clinic_reviews (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE CASCADE,
  rating smallint NOT NULL,
  comment text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT clinic_reviews_booking_unique UNIQUE (booking_id),
  CONSTRAINT clinic_reviews_ratng_range CHECK (
    rating >= 1
    AND rating <= 5
  )
);

CREATE INDEX clinic_reviews_clinic_id_idx ON public.clinic_reviews USING btree (clinic_id);

CREATE INDEX clinic_reviews_user_id_idx ON public.clinic_reviews USING btree (user_id);

CREATE INDEX clinic_reviews_created_at_idx ON public.clinic_reviews USING btree (created_at);

CREATE OR REPLACE FUNCTION public.clinic_review_matches_booking()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  b public.bookings%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.bookings
  WHERE
    id = NEW.booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found';
  END IF;

  IF NEW.user_id IS DISTINCT FROM b.customer_id THEN
    RAISE EXCEPTION 'user_id must match the booking customer (customer_profiles.id)';
  END IF;

  IF NEW.clinic_id IS DISTINCT FROM b.clinic_id THEN
    RAISE EXCEPTION 'clinic_id must match the booking clinic';
  END IF;

  IF b.status IS DISTINCT FROM 'completed'::public.booking_status THEN
    RAISE EXCEPTION 'reviews are only allowed for bookings with status completed';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER clinic_review_matches_booking_check
BEFORE INSERT
OR UPDATE OF booking_id, user_id, clinic_id ON public.clinic_reviews
FOR EACH ROW
EXECUTE PROCEDURE public.clinic_review_matches_booking();
