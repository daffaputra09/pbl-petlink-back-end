-- Petlink core schema: profiles linked to auth.users, role-specific profiles, pets.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ISO weekday 1 = Monday … 7 = Sunday; each element must be in 1..7.
CREATE OR REPLACE FUNCTION public.open_days_are_valid(days smallint[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT days IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM unnest(days) AS d WHERE d < 1 OR d > 7
    );
$$;

CREATE TYPE public.user_role AS ENUM ('customer', 'clinic', 'doctor', 'admin');

CREATE TYPE public.gender AS ENUM ('male', 'female');

CREATE TABLE public.profiles (
  id uuid NOT NULL PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  name character varying NOT NULL,
  role public.user_role NOT NULL,
  image_url text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX profiles_role_idx ON public.profiles USING btree (role);

CREATE INDEX profiles_is_active_idx ON public.profiles USING btree (is_active);

CREATE TABLE public.customer_profiles (
  id uuid NOT NULL PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  gender public.gender,
  birth_date date,
  address text
);

CREATE TABLE public.clinic_profiles (
  id uuid NOT NULL PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  description text,
  address text,
  longitude double precision,
  latitude double precision,
  open_time time without time zone,
  close_time time without time zone,
  -- ISO-style weekday integers: 1 = Monday … 7 = Sunday (see open_days_are_valid).
  open_days smallint[] NOT NULL DEFAULT '{}'::smallint[],
  CONSTRAINT clinic_open_days_valid CHECK (public.open_days_are_valid(open_days)),
  is_verified boolean NOT NULL DEFAULT false,
  average_rating numeric(4, 2) NOT NULL DEFAULT 0,
  total_reviews integer NOT NULL DEFAULT 0,
  balance numeric(14, 2) NOT NULL DEFAULT 0,
  bank_name character varying(255),
  account_name character varying(255),
  account_number character varying(255),
  bank_code character varying(255),
  CONSTRAINT clinic_total_reviews_non_negative CHECK (total_reviews >= 0)
);

CREATE TABLE public.doctor_profiles (
  id uuid NOT NULL PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  clinic_id uuid NOT NULL REFERENCES public.clinic_profiles (id) ON DELETE RESTRICT,
  bio text,
  specialization text,
  license_number text,
  consultation_fee numeric(14, 2) NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true
);

CREATE INDEX doctor_profiles_clinic_id_idx ON public.doctor_profiles USING btree (clinic_id);

CREATE TABLE public.pet_types (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at timestamp with time zone
);

CREATE UNIQUE INDEX pet_types_name_active_unique ON public.pet_types USING btree (name)
WHERE
  deleted_at IS NULL;

CREATE TABLE public.customer_pets (
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customer_profiles (id) ON DELETE CASCADE,
  pet_type_id uuid NOT NULL REFERENCES public.pet_types (id),
  name text NOT NULL,
  breed text,
  sex public.gender NOT NULL,
  birth_month smallint NOT NULL,
  birth_year smallint NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at timestamp with time zone,
  CONSTRAINT customer_pets_birth_month_range CHECK (
    birth_month >= 1
    AND birth_month <= 12
  ),
  CONSTRAINT customer_pets_birth_year_range CHECK (
    birth_year >= 1900
    AND birth_year <= 2100
  )
);

CREATE INDEX customer_pets_customer_id_idx ON public.customer_pets USING btree (customer_id);

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER pet_types_set_updated_at
BEFORE UPDATE ON public.pet_types
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();

CREATE TRIGGER customer_pets_set_updated_at
BEFORE UPDATE ON public.customer_pets
FOR EACH ROW
EXECUTE PROCEDURE public.set_updated_at();
