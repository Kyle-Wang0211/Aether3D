-- Discovery: tags, work_tags, mentions.
--
-- tags is the canonical hashtag table; work_tags is the M:N bridge
-- between works and tags. mentions tracks @user references inside
-- comments / work descriptions for notification fan-out.
--
-- Depends on: 20260429020000_core_business.sql

-- =====================================================================
-- tags  ── canonical hashtag list
-- =====================================================================
create table if not exists public.tags (
  id uuid primary key default gen_random_uuid(),
  -- Lowercased, normalized form. Display copy lives in display_name.
  name text not null unique check (
    char_length(name) between 1 and 50
    and name = lower(name)
    and name ~ '^[a-z0-9_一-鿿]+$'  -- ascii alnum + underscore + CJK
  ),
  display_name text not null check (char_length(display_name) between 1 and 50),
  -- Cached count of works tagged with this. Maintained by trigger on
  -- work_tags.
  works_count int not null default 0 check (works_count >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_tags_works_count on public.tags(works_count desc);

alter table public.tags enable row level security;

-- READ: tags are public.
create policy tags_select_all on public.tags
  for select to anon, authenticated using (true);

-- INSERT: any authenticated user can create a tag (typical first-use
-- pattern: app does upsert(name) when user hashtag-tags a work).
create policy tags_insert_authenticated on public.tags
  for insert to authenticated with check (true);

-- No UPDATE / DELETE from clients. Admin-only via service_role if
-- a tag needs to be merged or banned.

-- =====================================================================
-- work_tags  ── M:N bridge
-- =====================================================================
create table if not exists public.work_tags (
  work_id uuid not null references public.works(id) on delete cascade,
  tag_id uuid not null references public.tags(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (work_id, tag_id)
);

create index if not exists idx_work_tags_tag_id on public.work_tags(tag_id, created_at desc);

alter table public.work_tags enable row level security;

-- READ: visible iff the parent work is visible.
create policy work_tags_select_visible on public.work_tags
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_tags.work_id
        and (
          w.visibility = 'public'
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- WRITE: only the work owner can attach/detach tags.
create policy work_tags_owner_modify on public.work_tags
  for all to authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_tags.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  )
  with check (
    exists (
      select 1 from public.works w
      where w.id = work_tags.work_id
        and w.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- ── trigger: maintain tags.works_count ───────────────────────────────
create or replace function public.bump_tag_works_count()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.tags set works_count = works_count + 1 where id = NEW.tag_id;
  elsif (TG_OP = 'DELETE') then
    update public.tags set works_count = greatest(0, works_count - 1) where id = OLD.tag_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_tag_works_count_ins
after insert on public.work_tags
for each row execute function public.bump_tag_works_count();

create trigger bump_tag_works_count_del
after delete on public.work_tags
for each row execute function public.bump_tag_works_count();

-- =====================================================================
-- mentions  ── @user references inside comments / work descriptions
--
-- Populated by the app (or an Edge Function that parses body text on
-- insert). Used for notification fan-out: when X mentions Y, Y gets a
-- notification.
-- =====================================================================
create table if not exists public.mentions (
  id bigserial primary key,
  -- The user being mentioned.
  mentioned_user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  -- Polymorphic source.
  source_type text not null check (source_type in ('comment', 'work_description')),
  source_id uuid not null,
  actor_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  created_at timestamptz not null default now()
);

create index if not exists idx_mentions_user_id on public.mentions(mentioned_user_id, created_at desc);
create index if not exists idx_mentions_source on public.mentions(source_type, source_id);
create unique index if not exists uq_mentions_dedup
  on public.mentions(source_type, source_id, mentioned_user_id);

alter table public.mentions enable row level security;

-- READ: the mentioned user can see who mentioned them; the actor can
-- see their own mentions; nobody else.
create policy mentions_select_party on public.mentions
  for select to authenticated
  using (
    auth.uid() = mentioned_user_id  -- [PORTABLE]
    or auth.uid() = actor_id        -- [PORTABLE]
  );

-- INSERT: actor must be self. Source-side validation (does the comment
-- actually contain @mentioned_user_id?) is done in the Edge Function /
-- app, not in RLS.
create policy mentions_insert_self on public.mentions
  for insert to authenticated
  with check (auth.uid() = actor_id);  -- [PORTABLE]

-- DELETE: only when the source row is deleted (CASCADE not possible
-- with polymorphic source, so cleanup is done by the app on delete of
-- comment / work).
