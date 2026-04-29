-- Supabase Storage buckets + RLS policies on storage.objects.
--
-- Four buckets, each with a distinct privacy model:
--   • avatars     — public read,  owner write (small images)
--   • thumbnails  — public read,  owner write (work covers)
--   • works       — visibility-aware read (public works are readable),
--                   owner write (.glb / .spz / .gsplat / .ply)
--   • scans       — fully private (raw scans never leave the owner)
--
-- Convention: every object path starts with `{user_id}/...`. RLS
-- policies match (storage.foldername(name))[1] = auth.uid()::text to
-- enforce path ownership. This convention is portable to any S3-style
-- store — when you migrate to Tencent COS / Aliyun OSS / MinIO, you
-- enforce the same prefix-based policy in their bucket policy DSL.
--
-- Migration-readiness: the `storage` schema is Supabase-specific (it
-- wraps Postgres + GoTrue + a separate object backend). On migration:
--   1. Move physical files via rclone / awscli to new bucket
--   2. Recreate buckets at the new provider with same names
--   3. Mirror these RLS policies in the new provider's policy language
--      (e.g. AWS S3 IAM policies, Aliyun OSS RAM policies)
--   4. App code calls switch from supabase.storage.from('works')
--      .upload(...) to whatever new client SDK supports same path
--      convention

-- ---------------------------------------------------------------------
-- Bucket creation. Idempotent via on conflict.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 5 * 1024 * 1024,
    array['image/jpeg', 'image/png', 'image/webp', 'image/heic']),
  ('thumbnails', 'thumbnails', true, 10 * 1024 * 1024,
    array['image/jpeg', 'image/png', 'image/webp']),
  ('works', 'works', false, 500 * 1024 * 1024,
    array['model/gltf-binary', 'application/octet-stream']),
  -- 2 GB written explicitly as a bigint literal — multiplication chain
  -- 2*1024*1024*1024 silently overflows int4 in Postgres before the
  -- implicit cast to bigint can apply.
  ('scans', 'scans', false, 2147483648, null)  -- mime open
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- avatars  ── public read, owner write/delete (path = {user_id}/...)
-- ---------------------------------------------------------------------
create policy "avatars_select_public"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');

create policy "avatars_insert_self"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "avatars_update_self"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "avatars_delete_self"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

-- ---------------------------------------------------------------------
-- thumbnails  ── same as avatars (public read, owner write)
-- ---------------------------------------------------------------------
create policy "thumbnails_select_public"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'thumbnails');

create policy "thumbnails_insert_self"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'thumbnails'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "thumbnails_update_self"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'thumbnails'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "thumbnails_delete_self"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'thumbnails'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

-- ---------------------------------------------------------------------
-- works  ── visibility-aware read; owner write
--
-- Path convention:  works/{user_id}/{work_id}.{format}
-- The path's {work_id} segment is matched against public.works to
-- determine if a non-owner can read.
-- ---------------------------------------------------------------------

-- Owner can always read their own files.
create policy "works_select_owner"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'works'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

-- Anyone can read a file whose corresponding works row has
-- visibility='public'.
create policy "works_select_public"
  on storage.objects for select to anon, authenticated
  using (
    bucket_id = 'works'
    and exists (
      select 1 from public.works w
      where w.model_storage_path = storage.objects.name
        and w.visibility = 'public'
    )
  );

create policy "works_insert_self"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'works'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "works_update_self"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'works'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "works_delete_self"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'works'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

-- ---------------------------------------------------------------------
-- scans  ── fully private (owner only). Path = {user_id}/{scan_id}/...
-- ---------------------------------------------------------------------
create policy "scans_select_self"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'scans'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "scans_insert_self"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'scans'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "scans_update_self"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'scans'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );

create policy "scans_delete_self"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'scans'
    and (storage.foldername(name))[1] = auth.uid()::text  -- [PORTABLE]
  );
