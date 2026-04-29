// Platform-channel ARPoseProvider.
//
// Expects the following MethodChannel surface at `aether_arkit`:
//   `startSession` → void (returns when AR session is running)
//   `stopSession`  → void
//   EventChannel `aether_arkit/pose_stream` → JSON pose events:
//       {
//         tx, ty, tz, qx, qy, qz, qw, isTracking, t
//       }
//
// If the channel isn't registered (e.g. iOS native plugin not wired
// yet, or running on Android / web), this provider transparently
// falls back to MockARPoseProvider so Dart tests and the dome demo
// keep running. Gap tracked in PORTING_BACKLOG.md D1.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

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
      await _method.invokeMethod('startSession');
      _nativeSub = _poseEvents.receiveBroadcastStream().listen(
        (event) {
          final map = (event as Map).cast<String, Object?>();
          final pose = ARPose.fromPositionOrientation(
            position: Vector3(
              (map['tx'] as num?)?.toDouble() ?? 0,
              (map['ty'] as num?)?.toDouble() ?? 0,
              (map['tz'] as num?)?.toDouble() ?? 0,
            ),
            orientation: Quaternion(
              (map['qx'] as num?)?.toDouble() ?? 0,
              (map['qy'] as num?)?.toDouble() ?? 0,
              (map['qz'] as num?)?.toDouble() ?? 0,
              (map['qw'] as num?)?.toDouble() ?? 1,
            ),
            isTracking: (map['isTracking'] as bool?) ?? true,
            timestamp: (map['t'] as num?)?.toDouble() ?? 0,
          );
          _lastPose = pose;
          if (!_controller.isClosed) _controller.add(pose);
        },
        onError: (err) {
          // Surface to logs but don't bring the dome down — fall back
          // to mock so UI keeps animating.
          _switchToFallback();
        },
      );
    } on MissingPluginException {
      _switchToFallback();
    } on PlatformException {
      _switchToFallback();
    } catch (_) {
      _switchToFallback();
    }
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
  Future<void> stop() async {
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _fallback.stop();
    try {
      await _method.invokeMethod('stopSession');
    } catch (_) {/* best effort */}
  }
}
