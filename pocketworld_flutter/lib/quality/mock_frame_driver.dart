// Synthetic camera-frame driver for GuidanceEngine / QualityDebugOverlay.
//
// Real product needs a camera plugin feeding the GPU quality shaders
// (blur/brightness/motion WGSL already ported; host wiring deferred to
// D2 in PORTING_BACKLOG.md). Until then, this driver produces
// VisualFrameSample + QualityDebugStats at ~30 Hz with realistic-
// looking distributions so the guidance / audit / debug UI can be
// demo'd without a camera.
//
// Distribution design (matches typical captured-video profiles):
//   • 80% "good" frames: laplacian 750..1300, brightness 90..170,
//     variance 45..100 — guidance engine accepts these.
//   • 12% "soft-rejects": low brightness or low variance — engine
//     counts them into audit softDowngrade* buckets.
//   • 6% "blurry" (laplacian 200..450) — engine hardRejects.
//   • 2% "too dark / too bright" — engine hardRejects.
//
// Signature bytes jitter smoothly across frames so the engine's
// novelty heuristic sees "similar-but-drifting" samples (i.e. real
// orbit motion), with occasional large jumps (when the user rotates
// past a new face of the object).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'frame_quality_constants.dart';
import 'guidance_engine.dart';
import 'quality_debug_overlay.dart';

class MockFrameDriver {
  final GuidanceEngine engine;
  final void Function(QualityDebugStats)? onDebugStats;

  final _rng = math.Random(20260427);
  Timer? _timer;
  int _frameCounter = 0;
  final _signature = Uint8List(64);
  double _azimuthHint = 0;

  // Rolling window for `avgVariance`.
  final List<double> _variances = <double>[];
  static const int _windowSize = 30;

  MockFrameDriver({required this.engine, this.onDebugStats});

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) => _emit());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  void _emit() {
    _frameCounter += 1;
    final bucket = _rng.nextDouble();
    late final double laplacian;
    late final double brightness;
    late final double globalVariance;

    if (bucket < 0.80) {
      // Good frame.
      laplacian = 750 + _rng.nextDouble() * 550;
      brightness = 90 + _rng.nextDouble() * 80;
      globalVariance = 45 + _rng.nextDouble() * 55;
    } else if (bucket < 0.92) {
      // Soft reject — low variance or dim.
      laplacian = 500 + _rng.nextDouble() * 280;
      brightness = 55 + _rng.nextDouble() * 40;
      globalVariance = 14 + _rng.nextDouble() * 16; // below MIN_LOCAL_VARIANCE_FOR_TEXTURE
    } else if (bucket < 0.98) {
      // Hard reject blur.
      laplacian = 200 + _rng.nextDouble() * 250;
      brightness = 80 + _rng.nextDouble() * 60;
      globalVariance = 30 + _rng.nextDouble() * 40;
    } else {
      // Hard reject exposure.
      if (_rng.nextBool()) {
        laplacian = 700 + _rng.nextDouble() * 400;
        brightness = 12 + _rng.nextDouble() * 15; // too dark
        globalVariance = 30 + _rng.nextDouble() * 30;
      } else {
        laplacian = 700 + _rng.nextDouble() * 400;
        brightness = 240 + _rng.nextDouble() * 12; // too bright
        globalVariance = 30 + _rng.nextDouble() * 30;
      }
    }

    // Drift the signature bytes slowly — small chance of a "new angle"
    // jump (big signature diff) so novelty spikes occasionally.
    if (_rng.nextDouble() < 0.04) {
      for (int i = 0; i < _signature.length; i++) {
        _signature[i] = _rng.nextInt(256);
      }
    } else {
      for (int i = 0; i < _signature.length; i++) {
        final d = (_rng.nextInt(7) - 3);
        _signature[i] = ((_signature[i] + d) & 0xFF);
      }
    }

    final timestamp = _frameCounter * 0.033;
    final sample = VisualFrameSample(
      timestamp: timestamp,
      signatureWidth: 8,
      signatureHeight: 8,
      signature: Uint8List.fromList(_signature),
      laplacianVariance: laplacian,
      meanBrightness: brightness,
      globalVariance: globalVariance,
    );

    engine.processVisualSample(
      sample,
      targetZoneAnchor: const Offset(0.5, 0.5),
      targetZoneMode: TargetZoneMode.balanced,
    );

    // Update rolling window for debug HUD.
    _variances.add(laplacian);
    if (_variances.length > _windowSize) _variances.removeAt(0);
    final avg = _variances.reduce((a, b) => a + b) / _variances.length;
    final passed = engine.snapshot.acceptedFrames;
    final total = engine.auditSummary.totalSamples;
    final passRate = total > 0 ? passed / total : 0.0;

    _azimuthHint = (_azimuthHint + 0.02) % (2 * math.pi);
    final omega = 0.4 + math.sin(_azimuthHint * 3) * 0.3 + _rng.nextDouble() * 0.2;
    final tilt = 3.0 + _rng.nextDouble() * 6.0;
    final gravDev = 1.5 + _rng.nextDouble() * 3.5;

    onDebugStats?.call(QualityDebugStats(
      currentVariance: laplacian,
      avgVariance: avg,
      brightness: brightness,
      threshold: 500,
      angularVelocity: omega,
      angularVelocityLimit: 1.2,
      tiltDegrees: tilt,
      tiltDegreesLimit: 15,
      gravityDeviationDegrees: gravDev,
      gravityDeviationLimit: 12,
      passRate: passRate.clamp(0.0, 1.0),
      sampleCountInWindow: _variances.length,
      timestamp: timestamp,
    ));
  }
}

