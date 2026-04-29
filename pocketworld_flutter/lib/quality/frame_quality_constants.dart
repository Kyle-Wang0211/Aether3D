// Dart mirror of FrameQualityConstants referenced across
// ObjectModeV2GuidanceEngine + ObjectModeV2QualityDebugOverlay.
//
// Numerical values are initial estimates derived from the Swift source
// signature + the behavior described in the prototype's comments. Real
// tuning will happen on-device against the iPhone 14 Pro once the
// camera frame → GPU → GuidanceEngine pipeline is fully wired (that's
// tracked in PORTING_BACKLOG.md under D2).

class FrameQualityConstants {
  FrameQualityConstants._();

  /// Laplacian-variance threshold below which a frame is marked blurry
  /// → hard reject. Matches the iPhone 14 Pro tuning budget; raise for
  /// high-light scenes, lower for low-light.
  static const double blurThresholdLaplacian = 500.0;

  /// Mean-brightness threshold below which a frame is considered dark
  /// (hard reject for the object-mode-V2 pipeline).
  static const double darkThresholdBrightness = 30.0;

  /// Mean-brightness threshold above which a frame is considered
  /// blown-out (hard reject).
  static const double brightThresholdBrightness = 235.0;

  /// Minimum global variance under which the target texture is
  /// considered too flat for reliable SfM tracking — soft downgrade.
  static const double minLocalVarianceForTexture = 28.0;

  /// Inherited from the native ORB pipeline — minimum feature count per
  /// frame before SfM is viable. Used by the broker `pipelineAuditFields`
  /// payload so the cloud can cross-check the client's local audit.
  static const int minOrbFeaturesForSfm = 180;
  static const int warnOrbFeaturesForSfm = 260;
}

/// Target-zone mode — affects acceptance threshold for the target zone
/// occupancy / similarity gates. Keep the raw values stable since they
/// appear as string IDs in the broker audit payload.
enum TargetZoneMode {
  balanced('balanced'),
  loose('loose'),
  strict('strict');

  const TargetZoneMode(this.rawValue);
  final String rawValue;
}
