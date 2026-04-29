-- Strict-OTP password reset flow.
--
-- Mirrors the pending_signups pattern: instead of using Supabase Auth's
-- built-in password recovery (which renders an English-only template
-- because .Data has no locale at recovery time), we generate OTPs in
-- our own Edge Function and store them here. password-reset-verify
-- calls admin.updateUserById to rotate the password once the OTP is
-- confirmed.
--
-- No password is stored in this table — unlike pending_signups, the
-- new password isn't known until verify time. Only an OTP hash + the
-- requested locale (so resend can re-use it).
--
-- RLS denies all anon/authenticated access; only service-role Edge
-- Functions touch this table. pg_cron sweeps expired rows every 5 min.

create table if not exists public.pending_password_resets (
  email text primary key,
  otp_hash text not null,
  attempts int not null default 0,
  locale text not null default 'en',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists pending_password_resets_expires_at_idx
  on public.pending_password_resets (expires_at);

alter table public.pending_password_resets enable row level security;

-- Periodic cleanup. pg_cron is already enabled by the pending_signups
-- migration; this just adds another schedule.
do $$
begin
  perform cron.unschedule('cleanup-expired-pending-password-resets');
exception when others then
  null;
end $$;

select cron.schedule(
  'cleanup-expired-pending-password-resets',
  '*/5 * * * *',
  $$delete from public.pending_password_resets where expires_at < now()$$
);
