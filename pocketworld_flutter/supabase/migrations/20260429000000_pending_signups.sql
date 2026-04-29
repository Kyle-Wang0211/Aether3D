-- Strict-confirmation signup flow.
--
-- The Flutter client never calls auth.signUp directly. Instead it calls
-- the signup-start Edge Function, which writes a row here and emails an
-- OTP. Only when signup-verify confirms the OTP does it create the real
-- auth.users row via the admin API. Until then, the email is "claimed"
-- only inside this table — auth.users stays untouched, so we never
-- accumulate ghost confirmed=NULL accounts that block re-signup.
--
-- Security:
--   • Plaintext password is held for the TTL window only (default
--     10 minutes). RLS denies all anon / authenticated access; only the
--     Edge Functions, which use service_role, can read this table.
--   • OTP itself is stored as a SHA-256 hash, not plaintext.
--   • A pg_cron job sweeps expired rows every 5 minutes.
--
-- This table is intentionally NOT exposed via PostgREST for any role
-- other than service_role.

create table if not exists public.pending_signups (
  email text primary key,
  password text not null,
  otp_hash text not null,
  attempts int not null default 0,
  display_name text,
  locale text not null default 'en',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists pending_signups_expires_at_idx
  on public.pending_signups (expires_at);

alter table public.pending_signups enable row level security;

-- No policies = no anon / authenticated access. Service-role bypasses
-- RLS so the Edge Functions can still read/write.

-- Periodic cleanup. Requires pg_cron (built-in on Supabase).
create extension if not exists pg_cron with schema extensions;

-- Drop any prior schedule so this migration is idempotent.
do $$
begin
  perform cron.unschedule('cleanup-expired-pending-signups');
exception when others then
  -- no-op if the job doesn't exist
  null;
end $$;

select cron.schedule(
  'cleanup-expired-pending-signups',
  '*/5 * * * *',
  $$delete from public.pending_signups where expires_at < now()$$
);
