-- Profile/clinic photos: files live in Supabase Storage; database keeps URL only.
--
-- Flow (mobile register):
--   1. Upload binary → storage.objects in public bucket petlink_bucket
--      Path: {auth.uid()}/profile.{jpg|png|webp}
--   2. App reads public URL via storage.getPublicUrl(path)
--   3. App saves that URL string → public.profiles.image_url (text, not the file)
--
-- Public bucket: anyone with the URL can view the file (profile pictures).
-- Upload/update/delete still require authenticated RLS on storage.objects.
-- See: https://supabase.com/docs/guides/storage/buckets/fundamentals

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'petlink_bucket',
  'petlink_bucket',
  true,
  2097152,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Public read (serving files via CDN URL — public bucket behaviour).
CREATE POLICY "petlink_bucket_public_read"
ON storage.objects
FOR SELECT
TO public
USING (bucket_id = 'petlink_bucket');

-- Authenticated users upload only under their own folder ({user_id}/...).
CREATE POLICY "petlink_bucket_insert_own_folder"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'petlink_bucket'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "petlink_bucket_update_own_folder"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'petlink_bucket'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "petlink_bucket_delete_own_folder"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'petlink_bucket'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Registration RLS: users insert/update their own profile rows after auth.signUp.
-- profiles.image_url stores the Storage public URL, not file bytes.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_select_own"
ON public.profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());

CREATE POLICY "profiles_insert_own"
ON public.profiles
FOR INSERT
TO authenticated
WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update_own"
ON public.profiles
FOR UPDATE
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

ALTER TABLE public.customer_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customer_profiles_select_own"
ON public.customer_profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());

CREATE POLICY "customer_profiles_insert_own"
ON public.customer_profiles
FOR INSERT
TO authenticated
WITH CHECK (id = auth.uid());

CREATE POLICY "customer_profiles_update_own"
ON public.customer_profiles
FOR UPDATE
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

ALTER TABLE public.clinic_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "clinic_profiles_select_own"
ON public.clinic_profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());

CREATE POLICY "clinic_profiles_select_verified_public"
ON public.clinic_profiles
FOR SELECT
TO anon, authenticated
USING (is_verified = true);

CREATE POLICY "clinic_profiles_insert_own"
ON public.clinic_profiles
FOR INSERT
TO authenticated
WITH CHECK (id = auth.uid());

CREATE POLICY "clinic_profiles_update_own"
ON public.clinic_profiles
FOR UPDATE
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

GRANT EXECUTE ON FUNCTION public.replace_clinic_opening_hours(uuid, jsonb) TO authenticated;
