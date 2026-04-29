-- Auto-initialize public.profiles + public.notification_settings when
-- a new auth.users row is created.
--
-- Without this, signed-up users have no profile row, so app code
-- querying public.profiles for the current user gets nothing back.
-- We bridge the auth → business layer here so the app can assume "if
-- you're signed in, your profile row exists."
--
-- The trigger runs SECURITY DEFINER so it bypasses RLS on public.profiles
-- (which would otherwise block the auth-system insert). It's idempotent
-- via ON CONFLICT DO NOTHING — safe across migration replays.
--
-- Display name default: email local part (everything before @). User
-- can rename later via the Me page. We don't try to read a display_name
-- from raw_user_meta_data because our signup-verify Edge Function
-- intentionally doesn't set it (display name UX is on the to-do list).

create or replace function public.handle_new_user()
returns trigger
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data->>'display_name', ''),
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;

  insert into public.notification_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$ language plpgsql;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Backfill: any existing auth.users row that's missing its profile /
-- notification_settings row gets one now. Idempotent.
-- ---------------------------------------------------------------------
insert into public.profiles (id, display_name)
select
  u.id,
  coalesce(
    nullif(u.raw_user_meta_data->>'display_name', ''),
    split_part(u.email, '@', 1)
  )
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

insert into public.notification_settings (user_id)
select u.id from auth.users u
where not exists (select 1 from public.notification_settings ns where ns.user_id = u.id)
on conflict (user_id) do nothing;
