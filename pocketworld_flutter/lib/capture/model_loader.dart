// Cross-platform DA3 model loader / tier dispatcher.
//
// Target install path:
//   pocketworld_flutter/lib/capture/model_loader.dart
//
// What this does
// --------------
// Product parity target uses one commercial-safe DA3-BASE CoreML variant:
//
//   SEALED tier:
//     DA3BASE_280x504_N35_image_only.mlmodelc/.mlpackage  — K=35 official image-only
//     ODR tag: `tier:high` (`tier:low` is accepted as a legacy alias)
//
// The sealed model ships as an iOS On-Demand Resource so the wire-down
// install of the PocketWorld app stays small and every platform consumes
// the same Flutter/Dart DA3 runtime contract.
//
// Why Flutter-first
// -----------------
// Per the cross-platform mandate: PocketWorld targets iOS, Android, Web,
// and HarmonyOS, so anything that CAN live in Dart MUST live in Dart.
// Only `NSBundleResourceRequest` (iOS-only ODR API) and `physicalMemory`
// lookup ever cross the MethodChannel. Future platforms (Android Play
// Asset Delivery, Web CDN, HarmonyOS Asset Pack) implement the same
// channel surface and the Dart side is unchanged.
//
// MethodChannel `pocketworld/model_loader`
//   `getDeviceTier`         → String  ("low" | "high")
//   `getLocalModelPath`     → String? — non-null iff cached on device
//   `ensureModelDownloaded` → String  — absolute CoreML path; long-running
//                             Side-effect: progress events on
//                             EventChannel `pocketworld/model_loader/progress`
//                             as `{tag, progress}` where progress in [0, 1].

import 'dart:async';

import 'package:flutter/services.dart';

/// Logical tags describing which DA3 mlpackage to fetch.
///
/// Backend-agnostic: every platform's plugin maps these to its own
/// resource ID (iOS ODR tag, Android Play Asset Delivery pack, Web CDN
/// URL, HarmonyOS Asset Pack tag).
enum ModelTag {
  /// Legacy low-tier alias. It deliberately resolves to the sealed model.
  tierLow('tier:high'),

  /// DA3-BASE K35 official-preprocess image-only model.
  tierHigh('tier:high');

  const ModelTag(this.wireName);

  /// String sent over the MethodChannel.
  final String wireName;

  static ModelTag fromTierString(String tier) {
    switch (tier) {
      case 'low':
        return ModelTag.tierHigh;
      case 'high':
        return ModelTag.tierHigh;
      default:
        return ModelTag.tierHigh;
    }
  }
}

/// Result of an `ensureReady` call. Caller passes `localPath` straight to
/// the platform CoreML/ONNX loader.
class ModelReadyResult {
  ModelReadyResult({
    required this.tag,
    required this.localPath,
    required this.wasAlreadyCached,
  });

  final ModelTag tag;
  final String localPath;

  /// True iff `getLocalModelPath` returned non-null and we skipped the
  /// download path entirely. UI may use this to avoid a one-frame
  /// spinner flash on the cached fast path.
  final bool wasAlreadyCached;
}

/// Progress event emitted while `ensureModelDownloaded` runs.
class ModelDownloadProgress {
  ModelDownloadProgress({required this.tag, required this.fraction});

  final ModelTag tag;

  /// Range [0.0, 1.0]. Resolution depends on backend: iOS
  /// NSBundleResourceRequest reports KVO on `progress.fractionCompleted`
  /// at roughly 10 Hz; Play Asset Delivery streams every ~1% chunk.
  final double fraction;
}

class ModelLoader {
  ModelLoader._();

  static final ModelLoader instance = ModelLoader._();

  static const MethodChannel _method = MethodChannel(
    'pocketworld/model_loader',
  );
  static const EventChannel _progressEvents = EventChannel(
    'pocketworld/model_loader/progress',
  );

  /// Memoize the tier — physicalMemory doesn't change at runtime.
  ModelTag? _cachedTier;

