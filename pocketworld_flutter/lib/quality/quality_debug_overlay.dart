// Dart port of App/ObjectModeV2/ObjectModeV2QualityDebugOverlay.swift.
//
// On-device HUD for tuning the dome's sharpness threshold. Placed in the
// top-right of the capture view during debug sessions. Hidden by
// default in production; toggled via a long-press gesture (or a
// dart-define flag — see capture_page.dart when Dome UI lands).

import 'package:flutter/material.dart';

class QualityDebugStats {
  final double currentVariance;
  final double avgVariance;
  final double brightness;
  final double threshold;
  final double angularVelocity;
  final double angularVelocityLimit;
  final double tiltDegrees;
  final double tiltDegreesLimit;
  final double gravityDeviationDegrees;
  final double gravityDeviationLimit;
  final double passRate; // 0..1
  final int sampleCountInWindow;
  final double timestamp;

  const QualityDebugStats({
    required this.currentVariance,
    required this.avgVariance,
    required this.brightness,
    required this.threshold,
    required this.angularVelocity,
    required this.angularVelocityLimit,
    required this.tiltDegrees,
    required this.tiltDegreesLimit,
    required this.gravityDeviationDegrees,
    required this.gravityDeviationLimit,
    required this.passRate,
    required this.sampleCountInWindow,
    required this.timestamp,
  });
}

class QualityDebugOverlay extends StatelessWidget {
  final QualityDebugStats? stats;

  const QualityDebugOverlay({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      child: stats == null
          ? _caption('waiting for analyzer…')
          : _content(stats!),
    );
  }

  Widget _content(QualityDebugStats s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _rowInt(
          label: 'variance',
          value: s.currentVariance.round(),
          color: _varianceColor(s.currentVariance, s.threshold),
        ),
        _rowInt(
          label: 'avg30f',
          value: s.avgVariance.round(),
          color: Colors.white,
        ),
        _rowInt(
          label: 'brightness',
          value: s.brightness.round(),
          color: _brightnessColor(s.brightness),
        ),
        _rowFloat(
          label: 'omega',
          value: s.angularVelocity,
          suffix: 'rad/s',
          color: _omegaColor(s.angularVelocity, s.angularVelocityLimit),
        ),
        _rowFloat(
          label: 'tilt',
          value: s.tiltDegrees,
          suffix: '°',
          color: _tiltColor(s.tiltDegrees, s.tiltDegreesLimit),
        ),
        _rowFloat(
          label: 'gravDev',
          value: s.gravityDeviationDegrees,
          suffix: '°',
          color: _tiltColor(
            s.gravityDeviationDegrees,
            s.gravityDeviationLimit,
          ),
        ),
        _rowInt(
          label: 'threshold',
          value: s.threshold.round(),
          color: Colors.white.withValues(alpha: 0.5),
        ),
        _rowFloat(
          label: 'omegaMax',
          value: s.angularVelocityLimit,
          suffix: 'rad/s',
          color: Colors.white.withValues(alpha: 0.5),
        ),
        _rowFloat(
          label: 'tiltMax',
          value: s.tiltDegreesLimit,
          suffix: '°',
          color: Colors.white.withValues(alpha: 0.5),
        ),
        _rowFloat(
          label: 'gravDevMax',
          value: s.gravityDeviationLimit,
          suffix: '°',
          color: Colors.white.withValues(alpha: 0.5),
        ),
        _rowInt(
          label: 'accept%',
          value: (s.passRate * 100).round(),
          color: _passRateColor(s.passRate),
        ),
        _rowInt(
          label: 'samples',
          value: s.sampleCountInWindow,
          color: Colors.white.withValues(alpha: 0.5),
        ),
      ],
    );
  }

  Widget _caption(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontFamily: 'Menlo',
        color: Colors.white.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _rowInt({
    required String label,
    required int value,
    required Color color,
  }) =>
      _row(label: label, valueText: '$value', color: color);

  Widget _rowFloat({
    required String label,
    required double value,
    required String suffix,
    required Color color,
  }) =>
      _row(
        label: label,
        valueText: '${value.toStringAsFixed(2)} $suffix',
        color: color,
      );

  Widget _row({
    required String label,
    required String valueText,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'Menlo',
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(),
          Text(
            valueText,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'Menlo',
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  static Color _omegaColor(double omega, double limit) {
    if (omega >= limit) return Colors.red;
    if (omega >= limit * 0.7) return Colors.yellow;
    return Colors.green;
  }

  static Color _tiltColor(double tilt, double limit) {
    if (tilt >= limit) return Colors.red;
    if (tilt >= limit * 0.7) return Colors.yellow;
    return Colors.green;
  }

  static Color _varianceColor(double v, double threshold) {
    if (v >= threshold * 1.1) return Colors.green;
    if (v >= threshold * 0.9) return Colors.yellow;
    return Colors.red;
  }

  static Color _brightnessColor(double b) {
    if (b < 30) return Colors.red;
    if (b < 60) return Colors.yellow;
    return Colors.white;
  }

  static Color _passRateColor(double p) {
    if (p >= 0.6) return Colors.green;
    if (p >= 0.3) return Colors.yellow;
    return Colors.red;
  }
}
