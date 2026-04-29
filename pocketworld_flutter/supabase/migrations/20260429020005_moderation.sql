-- Moderation + collections.
--
-- reports = user-submitted "this content is bad" requests. Reviewed by
-- you (admin) via SQL Editor or future admin Edge Function.
-- audit_logs = all interesting platform events. Internal-only.
-- collections + collection_works = user-curated lists of works (think
-- "boards" or "playlists").
--
-- Depends on: 20260429020000_core_business.sql

-- =====================================================================
-- reports  ── user reports a work / comment / user
-- =====================================================================
create table if not exists public.reports (
  id bigserial primary key,
  reporter_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  target_type text not null check (target_type in ('work', 'comment', 'user', 'project')),
  target_id uuid not null,
  reason text not null check (reason in (
    'spam', 'harassment', 'hate_speech', 'sexual_content',
    'violence', 'copyright', 'misinformation', 'other'
  )),
  detail text check (char_length(detail) <= 2000),
  status text not null default 'pending' check (status in (
    'pending', 'in_review', 'actioned', 'dismissed'
  )),
  -- Optional admin notes when resolving the report. Only writable via
  -- service_role (admin tooling).
  admin_notes text,
  resolved_by uuid references auth.users(id) on delete set null,  -- [PORTABLE]
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_reports_target on public.reports(target_type, target_id);
create index if not exists idx_reports_status_created
  on public.reports(status, created_at desc) where status = 'pending';
create index if not exists idx_reports_reporter on public.reports(reporter_id);

alter table public.reports enable row level security;

-- READ: reporter can see their own reports (and their status); admin
-- (service_role) bypasses RLS.
create policy reports_select_self on public.reports
  for select to authenticated
  using (auth.uid() = reporter_id);  -- [PORTABLE]

-- INSERT: authenticated, reporter must be self.
create policy reports_insert_self on public.reports
  for insert to authenticated
  with check (
    auth.uid() = reporter_id  -- [PORTABLE]
    -- Resolved fields must start blank.
    and admin_notes is null
    and resolved_by is null
    and resolved_at is null
    and status = 'pending'
  );

-- No UPDATE / DELETE from clients. Admin tools (service_role) handle
-- resolution and bypass RLS.

-- =====================================================================
-- audit_logs  ── append-only platform event log (internal/admin only)
-- =====================================================================
create table if not exists public.audit_logs (
  id bigserial primary key,
  -- Intentionally NO foreign key — log row survives the user being
  -- deleted, so we can investigate post-account-deletion.
  actor_id uuid,
  action text not null check (char_length(action) <= 80),
    -- Examples: 'user.signup', 'user.signin', 'user.signout',
    --   'work.published', 'work.unpublished', 'work.deleted',
    --   'admin.user_banned', 'admin.work_taken_down',
    --   'admin.report_resolved', 'security.password_reset'
  target_type text check (target_type in ('user', 'work', 'comment', 'project', 'report', 'system')),
  target_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_logs_actor
  on public.audit_logs(actor_id, created_at desc) where actor_id is not null;
create index if not exists idx_audit_logs_action
  on public.audit_logs(action, created_at desc);
create index if not exists idx_audit_logs_target
  on public.audit_logs(target_type, target_id);
create index if not exists idx_audit_logs_created
  on public.audit_logs(created_at desc);

alter table public.audit_logs enable row level security;

-- DENY ALL to anon / authenticated. service_role (Edge Functions, your
-- SQL Editor) bypasses RLS by design.
-- (Empty policy set + RLS enabled = no client access.)

-- =====================================================================
-- collections + collection_works  ── user-curated lists of works
-- =====================================================================
create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  title text not null check (char_length(title) between 1 and 100),
  description text check (char_length(description) <= 2000),
  cover_thumbnail_url text,
  visibility text not null default 'private'
    check (visibility in ('public', 'private')),
  works_count int not null default 0 check (works_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_collections_user on public.collections(user_id);
create index if not exists idx_collections_visibility
  on public.collections(visibility) where visibility = 'public';

create trigger set_updated_at_collections
before update on public.collections
for each row execute function public.set_updated_at();

alter table public.collections enable row level security;

create policy collections_select_visible on public.collections
  for select to anon, authenticated
  using (
    visibility = 'public'
    or auth.uid() = user_id  -- [PORTABLE]
  );

create policy collections_insert_own on public.collections
  for insert to authenticated
  with check (auth.uid() = user_id);  -- [PORTABLE]

create policy collections_update_own on public.collections
  for update to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

create policy collections_delete_own on public.collections
  for delete to authenticated
  using (auth.uid() = user_id);  -- [PORTABLE]

create table if not exists public.collection_works (
  collection_id uuid not null references public.collections(id) on delete cascade,
  work_id uuid not null references public.works(id) on delete cascade,
  -- Order within the collection. App can renumber on reorder.
  position int not null default 0,
  added_at timestamptz not null default now(),
  primary key (collection_id, work_id)
);

create index if not exists idx_collection_works_pos
  on public.collection_works(collection_id, position);

alter table public.collection_works enable row level security;

-- READ: visible iff parent collection is visible AND parent work is
-- visible (preventing private works from leaking via someone else's
-- collection).
create policy collection_works_select_visible on public.collection_works
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.collections c
      where c.id = collection_works.collection_id
        and (c.visibility = 'public' or c.user_id = auth.uid())  -- [PORTABLE]
    )
    and exists (
      select 1 from public.works w
      where w.id = collection_works.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- WRITE: collection owner.
create policy collection_works_owner_modify on public.collection_works
  for all to authenticated
  using (
    exists (
      select 1 from public.collections c
      where c.id = collection_works.collection_id
        and c.user_id = auth.uid()  -- [PORTABLE]
    )
  )
  with check (
    exists (
      select 1 from public.collections c
      where c.id = collection_works.collection_id
        and c.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- ── trigger: maintain collections.works_count ────────────────────────
create or replace function public.bump_collection_works_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.collections set works_count = works_count + 1
     where id = NEW.collection_id;
  elsif (TG_OP = 'DELETE') then
    update public.collections set works_count = greatest(0, works_count - 1)
     where id = OLD.collection_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_collection_works_count_ins
after insert on public.collection_works
for each row execute function public.bump_collection_works_count();

create trigger bump_collection_works_count_del
after delete on public.collection_works
for each row execute function public.bump_collection_works_count();
