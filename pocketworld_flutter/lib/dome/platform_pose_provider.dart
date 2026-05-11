// Platform-channel ARPoseProvider.
//
// Expects MethodChannel `aether_arkit` (registered by
// AetherARKitPlugin in ios/Runner) with:
//   `isAvailable`  → Bool
//   `startSession` → Void
//   `stopSession`  → Void
//   `lockOrigin`   → {originX, originY, originZ, worldYaw}
//
// EventChannel `aether_arkit/pose_stream` → JSON pose events:
//   {tx, ty, tz, qx, qy, qz, qw, extrinsic, intrinsicFxFyCxCy,
//    hasOrigin, worldOriginX, worldOriginY, worldOriginZ, worldYaw,
//    isTracking, trackingStateName, t}
//
// If neither iOS ARKit nor Android ARCore is available this provider
// transparently falls back to MockARPoseProvider.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

import '../quality/quality_compute.dart';
import 'ar_pose.dart';
import 'mock_pose_provider.dart';

class PlatformARPoseProvider implements ARPoseProvider {
  static const _method = MethodChannel('aether_arkit');
  static const _poseEvents = EventChannel('aether_arkit/pose_stream');

  final MockARPoseProvider _fallback = MockARPoseProvider();
  bool _usingFallback = false;
  StreamSubscription<dynamic>? _nativeSub;
  final _controller = StreamController<ARPose>.broadcast();
  ARPose? _lastPose;

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() {
    _tryStartNative();
    return _controller.stream;
  }

  Future<void> _tryStartNative() async {
    if (_usingFallback) return;
    try {
      final isAvailable = await _method.invokeMethod<bool>('isAvailable');
      if (isAvailable != true) {
        _switchToFallback();
        return;
      }
      await _method.invokeMethod('startSession');
      _nativeSub = _poseEvents.receiveBroadcastStream().listen(
        (event) => _onNativePose(event),
        onError: (Object _) => _switchToFallback(),
      );
    } on MissingPluginException {
      _switchToFallback();
    } on PlatformException {
      _switchToFallback();
    } catch (_) {
      _switchToFallback();
    }
  }

