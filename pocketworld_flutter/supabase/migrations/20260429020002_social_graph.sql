-- Social graph: follows, blocks.
--
-- Order within this file matters because:
--   • follows.policies reference blocks (for "can't follow if blocked")
--   • blocks.cascade_unfollow trigger references follows (deletes rows)
-- We resolve this by:
--   1. Creating blocks table (without the cascade trigger)
--   2. Creating follows (table + RLS + counts trigger). RLS can now
--      reference blocks since blocks table exists.
--   3. Adding the blocks → follows cascade trigger AFTER follows exists.
--
-- Depends on: 20260429020000_core_business.sql

-- =====================================================================
-- blocks (table + RLS only; cascade trigger added at the end of file)
-- =====================================================================
create table if not exists public.blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  blocked_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  reason text check (char_length(reason) <= 500),
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index if not exists idx_blocks_blocked_id on public.blocks(blocked_id);

alter table public.blocks enable row level security;

-- READ: only the blocker. Blocked users shouldn't be able to enumerate
-- who blocked them (privacy).
create policy blocks_select_blocker on public.blocks
  for select to authenticated
  using (auth.uid() = blocker_id);  -- [PORTABLE]

create policy blocks_insert_self on public.blocks
  for insert to authenticated
  with check (auth.uid() = blocker_id);  -- [PORTABLE]

create policy blocks_delete_self on public.blocks
  for delete to authenticated
  using (auth.uid() = blocker_id);  -- [PORTABLE]

-- =====================================================================
-- follows (directional, A follows B)
-- =====================================================================
create table if not exists public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  followee_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create index if not exists idx_follows_followee_id on public.follows(followee_id, created_at desc);
create index if not exists idx_follows_follower_id on public.follows(follower_id, created_at desc);

alter table public.follows enable row level security;

-- READ: anyone can see who follows whom (public social graph).
create policy follows_select_all on public.follows
  for select to anon, authenticated
  using (true);

-- INSERT: only the follower. Refuse if the followee has blocked them.
create policy follows_insert_self on public.follows
  for insert to authenticated
  with check (
    auth.uid() = follower_id  -- [PORTABLE]
    and not exists (
      select 1 from public.blocks b
      where b.blocker_id = follows.followee_id
        and b.blocked_id = follows.follower_id
    )
  );

-- DELETE: follower can unfollow; followee can also remove a follower.
create policy follows_delete_self_or_followee on public.follows
  for delete to authenticated
  using (
    auth.uid() = follower_id  -- [PORTABLE]
    or auth.uid() = followee_id  -- [PORTABLE]
  );

-- ── trigger: maintain profiles.followers_count + following_count ────
create or replace function public.bump_profile_follow_counts()
returns trigger
security definer
set search_path = public
as $$
begin
  if (TG_OP = 'INSERT') then
    update public.profiles set followers_count = followers_count + 1 where id = NEW.followee_id;
    update public.profiles set following_count = following_count + 1 where id = NEW.follower_id;
  elsif (TG_OP = 'DELETE') then
    update public.profiles set followers_count = greatest(0, followers_count - 1) where id = OLD.followee_id;
    update public.profiles set following_count = greatest(0, following_count - 1) where id = OLD.follower_id;
  end if;
  return null;
end;
$$ language plpgsql;

create trigger bump_profile_follow_counts_ins
after insert on public.follows
for each row execute function public.bump_profile_follow_counts();

create trigger bump_profile_follow_counts_del
after delete on public.follows
for each row execute function public.bump_profile_follow_counts();

-- =====================================================================
-- blocks → follows cascade (now that both tables exist)
-- ─ When A blocks B, force-unfollow both directions
-- =====================================================================
create or replace function public.cascade_block_unfollow()
returns trigger
security definer
set search_path = public
as $$
begin
  delete from public.follows
   where (follower_id = NEW.blocker_id and followee_id = NEW.blocked_id)
      or (follower_id = NEW.blocked_id and followee_id = NEW.blocker_id);
  return null;
end;
$$ language plpgsql;

create trigger cascade_block_unfollow_ins
after insert on public.blocks
for each row execute function public.cascade_block_unfollow();
