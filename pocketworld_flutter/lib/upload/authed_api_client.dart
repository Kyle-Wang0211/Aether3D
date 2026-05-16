// Single factory for AetherApiClient instances that pull their bearer
// token straight from the live Supabase session AND know how to ask
// supabase_flutter for a fresh token when the control plane reports
// 401.

import 'dart:convert';
//
// Why centralized:
//   • The capture page's CaptureUploader and the JobStatusWatcher
//     singleton both talk to the control plane and need the same auth
//     wiring. Defining the wiring twice has already drifted once
//     (watcher used the no-auth default constructor → every poll
//     would 401), and Supabase token expiry is a recurring class of
//     bug, so a single source of truth helps.
//
// Token lifecycle:
//   • supabase_flutter caches the most-recent access token in
//     `currentSession?.accessToken`. We read it synchronously per
//     request via `getApiKey`.
//   • If the cached token has expired (default 1 h, can drift past
//     while the app is backgrounded) the control plane returns 401
//     with `jwt_invalid / Fail to fetch data from the url, HTTP 401`.
//   • The `refreshAccessToken` callback then calls
//     `Supabase.instance.client.auth.refreshSession()` which
//     exchanges the long-lived refresh token for a fresh access
//     token. Returns true if a new token landed in `currentSession`
//     for the retry.

import 'package:supabase_flutter/supabase_flutter.dart';

import 'aether_api_client.dart';

/// Build a control-plane API client that automatically refreshes the
/// Supabase session on a 401 and retries the original request once.
AetherApiClient buildAuthedApiClient() {
  // NOTE: re-read `Supabase.instance.client.auth` per call rather than
  // capturing it once. Supabase Flutter is supposed to keep the client
  // singleton stable across signOut/signIn, but if a future refactor
  // ever re-creates it, capturing would silently leak stale auth into
  // every request. Re-reading is microseconds; not worth the risk.
  //
  // Log de-duplication state: a multipart upload's part-ready notifies
  // call getApiKey() ~N+ times in a few seconds (one per part PUT plus
  // the final complete POST). Logging the full session + JWT claims
  // each time floods the console (observed 182 lines for a 91-part
  // 1.5 GB upload). We log only on token CHANGE — the first call after
  // any refresh-and-back-to-stable, plus the very first call of the
  // process. Token still valid + same value → silent.
  String? lastLoggedTokenHash;
  return AetherApiClient(
    getApiKey: () {
      final session = Supabase.instance.client.auth.currentSession;
      final token = session?.accessToken;
      // Cheap fingerprint: token length + last 8 chars. Avoids hashing
      // the full ~800-char JWT every call while still detecting any
      // refresh (which always changes the trailing signature).
      final tokenFingerprint = token == null
          ? 'null'
          : '${token.length}:${token.substring(token.length - 8)}';
      final shouldLog = tokenFingerprint != lastLoggedTokenHash;
      if (shouldLog) {
        lastLoggedTokenHash = tokenFingerprint;
        // ignore: avoid_print
        print(
          '[AuthedAPI] getApiKey: '
          'session=${session == null ? "null" : "exists"} '
          'token=${token == null ? "null" : "${token.length}chars"} '
          'expiresAt=${session?.expiresAt} '
          'user=${session?.user.email}',
        );
        if (token != null) {
          // Decode the JWT payload (middle base64 segment) so we can see
          // the iss / sub / aud claims. If `iss` doesn't match what the
          // control plane expects, that's the smoking gun: app and server
          // are pointing at different Supabase projects.
          final parts = token.split('.');
          if (parts.length == 3) {
            try {
              final padded = parts[1] + '=' * ((4 - parts[1].length % 4) % 4);
              final claims = json.decode(
                utf8.decode(base64Url.decode(padded)),
              ) as Map<String, dynamic>;
              // ignore: avoid_print
              print(
                '[AuthedAPI] JWT claims: '
                'iss=${claims['iss']} '
                'sub=${claims['sub']} '
                'aud=${claims['aud']} '
                'role=${claims['role']} '
                'exp=${claims['exp']} '
                'iat=${claims['iat']}',
              );
            } catch (e) {
              // ignore: avoid_print
              print('[AuthedAPI] JWT decode failed: $e');
            }
          }
        }
      }
      return token;
    },
    refreshAccessToken: () async {
      // ignore: avoid_print
      print('[AuthedAPI] refreshAccessToken: starting');
      try {
        final res = await Supabase.instance.client.auth.refreshSession();
        final ok = res.session?.accessToken != null;
        // ignore: avoid_print
        print(
          '[AuthedAPI] refreshAccessToken: result=$ok '
          'newToken=${res.session?.accessToken == null ? "null" : "${res.session!.accessToken.length}chars"}',
        );
        return ok;
      } on AuthException catch (e) {
        // ignore: avoid_print
        print('[AuthedAPI] refreshAccessToken AuthException: ${e.message}');
        return false;
      } catch (e) {
        // ignore: avoid_print
        print('[AuthedAPI] refreshAccessToken catch-all: $e');
        return false;
      }
    },
  );
}
