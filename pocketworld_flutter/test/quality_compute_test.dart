// Unit tests for lib/quality/quality_compute.dart — the pure-Dart port
// of what used to live in AetherARKitPlugin.swift::computeQuality.
//
// What we're proving:
//   1. Constant-color input → sharpness = 0, globalVariance = 0,
//      meanBrightness exact, signature all-equal.
//   2. Single-pixel impulse → sharpness > 0 (Laplacian non-zero).
//   3. High-contrast checkerboard → sharpness large + globalVariance
//      large + signature reflects block-mean.
//   4. Signature is exactly the block-mean downsample (8×8 blocks).
//   5. Input-size validation (wrong length throws).
//
// Numerical agreement with the previous Swift implementation:
// constants like sharpness on a fixed pattern are deterministic and
// will match Swift to within fp representation. Test 3's expected
// signature is computed from first principles, not lifted from a
// Swift run, so it'll catch any algorithmic drift.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/quality/quality_compute.dart';

void main() {
  group('computeFrameQualityFromGray128', () {
    test('constant-color frame → zero sharpness + zero variance', () {
      // Uniform gray 100 everywhere.
      final gray = Uint8List(128 * 128)..fillRange(0, 128 * 128, 100);

      final r = computeFrameQualityFromGray128(gray);

      expect(r.sharpness, 0.0);
      expect(r.globalVariance, 0.0);
      expect(r.meanBrightness, 100.0);
      // Every signature block averages to 100.
      for (final b in r.signature) {
        expect(b, 100);
      }
      expect(r.signature.length, 16 * 16);
      expect(r.signatureWidth, 16);
      expect(r.signatureHeight, 16);
    });

    test('single-pixel impulse on a black background → sharpness > 0', () {
      // 128×128 black with one bright pixel at (64, 64).
      final gray = Uint8List(128 * 128);
      gray[64 * 128 + 64] = 255;

      final r = computeFrameQualityFromGray128(gray);

      // The Laplacian at (64,64) is 4·255 - 0 - 0 - 0 - 0 = 1020.
      // The Laplacian at the 4 neighbour cells of (64,64) is
      //   4·0 - 255 - 0 - 0 - 0 = -255 each.
      // All other interior cells contribute 0.
      //
      // lapN = 126 × 126 = 15876.
      // lapSum   = 1020 + 4·(-255) = 1020 - 1020 = 0
      // lapSumSq = 1020² + 4·255²  = 1040400 + 260100 = 1300500
      // sharpness = lapSumSq / lapN − (lapSum / lapN)²
      //           = 1300500 / 15876 − 0
      //           ≈ 81.92
      expect(r.sharpness, closeTo(81.92, 0.01));

      // Mean brightness ≈ 255 / 16384 ≈ 0.01556.
      expect(r.meanBrightness, closeTo(255.0 / (128.0 * 128.0), 1e-9));

      // Signature: only block (8, 8) — which covers rows 64-71, cols
      // 64-71 — contains the bright pixel. Its mean = 255 / 64 ≈ 3,
      // truncated to int = 3. All other blocks are 0.
      for (var by = 0; by < 16; by++) {
        for (var bx = 0; bx < 16; bx++) {
          final v = r.signature[by * 16 + bx];
          if (by == 8 && bx == 8) {
            expect(v, 3, reason: 'block (8,8) holds the impulse');
          } else {
            expect(v, 0, reason: 'block ($bx,$by) should be 0');
          }
        }
      }
    });

    test('high-contrast vertical-stripes → high sharpness', () {
      // 128×128 alternating columns of 0 / 255 → every interior
      // pixel has horizontal neighbours of opposite color.
      final gray = Uint8List(128 * 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          gray[y * 128 + x] = (x.isEven) ? 0 : 255;
        }
      }

      final r = computeFrameQualityFromGray128(gray);

      // Sharpness on this pattern is huge — Laplacian on even cols
      // is 4·0 − 0 − 0 − 255 − 255 = −510; on odd cols 4·255 − 255 −
      // 255 − 0 − 0 = 510. Both squared = 260100. Mean of laplacian
      // across all interior cells is 0. So sharpness = 260100.
      expect(r.sharpness, closeTo(260100.0, 1.0));

      // Mean brightness ≈ 127.5.
      expect(r.meanBrightness, closeTo(127.5, 1e-9));

      // Global variance: pixels are exactly 0 or 255, each occurring
      // 50% of the time. var = E[X²] − E[X]² = (255²/2) − 127.5²
      //   = 32512.5 − 16256.25 = 16256.25.
      expect(r.globalVariance, closeTo(16256.25, 1e-6));

      // Signature blocks each cover an 8×8 region with 4 even cols
      // (value 0) and 4 odd cols (value 255), 8 rows each. Block
      // mean = (4 × 8 × 0 + 4 × 8 × 255) / 64 = 8160 / 64 = 127.5
      // truncated to int = 127.
      for (final b in r.signature) {
        expect(b, 127);
      }
    });

    test('signature is block-mean of 8×8 blocks', () {
      // 128×128 image with diagonal gradient: row*2 + col*2, clamped.
      final gray = Uint8List(128 * 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          var v = y + x;
          if (v > 255) v = 255;
          gray[y * 128 + x] = v;
        }
      }

      final r = computeFrameQualityFromGray128(gray);

      // Manually compute block (0, 0)'s expected mean:
      // rows 0..7, cols 0..7 → values 0..14.
      var expectedAcc = 0;
      for (var py = 0; py < 8; py++) {
        for (var px = 0; px < 8; px++) {
          var v = py + px;
          if (v > 255) v = 255;
          expectedAcc += v;
        }
      }
      final expectedMean = expectedAcc ~/ 64;
      expect(r.signature[0], expectedMean);

      // Block (1, 0): rows 0..7, cols 8..15 → values 8..22.
      expectedAcc = 0;
      for (var py = 0; py < 8; py++) {
        for (var px = 0; px < 8; px++) {
          var v = py + (8 + px);
          if (v > 255) v = 255;
          expectedAcc += v;
        }
      }
      expect(r.signature[0 * 16 + 1], expectedAcc ~/ 64);
    });

    test('wrong input size throws ArgumentError', () {
      expect(
        () => computeFrameQualityFromGray128(Uint8List(127 * 128)),
        throwsArgumentError,
      );
      expect(
        () => computeFrameQualityFromGray128(Uint8List(0)),
        throwsArgumentError,
      );
      expect(
        () => computeFrameQualityFromGray128(Uint8List(256 * 256)),
        throwsArgumentError,
      );
    });

    test('latency sanity: < 20 ms in debug mode', () {
      // Not a hard performance assertion; in release mode this is
      // typically 1–2 ms. Mostly catches accidental O(N²) regressions
      // in the inner loops.
      final gray = Uint8List(128 * 128);
      for (var i = 0; i < gray.length; i++) {
        gray[i] = i & 0xFF;
      }

      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        computeFrameQualityFromGray128(gray);
      }
      sw.stop();
      final perCallMs = sw.elapsedMilliseconds / 10.0;
      expect(perCallMs, lessThan(20.0),
          reason: 'compute took $perCallMs ms/call — regression?');
    });
  });
}
