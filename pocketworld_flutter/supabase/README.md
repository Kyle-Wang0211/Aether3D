# PocketWorld backend (Supabase)

Auth flow + database schema + Edge Functions + Storage buckets for the
PocketWorld Flutter app. This README is the one place documenting the
architectural decisions that aren't obvious from reading any single
file.

If you're a future contributor (or future-you in 3 months) trying to
understand why something is the way it is — start here.

---

## Table of contents

1. [Architecture at a glance](#architecture-at-a-glance)
2. [Auth flow](#auth-flow)
3. [RLS philosophy](#rls-philosophy)
4. [Schema overview (26 tables)](#schema-overview)
5. [Storage buckets (4)](#storage-buckets)
6. [Edge Functions (4)](#edge-functions)
7. [pg_cron jobs](#pg_cron-jobs)
8. [Deployment](#deployment)
9. [Migrating off Supabase](#migrating-off-supabase)
10. [Open work](#open-work)

---

## Architecture at a glance

```
┌────────────────────────────────────────────────────────────────┐
│                    Flutter app (iOS / Android)                  │
│   • lib/auth/       — CurrentUser ChangeNotifier + AuthService │
│   • lib/ui/auth/    — Sign in / Sign up / OTP / Reset password │
│   • supabase_flutter SDK 2.8.x                                  │
└─────────────────────────────┬──────────────────────────────────┘
                              │ HTTPS (anon key for SDK,
                              │        no auth for our Edge Fns)
                              ▼
┌────────────────────────────────────────────────────────────────┐
│            Supabase project (Pro tier, US East)                 │
│   • Postgres 15            (8 GB cap on Pro)                    │
│   • GoTrue Auth            (issues JWT sessions)                │
│   • Storage                (4 buckets, 100 GB Pro cap)          │
│   • Edge Functions (Deno)  (4 functions, 2M invocations/mo)     │
│   • pg_cron                (cleanup expired pending rows)       │
└────────────────────────────────────────────────────────────────┘
```

Two non-default decisions that shape everything else:

1. **Strict-confirmation signup** — we don't call `auth.signUp` from the
   client. Instead, our `signup-start` Edge Function holds the signup
   in a `pending_signups` table (with hashed OTP) and only calls
   `admin.createUser` after the OTP is verified. This avoids "ghost"
   `auth.users` rows that block re-signup, and lets us localize the
   OTP email per-user via metadata.

2. **Strict-OTP password reset** — same pattern, different table
   (`pending_password_resets`). Replaces `auth.resetPasswordForEmail`
   so we get the same i18n control over the recovery email and we
   don't leak SMTP errors back to the client.

Everything else (RLS, triggers, cached counts) is straight Supabase
+ standard Postgres.

---

## Auth flow

### Sign-up

```
  1. User types email + password in EmailSignUpView
  2. Dart → POST /functions/v1/signup-start
                { email, password, display_name?, locale }
  3. signup-start:
     a. listUsers + filter — refuse if email is already in auth.users
        (returns 409 account_already_exists)
     b. Generate 6-digit OTP, sha256 hash, upsert pending_signups
     c. Send OTP via Resend API (zh or en template)
     d. Return 200 ok
  4. Dart catches via EmailVerificationPending(email, password)
     → push OtpVerificationView (carries password forward)
  5. User types 6-digit OTP → POST /functions/v1/signup-verify
                                   { email, otp }
  6. signup-verify:
     a. Look up pending_signups, validate OTP hash, attempts < 5
     b. admin.createUser(email_confirm: true, ...)  ← real auth.users
     c. The on_auth_user_created trigger auto-creates:
          - public.profiles row
          - public.notification_settings row
     d. Delete pending_signups row
     e. Return 200 ok
  7. Dart calls signInWithPassword(email, password) → real session
  8. CurrentUser._state = signedIn → AuthGate routes to HomeScreen
```

Why pass password forward in `EmailVerificationPending`:
admin.createUser returns no session. The client has to do a normal
signInWithPassword to obtain one. The only way to do that without
making the user retype is to keep the password in memory across
the OTP screen. That's what `EmailVerificationPending(email, password)`
exists for.

### Password reset

Symmetric flow, separate tables/functions:

```
  1. EmailSignInView "忘记密码?" → push ResetPasswordView
  2. Step 1: enter email
     → Dart → POST /functions/v1/password-reset-start
                  { email, locale }
     → signup-start emails OTP (or silently 200 if email not registered)
  3. Step 2: enter OTP + new password (same page)
     → Dart → POST /functions/v1/password-reset-verify
                  { email, otp, new_password }
     → admin.updateUserById to rotate password
     → Dart calls signInWithPassword → session
     → CurrentUser._state = signedIn → HomeScreen
```

### Bilingual emails

Both Edge Functions accept a `locale` parameter (`'zh'` or `'en'`) and
pick the email body accordingly. The client passes the current
`LocaleNotifier.locale.languageCode`. Supabase's built-in email
templates aren't used for signup/reset — too restrictive for i18n.

The remaining built-in template — "Confirm signup" via Auth → Email
Templates — is rendered when our `admin.createUser` runs (which has
`email_confirm: true`, so it doesn't actually send a real-confirmation
email; the template still exists but is dead).

### iOS Keychain autofill

`AutofillGroup` wraps each form. Email fields use
`AutofillHints.username`, password fields use `AutofillHints.password`
or `AutofillHints.newPassword`. On successful submit we call
`TextInput.finishAutofillContext()` so iOS shows "Save Password to
Keychain". For autocorrect/suggestions to be off (otherwise iOS won't
recognize the field as a password), `AuthField` forces these off when
`isSecure || keyboard == email`.

### Session persistence (30-day idle)

Supabase Flutter SDK persists sessions automatically (SharedPreferences
on Android, Keychain-backed on iOS). On app start, `CurrentUser.bootstrap`
calls `_service.currentUser()` which reads `_client.auth.currentSession`.
On top of that, `CurrentUser` tracks a 30-day "idle since last activity"
timestamp; if exceeded, force-signout regardless of token validity.

---

## RLS philosophy

Every table has RLS enabled, and **public tables follow this layered
pattern**:

```
  SELECT  : own row OR a "visible to others" predicate (e.g.
            visibility = 'public')
  INSERT  : authenticated, with check (user_id = auth.uid())
  UPDATE  : owner only (using = with check)
  DELETE  : owner only (or controlled cascade)
```

Internal-only tables (`audit_logs`) have RLS enabled but **zero
policies** — meaning no client (anon or authenticated) can read/write,
only `service_role` (used by Edge Functions and the SQL Editor) can.

Cached counts (`profiles.works_count`, `works.likes_count`,
`tags.works_count`, etc.) are maintained by `SECURITY DEFINER`
triggers so they update even when the trigger-firing client wouldn't
have UPDATE rights on the count column.

The `'followers'` value in `works.visibility` and similar CHECK
constraints is kept in the schema as a forward-compat slot. Until the
followers UI ships, the RLS treats it like `'private'`. When the UI is
ready, do `alter policy works_select_visible ... using (
  visibility = 'public' OR auth.uid() = user_id OR
  (visibility = 'followers' AND exists (select 1 from public.follows ...))
)`.

---

## Schema overview

26 tables across 7 logical migrations:

| Migration                       | Tables                                                                 |
|---------------------------------|------------------------------------------------------------------------|
| 020000_core_business            | profiles, projects, scans, works, comments                             |
| 020001_engagement               | work_likes, work_bookmarks, comment_likes, work_views, work_versions   |
| 020002_social_graph             | follows, blocks                                                        |
| 020003_discovery                | tags, work_tags, mentions                                              |
| 020004_communications           | notifications, notification_settings, conversations, conversation_members, messages, live_sessions, live_participants |
| 020005_moderation               | reports, audit_logs, collections, collection_works                     |
| 030000_auto_init_user_profile   | (just trigger + backfill, no new tables)                               |

Plus 2 earlier migrations for the auth flow:

| Migration                       | Tables                                                                 |
|---------------------------------|------------------------------------------------------------------------|
| 000000_pending_signups          | pending_signups                                                        |
| 010000_pending_password_resets  | pending_password_resets                                                |

Total: 28 tables in `public`.

### Key relationships

```
auth.users (Supabase)
  ├── profiles            (1:1, FK to auth.users.id)
  ├── notification_settings (1:1, FK to auth.users.id)
  ├── projects            (1:N)
  ├── scans               (1:N)         scans.project_id → projects (nullable)
  ├── works               (1:N)         works.scan_id → scans (nullable)
  │                                     works.project_id → projects (nullable)
  │   ├── comments        (1:N)
  │   │   ├── comment_likes
  │   │   └── (parent_id) for threading
  │   ├── work_likes
  │   ├── work_bookmarks
  │   ├── work_views
  │   ├── work_versions
  │   └── work_tags ──→ tags (M:N)
  ├── follows             (M:N self-ref via follower_id / followee_id)
  ├── blocks              (M:N self-ref)
  ├── notifications       (recipient_id)
  ├── conversations / conversation_members / messages
  └── live_sessions / live_participants
```

`audit_logs` is intentionally not FK-linked (rows survive user
deletion).

---

## Storage buckets

| Bucket       | Public read | File size limit | Allowed mimes                                | Path convention                  |
|--------------|-------------|-----------------|----------------------------------------------|----------------------------------|
| avatars      | yes         | 5 MB            | image/jpeg, png, webp, heic                  | `{user_id}/...`                  |
| thumbnails   | yes         | 10 MB           | image/jpeg, png, webp                        | `{user_id}/...`                  |
| works        | conditional | 500 MB          | model/gltf-binary, application/octet-stream  | `{user_id}/{work_id}.{format}`   |
| scans        | private     | 2 GB            | (any)                                        | `{user_id}/{scan_id}/...`        |

Path convention enforced by RLS: `(storage.foldername(name))[1] = auth.uid()::text`
ensures only the owner can write. For `works`, the SELECT policy
additionally checks `public.works.visibility = 'public'` so anonymous
users can read public work files but not private ones.

---

## Edge Functions

All four are **deployed with `--no-verify-jwt`**: the project uses
the new `sb_publishable_*` API key format, which Supabase Edge
Functions' default JWT verification doesn't recognize. Since these
endpoints are intentionally public (anonymous users hit signup/reset),
disabling JWT verify is correct — the function does its own input
validation + per-email rate limits via `pending_*` tables.

| Function              | Purpose                                                                                         |
|-----------------------|-------------------------------------------------------------------------------------------------|
| signup-start          | Begin a strict-confirmation signup. Refuses if email exists, otherwise upserts pending_signups + emails OTP |
| signup-verify         | Validate OTP, call admin.createUser with email_confirm:true, delete pending row                 |
| password-reset-start  | Same pattern for password reset (silent on missing email for security)                          |
| password-reset-verify | Validate OTP, admin.updateUserById to set new password, delete pending row                      |

### Required secrets

Set in **Edge Functions → Secrets** in the Supabase dashboard, never
in chat / git:

| Secret                     | Used by                | Where to get                          |
|----------------------------|------------------------|---------------------------------------|
| SUPABASE_URL               | all four               | auto-populated                        |
| SUPABASE_SERVICE_ROLE_KEY  | all four               | auto-populated                        |
| RESEND_API_KEY             | -start functions       | https://resend.com/api-keys           |
| PW_EMAIL_FROM (optional)   | -start functions       | defaults to `PocketWorld <noreply@pocketworld.io>` |

`RESEND_API_KEY` is **not** the same place as Auth → Email → SMTP
Settings (those are separate paths). Both use the same Resend key
value, but there are two storage locations and you must update both
when rotating.

---

## pg_cron jobs

Scheduled in migration files via `cron.schedule(...)`. Inspect:
`SELECT jobid, schedule, jobname FROM cron.job ORDER BY jobid;`

| Job name                                  | Schedule       | What it does                                                  |
|-------------------------------------------|----------------|---------------------------------------------------------------|
| cleanup-expired-pending-signups           | every 5 min    | DELETE FROM pending_signups WHERE expires_at < now()          |
| cleanup-expired-pending-password-resets   | every 5 min    | DELETE FROM pending_password_resets WHERE expires_at < now()  |

Each is idempotent and self-recreating — re-running the migration
unschedule + reschedules without duplicating.

---

## Deployment

### From scratch (a brand-new Supabase project)

```bash
# 1. Install Supabase CLI (Homebrew if your Xcode CLT is current,
#    or manual binary download from github.com/supabase/cli/releases)
brew install supabase/tap/supabase

# 2. Login + link
supabase login           # opens browser OAuth
supabase link --project-ref <YOUR_PROJECT_REF>

# 3. Apply all migrations atomically
cd pocketworld_flutter
supabase db push

# 4. Deploy Edge Functions (--no-verify-jwt is critical for sb_publishable_* keys)
supabase functions deploy signup-start          --no-verify-jwt --project-ref <REF>
supabase functions deploy signup-verify         --no-verify-jwt --project-ref <REF>
supabase functions deploy password-reset-start  --no-verify-jwt --project-ref <REF>
supabase functions deploy password-reset-verify --no-verify-jwt --project-ref <REF>

# 5. Set RESEND_API_KEY secret via dashboard (NOT via CLI / chat)
#    https://supabase.com/dashboard/project/<REF>/functions/secrets

# 6. Verify
supabase db push --dry-run     # should print "Remote database is up to date"
supabase functions list        # should show 4 ACTIVE
```

### Incremental migration (adding a new feature)

1. Write a new SQL file in `supabase/migrations/<UTC_TIMESTAMP>_<name>.sql`
2. `supabase db push` — applies only the new file
3. If the migration adds a new Edge Function, `supabase functions deploy <name> --no-verify-jwt`

---

## Migrating off Supabase

The schema is portable Postgres. The Supabase-specific bindings are
isolated and tagged with `[PORTABLE]` comments. To move to self-hosted
Postgres / Tencent CDB / Aliyun RDS:

```
$ grep -rn "\[PORTABLE\]" supabase/migrations/ | wc -l
   80+
```

Each `[PORTABLE]` marker is one of three things:

1. **`auth.users(id)` references** — Supabase's auth schema. On migration:
   - Set up your new auth provider, ideally one that issues JWTs with a
     `sub` claim equal to a UUID per user.
   - Mirror auth.users (or its replacement) under whatever schema your
     new stack uses.
   - Replace each `references auth.users(id)` with `references <new>.users(id)`.
   - Preserve UUIDs across the dump/restore so downstream FKs survive.

2. **`auth.uid()` calls inside RLS policies** — Supabase helper that
   reads the `sub` claim from the JWT. On self-hosted, replace with:
   ```sql
   create or replace function public.current_user_id()
   returns uuid as $$
     select coalesce(
       current_setting('request.jwt.claims', true)::jsonb->>'sub',
       null
     )::uuid;
   $$ language sql stable;
   ```
   Then `sed -i 's/auth\.uid()/public.current_user_id()/g'` across all
   policy definitions.

3. **`storage.objects` policies** — Supabase Storage's table. On
   migration to S3 / Aliyun OSS / Tencent COS:
   - The path convention `{user_id}/{...}` translates 1:1 to bucket
     prefixes.
   - Re-implement the equivalent prefix-based policies in the new
     provider's policy DSL (AWS IAM, OSS RAM, COS CAM).
   - Update the Flutter Storage SDK calls (or write a thin abstraction
     around bucket operations now to ease the future swap).

Edge Functions need a full rewrite for whatever serverless platform
the new stack uses (AWS Lambda, Aliyun Function Compute, Cloudflare
Workers). The TypeScript logic itself is portable; only the
`createClient(...)` import and env-reading lines change.

`pg_cron` is built into all major managed Postgres offerings (Tencent
CDB, AWS RDS, Aliyun RDS via extension) so the cleanup jobs port
without changes.

---

## Open work

These are intentional v1 trade-offs flagged for future iterations:

| Item                                          | Why deferred                                                           |
|-----------------------------------------------|------------------------------------------------------------------------|
| `visibility = 'followers'` policy logic       | Followers UI not yet built; treated as private until then              |
| Audit log fan-out from Edge Functions         | Tables exist, but no Edge Function writes to them yet                  |
| Account switching (multiple sessions)         | v1 keeps single-session; multi-session is a P2 feature                 |
| `analytics_events` table                      | Skipped for v1 — add when product analytics is needed (separate from audit_logs) |
| LCC2 / `.spz` Gaussian Splat support in app   | Schema accepts these formats in `works.format`, but app upload pipeline needs work |
| Reports admin tooling                         | Reports table exists but no admin UI; review via SQL Editor for now    |

---

## Quick reference

```bash
# Run a one-off SQL query against the live DB (read-only sanity check)
supabase db query --linked "select count(*) from public.works"

# See all pending migrations (dry run)
supabase db push --dry-run

# Tail a function's logs
# (no CLI command yet — open in dashboard)
# https://supabase.com/dashboard/project/<REF>/functions/<name>/logs

# Inspect cron jobs
supabase db query --linked "select jobid, schedule, jobname from cron.job"
```
