// Cross-platform AR pose abstraction.
//
// Design rule: business logic (dome view, coverage map, guidance
// engine) depends on this interface ONLY. Per-platform AR backends
// (ARKit, ARCore, HarmonyOS XR Engine, WebXR) implement it behind
// a MethodChannel. This keeps the Dart side 100% portable.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Camera pose at one AR frame. All values in world space with the
/// scene's origin at the captured object's approximate center (set by
/// `lockOrigin` once the user has framed the subject).
class ARPose {
  /// Camera position in world space, meters.
  final Vector3 position;

  /// Camera orientation (unit quaternion). `rotate(Vector3(0, 0, -1))`
  /// is the camera's forward axis — ARKit / ARCore convention.
  final Quaternion orientation;

  /// Position-based azimuth in radians, relative to `worldYaw`.
  /// Equals `atan2(rel.z, rel.x) - worldYaw` where
  /// `rel = position - worldOrigin`. Zero means "at the lock pose".
  final double azimuth;

  /// Position-based elevation in radians. Equals
  /// `atan2(rel.y, max(horizDist, 0.001))`. Positive = camera is
  /// above the world origin's horizontal plane.
  final double elevation;

  /// Tracking state. Dome UI hides guidance when not tracking.
  final bool isTracking;

  /// Native AR runtime's tracking-state classification, mirrored as a
  /// string so the Dart layer doesn't carry per-platform enums. Values:
  ///
  ///   "normal", "not_available",
  ///   "limited_initializing", "limited_relocalizing",
  ///   "limited_excessive_motion", "limited_insufficient_features",
  ///   "limited_unknown"
  ///
  /// Set by `AetherARKitPlugin` (iOS) verbatim of `ARCamera.TrackingState`.
  /// Mock providers (Web, HarmonyOS, simulator) pass `"normal"` because
  /// they have no real tracker. Null when the underlying provider hasn't
  /// supplied a value yet — `PoseDriftTracker` treats null as `"normal"`
  /// to avoid mis-attributing diagnostic time to the mock path.
  ///
  /// Used purely for Tier 1 pose-drift aggregation in
  /// [PoseDriftTracker]; nothing in the live UI consumes it (dome cell
  /// colors already convey real-time AR health).
  final String? trackingStateName;

  /// Wall-clock timestamp (seconds since app start, ARFrame timeline)
  /// used by smoothing / time-spread checks.
  final double timestamp;

  /// True iff `lockOrigin` has been called and the world reference
  /// frame is established. Before lock, `azimuth` / `elevation` are
  /// zero placeholders.
  final bool hasOrigin;

  /// World origin (the captured object's approximate center). Zero
  /// vector before lock.
  final Vector3 worldOrigin;

  /// Camera's bearing at lock time. Zero before lock.
  final double worldYaw;

  /// 16-float column-major 4×4 camera-to-world transform from the
  /// underlying AR runtime. Goes straight into curated.json's
  /// `arkit_extrinsic_4x4` field. Empty if the backend doesn't
  /// supply it (mock path).
  final List<double> extrinsic4x4;

  /// Camera intrinsics `[fx, fy, cx, cy]`. Same target field as
  /// extrinsic — populated when the backend has them.
  final List<double> intrinsicFxFyCxCy;

  /// Per-frame quality report — Laplacian variance + brightness +
  /// signature, derived in pure Dart from the 128×128 Y-plane thumbnail
  /// the native AR plugin ships at 6 Hz (matching iOS Aether3D's
  /// `visualSampleInterval = 1.0 / 6.0`). The math itself lives in
  /// `lib/quality/quality_compute.dart` so all four target platforms
  /// (iOS, Android, Web, HarmonyOS) share one implementation — each
  /// platform's native bridge only has to produce the gray128 blob
  /// out of its respective YUV camera buffer.
  ///
  /// ARKit on iOS holds exclusive camera access while the AR session
  /// is running, so the Flutter `camera` plugin can't deliver an image
  /// stream in parallel — that's why this path exists in the first
  /// place. Null on pre-quality frames or when running on the
  /// synthetic mock.
  final FrameQualityReport? quality;

  const ARPose({
    required this.position,
    required this.orientation,
    required this.azimuth,
    required this.elevation,
    required this.isTracking,
    required this.timestamp,
    required this.hasOrigin,
    required this.worldOrigin,
    required this.worldYaw,
    required this.extrinsic4x4,
    required this.intrinsicFxFyCxCy,
    this.quality,
    this.trackingStateName,
  });

