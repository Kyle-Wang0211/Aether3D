// Dart abstraction for "waiting-for-training" realtime signals.
//
// Mirrors the intent of GaussianTraining.metal kernels:
//   • depthPearsonReducePartial / Final  → depth-truth correlation
//   • densificationStats                 → gaussian-count growth rate
//   • adamUpdate                          → step count
// The WGSL equivalents already live in aether_cpp/shaders/wgsl/ via
// Phase 6.3a (the Brush training chain). What's missing is a C ABI
// that exposes these metrics from the running training session to
// Dart.
//
// Today this file ships:
//   • `TrainingConvergenceSnapshot` data class
//   • `TrainingConvergenceProvider` abstract interface
//   • `MockTrainingConvergenceProvider` synthetic-signal driver so the
//     debug overlay can be demo'd without a real training run
//
// Real FFI binding to an `aether_train_get_convergence_stats()` C
// function is tracked in PORTING_BACKLOG.md D3 — once aether_cpp
// exposes the symbol, add an `FfiTrainingConvergenceProvider` here
// that reads it via dart:ffi.

import 'dart:async';
import 'dart:math' as math;

class TrainingConvergenceSnapshot {
  /// Training step index (Adam update count). Monotonically increasing.
  final int step;

  /// Total number of steps the current plan expects to run.
  final int targetSteps;

  /// Gaussian count after densification at this step.
  final int gaussianCount;

  /// Pearson correlation between rendered depth and depth prior.
  /// Close to 1.0 = well-converged geometry. -1..1 range.
  final double depthPearson;

  /// Training loss (unitless, typically photometric L1 + SSIM mix).
  final double loss;

  /// Densification growth rate over the last N=100 steps. > 0 means
  /// still actively splitting; ~0 means the model has settled.
  final double densificationRate;

  /// Seconds since the training run started.
  final double elapsedSeconds;

  const TrainingConvergenceSnapshot({
    required this.step,
    required this.targetSteps,
    required this.gaussianCount,
    required this.depthPearson,
    required this.loss,
    required this.densificationRate,
    required this.elapsedSeconds,
  });

  /// Heuristic "is training converged enough to export" signal.
  /// UI can use this to flip the "等待中 → 即将就绪" label early.
  bool get isConverging =>
      step >= targetSteps * 0.6 &&
      depthPearson > 0.75 &&
      densificationRate.abs() < 0.02;

  double get progressFraction {
    if (targetSteps <= 0) return 0;
    return (step / targetSteps).clamp(0.0, 1.0);
  }
}

abstract class TrainingConvergenceProvider {
  /// Start emitting snapshots. Multiple `start()` calls are idempotent.
  Stream<TrainingConvergenceSnapshot> start();

  /// Stop emitting (keeps subscribers' stream open but quiescent).
  Future<void> stop();

  TrainingConvergenceSnapshot? get lastSnapshot;
}

/// Synthetic driver — produces a realistic-looking training curve so
/// the QualityDebugOverlay / "等待训练" UI has something to animate
/// against during development. Designed to match the Brush training
/// loop's typical behavior on the Mip-NeRF 360 garden:
///   step 0..400, gaussians 50k→120k, pearson 0.3→0.94, loss 0.18→0.05
class MockTrainingConvergenceProvider
    implements TrainingConvergenceProvider {
  final int targetSteps;
  final Duration tick;

  final _controller =
      StreamController<TrainingConvergenceSnapshot>.broadcast();
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _step = 0;
  TrainingConvergenceSnapshot? _last;

  MockTrainingConvergenceProvider({
    this.targetSteps = 400,
    this.tick = const Duration(milliseconds: 500),
  });

  @override
  TrainingConvergenceSnapshot? get lastSnapshot => _last;

  @override
  Stream<TrainingConvergenceSnapshot> start() {
    if (_timer != null) return _controller.stream;
    _clock.start();
    _timer = Timer.periodic(tick, (_) {
      if (_step >= targetSteps) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      _step += 1;
      final snap = _synthesize(_step);
      _last = snap;
      if (!_controller.isClosed) _controller.add(snap);
    });
    return _controller.stream;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  TrainingConvergenceSnapshot _synthesize(int step) {
    final f = step / targetSteps;
    // Smooth growth: sigmoid-ish curve from 0.3 to 0.94.
    final pearson = 0.3 + 0.64 * (1.0 / (1.0 + math.exp(-8 * (f - 0.45))));
    final loss = 0.18 - 0.13 * f + math.sin(step * 0.12) * 0.008;
    final gaussians =
        (50000 + (70000 * math.min(1.0, f * 1.3))).round();
    final densRate = math.max(0.0, 0.08 - f * 0.095) +
        math.max(0.0, math.sin(step * 0.21) * 0.01);
    return TrainingConvergenceSnapshot(
      step: step,
      targetSteps: targetSteps,
      gaussianCount: gaussians,
      depthPearson: pearson,
      loss: loss.clamp(0.03, 0.3),
      densificationRate: densRate,
      elapsedSeconds: _clock.elapsedMilliseconds / 1000.0,
    );
  }
}
