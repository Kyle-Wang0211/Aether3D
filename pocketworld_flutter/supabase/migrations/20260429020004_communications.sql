-- Communications: notifications, notification_settings, conversations,
-- conversation_members, messages, live_sessions, live_participants.
--
-- notifications is the outbound feed (likes / comments / follows /
-- mentions). conversations + messages are direct messaging skeleton.
-- live_sessions + live_participants are co-viewing skeleton.
--
-- Depends on: 20260429020000_core_business.sql

-- =====================================================================
-- notifications  ── per-user inbox of "something happened to you" events
-- =====================================================================
create table if not exists public.notifications (
  id bigserial primary key,
  recipient_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  -- actor_id is who triggered this. Nullable for system notifications.
  actor_id uuid references auth.users(id) on delete cascade,  -- [PORTABLE]
  type text not null check (type in (
    'work_liked', 'work_commented', 'comment_replied', 'comment_liked',
    'user_followed', 'user_mentioned', 'work_published_by_followee',
    'system_announcement'
  )),
  -- Polymorphic target — the thing being notified about.
  target_type text check (target_type in ('work', 'comment', 'user', 'project')),
  target_id uuid,
  -- Free-form payload for rendering (e.g. preview snippet of comment).
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_recipient
  on public.notifications(recipient_id, created_at desc);
create index if not exists idx_notifications_unread
  on public.notifications(recipient_id, created_at desc)
  where read_at is null;

alter table public.notifications enable row level security;

-- READ: only the recipient.
create policy notifications_select_self on public.notifications
  for select to authenticated
  using (auth.uid() = recipient_id);  -- [PORTABLE]

-- UPDATE: only the recipient (to mark read).
create policy notifications_update_self on public.notifications
  for update to authenticated
  using (auth.uid() = recipient_id)         -- [PORTABLE]
  with check (auth.uid() = recipient_id);   -- [PORTABLE]

-- DELETE: only the recipient.
create policy notifications_delete_self on public.notifications
  for delete to authenticated
  using (auth.uid() = recipient_id);  -- [PORTABLE]

-- INSERT: client-side inserts are intentionally NOT allowed. Notifications
-- are fanned out by Edge Functions / triggers (with service_role) so
-- that we can attribute correctly and rate-limit per-recipient.

-- =====================================================================
-- notification_settings  ── per-user opt-in/out per notification type
-- =====================================================================
create table if not exists public.notification_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,  -- [PORTABLE]
  push_enabled boolean not null default true,
  email_enabled boolean not null default true,
  -- Per-type toggles.
  on_work_liked boolean not null default true,
  on_work_commented boolean not null default true,
  on_comment_replied boolean not null default true,
  on_comment_liked boolean not null default true,
  on_user_followed boolean not null default true,
  on_user_mentioned boolean not null default true,
  on_work_published_by_followee boolean not null default true,
  -- Quiet hours: if both set, push is suppressed during this window in
  -- the user's local TZ. Stored as ints (24-hour clock).
  quiet_hours_start int check (quiet_hours_start between 0 and 23),
  quiet_hours_end int check (quiet_hours_end between 0 and 23),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at_notification_settings
before update on public.notification_settings
for each row execute function public.set_updated_at();

alter table public.notification_settings enable row level security;

create policy notification_settings_self_all on public.notification_settings
  for all to authenticated
  using (auth.uid() = user_id)         -- [PORTABLE]
  with check (auth.uid() = user_id);   -- [PORTABLE]

-- =====================================================================
-- conversations + conversation_members + messages  ── DM skeleton
--
-- Policies on conversations reference conversation_members (you must
-- be a member to see it), so we create both TABLES first, then add
-- policies on both. Without this ordering, the conversations policy
-- would fail to compile because conversation_members doesn't yet exist.
-- =====================================================================
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'dm' check (type in ('dm', 'group')),
  -- For 'dm', this is a stable hash of the two member ids so you can
  -- upsert "open chat with X" without race-creating duplicates.
  dm_pair_key text unique,
  title text,  -- groups only
  created_by uuid references auth.users(id) on delete set null,  -- [PORTABLE]
  last_message_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_conversations_last_message_at
  on public.conversations(last_message_at desc nulls last);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  joined_at timestamptz not null default now(),
  last_read_message_id bigint,
  primary key (conversation_id, user_id)
);

create index if not exists idx_conversation_members_user
  on public.conversation_members(user_id);

-- Now both tables exist; safe to define mutually-referencing policies.

alter table public.conversations enable row level security;

create policy conversations_select_member on public.conversations
  for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  );

create policy conversations_insert_authenticated on public.conversations
  for insert to authenticated
  with check (created_by = auth.uid());  -- [PORTABLE]

create policy conversations_update_member on public.conversations
  for update to authenticated
  using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  )
  with check (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  );

alter table public.conversation_members enable row level security;

-- READ: any member can see who else is in the conversation.
create policy conversation_members_select_member on public.conversation_members
  for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members m2
      where m2.conversation_id = conversation_members.conversation_id
        and m2.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- INSERT: only members can add others (group invites). For 'dm', the