  /// Override a subset of fields. Used by [CaptureSession] to build a
  /// "hybrid" effective pose — when ARKit is in `.limited(...)` but IMU
  /// dead-reckoning is anchored, the session substitutes the IMU-derived
  /// az/el and flips `isTracking` back to true so downstream consumers
  /// (dome ingest, dome view) keep operating instead of freezing. The
  /// raw ARKit values stay accessible by listening to the underlying
  /// provider directly; CaptureSession's `poseStream` emits the hybrid.
  ARPose copyWith({
    double? azimuth,
    double? elevation,
    bool? isTracking,
  }) {
    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth ?? this.azimuth,
      elevation: elevation ?? this.elevation,
      isTracking: isTracking ?? this.isTracking,
      timestamp: timestamp,
      hasOrigin: hasOrigin,
      worldOrigin: worldOrigin,
      worldYaw: worldYaw,
      extrinsic4x4: extrinsic4x4,
      intrinsicFxFyCxCy: intrinsicFxFyCxCy,
      quality: quality,
      // Note: deliberately NOT remapping `trackingStateName` from the
      // hybrid `isTracking` boolean. The string is the raw native AR
      // signal from the provider; CaptureSession's IMU-substituted
      // pose still carries the underlying ARKit reason so the drift
      // tracker correctly attributes the degraded window to its
      // root cause (e.g. limited_excessive_motion) rather than to the
      // hybrid resolver's "I forced isTracking back to true" output.
      trackingStateName: trackingStateName,
    );
  }

  /// Convenience factory used by test mocks / synthetic providers
  /// that don't have a real lock origin. Computes az/el from the
  /// camera's forward axis (NOT position).
  static ARPose fromForwardAxis({
    required Vector3 position,
    required Quaternion orientation,
    required double timestamp,
    bool isTracking = true,
  }) {
    final forward = orientation.rotated(Vector3(0, 0, -1));
    final azimuth = math.atan2(forward.x, forward.z);
    final elevation = math.asin(forward.y.clamp(-1.0, 1.0));
    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      isTracking: isTracking,
      timestamp: timestamp,
      hasOrigin: false,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[],
      intrinsicFxFyCxCy: const <double>[],
      // Synthetic / test factory — there is no real AR runtime, so the
      // best the drift tracker can do is "treat as healthy". Matches
      // the mock provider convention.
      trackingStateName: isTracking ? 'normal' : null,
    );
  }
}

/// Result of a successful `lockOrigin` call. Surfaced so the UI can
/// transition from "frame the subject" overlay → "you're locked,
/// orbit now" overlay without waiting for the next pose event.
class ARLockResult {
  final Vector3 worldOrigin;
  final double worldYaw;
  const ARLockResult({required this.worldOrigin, required this.worldYaw});
}

/// Per-frame quality numbers derived from the 128×128 Y-plane
/// thumbnail the AR plugin produces at 6 Hz. Math lives in
/// `lib/quality/quality_compute.dart` (pure Dart, shared across
/// iOS/Android/Web/HarmonyOS); this struct is the result type.
class FrameQualityReport {
  /// Laplacian variance (bigger = sharper).
  final double sharpness;

  /// Mean luma 0..255 across the 128² downsample.
  final double meanBrightness;

  /// Pixel-intensity variance across the 128² downsample. Drives the
  /// GuidanceEngine's low-texture (flat-wall) soft downgrade.
  final double globalVariance;

  /// `signatureSide` × `signatureSide` block-mean grayscale thumbnail.
  /// Used by GuidanceEngine for byte-by-byte novelty / similarity.
  final Uint8List signature;
  final int signatureWidth;
  final int signatureHeight;

  const FrameQualityReport({
    required this.sharpness,
    required this.meanBrightness,
    required this.globalVariance,
    required this.signature,
    required this.signatureWidth,
    required this.signatureHeight,
  });
}

/// Result of `stopRecording` — `null` when no recording was in
/// progress or the platform doesn't support video recording (mock
/// path). File path points at a `.mov` on iOS.
class ARRecordingResult {
  final String filePath;
  final double durationSeconds;
  final int fileSizeBytes;
  const ARRecordingResult({
    required this.filePath,
    required this.durationSeconds,
    required this.fileSizeBytes,
  });
}

abstract class ARPoseProvider {
  /// Start receiving pose updates. Returns a stream that the dome view
  /// subscribes to. Safe to call multiple times — implementations
  /// should be idempotent.
  Stream<ARPose> start();

  /// Snapshot the camera's current pose, place the world origin
  /// `distanceMeters` ahead of the camera's optical axis, capture
  /// `worldYaw` as the bearing at this moment.
  ///
  /// Returns null if the AR session has no current frame to lock
  /// against. Caller should retry after the next pose event.
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0});

  /// Begin writing each ARFrame's `capturedImage` to an .mov file via
  /// AVAssetWriter on the native side. Verbatim port of
  /// ObjectModeV2ARCaptureCoordinator.startRecording.
  Future<void> startRecording();

  /// Finish the in-progress recording and return its path/size/duration.
  /// Returns null when the platform doesn't support recording (e.g. the
  /// synthetic mock provider used on simulator/web).
  Future<ARRecordingResult?> stopRecording();

  /// Stop the AR session. Does not dispose the provider; a subsequent
  /// `start()` call must work.
  Future<void> stop();

  /// Most recent pose synchronously accessible (null if not started yet).
  ARPose? get lastPose;
}
