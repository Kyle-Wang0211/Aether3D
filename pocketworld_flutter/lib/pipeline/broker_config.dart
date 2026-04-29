// Dart port of the Swift prototype's `BackgroundUploadBrokerConfiguration`.
//
// Reads broker endpoint + API key from either:
//   (1) dart-define compile-time constants — preferred for CI and
//       flutter run with `--dart-define=AETHER_BROKER_BASE_URL=...`
//   (2) a platform-channel bridge to native Info.plist (not wired yet —
//       see PORTING_BACKLOG.md's C1 section). When we want real plist
//       reads, extend this file with a MethodChannel call.
//
// Returning `null` from `current()` is the signal that the app should
// fall back to NotConfiguredRemoteB1Client.

class BackgroundUploadBrokerConfiguration {
  final Uri baseUrl;
  final Uri? fallbackBaseUrl;
  final String? apiKey;
  final String? backgroundSessionId;
  final int backgroundMaxConnectionsPerHost;
  final int foregroundMultipartMaxConnectionsPerHost;

  const BackgroundUploadBrokerConfiguration({
    required this.baseUrl,
    this.fallbackBaseUrl,
    this.apiKey,
    this.backgroundSessionId,
    this.backgroundMaxConnectionsPerHost = 4,
    this.foregroundMultipartMaxConnectionsPerHost = 4,
  });

  /// Reads from dart-define compile-time environment. If
  /// AETHER_BROKER_BASE_URL is missing / unparseable, returns null.
  ///
  /// Accepts the same env var names as the Swift implementation so ops
  /// tooling (CI secret templates, etc.) stays unchanged:
  ///   AETHER_BROKER_BASE_URL                        (required)
  ///   AETHER_BROKER_FALLBACK_BASE_URL              (optional)
  ///   AETHER_BROKER_API_KEY                         (optional)
  ///   AETHER_BROKER_BACKGROUND_SESSION_ID           (optional)
  ///   AETHER_BROKER_BACKGROUND_MAX_CONNECTIONS_PER_HOST  (optional int)
  ///   AETHER_BROKER_FOREGROUND_MULTIPART_MAX_CONNECTIONS_PER_HOST (optional int)
  static BackgroundUploadBrokerConfiguration? current() {
    const base = String.fromEnvironment('AETHER_BROKER_BASE_URL');
    if (base.isEmpty) return null;
    final parsedBase = Uri.tryParse(base);
    if (parsedBase == null) return null;
    const fallback = String.fromEnvironment('AETHER_BROKER_FALLBACK_BASE_URL');
    const apiKey = String.fromEnvironment('AETHER_BROKER_API_KEY');
    const sessionId =
        String.fromEnvironment('AETHER_BROKER_BACKGROUND_SESSION_ID');
    const bgConns = int.fromEnvironment(
      'AETHER_BROKER_BACKGROUND_MAX_CONNECTIONS_PER_HOST',
      defaultValue: 4,
    );
    const fgConns = int.fromEnvironment(
      'AETHER_BROKER_FOREGROUND_MULTIPART_MAX_CONNECTIONS_PER_HOST',
      defaultValue: 4,
    );
    return BackgroundUploadBrokerConfiguration(
      baseUrl: parsedBase,
      fallbackBaseUrl:
          fallback.isEmpty ? null : Uri.tryParse(fallback),
      apiKey: apiKey.isEmpty ? null : apiKey,
      backgroundSessionId: sessionId.isEmpty ? null : sessionId,
      backgroundMaxConnectionsPerHost: bgConns,
      foregroundMultipartMaxConnectionsPerHost: fgConns,
    );
  }
}