-- creator inserts both members in the same transaction.
create policy conversation_members_insert_member on public.conversation_members
  for insert to authenticated
  with check (
    -- Either you're the row being inserted (joining yourself), or
    -- you're already a member (inviting someone else).
    user_id = auth.uid()  -- [PORTABLE]
    or exists (
      select 1 from public.conversation_members m
      where m.conversation_id = conversation_members.conversation_id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  );

create policy conversation_members_delete_self on public.conversation_members
  for delete to authenticated
  using (user_id = auth.uid());  -- [PORTABLE]

create policy conversation_members_update_self on public.conversation_members
  for update to authenticated
  using (user_id = auth.uid())         -- [PORTABLE]
  with check (user_id = auth.uid());   -- [PORTABLE]

create table if not exists public.messages (
  id bigserial primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  body text not null check (char_length(body) between 1 and 5000),
  -- Attached work (e.g. "check out my latest scan") — optional.
  attached_work_id uuid references public.works(id) on delete set null,
  edited_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_messages_conversation
  on public.messages(conversation_id, created_at desc);

alter table public.messages enable row level security;

create policy messages_select_member on public.messages
  for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  );

create policy messages_insert_member on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()  -- [PORTABLE]
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = auth.uid()  -- [PORTABLE]
    )
  );

-- UPDATE: sender can edit their own message.
create policy messages_update_sender on public.messages
  for update to authenticated
  using (sender_id = auth.uid())         -- [PORTABLE]
  with check (sender_id = auth.uid());   -- [PORTABLE]

-- DELETE: sender can delete own message.
create policy messages_delete_sender on public.messages
  for delete to authenticated
  using (sender_id = auth.uid());  -- [PORTABLE]

-- ── trigger: bump conversations.last_message_at on new message ───────
create or replace function public.touch_conversation_last_message()
returns trigger
security definer
set search_path = public
as $$
begin
  update public.conversations
     set last_message_at = NEW.created_at
   where id = NEW.conversation_id;
  return null;
end;
$$ language plpgsql;

create trigger touch_conversation_last_message_ins
after insert on public.messages
for each row execute function public.touch_conversation_last_message();

-- =====================================================================
-- live_sessions + live_participants  ── live co-viewing skeleton
--
-- live_sessions.select policy references live_participants — same
-- create-tables-first-then-policies pattern as conversations above.
-- =====================================================================
create table if not exists public.live_sessions (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  work_id uuid references public.works(id) on delete set null,
  title text not null check (char_length(title) between 1 and 100),
  status text not null default 'scheduled' check (status in ('scheduled', 'live', 'ended')),
  scheduled_for timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_live_sessions_host on public.live_sessions(host_id);
create index if not exists idx_live_sessions_status on public.live_sessions(status, started_at desc);

create trigger set_updated_at_live_sessions
before update on public.live_sessions
for each row execute function public.set_updated_at();

create table if not exists public.live_participants (
  session_id uuid not null references public.live_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,  -- [PORTABLE]
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (session_id, user_id)
);

create index if not exists idx_live_participants_user on public.live_participants(user_id);

-- Both tables exist; now safe to add policies.

alter table public.live_sessions enable row level security;

-- READ: hosts always; viewers when status='live' OR scheduled OR they
-- are a current participant.
create policy live_sessions_select on public.live_sessions
  for select to anon, authenticated
  using (
    status = 'live'
    or status = 'scheduled'
    or host_id = auth.uid()  -- [PORTABLE]
    or exists (
      select 1 from public.live_participants p
      where p.session_id = live_sessions.id
        and p.user_id = auth.uid()  -- [PORTABLE]
    )
  );

create policy live_sessions_insert_host on public.live_sessions
  for insert to authenticated
  with check (host_id = auth.uid());  -- [PORTABLE]

create policy live_sessions_update_host on public.live_sessions
  for update to authenticated
  using (host_id = auth.uid())         -- [PORTABLE]
  with check (host_id = auth.uid());   -- [PORTABLE]

create policy live_sessions_delete_host on public.live_sessions
  for delete to authenticated
  using (host_id = auth.uid());  -- [PORTABLE]

alter table public.live_participants enable row level security;

-- READ: host + the participant themselves can see participation rows.
create policy live_participants_select on public.live_participants
  for select to authenticated
  using (
    user_id = auth.uid()  -- [PORTABLE]
    or exists (
      select 1 from public.live_sessions s
      where s.id = live_participants.session_id
        and s.host_id = auth.uid()  -- [PORTABLE]
    )
  );

-- INSERT: user joins themselves.
create policy live_participants_insert_self on public.live_participants
  for insert to authenticated
  with check (user_id = auth.uid());  -- [PORTABLE]

create policy live_participants_update_self on public.live_participants
  for update to authenticated
  using (user_id = auth.uid())         -- [PORTABLE]
  with check (user_id = auth.uid());   -- [PORTABLE]
