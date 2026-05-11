// SamFrameProvider — Dart-side client for the iOS native bridge added
// in AetherARKitPlugin.swift Phase B1.
//
// Two MethodChannel calls are exposed:
//
//   1. `getDeviceTier()` → DeviceTier
//        Asked once at SAM-loop startup. Returns "high" on iPhone 12 Pro+
//        (>= 5 GB physicalMemory) and "low" on iPhone 11 / 12 (4 GB,
//        reported as ~3.86 GB). The MobileSAM loop refuses to start
//        on "low" because warmup would push phys_footprint past the
//        iOS jetsam threshold during 4K AR + AVAssetWriter capture.
//
//   2. `requestSamFrame({size = 1024})` → SamFrameSnapshot?
//        Pulls the latest ARFrame.capturedImage on demand, YUV→RGBA
//        and bilinear-scaled to (size×size). 4 MB of RGBA bytes per
//        call at the default 1024.
//
// Why TransferableTypedData wrapping:
//   The 4 MB RGBA buffer comes back to the Dart main isolate as a
//   plain Uint8List. Without intervention, sending it to the SAM
//   inference isolate (in [SamLoop]) via SendPort would COPY the 4 MB
//   across thread boundaries — measurably (5–10 ms) on iPhone 12 Pro
//   and enough to drop a Flutter UI frame at 60 fps.
//
//   Wrapping into `TransferableTypedData` (Dart 2.15+) lets us *transfer*
//   the buffer's underlying memory ownership to the receiver isolate
//   in O(1). The main isolate loses access (which is fine — we don't
//   need it again), and the SAM isolate materializes a `ByteBuffer`
//   over the same memory with no copy.
//
//   The transfer is one-way (no shared memory), so this is safe even
//   with isolates that don't share state. The receiver calls
//   `.materialize().asUint8List()` to get its working buffer.
//
// Cross-platform note: this file only knows how to talk to the iOS
// MethodChannel `aether_arkit`. On Android/Web/HarmonyOS where no
// equivalent native bridge exists, [SamLoop] never instantiates this
// class — it just emits null frames and the manifest skips
// `subject_mask` for that capture (graceful degrade). The Android
// ARCore equivalent will register the same channel name when that
// scaffolding lands.

import 'dart:async';
import 'dart:isolate' show TransferableTypedData;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Result of one [SamFrameProvider.getDeviceTier] call.
///
/// Mirrors the Swift-side `physMemBytes >= 5_000_000_000` boundary.
/// The threshold is duplicated documentation-only here; the Swift
/// side is the source of truth so changing it server-side requires
/// only one edit.
enum DeviceTier {
  /// iPhone 12 Pro+, 13+, 14+, 15+ (>= 5 GB physicalMemory). SAM
  /// inference + manifest carrying subject masks is enabled.
  high,

  /// iPhone 11, 12, 12 mini (4 GB RAM, ~3.86 GB reported). SAM is
  /// SKIPPED to stay below the iOS jetsam threshold during 4K AR +
  /// AVAssetWriter capture (~2.0 GB phys_footprint already).
  low,
}

/// One pulled-then-transferred ARFrame snapshot.
///
/// The RGBA bytes are wrapped in [TransferableTypedData] so the
/// caller (which runs on the Dart main isolate) can hand the result
/// off to a background isolate for SAM inference WITHOUT copying the
/// 4 MB buffer. After [transferableRgba.materialize()] is called on
/// either side, only THAT side has access — it's a one-way transfer.
class SamFrameSnapshot {
  /// Pixel dimension of the square RGBA buffer. Always == [width] ==
  /// [height] (the native bridge always returns squares; aspect ratio
  /// is squashed to match MobileSAM's ResizeLongestSide(1024) training
  /// preprocessing).
  final int width;
  final int height;

  /// Wall-clock timestamp at which we received the snapshot from the
  /// platform side. Used by the SAM loop to associate masks with
  /// captured frames (temporal nearest-neighbour matching at curate
  /// time).
  final DateTime receivedAt;

  /// Zero-copy-transferable wrapper around `width * height * 4` bytes
  /// of RGBA pixel data. Materialize once, then it's gone from the
  /// other side.
  final TransferableTypedData transferableRgba;

  const SamFrameSnapshot({
    required this.width,
    required this.height,
    required this.receivedAt,
    required this.transferableRgba,
  });
}

class SamFrameProvider {
  /// Same channel name the AetherARKitPlugin registers. Hardcoding
  /// rather than DI'ing because the channel is a process-singleton
  /// and a typo would silently fail at first invocation rather than
  /// at startup.
  static const MethodChannel _channel = MethodChannel('aether_arkit');

