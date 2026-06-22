// SubjectMaskData — manifest-side representation of one MobileSAM
// segmentation result, encoded RLE+base64 for compact transport in
// curated.json.
//
// Producer: lib/capture/sam/mobile_sam_inference.dart returns a
// MobileSamResult (raw packed Uint8List mask). The capture layer is
// expected to call SubjectMaskData.fromBinaryMask(...) to compress.
//
// Consumer: server worker `pipeline/apply_subject_mask.py` decodes the
// RLE, upsamples to frame resolution, and white-outs background pixels
// before VGGT geometry runs.
//
// Wire format (per-frame inside curated.json):
//
//   "subject_mask": {
//     "width": 1024,
//     "height": 1024,
//     "rle_b64": "<base64 of run-length-encoded binary mask>",
//     "centerProb": 0.92,
//     "fillRatio": 0.18,
//     "mask_uuid": "msk-708"
//   }
//
// Recommended mask resolution is 1024×1024 (see kRecommendedMaskSize
// below). Width/height are wire fields, not hardcoded constants —
// any (W, H) pair the producer wrote is what the consumer decodes —
// but Phase B implementers should default to kRecommendedMaskSize.
//
// Why 1024 and not 512: MobileSAM's encoder is trained at exactly
// 1024×1024 input (ResizeLongestSide(1024)). Cross-bridging the
// camera frame at 1024×1024 gives SAM the maximum detail it can
// actually use; anything larger gets internally downsampled before
// the encoder sees it. Mask output then matches SAM's natural
// resolution, eliminating one resize step worker-side.
//
// RLE format: row-major scan starts on background (0). Each run is
// emitted as a little-endian uint16 run length. A run length of 0 means
// "next run also starts in the same color" — used when a single run
// would overflow uint16. Decoder accumulates colors by alternating
// 0→1→0→1 for each non-zero run; zero-length runs do not flip.
//
// This format is identical to the one expected by the server worker's
// apply_subject_mask.py decoder (single source of truth for the wire
// format is this docstring).

import 'dart:convert';
import 'dart:typed_data';

/// Recommended mask + cross-bridge resolution for Phase B producers.
///
/// Tradeoff table:
///
/// | size | RLE/frame | manifest @ 118 frames | 4K JPEG edge aliasing |
/// | 256  |   ~2 KB   |        236 KB         |       ~15 px          |
/// | 384  |   ~4 KB   |        472 KB         |       ~10 px          |
/// | 512  |   ~8 KB   |        944 KB         |       ~7.5 px         |
/// | 768  |  ~18 KB   |        2.1 MB         |       ~5 px           |
/// | 1024 |  ~32 KB   |        3.7 MB         |       ~3.75 px        |  ← default
///
/// 1024 is the natural ceiling: MobileSAM's encoder is trained at
/// 1024×1024 (ResizeLongestSide(1024) preprocessing). Anything
/// larger gets downsampled internally and provides zero extra signal.
///
/// Cross-bridge data flow at 1024:
///   • Native bridge captures 1024×1024×4 = 4 MB RGBA per pull
///   • 5 Hz pull cadence → 20 MB/s sustained while SAM is enabled
///   • iPhone MethodChannel cap is ~200 MB/s → 10% of budget
///   • Dart isolate handoff uses TransferableTypedData (Dart 2.15+,
///     zero-copy) so the main isolate never copies the 4 MB blob
///     across the SendPort — critical for 60 fps Flutter UI
///   • SAM inference cost (encoder + decoder on iPhone 12 Pro+ A14
///     CoreML) is ~31 ms per call regardless of this value, since
///     the encoder always runs at 1024×1024 internally
///   • Manifest 3.7 MB is negligible vs the 30–80 MB .mov upload
///
/// LOW tier devices (iPhone 11/12, 4 GB RAM) skip SAM entirely via
/// the `>= 5 GB physicalMemory` device-tier gate in
/// AetherARKitPlugin.swift::startSession(); see
/// project_pocketworld_device_tier.md memory for the full estimate.
const int kRecommendedMaskSize = 1024;

class SubjectMaskData {
  final int width;
  final int height;
  final String rleB64;
  final double centerProb;
  final double fillRatio;
  final String maskUuid;

  const SubjectMaskData({
    required this.width,
    required this.height,
    required this.rleB64,
    required this.centerProb,
    required this.fillRatio,
    required this.maskUuid,
  });

  /// Compress a packed binary mask (one byte per pixel, 0 or 1, row-major)
  /// into RLE+base64. Used by the capture layer when storing inference
  /// results for later embedding in the curated manifest.
  factory SubjectMaskData.fromBinaryMask({
    required Uint8List mask,
    required int width,
    required int height,
    required double centerProb,
    required double fillRatio,
    required String maskUuid,
  }) {
    if (mask.length != width * height) {
      throw ArgumentError(
        'mask.length (${mask.length}) != width*height (${width * height})',
      );
    }
    final rleBytes = _encodeRle(mask);
    return SubjectMaskData(
      width: width,
      height: height,
      rleB64: base64Encode(rleBytes),
      centerProb: centerProb,
      fillRatio: fillRatio,
      maskUuid: maskUuid,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'width': width,
        'height': height,
        'rle_b64': rleB64,
        'centerProb': centerProb,
        'fillRatio': fillRatio,
        'mask_uuid': maskUuid,
      };

  /// Run-length encode a binary mask. Output: little-endian uint16 run
  /// lengths, starting on background (0). A zero-length run is the
  /// continuation marker for runs > 65535 pixels (rare at 256×256 where
  /// max mask = 65536 so a single full-foreground run would need it).
  static Uint8List _encodeRle(Uint8List mask) {
    final runs = <int>[];
    var current = 0; // start with background
    var runLength = 0;

    void flushRun() {
      while (runLength > 0xFFFF) {
        runs.add(0xFFFF);
        runs.add(0); // continuation: same color, no flip
        runLength -= 0xFFFF;
      }
      runs.add(runLength);
    }

    for (var i = 0; i < mask.length; i++) {
      final pixel = mask[i] != 0 ? 1 : 0;
      if (pixel == current) {
        runLength++;
      } else {
        flushRun();
        current = pixel;
        runLength = 1;
      }
    }
    flushRun();

    // Serialize as little-endian uint16.
    final out = Uint8List(runs.length * 2);
    final bd = ByteData.view(out.buffer);
    for (var i = 0; i < runs.length; i++) {
      bd.setUint16(i * 2, runs[i], Endian.little);
    }
    return out;
  }
}
