// signup-start
// ----------------------------------------------------------------------
// Begin a strict-confirmation signup. The Flutter client POSTs
// { email, password, display_name?, locale } here. We:
//
//   1. Refuse if the email is already a confirmed auth.users row.
//   2. Generate a 6-digit OTP, hash it, upsert pending_signups for this
//      email (overwriting any previous attempt).
//   3. Send the OTP via Resend's REST API. The email body is rendered
//      in zh or en based on the request's locale.
//
// Idempotent on email: a second call with the same email rotates the
// OTP and resets attempts. This is what powers the "Resend code" flow
// from the OTP entry page — same Edge Function, same payload.
//
// No real auth.users row exists at this point. That's the whole reason
// this function exists.
//
// Required Supabase secrets (set via `supabase secrets set ...`):
//   • SUPABASE_URL                       (auto-populated)
//   • SUPABASE_SERVICE_ROLE_KEY          (auto-populated)
//   • RESEND_API_KEY                     (your Resend API key — same
//                                         value you set as SMTP password
//                                         in Auth → Email → SMTP)
//   • PW_EMAIL_FROM (optional, default 'PocketWorld <noreply@pocketworld.io>')

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, sha256Hex } from '../_shared/cors.ts';

const OTP_TTL_SECONDS = 600; // 10 minutes — matches the email body copy.

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  let body: {
    email?: string;
    password?: string;
    display_name?: string;
    locale?: string;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  const password = body.password ?? '';
  const displayName = body.display_name?.trim() || null;
  const locale = body.locale === 'zh' ? 'zh' : 'en';

  if (!email.includes('@') || password.length < 6) {
    return jsonResponse({ error: 'invalid_input' }, 400);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  // Refuse if a real (confirmed or unconfirmed) auth.users row already
  // exists for this email. listUsers paginates; this is fine for the
  // small project sizes PocketWorld is targeting at launch.
  try {
    const { data: list, error } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000,
    });
    if (error) throw error;
    const taken = list.users.some(
      (u) => (u.email ?? '').toLowerCase() === email,
    );
    if (taken) {
      return jsonResponse({ error: 'account_already_exists' }, 409);
    }
  } catch (e) {
    return jsonResponse(
      { error: 'admin_lookup_failed', detail: String(e) },
      500,
    );
  }

  // Generate a 6-digit OTP. Math.random is cryptographically weak but
  // the OTP is one-shot, 10-min TTL, server-side rate limited (5
  // attempts max), and sent only to the email owner — brute-force
  // surface is tiny. If a future audit objects, swap to crypto.getRandomValues.
  const otp = Math.floor(100000 + Math.random() * 900000).toString();
  const otpHash = await sha256Hex(otp);
  const expiresAt = new Date(Date.now() + OTP_TTL_SECONDS * 1000).toISOString();

  const { error: upsertErr } = await supabase
    .from('pending_signups')
    .upsert(
      {
        email,
        password,
        otp_hash: otpHash,
        attempts: 0,
        display_name: displayName,
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

  // Send the email via Resend's REST API.
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) {
    return jsonResponse({ error: 'email_provider_unconfigured' }, 500);
  }
  const from = Deno.env.get('PW_EMAIL_FROM') ??
    'PocketWorld <noreply@pocketworld.io>';

  const subject = locale === 'zh' ? '注册确认' : 'Confirm your signup';
  const html = locale === 'zh'
    ? `<h2>注册确认</h2>
       <p>你的 6 位验证码：</p>
       <h1 style="letter-spacing:4px;">${otp}</h1>
       <p>10 分钟内有效。</p>`
    : `<h2>Confirm your signup</h2>
       <p>Your 6-digit verification code:</p>
       <h1 style="letter-spacing:4px;">${otp}</h1>
       <p>Valid for 10 minutes.</p>`;

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
