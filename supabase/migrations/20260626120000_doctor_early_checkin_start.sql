-- Allow doctor home check-in before scheduled start (radius still enforced).

CREATE OR REPLACE FUNCTION public.doctor_check_in_home_booking(
  p_booking_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_max_radius_meters double precision DEFAULT 200
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
  v_distance double precision;
BEGIN
  PERFORM public.assert_doctor_owns_booking(p_booking_id);

  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
    AND doctor_id = auth.uid();

  IF v_booking.channel IS DISTINCT FROM 'home'::public.booking_channel THEN
    RAISE EXCEPTION 'check-in hanya untuk layanan ke rumah';
  END IF;

  IF v_booking.status IS DISTINCT FROM 'confirmed'::public.booking_status THEN
    RAISE EXCEPTION 'booking tidak dapat di-check-in pada status ini';
  END IF;

  IF v_booking.visit_latitude IS NULL OR v_booking.visit_longitude IS NULL THEN
    RAISE EXCEPTION 'koordinat lokasi kunjungan tidak tersedia';
  END IF;

  IF p_latitude IS NULL OR p_longitude IS NULL THEN
    RAISE EXCEPTION 'koordinat dokter tidak valid';
  END IF;

  IF p_latitude < -90 OR p_latitude > 90 OR p_longitude < -180 OR p_longitude > 180 THEN
    RAISE EXCEPTION 'koordinat dokter tidak valid';
  END IF;

  IF now() >= v_booking.scheduled_end_at THEN
    RAISE EXCEPTION 'waktu kunjungan sudah berakhir';
  END IF;

  v_distance := public.haversine_meters(
    p_latitude,
    p_longitude,
    v_booking.visit_latitude,
    v_booking.visit_longitude
  );

  IF v_distance > p_max_radius_meters THEN
    RAISE EXCEPTION 'Anda belum berada di lokasi customer (jarak %.0f m, maks. %.0f m)',
      v_distance, p_max_radius_meters;
  END IF;

  UPDATE public.bookings
  SET
    status = 'in_progress'::public.booking_status,
    checked_in_at = now()
  WHERE id = p_booking_id
    AND doctor_id = auth.uid();
END;
$$;