  final _progressController =
      StreamController<ModelDownloadProgress>.broadcast();
  StreamSubscription<dynamic>? _progressSub;

  /// Stream of progress events from the most recent / in-flight
  /// `ensureReady` call. Closed only when the app shuts down.
  Stream<ModelDownloadProgress> get progress => _progressController.stream;

  /// Keep the legacy device-tier call for backend compatibility; current
  /// policy maps every tier to the K35 official image-only DA3-BASE target.
  Future<ModelTag> deviceTier() async {
    final cached = _cachedTier;
    if (cached != null) return cached;
    try {
      final raw = await _method.invokeMethod<String>('getDeviceTier');
      final tier = ModelTag.fromTierString(raw ?? 'low');
      _cachedTier = tier;
      return tier;
    } on MissingPluginException {
      // Plugin not registered (e.g. simulator without ODR, web stub
      // not wired) — fall back to the sealed model so the app keeps booting.
      _cachedTier = ModelTag.tierHigh;
      return ModelTag.tierHigh;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print(
        '[ModelLoader] getDeviceTier failed: ${e.message}; using sealed DA3',
      );
      _cachedTier = ModelTag.tierHigh;
      return ModelTag.tierHigh;
    }
  }

  /// Returns a cached on-device path for the CoreML artifact matching `tag`,
  /// or null if it still needs to be requested.
  ///
  /// Cheap call — does NOT trigger an ODR request. UI may call this on
  /// every capture-page open to decide whether to show a download
  /// dialog or jump straight into capture.
  Future<String?> localPathIfCached(ModelTag tag) async {
    try {
      return await _method.invokeMethod<String>(
        'getLocalModelPath',
        <String, dynamic>{'tag': tag.wireName},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Top-level entry point. Returns the local path of the CoreML artifact that
  /// matches the device's tier, downloading on demand if not yet cached.
  /// Subscribe to `progress` for UI updates during the download window.
  ///
  /// Idempotent — a second call once the model is cached returns
  /// immediately with `wasAlreadyCached = true`.
  Future<ModelReadyResult> ensureReady() async {
    final tag = await deviceTier();

    // Fast path: already cached?
    final cached = await localPathIfCached(tag);
    if (cached != null) {
      return ModelReadyResult(
        tag: tag,
        localPath: cached,
        wasAlreadyCached: true,
      );
    }

    // Attach to progress stream once per app lifetime. The controller's
    // broadcast nature handles multiple UI subscribers.
    _progressSub ??= _progressEvents.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final t = event['tag'] as String?;
          final p = (event['progress'] as num?)?.toDouble();
          if (t != null && p != null) {
            _progressController.add(
              ModelDownloadProgress(
                tag: ModelTag.fromTierString(_tierFromTag(t)),
                fraction: p.clamp(0.0, 1.0),
              ),
            );
          }
        }
      },
      onError: (Object _) {
        /* swallow; UI shows spinner */
      },
    );

    // Slow path — triggers NSBundleResourceRequest.beginAccessingResources
    // (iOS) / AssetPackManager.fetch (Android, future) / fetch from CDN
    // (Web stub, future).
    final path = await _method.invokeMethod<String>(
      'ensureModelDownloaded',
      <String, dynamic>{'tag': tag.wireName},
    );
    if (path == null) {
      throw const ModelLoadException(
        'ensureModelDownloaded returned null path',
      );
    }
    return ModelReadyResult(tag: tag, localPath: path, wasAlreadyCached: false);
  }

  /// Pulls `low` / `high` out of an ODR-style `tier:low` wire tag.
  static String _tierFromTag(String wire) {
    final i = wire.indexOf(':');
    if (i < 0) return wire;
    return wire.substring(i + 1);
  }
}

/// Thrown when the loader can't produce a usable model path. Caller
/// should surface this as a non-recoverable capture-page error.
class ModelLoadException implements Exception {
  const ModelLoadException(this.message);
  final String message;

  @override
  String toString() => 'ModelLoadException: $message';
}
