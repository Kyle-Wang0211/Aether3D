// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 5 — Flutter wrapper unit tests for GlbNormalizer.
//
// Two layers of coverage:
//
// 1. Pure-Dart sanity tests that don't touch FFI. Always run; verify
//    that the Dart enum / stats / result types stay in sync with the C
//    ABI's wire format (status code count, default options).
//
// 2. End-to-end fixture round-trip via the native FFI. Outcomes:
//      - GlbNormUnavailable thrown → host doesn't have the symbols
//        linked (typical for `flutter test` on macOS without the
//        dylib next to the test binary). Test marked skipped — this
//        is expected and not a regression.
//      - GlbNormStatus.ok → assert glTF magic header on output.
//      - GlbNormStatus.unsupported → soft-pass: the FFI bridge is
//        wired (call reached C, C returned, result mapped) but the
//        Phase 1+ algorithm is not landed yet. Recorded explicitly
//        so a future failure mode (e.g. invalidGlb on a known-good
//        fixture) doesn't get silently swallowed.
//      - any other status → fail with the status name.

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/glb_norm/glb_norm.dart';

const _fixturePath = 'assets/models/Duck.glb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GlbNormStatus wire format', () {
    test('enum order matches aether_glb_norm_result_t (0..10)', () {
      expect(GlbNormStatus.values.length, 11);
      expect(GlbNormStatus.ok.index, 0);
      expect(GlbNormStatus.invalidGlb.index, 1);
      expect(GlbNormStatus.noMaterials.index, 2);
      expect(GlbNormStatus.noTextures.index, 3);
      expect(GlbNormStatus.pngDecode.index, 4);
      expect(GlbNormStatus.packingFailed.index, 5);
      expect(GlbNormStatus.pngEncode.index, 6);
      expect(GlbNormStatus.outOfMemory.index, 7);
      expect(GlbNormStatus.cancelled.index, 8);
      expect(GlbNormStatus.unsupported.index, 9);
      expect(GlbNormStatus.internal.index, 10);
    });
  });

  group('GlbNormOptions defaults', () {
    test('defaults match the C ABI sane-default policy', () {
      const opts = GlbNormOptions();
      expect(opts.targetAtlasSize, 0);
      expect(opts.maxAtlasSize, 8192);
      expect(opts.targetFaceCount, 500000);
      expect(opts.allowOversizeTextures, isFalse);
    });
  });

  group('GlbNormResult', () {
    test('isOk reflects status', () {
      const ok = GlbNormResult(
        output: null,
        stats: GlbNormStats(),
        status: GlbNormStatus.ok,
      );
      const err = GlbNormResult(
        output: null,
        stats: GlbNormStats(),
        status: GlbNormStatus.invalidGlb,
        error: 'invalid_glb',
      );
      expect(ok.isOk, isTrue);
      expect(err.isOk, isFalse);
    });
  });

  group('GlbNormalizer.normalize fixture round-trip', () {
    late Uint8List input;

    setUpAll(() async {
      final byteData = await rootBundle.load(_fixturePath);
      input = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      // Sanity: fixture is a real GLB (magic = 'glTF').
      expect(input.length, greaterThan(12));
      expect(_glbMagic(input), equals(0x46546C67));
    });

    test('runs end-to-end and either succeeds or surfaces a clean status',
        () async {
      GlbNormResult result;
      try {
        result = await GlbNormalizer.normalize(input: input);
      } on GlbNormUnavailable catch (e) {
        markTestSkipped(
          'Native aether_glb_norm symbols not resolvable in this test '
          'host (this is expected for `flutter test` on desktop without '
          'libaether3d_ffi.dylib next to the runner). Reason: ${e.message}',
        );
        return;
      }

      switch (result.status) {
        case GlbNormStatus.ok:
          // Real Phase 1+ implementation is live. Validate output is a
          // GLB by checking the 12-byte header (magic, version, length).
          expect(result.output, isNotNull);
          expect(result.output!.length, greaterThan(12));
          expect(_glbMagic(result.output!), equals(0x46546C67));
          expect(_glbVersion(result.output!), equals(2));
          // Stats invariants from the header contract.
          expect(result.stats.outputPrimitiveCount, 1);
          expect(result.stats.outputMaterialCount, 1);
          expect(result.stats.outputFaceCount, greaterThan(0));
          expect(result.stats.outputAtlasSize, greaterThan(0));
          break;
        case GlbNormStatus.unsupported:
          // Phase 0 stub is in place — FFI bridge is verified end-to-
          // end, but the algorithm port hasn't landed. Document this
          // explicitly so a future regression that returns a different
          // status (e.g. invalidGlb on a known-good Duck.glb) is loud.
          expect(result.output, isNull);
          expect(result.error, equals('unsupported'));
          // ignore: avoid_print
          print(
            'NOTE: aether_glb_norm_run returned UNSUPPORTED — FFI '
            'bridge OK but Phase 1+ algorithm not landed yet.',
          );
          break;
        default:
          fail(
            'Unexpected normalize status on Duck.glb fixture: '
            '${result.status} (${result.error})',
          );
      }
    });
  });
}

int _glbMagic(Uint8List bytes) {
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, 4)
      .getUint32(0, Endian.little);
}

int _glbVersion(Uint8List bytes) {
  return ByteData.view(bytes.buffer, bytes.offsetInBytes + 4, 4)
      .getUint32(0, Endian.little);
}
