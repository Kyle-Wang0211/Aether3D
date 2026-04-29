// Aether3D splash overlay — Flutter-side, covers Dawn renderer cold-boot.
//
// Purpose: iOS LaunchScreen.storyboard is static (Apple hard limit — no
// Dart / Swift animation code is allowed to run there). That covers the
// first ~500ms until the Flutter engine is ready. After that, the Flutter
// UI starts rendering but the Dawn GPU backend is still warming up for
// another 2–3s (release) / 5–10s (debug) before the 3D texture is
// available. This overlay fills that gap with a branded animated splash
// instead of exposing the placeholder UI state.
//
// Visual direction (2026-04-27): strict black & white. The rotating
// logo glyph is a square-framed diamond that pulses between two gray
// tones — no chroma. When Figma brings a real brand mark, replace the
// `_LogoMark` CustomPaint body; the controller scaffold stays.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'design_system.dart';

class AetherSplashOverlay extends StatefulWidget {
  final bool visible;
  final String? progressMessage;

  const AetherSplashOverlay({
    super.key,
    required this.visible,
    this.progressMessage,
  });

  @override
  State<AetherSplashOverlay> createState() => _AetherSplashOverlayState();
}

class _AetherSplashOverlayState extends State<AetherSplashOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _spinCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _fadeCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: widget.visible ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant AetherSplashOverlay old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      if (widget.visible) {
        _fadeCtrl.forward();
      } else {
        _fadeCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !widget.visible,
      child: FadeTransition(
        opacity: _fadeCtrl,
        child: Container(
          decoration: const BoxDecoration(gradient: AetherGradients.splash),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AetherSpacing.xl,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 3),
                  AnimatedBuilder(
                    animation: Listenable.merge([_spinCtrl, _pulseCtrl]),
                    builder: (context, _) {
                      final spin = _spinCtrl.value * 2 * math.pi;
                      final pulse =
                          1.0 + 0.05 * math.sin(_pulseCtrl.value * 2 * math.pi);
                      return Transform.scale(
                        scale: pulse,
                        child: Transform.rotate(
                          angle: spin,
                          child: _LogoMark(pulse: _pulseCtrl.value),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: AetherSpacing.xl),
                  Text(
                    AppL10n.of(context).appBrand,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.9,
                      color: AetherColors.primary,
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.sm),
                  Text(
                    AppL10n.of(context).splashSubtitle,
                    style: AetherTextStyles.bodySm,
                  ),
                  const Spacer(flex: 4),
                  SizedBox(
                    width: 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AetherRadii.pill),
                      child: const LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: AetherColors.border,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AetherColors.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.md),
                  Text(
                    widget.progressMessage ?? '正在启动 3D 引擎…',
                    style: AetherTextStyles.caption,
                  ),
                  const SizedBox(height: AetherSpacing.xxl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  final double pulse;

  const _LogoMark({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      height: 112,
      child: CustomPaint(painter: _LogoPainter(pulse: pulse)),
    );
  }
}

/// Minimal black-and-white mark: 3/4 thin outer ring + inset diamond.
/// Pulses between near-black and mid-gray on the diamond fill; ring is
/// constant near-black. Intentionally reads as "placeholder" rather than
/// "finished brand" so Figma has room to replace it.
class _LogoPainter extends CustomPainter {
  final double pulse;

  _LogoPainter({required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    final ringPaint = Paint()
      ..color = AetherColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r - 5),
      -math.pi / 2,
      math.pi * 1.5,
      false,
      ringPaint,
    );

    final scale = 0.56 + 0.04 * pulse;
    final diaPath = Path()
      ..moveTo(center.dx, center.dy - r * scale)
      ..lineTo(center.dx + r * scale * 0.88, center.dy)
      ..lineTo(center.dx, center.dy + r * scale)
      ..lineTo(center.dx - r * scale * 0.88, center.dy)
      ..close();

    final diaFill = Color.lerp(
      const Color(0xFF111111),
      const Color(0xFF555555),
      pulse,
    )!;
    canvas.drawPath(diaPath, Paint()..color = diaFill);

    canvas.drawCircle(
      center,
      3.0,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => pulse != old.pulse;
}