  void _onNativePose(dynamic event) {
    final map = (event as Map).cast<String, Object?>();
    final position = Vector3(
      (map['tx'] as num?)?.toDouble() ?? 0,
      (map['ty'] as num?)?.toDouble() ?? 0,
      (map['tz'] as num?)?.toDouble() ?? 0,
    );
    final orientation = Quaternion(
      (map['qx'] as num?)?.toDouble() ?? 0,
      (map['qy'] as num?)?.toDouble() ?? 0,
      (map['qz'] as num?)?.toDouble() ?? 0,
      (map['qw'] as num?)?.toDouble() ?? 1,
    );
    final hasOrigin = (map['hasOrigin'] as bool?) ?? false;
    final worldOrigin = Vector3(
      (map['worldOriginX'] as num?)?.toDouble() ?? 0,
      (map['worldOriginY'] as num?)?.toDouble() ?? 0,
      (map['worldOriginZ'] as num?)?.toDouble() ?? 0,
    );
    final worldYaw = (map['worldYaw'] as num?)?.toDouble() ?? 0;

    // Position-based azimuth / elevation per
    // ObjectModeV2ARDomeCoordinator.handleFrame:
    //   az = atan2(rel.z, rel.x) - worldYaw
    //   el = atan2(rel.y, max(horizDist, 0.001))
    double azimuth = 0;
    double elevation = 0;
    if (hasOrigin) {
      final relX = position.x - worldOrigin.x;
      final relY = position.y - worldOrigin.y;
      final relZ = position.z - worldOrigin.z;
      final horizDist = math.sqrt(relX * relX + relZ * relZ);
      azimuth = math.atan2(relZ, relX) - worldYaw;
      elevation = math.atan2(relY, horizDist < 0.001 ? 0.001 : horizDist);
    }

    final extrinsic = _decodeFloatList(map['extrinsic']);
    final intrinsic = _decodeFloatList(map['intrinsicFxFyCxCy']);

    // Optional quality block. Native ships a 128×128 grayscale Y-plane
    // thumbnail on the throttled (6 Hz) frames; we derive sharpness +
    // brightness + signature here in pure Dart. Cross-platform: every
    // platform's native bridge (iOS today, Android next, Web/HarmonyOS
    // mock) only has to ship the gray128 blob — the Laplacian / variance
    // / signature math is shared from lib/quality/quality_compute.dart.
    FrameQualityReport? quality;
    final grayRaw = map['q_gray128'];
    if (grayRaw is Uint8List && grayRaw.length == kQualityGraySide * kQualityGraySide) {
      try {
        quality = computeFrameQualityFromGray128(grayRaw);
      } on ArgumentError {
        // Length mismatch — shouldn't happen since we just checked,
        // but defensively leave quality = null rather than crash the
        // pose stream.
        quality = null;
      }
    } else if (grayRaw is List && grayRaw.length == kQualityGraySide * kQualityGraySide) {
      // Some MethodChannel codecs surface byte blobs as List<int>
      // depending on platform — paper over that here.
      try {
        quality = computeFrameQualityFromGray128(
          Uint8List.fromList(grayRaw.cast<int>()),
        );
      } on ArgumentError {
        quality = null;
      }
    }

    final pose = ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      isTracking: (map['isTracking'] as bool?) ?? true,
      timestamp: (map['t'] as num?)?.toDouble() ?? 0,
      hasOrigin: hasOrigin,
      worldOrigin: worldOrigin,
      worldYaw: worldYaw,
      extrinsic4x4: extrinsic,
      intrinsicFxFyCxCy: intrinsic,
      quality: quality,
      // ARKit reason string (iOS only). Null for any other backend
      // (ARCore plugin not yet registered on Android, HarmonyOS XR
      // Engine, WebXR) — PoseDriftTracker treats null as "normal" so
      // backends without a tracker classification don't poison the
      // health stats.
      trackingStateName: map['trackingStateName'] as String?,
    );
    _lastPose = pose;
    if (!_controller.isClosed) _controller.add(pose);
  }

  static List<double> _decodeFloatList(Object? raw) {
    if (raw is List) {
      return raw.map((v) => (v as num).toDouble()).toList(growable: false);
    }
    return const <double>[];
  }

  void _switchToFallback() {
    if (_usingFallback) return;
    _usingFallback = true;
    _fallback.start().listen((p) {
      _lastPose = p;
      if (!_controller.isClosed) _controller.add(p);
    });
  }

  @override
  Future<void> startRecording() async {
    if (_usingFallback) return _fallback.startRecording();
    try {
      await _method.invokeMethod<void>('startRecording');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[PlatformARPoseProvider] startRecording failed: ${e.message}');
      rethrow;
    } on MissingPluginException {
      // Plugin not registered — recording silently disabled.
    }
  }

  @override
  Future<ARRecordingResult?> stopRecording() async {
    if (_usingFallback) return _fallback.stopRecording();
    try {
      final result = await _method.invokeMapMethod<String, dynamic>(
        'stopRecording',
      );
      if (result == null) return null;
      final path = result['fileURL'];
      if (path is! String || path.isEmpty) return null;
      return ARRecordingResult(
        filePath: path,
        durationSeconds:
            (result['duration'] as num?)?.toDouble() ?? 0,
        fileSizeBytes: (result['fileSize'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[PlatformARPoseProvider] stopRecording failed: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async {
    if (_usingFallback) {
      return _fallback.lockOrigin(distanceMeters: distanceMeters);
    }
    try {
      final result = await _method.invokeMapMethod<String, dynamic>(
        'lockOrigin',
        <String, dynamic>{'distanceMeters': distanceMeters},
      );
      if (result == null) return null;
      return ARLockResult(
        worldOrigin: Vector3(
          (result['originX'] as num?)?.toDouble() ?? 0,
          (result['originY'] as num?)?.toDouble() ?? 0,
          (result['originZ'] as num?)?.toDouble() ?? 0,
        ),
        worldYaw: (result['worldYaw'] as num?)?.toDouble() ?? 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _fallback.stop();
    try {
      await _method.invokeMethod('stopSession');
    } catch (_) {/* best effort */}
  }
}
