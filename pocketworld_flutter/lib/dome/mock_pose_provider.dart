// Mock ARPoseProvider — produces a smooth synthetic orbit around the
// origin so the dome view can be demo'd without any AR runtime. Used
// during development and as a fallback when the native plugin isn't
// registered yet (see PlatformARPoseProvider).

import 'dart:async';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'ar_pose.dart';

class MockARPoseProvider implements ARPoseProvider {
  static const double _orbitRadius = 0.8;
  static const double _sweepDurationSeconds = 60;

  Timer? _timer;
  final _controller = StreamController<ARPose>.broadcast();
  final Stopwatch _clock = Stopwatch();
  ARPose? _lastPose;

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() {
    if (_timer != null) return _controller.stream;
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _emit();
    });
    return _controller.stream;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  void _emit() {
    final t = _clock.elapsedMilliseconds / 1000.0;
    // Two-axis motion: azimuth full sweep in `_sweepDurationSeconds`,
    // elevation oscillates sinusoidally between -40° and +40°.
    final azimuth = (t / _sweepDurationSeconds) * 2 * math.pi;
    final elevation = math.sin(t * 0.21) * (40.0 * math.pi / 180.0);

    // Camera sits on the sphere looking at origin.
    final cx = _orbitRadius * math.cos(elevation) * math.sin(azimuth);
    final cy = _orbitRadius * math.sin(elevation);
    final cz = _orbitRadius * math.cos(elevation) * math.cos(azimuth);
    final position = Vector3(cx, cy, cz);

    // Orientation: look-at matrix → extract quaternion. Vector math
    // ships `setViewMatrix`; easier route is to compose pitch around X
    // * yaw around Y so (0,0,-1) rotates to look at origin.
    final yaw = Quaternion.axisAngle(Vector3(0, 1, 0), azimuth + math.pi);
    final pitch = Quaternion.axisAngle(Vector3(1, 0, 0), elevation);
    final orient = yaw * pitch;

    final pose = ARPose.fromPositionOrientation(
      position: position,
      orientation: orient,
      timestamp: t,
    );
    _lastPose = pose;
    if (!_controller.isClosed) _controller.add(pose);
  }
}
