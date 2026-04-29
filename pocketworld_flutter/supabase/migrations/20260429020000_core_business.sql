-- Core business tables: profiles, projects, scans, works, comments.
--
-- These hold the primary user-generated content: a user has a profile,
-- creates projects, captures raw scans, scans get trained into works,
-- works receive comments. The social / engagement / moderation layers
-- in subsequent migrations all reference these.
--
-- Migration-readiness notes (search for [PORTABLE] for the lever points
-- when moving off Supabase to self-hosted Postgres / Tencent / Aliyun):
--   • auth.users(id) FKs assume Supabase Auth. To replace, drop and
--     recreate the FK pointing at your new auth-users table; UUIDs
--     should be preserved during the dump/restore so existing rows
--     stay intact.
--   • auth.uid() in RLS policies is a Supabase helper. The equivalent
--     on self-hosted Postgres is a small SQL function that reads sub
--     out of current_setting('request.jwt.claims', true)::jsonb.
--   • Everything else (gen_random_uuid, TIMESTAMPTZ, CHECK constraints,
--     RLS, triggers, pg_cron) is standard Postgres 13+ and portable.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Shared updated_at trigger function. Reused by every table that has
-- an updated_at column. SECURITY DEFINER not required — this just sets
-- NEW.updated_at, which the row's modifier already has permission to do.
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- =====================================================================
-- profiles  ── public-facing user profile, 1:1 with auth.users
-- =====================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,  -- [PORTABLE]
  display_name text not null check (char_length(display_name) between 1 and 50),
  avatar_url text,
  banner_url text,
  bio text check (char_length(bio) <= 1000),
  location text check (char_length(location) <= 100),
  website text check (char_length(website) <= 200),
  is_private boolean not null default false,
  -- Counts maintained by triggers on follows / works.
  followers_count int not null default 0 check (followers_count >= 0),
  following_count int not null default 0 check (following_count >= 0),
  works_count int not null default 0 check (works_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at_profiles
before update on public.profiles
for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;

-- READ: public can read non-private profiles; you can always read your own.
create policy profiles_select_public on public.profiles
  for select to anon, authenticated
  using (
    not is_private
    or auth.uid() = id  -- [PORTABLE]
  );

-- INSERT: you can only insert your own profile (typically called from a
-- post-signup hook or the app's first run).
create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (auth.uid() = id);  -- [PORTABLE]

-- UPDATE: only the owner. Counts are protected via triggers running as
-- definer, so update on counts from clients still goes through this
-- policy (effectively no-op since the trigger overwrites).
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (auth.uid() = id)         -- [PORTABLE]
  with check (auth.uid() = id);   -- [PORTABLE]

-- DELETE: cascades from auth.users; explicit delete from clients
-- disallowed (account deletion goes through admin Edge Function).

-- =====================================================================
-- projects  ── user-organized container for scans / works
-- =====================================================================
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  title text not null check (char_length(title) between 1 and 100),
  description text check (char_length(description) <= 2000),
  cover_thumbnail_url text,
  visibility text not null default 'private'
    check (visibility in ('public', 'private')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_projects_user_id on public.projects(user_id);
create index if not exists idx_projects_visibility on public.projects(visibility)
  where visibility = 'public';

create trigger set_updated_at_projects
before update on public.projects
for each row execute function public.set_updated_at();

alter table public.projects enable row level security;

create policy projects_select_visible on public.projects
  for select to anon, authenticated
  using (
    visibility = 'public'
    or auth.uid() = user_id  -- [PORTABLE]
  );

create policy projects_insert_own on public.projects
  for insert to authenticated
  with check (auth.uid() = user_id);  -- [PORTABLE]

create policy projects_update_own on public.projects
  for update to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

create policy projects_delete_own on public.projects
  for delete to authenticated
  using (auth.uid() = user_id);  -- [PORTABLE]

-- =====================================================================
-- scans  ── raw capture session before training (private to creator)
-- =====================================================================
create table if not exists public.scans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  project_id uuid references public.projects(id) on delete set null,
  status text not null default 'uploading' check (status in (
    'uploading', 'pending', 'training', 'packaging', 'completed', 'failed'
  )),
  frames_count int not null default 0 check (frames_count >= 0),
  duration_seconds int not null default 0 check (duration_seconds >= 0),
  raw_storage_path text,
  cover_thumbnail_path text,
  -- Metadata captured from VGGT pipeline / app:
  --   { device_model, ios_version, capture_quality, ... }
  metadata jsonb not null default '{}'::jsonb,
  error_message text,
  training_started_at timestamptz,
  training_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_scans_user_id on public.scans(user_id);
create index if not exists idx_scans_project_id on public.scans(project_id);
create index if not exists idx_scans_status on public.scans(status);

create trigger set_updated_at_scans
before update on public.scans
for each row execute function public.set_updated_at();

alter table public.scans enable row level security;

-- scans are intentionally private — they're the training fodder, not
-- the published artifact. Only the owner ever reads/writes.
create policy scans_owner_all on public.scans
  for all to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

-- =====================================================================
-- works  ── trained, publishable 3D model
-- =====================================================================
create table if not exists public.works (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  scan_id uuid references public.scans(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  title text not null check (char_length(title) between 1 and 100),
  description text check (char_length(description) <= 5000),
  -- glb is the primary VGGT pipeline output. spz / gsplat / ply are
  -- accepted for community uploads or future format support.
  format text not null check (format in ('glb', 'spz', 'gsplat', 'ply')),
  model_storage_path text not null,
  thumbnail_storage_path text,
  preview_video_path text,
  file_size_bytes bigint check (file_size_bytes >= 0),
  visibility text not null default 'private'
    check (visibility in ('public', 'followers', 'private')),
  -- Cached counts maintained by triggers on work_likes / comments /
  -- work_bookmarks / work_views.
  likes_count int not null default 0 check (likes_count >= 0),
  comments_count int not null default 0 check (comments_count >= 0),
  bookmarks_count int not null default 0 check (bookmarks_count >= 0),
  views_count int not null default 0 check (views_count >= 0),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_works_user_id on public.works(user_id);
create index if not exists idx_works_project_id on public.works(project_id);
create index if not exists idx_works_visibility on public.works(visibility)
  where visibility = 'public';
create index if not exists idx_works_published_at on public.works(published_at desc)
  where visibility = 'public' and published_at is not null;

create trigger set_updated_at_works
before update on public.works
for each row execute function public.set_updated_at();

alter table public.works enable row level security;

-- READ: public works visible to all; otherwise owner only.
-- NOTE: visibility = 'followers' is reserved in the CHECK constraint
-- for the future followers feature. Until that ships, 'followers' is
-- treated like 'private' (no one but the owner sees it). When the
-- followers UI lands, ALTER this policy to OR-in a follows lookup.
-- See migrations/<future>_followers_visibility.sql.
create policy works_select_visible on public.works
  for select to anon, authenticated
  using (
    visibility = 'public'
    or auth.uid() = user_id  -- [PORTABLE]
  );

create policy works_insert_own on public.works
  for insert to authenticated
  with check (auth.uid() = user_id);  -- [PORTABLE]

create policy works_update_own on public.works
  for update to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

create policy works_delete_own on public.works
  for delete to authenticated
  using (auth.uid() = user_id);  -- [PORTABLE]

-- ── trigger: maintain profiles.works_count ───────────────────────────
create or replace function public.bump_profile_works_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.profiles
       set works_count = works_count + 1
     where id = NEW.user_id;
  elsif (TG_OP = 'DELETE') then
    update public.profiles
       set works_count = greatest(0, works_count - 1)
     where id = OLD.user_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_profile_works_count_ins
after insert on public.works
for each row execute function public.bump_profile_works_count();

create trigger bump_profile_works_count_del
after delete on public.works
for each row execute function public.bump_profile_works_count();

-- =====================================================================
-- comments  ── threaded discussion on a work
-- =====================================================================
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.works(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  parent_id uuid references public.comments(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  likes_count int not null default 0 check (likes_count >= 0),
  is_pinned boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_comments_work_id on public.comments(work_id, created_at desc);
create index if not exists idx_comments_user_id on public.comments(user_id);
create index if not exists idx_comments_parent_id on public.comments(parent_id)
  where parent_id is not null;

create trigger set_updated_at_comments
before update on public.comments
for each row execute function public.set_updated_at();

alter table public.comments enable row level security;

-- READ: same visibility as the parent work (public, or own).
create policy comments_select_visible on public.comments
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = comments.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- INSERT: authenticated, on a work the user can READ. user_id must be self.
create policy comments_insert_self on public.comments
  for insert to authenticated
  with check (
    auth.uid() = user_id  -- [PORTABLE]
    and exists (
      select 1 from public.works w
      where w.id = comments.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

create policy comments_update_own on public.comments
  for update to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

-- DELETE: comment owner OR work owner (moderation on own work).
create policy comments_delete_own_or_workowner on public.comments
  for delete to authenticated
  using (
    auth.uid() = user_id  -- [PORTABLE]
    or exists (
      select 1 from public.works w
      where w.id = comments.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- ── trigger: maintain works.comments_count ───────────────────────────
create or replace function public.bump_work_comments_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.works
       set comments_count = comments_count + 1
     where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works
       set comments_count = greatest(0, comments_count - 1)
     where id = OLD.work_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_work_comments_count_ins
after insert on public.comments
for each row execute function public.bump_work_comments_count();

create trigger bump_work_comments_count_del
after delete on public.comments
for each row execute function public.bump_work_comments_count();
