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
//     "width": 256,
//     "height": 256,
//     "rle_b64": "<base64 of run-length-encoded binary mask>",
//     "centerProb": 0.92,
//     "fillRatio": 0.18,
//     "mask_uuid": "msk-708"
//   }
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
