// password-reset-start
// ----------------------------------------------------------------------
// Begin a strict-OTP password reset. Client POSTs { email, locale }; we:
//
//   1. Look up the user via admin.listUsers. If the email is NOT
//      registered, return 200 silently (security: never leak which
//      emails have accounts).
//   2. Generate a 6-digit OTP, hash it, upsert pending_password_resets
//      keyed on email.
//   3. Send a locale-aware email via Resend's REST API.
//
// Idempotent on email — re-calling rotates the OTP, resets attempts,
// re-sends the email. Used for both initial "Send code" and "Resend"
// from the reset password page.
//
// Required Supabase secrets (set previously for signup flow):
//   • SUPABASE_URL                       (auto)
//   • SUPABASE_SERVICE_ROLE_KEY          (auto)
//   • RESEND_API_KEY                     (your Resend API key)
//   • PW_EMAIL_FROM (optional)

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, sha256Hex } from '../_shared/cors.ts';

const OTP_TTL_SECONDS = 600;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  let body: { email?: string; locale?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  const locale = body.locale === 'zh' ? 'zh' : 'en';

  if (!email.includes('@')) {
    return jsonResponse({ error: 'invalid_input' }, 400);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // Check if a real auth.users row exists. If not, return 200 silently
  // — Supabase Auth's built-in recover endpoint does the same. We don't
  // want to leak which emails are registered.
  let userExists = false;
  try {
    const { data: list, error } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000,
    });
    if (error) throw error;
    userExists = list.users.some(
      (u) => (u.email ?? '').toLowerCase() === email,
    );
  } catch (e) {
    return jsonResponse(
      { error: 'admin_lookup_failed', detail: String(e) },
      500,
    );
  }

  if (!userExists) {
    // Pretend success. Don't write to pending_password_resets, don't
    // send an email. Indistinguishable from the success path to the
    // caller.
    return jsonResponse({ ok: true });
  }

  // Generate + hash OTP, upsert pending row, send email.
  const otp = Math.floor(100000 + Math.random() * 900000).toString();
  const otpHash = await sha256Hex(otp);
  const expiresAt = new Date(Date.now() + OTP_TTL_SECONDS * 1000).toISOString();

  const { error: upsertErr } = await supabase
    .from('pending_password_resets')
    .upsert(
      {
        email,
        otp_hash: otpHash,
        attempts: 0,
        locale,
        expires_at: expiresAt,
      },
      { onConflict: 'email' },
    );
  if (upsertErr) {
    return jsonResponse(
      { error: 'db_error', detail: upsertErr.message },
      500,
    );
  }

  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) {
    return jsonResponse({ error: 'email_provider_unconfigured' }, 500);
  }
  const from = Deno.env.get('PW_EMAIL_FROM') ??
    'PocketWorld <noreply@pocketworld.io>';

  const subject = locale === 'zh' ? '重置密码' : 'Reset your password';
  const html = locale === 'zh'
    ? `<h2>重置密码</h2>
       <p>你的 6 位验证码：</p>
       <h1 style="letter-spacing:4px;">${otp}</h1>
       <p>10 分钟内有效。如果你没有请求重置密码，请忽略此邮件。</p>`
    : `<h2>Reset your password</h2>
       <p>Your 6-digit verification code:</p>
       <h1 style="letter-spacing:4px;">${otp}</h1>
       <p>Valid for 10 minutes. If you didn't request a password reset, ignore this email.</p>`;

  const resendResp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${resendKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from, to: email, subject, html }),
  });

  if (!resendResp.ok) {
    const detail = await resendResp.text();
    return jsonResponse({ error: 'email_send_failed', detail }, 502);
  }

  return jsonResponse({ ok: true });
});