  /// Cache the device tier — `getDeviceTier` reads
  /// `ProcessInfo.physicalMemory` which doesn't change at runtime.
  /// Asking once and caching avoids an unnecessary MethodChannel
  /// roundtrip for every SamLoop.start() call.
  DeviceTier? _cachedTier;

  /// Synchronous getter — returns null if [getDeviceTier] hasn't
  /// resolved yet. Non-blocking; callers that need definite value
  /// should await [getDeviceTier].
  DeviceTier? get cachedTier => _cachedTier;

  /// Ask the native side for the device's memory tier. Result is
  /// cached after the first successful call.
  ///
  /// Returns [DeviceTier.low] on any error (failure to invoke,
  /// missing channel, malformed response) — defaulting to "low"
  /// means SAM stays disabled if we can't confirm the device is
  /// safe, rather than risking an OOM on a misclassified phone.
  Future<DeviceTier> getDeviceTier() async {
    if (_cachedTier != null) return _cachedTier!;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getDeviceTier',
      );
      if (result == null) {
        debugPrint('[SamFrameProvider] getDeviceTier returned null; assuming LOW');
        return _cachedTier = DeviceTier.low;
      }
      final tierStr = result['tier'] as String?;
      final memGB = (result['physicalMemoryGB'] as num?)?.toDouble();
      final tier = tierStr == 'high' ? DeviceTier.high : DeviceTier.low;
      debugPrint(
        '[SamFrameProvider] device tier=${tier.name} '
        '(physicalMemory=${memGB?.toStringAsFixed(2)} GB)',
      );
      return _cachedTier = tier;
    } on PlatformException catch (e) {
      debugPrint('[SamFrameProvider] getDeviceTier PlatformException: $e — assuming LOW');
      return _cachedTier = DeviceTier.low;
    } on MissingPluginException {
      // Channel not registered. Either we're on Android/Web/HarmonyOS
      // (where SAM should never run anyway) or simulator/test.
      debugPrint('[SamFrameProvider] aether_arkit channel not registered — assuming LOW (no SAM)');
      return _cachedTier = DeviceTier.low;
    } catch (e) {
      debugPrint('[SamFrameProvider] getDeviceTier unexpected error: $e — assuming LOW');
      return _cachedTier = DeviceTier.low;
    }
  }

  /// Pull the most recent ARFrame from the native plugin, scaled to
  /// (size × size). Returns null if:
  ///   • the ARSession hasn't produced its first frame yet (warm-up)
  ///   • the channel isn't registered (non-iOS, simulator)
  ///   • the native side threw (malformed pixel buffer, etc.)
  ///   • the response is missing required fields
  ///
  /// Caller should treat null as "skip this SAM tick", not as an
  /// error — null is the normal degraded path.
  ///
  /// `size` is clamped to [64, 1024] on the Swift side (>1024 gets
  /// downsampled by SAM internally anyway).
  Future<SamFrameSnapshot?> requestFrame({int size = 1024}) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestSamFrame',
        <String, dynamic>{'size': size},
      );
      if (result == null) return null;
      final width = (result['width'] as num?)?.toInt();
      final height = (result['height'] as num?)?.toInt();
      final rgba = result['rgba'] as Uint8List?;
      if (width == null || height == null || rgba == null) {
        debugPrint(
          '[SamFrameProvider] requestSamFrame missing fields: '
          'width=$width height=$height rgba=${rgba?.length}',
        );
        return null;
      }
      if (rgba.length != width * height * 4) {
        debugPrint(
          '[SamFrameProvider] requestSamFrame size mismatch: '
          'rgba.length=${rgba.length} expected=${width * height * 4}',
        );
        return null;
      }
      // Wrap in TransferableTypedData so the SAM isolate can take
      // ownership without copying the 4 MB buffer.
      final transferable = TransferableTypedData.fromList(<Uint8List>[rgba]);
      return SamFrameSnapshot(
        width: width,
        height: height,
        receivedAt: DateTime.now(),
        transferableRgba: transferable,
      );
    } on PlatformException catch (e) {
      debugPrint('[SamFrameProvider] requestFrame PlatformException: $e');
      return null;
    } on MissingPluginException {
      // Expected on non-iOS / simulator — only print once per process
      // would be nice but not worth the bookkeeping; just stay quiet
      // since the SAM loop won't start on a LOW-tier-treated platform
      // anyway (getDeviceTier returns low when channel missing).
      return null;
    } catch (e) {
      debugPrint('[SamFrameProvider] requestFrame unexpected error: $e');
      return null;
    }
  }
}
