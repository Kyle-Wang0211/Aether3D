-- Engagement tables: work_likes, work_bookmarks, comment_likes,
-- work_views, work_versions.
--
-- These are user-to-content interactions. Likes/bookmarks/views drive
-- the cached counts on works; versions track training iterations on a
-- given work.
--
-- Depends on: 20260429020000_core_business.sql

-- =====================================================================
-- work_likes  ── user likes a work (1 row per user per work)
-- =====================================================================
create table if not exists public.work_likes (
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  work_id uuid not null references public.works(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, work_id)
);

create index if not exists idx_work_likes_work_id on public.work_likes(work_id, created_at desc);

alter table public.work_likes enable row level security;

-- READ: anyone can see who liked a public work (used by "people who
-- liked this" pages); for non-public works the work itself isn't
-- readable, so this policy doesn't expose it.
create policy work_likes_select_visible on public.work_likes
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_likes.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

create policy work_likes_insert_self on public.work_likes
  for insert to authenticated
  with check (auth.uid() = user_id);  -- [PORTABLE]

create policy work_likes_delete_self on public.work_likes
  for delete to authenticated
  using (auth.uid() = user_id);  -- [PORTABLE]

-- ── trigger: maintain works.likes_count ──────────────────────────────
create or replace function public.bump_work_likes_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.works set likes_count = likes_count + 1 where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works set likes_count = greatest(0, likes_count - 1) where id = OLD.work_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_work_likes_count_ins
after insert on public.work_likes
for each row execute function public.bump_work_likes_count();

create trigger bump_work_likes_count_del
after delete on public.work_likes
for each row execute function public.bump_work_likes_count();

-- =====================================================================
-- work_bookmarks  ── user saves a work to revisit later
-- =====================================================================
create table if not exists public.work_bookmarks (
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  work_id uuid not null references public.works(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, work_id)
);

create index if not exists idx_work_bookmarks_user_id on public.work_bookmarks(user_id, created_at desc);

alter table public.work_bookmarks enable row level security;

-- bookmarks are private — only the bookmarker can see their own.
create policy work_bookmarks_self_all on public.work_bookmarks
  for all to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

-- ── trigger: maintain works.bookmarks_count ──────────────────────────
create or replace function public.bump_work_bookmarks_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.works set bookmarks_count = bookmarks_count + 1 where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works set bookmarks_count = greatest(0, bookmarks_count - 1) where id = OLD.work_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_work_bookmarks_count_ins
after insert on public.work_bookmarks
for each row execute function public.bump_work_bookmarks_count();

create trigger bump_work_bookmarks_count_del
after delete on public.work_bookmarks
for each row execute function public.bump_work_bookmarks_count();

-- =====================================================================
-- comment_likes  ── like a comment
-- =====================================================================
create table if not exists public.comment_likes (
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  comment_id uuid not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);

create index if not exists idx_comment_likes_comment_id on public.comment_likes(comment_id);

alter table public.comment_likes enable row level security;

create policy comment_likes_select_visible on public.comment_likes
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.comments c
      where c.id = comment_likes.comment_id
        -- Re-uses the visibility check from comments_select_visible —
        -- a comment is visible iff its parent work is visible.
        and exists (
          select 1 from public.works w
          where w.id = c.work_id
            and (
              w.visibility = 'public'
              or w.user_id = auth.uid()  -- [PORTABLE]
            )
        )
    )
  );

create policy comment_likes_insert_self on public.comment_likes
  for insert to authenticated
  with check (auth.uid() = user_id);  -- [PORTABLE]

create policy comment_likes_delete_self on public.comment_likes
  for delete to authenticated
  using (auth.uid() = user_id);  -- [PORTABLE]

-- ── trigger: maintain comments.likes_count ───────────────────────────
create or replace function public.bump_comment_likes_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.comments set likes_count = likes_count + 1 where id = NEW.comment_id;
  elsif (TG_OP = 'DELETE') then
    update public.comments set likes_count = greatest(0, likes_count - 1) where id = OLD.comment_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_comment_likes_count_ins
after insert on public.comment_likes
for each row execute function public.bump_comment_likes_count();

create trigger bump_comment_likes_count_del
after delete on public.comment_likes
for each row execute function public.bump_comment_likes_count();

-- =====================================================================
-- work_views  ── view event log for analytics (not used in feed yet)
-- =====================================================================
create table if not exists public.work_views (
  id bigserial primary key,
  -- viewer_id is nullable because anonymous viewers count too.
  viewer_id uuid references auth.users(id) on delete set null,  -- [PORTABLE]
  work_id uuid not null references public.works(id) on delete cascade,
  -- de-dup key: same viewer + same work + same hour = 1 view.
  view_bucket timestamptz not null default date_trunc('hour', now()),
  created_at timestamptz not null default now()
);

create unique index if not exists uq_work_views_dedup
  on public.work_views(work_id, coalesce(viewer_id::text, 'anon'), view_bucket);
create index if not exists idx_work_views_work_id on public.work_views(work_id, created_at desc);

alter table public.work_views enable row level security;

-- READ: only the work owner sees view records (analytics).
create policy work_views_select_workowner on public.work_views
  for select to authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_views.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- INSERT: anyone (anon or authenticated) can log a view, but for
-- authenticated users viewer_id must equal self.
create policy work_views_insert on public.work_views
  for insert to anon, authenticated
  with check (
    viewer_id is null
    or viewer_id = auth.uid()  -- [PORTABLE]
  );

-- ── trigger: maintain works.views_count (only on first row per
-- bucket, since bucket is part of the unique key — duplicates raise
-- and are caught by ON CONFLICT in the inserter).
create or replace function public.bump_work_views_count()
returns trigger
security definer
set search_path = public
as $$
begin
  update public.works set views_count = views_count + 1 where id = NEW.work_id;
  return null;
end;
$$ language plpgsql;

create trigger bump_work_views_count_ins
after insert on public.work_views
for each row execute function public.bump_work_views_count();

-- =====================================================================
-- work_versions  ── version history for a work (re-trains, manual edits)
-- =====================================================================
create table if not exists public.work_versions (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.works(id) on delete cascade,
  version_number int not null check (version_number >= 1),
  format text not null check (format in ('glb', 'spz', 'gsplat', 'ply')),
  model_storage_path text not null,
  thumbnail_storage_path text,
  file_size_bytes bigint check (file_size_bytes >= 0),
  notes text check (char_length(notes) <= 2000),
  created_at timestamptz not null default now(),
  unique (work_id, version_number)
);

create index if not exists idx_work_versions_work_id
  on public.work_versions(work_id, version_number desc);

alter table public.work_versions enable row level security;

-- READ: same visibility as the parent work.
create policy work_versions_select_visible on public.work_versions
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_versions.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- INSERT/UPDATE/DELETE: only the work owner.
create policy work_versions_owner_modify on public.work_versions
  for all to authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_versions.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  )
  with check (
    exists (
      select 1 from public.works w
      where w.id = work_versions.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  );
