// signup-verify
// ----------------------------------------------------------------------
// Finish a strict-confirmation signup. Client POSTs { email, otp }; we:
//
//   1. Look up the pending_signups row.
//   2. Reject if expired (410), missing (404), or attempts ≥ 5 (429).
//   3. Compare SHA-256(otp) to the stored hash. On mismatch, bump
//      attempts and return 401.
//   4. On match, call admin.createUser with email_confirm:true so the
//      user can immediately sign in with email+password from Dart.
//   5. Delete the pending row.
//
// The client follows up with supabase.auth.signInWithPassword(email,
// password) — Dart still has the password in memory, so we don't need
// to mint a token here.
//
// Required Supabase secrets:
//   • SUPABASE_URL                       (auto)
//   • SUPABASE_SERVICE_ROLE_KEY          (auto)

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, sha256Hex } from '../_shared/cors.ts';

const MAX_ATTEMPTS = 5;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  let body: { email?: string; otp?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  const otp = (body.otp ?? '').trim();
  if (!email.includes('@') || !/^\d{4,8}$/.test(otp)) {
    return jsonResponse({ error: 'invalid_input' }, 400);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  const { data: pending, error: fetchErr } = await supabase
    .from('pending_signups')
    .select('*')
    .eq('email', email)
    .maybeSingle();

  if (fetchErr) {
    return jsonResponse(
      { error: 'db_error', detail: fetchErr.message },
      500,
    );
  }
  if (!pending) {
    return jsonResponse({ error: 'not_found' }, 404);
  }
  if (new Date(pending.expires_at).getTime() < Date.now()) {
    // Cron will reap this eventually; we just refuse here.
    return jsonResponse({ error: 'expired' }, 410);
  }
  if (pending.attempts >= MAX_ATTEMPTS) {
    return jsonResponse({ error: 'too_many_attempts' }, 429);
  }

  const inputHash = await sha256Hex(otp);
  if (inputHash !== pending.otp_hash) {
    // Bump attempts so brute force has a hard cap.
    await supabase
      .from('pending_signups')
      .update({ attempts: pending.attempts + 1 })
      .eq('email', email);
    return jsonResponse({ error: 'invalid_code' }, 401);
  }

  // OTP good — create the real user, pre-confirmed.
  const { data: created, error: createErr } = await supabase.auth.admin
    .createUser({
      email: pending.email,
      password: pending.password,
      email_confirm: true,
      user_metadata: {
        ...(pending.display_name
          ? { display_name: pending.display_name }
          : {}),
        locale: pending.locale,
      },
    });
  if (createErr || !created.user) {
    return jsonResponse(
      { error: 'create_failed', detail: createErr?.message ?? 'no user' },
      500,
    );
  }

  // Best-effort cleanup; cron will mop up if this fails.
  await supabase.from('pending_signups').delete().eq('email', email);

  return jsonResponse({ ok: true, user_id: created.user.id });
});
