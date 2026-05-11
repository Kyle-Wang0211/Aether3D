// MobileSamInference — on-device subject masking via MobileSAM
// (Apache-2.0). Two ONNX sessions:
//   1. Encoder (mobile_sam_image_encoder.onnx, ~28 MB): runs once per
//      capture frame, produces a [1, 256, 64, 64] image embedding.
//      This is the heavy bit — ~80% of inference latency on a 1024×1024
//      input on an A12-class iPhone CPU/ANE.
//   2. Decoder (sam_mask_decoder_single.onnx, ~16 MB): runs once per
//      prompt point. Cheap (~10 ms) — takes embedding + (x, y) prompt
//      and returns the binary mask upsampled to the original frame
//      size.
//
// We pre-bundle both models under assets/models/edgesam/ (directory
// name is forward-compat from an earlier session — contents are
// MobileSAM, not EdgeSAM, and the license is Apache-2.0 not S-Lab).
//
// Performance contract:
//   • 5 Hz target (200 ms per call max). Caller (CaptureSession)
//     drives a Timer.periodic at 200 ms.
//   • runAsync executes on a background isolate inside the
//     onnxruntime package's OrtIsolateSession, so the UI / ARKit
//     main loop is never blocked even if a single inference spills
//     past the budget.
//
// Graceful failure modes (all return MobileSamResult? = null):
//   • Asset missing (pubspec.yaml drift)
//   • Native ORT load failure (HarmonyOS / Web — package doesn't
//     publish those platforms in 1.4.1)
//   • Decoder throws (rare — usually means the ONNX I/O contract
//     drifted upstream)
//
// Caller treats `null` as "no mask, use full frame" — the manifest
// writer omits `subject_mask`, the worker stage no-ops, reconstruction
// proceeds unmasked.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

/// Result of one MobileSAM segmentation call.
class MobileSamResult {
  /// Packed binary mask, length = `width * height`. Each byte is 0 or 1.
  /// Row-major order, top-left origin (matches PNG/RGBA convention).
  final Uint8List mask;
  final int width;
  final int height;

  /// SAM's IoU prediction score for the chosen mask candidate. Range
  /// [0, 1] — typically > 0.85 when the prompt is on a well-defined
  /// foreground object, < 0.5 when prompted on background. Surfaced
  /// to the manifest as `centerProb` so the worker can drop frames
  /// where the user clearly was NOT pointing at a subject.
  final double centerProb;

  /// Fraction of foreground pixels: `popcount(mask) / (W*H)`. Useful
  /// signal for "is the subject taking up too much / too little of
  /// the frame" — e.g. fillRatio < 0.02 usually means prompt missed
  /// the object; fillRatio > 0.7 usually means we segmented the
  /// background table-top by mistake.
  final double fillRatio;

  const MobileSamResult({
    required this.mask,
    required this.width,
    required this.height,
    required this.centerProb,
    required this.fillRatio,
  });
}

class MobileSamInference {
  static const String _encoderAsset =
      'assets/models/edgesam/mobile_sam_image_encoder.onnx';
  static const String _decoderAsset =
      'assets/models/edgesam/sam_mask_decoder_single.onnx';

  /// MobileSAM was trained at 1024×1024 input; the encoder ONNX is
  /// dynamic-shape but the SAM mask decoder math only matches the
  /// 1024 reference scale (point prompts and mask resampling use it
  /// implicitly through `orig_im_size`).
  static const int _samInputSize = 1024;

  OrtSession? _encoder;
  OrtSession? _decoder;
  OrtSessionOptions? _encoderOptions;
  OrtSessionOptions? _decoderOptions;

  bool _warmupAttempted = false;
  bool _warmupOk = false;

  /// Idempotent. Loads both ONNX sessions and configures execution
  /// providers. Safe to call multiple times — second + later calls
  /// short-circuit. If load fails, the exception is swallowed and
  /// `_warmupOk` stays false; subsequent `segment()` calls return null.
  Future<void> warmup() async {
    if (_warmupAttempted) return;
    _warmupAttempted = true;

    try {
      OrtEnv.instance.init();

      _encoderOptions = _buildSessionOptions();
      _decoderOptions = _buildSessionOptions();

      final encoderBytes = await _loadAssetBytes(_encoderAsset);
      _encoder = OrtSession.fromBuffer(encoderBytes, _encoderOptions!);

      final decoderBytes = await _loadAssetBytes(_decoderAsset);
      _decoder = OrtSession.fromBuffer(decoderBytes, _decoderOptions!);

      _warmupOk = true;
      debugPrint(
        '[MobileSamInference] warmup OK: '
        'encoder.inputs=${_encoder!.inputNames} '
        'encoder.outputs=${_encoder!.outputNames} '
        'decoder.inputs=${_decoder!.inputNames} '
        'decoder.outputs=${_decoder!.outputNames}',
      );
    } catch (e, st) {
      // Most likely on Web / HarmonyOS where the native ORT lib isn't
      // published in 1.4.1, OR if .onnx assets are missing (LFS not
      // pulled). Either way: stay degraded, do not throw.
      debugPrint('[MobileSamInference] warmup FAILED: $e\n$st');
      _encoder?.release();
      _decoder?.release();
      _encoderOptions?.release();
      _decoderOptions?.release();
      _encoder = null;
      _decoder = null;
      _encoderOptions = null;
      _decoderOptions = null;
      _warmupOk = false;
    }
  }

  /// True once `warmup()` has loaded both sessions successfully.
  bool get isReady => _warmupOk;

  /// Segment the foreground subject in [rgbaBytes] using a single
  /// point prompt at (promptX, promptY).
  ///
  /// Returns null if:
  ///   • Warmup failed / never ran
  ///   • Inference threw mid-flight
  ///   • Output shape disagrees with what the contract expects
  ///
  /// Caller should treat null as "no mask available, proceed unmasked".
  Future<MobileSamResult?> segment({
    required Uint8List rgbaBytes,
    required int width,
    required int height,
    required int promptX,
    required int promptY,
  }) async {
    if (!_warmupOk) {
      // First-call caller may have skipped warmup() — try once more.
      if (!_warmupAttempted) {
        await warmup();
      }
      if (!_warmupOk) return null;
    }

    if (rgbaBytes.length != width * height * 4) {
      debugPrint(
        '[MobileSamInference] rgbaBytes.length=${rgbaBytes.length} '
        '!= width*height*4=${width * height * 4}; refusing to segment',
      );
      return null;
    }

    OrtRunOptions? encoderRun;
    OrtRunOptions? decoderRun;
    OrtValueTensor? imageTensor;
    OrtValueTensor? embeddingTensor;
    OrtValueTensor? pointCoords;
    OrtValueTensor? pointLabels;
    OrtValueTensor? maskInput;
    OrtValueTensor? hasMaskInput;
    OrtValueTensor? origImSize;
    List<OrtValue?>? encoderOutputs;
    List<OrtValue?>? decoderOutputs;

    try {
      // ── Pre-process: resize RGBA → 1024×1024 RGB uint8 (HWC). ────
      final hwcBytes =
          _resizeRgbaToHwcUint8(rgbaBytes, width, height, _samInputSize);

      // Encoder input is HWC uint8 with shape [H, W, 3]. We always feed
      // 1024×1024 even though the dim is dynamic — it's what the SAM
      // decoder math expects via orig_im_size.
      imageTensor = OrtValueTensor.createTensorWithDataList(
        hwcBytes,
        <int>[_samInputSize, _samInputSize, 3],
      );

      encoderRun = OrtRunOptions();
      final encoderInputs = <String, OrtValue>{
        _encoder!.inputNames.first: imageTensor,
      };
      final encoderFut = _encoder!.runAsync(encoderRun, encoderInputs);
      if (encoderFut == null) return null;
      encoderOutputs = await encoderFut;

      // First (and only) encoder output is image_embeddings
      // [1, 256, 64, 64].
      final OrtValue? embRaw = encoderOutputs.isNotEmpty ? encoderOutputs[0] : null;
      if (embRaw is! OrtValueTensor) {
        debugPrint('[MobileSamInference] encoder output not a tensor');
        return null;
      }
      // Pull the values out as a flat Float32List so we can re-feed
      // into the decoder via createTensorWithDataList. The package
      // gives us a nested List<List<...>>; the cleanest way to send
      // it back into the decoder is to re-create a tensor from a
      // freshly allocated Float32List of the same shape.
      final flatEmbedding = _flattenToFloat32(embRaw.value);
      embeddingTensor = OrtValueTensor.createTensorWithDataList(
        flatEmbedding,
        <int>[1, 256, 64, 64],
      );

      // ── Decoder inputs ────────────────────────────────────────────
      // Single-point prompt scaled into the 1024×1024 input space.
      final scaleX = _samInputSize / width;
      final scaleY = _samInputSize / height;
      final px = (promptX * scaleX).clamp(0.0, _samInputSize - 1.0);
      final py = (promptY * scaleY).clamp(0.0, _samInputSize - 1.0);

      // SAM ONNX expects (x, y) point + a "padding" point at (0, 0)
      // with label -1, but the single-mask exporter (Acly's variant)
      // accepts a single positive point with label 1 and handles the
      // padding internally. Match Acly's expected wire format:
      //   point_coords: [1, 1, 2]
      //   point_labels: [1, 1]   value 1 = foreground positive
      pointCoords = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(<double>[px, py]),
        <int>[1, 1, 2],
      );
      pointLabels = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(<double>[1.0]),
        <int>[1, 1],
      );

      // No previous mask hint.
      final maskInputZeros = Float32List(1 * 1 * 256 * 256);
      maskInput = OrtValueTensor.createTensorWithDataList(
        maskInputZeros,
        <int>[1, 1, 256, 256],
      );
      hasMaskInput = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(<double>[0.0]),
        <int>[1],
      );

      // orig_im_size = [H, W] of the *intended* output mask space —
      // we want the decoder to upsample to the user-requested resolution
      // (the same dims they fed in). The decoder will Resize the
      // 256×256 logits up to (height, width), bilinear.
      origImSize = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(<double>[height.toDouble(), width.toDouble()]),
        <int>[2],
      );

      decoderRun = OrtRunOptions();
      final decoderInputs = <String, OrtValue>{
        'image_embeddings': embeddingTensor,
        'point_coords': pointCoords,
        'point_labels': pointLabels,
        'mask_input': maskInput,
        'has_mask_input': hasMaskInput,
        'orig_im_size': origImSize,
      };
      final decoderFut = _decoder!.runAsync(decoderRun, decoderInputs);
      if (decoderFut == null) return null;
      decoderOutputs = await decoderFut;

      if (decoderOutputs.length < 2) {
        debugPrint(
          '[MobileSamInference] decoder returned ${decoderOutputs.length} '
          'outputs, expected >=2',
        );
        return null;
      }

      // masks: [1, 1, height, width] float32, > 0 = foreground.
      final masksValue = decoderOutputs[0]?.value;
      // iou_predictions: [1, 1] float32 — single score for the
      // single-mask exporter.
      final iouValue = decoderOutputs[1]?.value;

      final flatMaskFloat = _flattenToFloat32(masksValue);
      if (flatMaskFloat.length != width * height) {
        debugPrint(
          '[MobileSamInference] mask elements=${flatMaskFloat.length} '
          '!= width*height=${width * height}',
        );
        return null;
      }

      final packedMask = Uint8List(width * height);
      var fgCount = 0;
      for (var i = 0; i < flatMaskFloat.length; i++) {
        if (flatMaskFloat[i] > 0.0) {
          packedMask[i] = 1;
          fgCount++;
        }
      }

      double centerProb = 0.0;
      if (iouValue is List) {
        final flat = _flattenToFloat32(iouValue);
        if (flat.isNotEmpty) centerProb = flat.first.toDouble();
      } else if (iouValue is num) {
        centerProb = iouValue.toDouble();
      }

      return MobileSamResult(
        mask: packedMask,
        width: width,
        height: height,
        centerProb: centerProb,
        fillRatio: fgCount / (width * height),
      );
    } catch (e, st) {
      debugPrint('[MobileSamInference] segment FAILED: $e\n$st');
      return null;
    } finally {
      // Release everything we allocated this call. OrtValueTensor
      // owns its native data buffer and must be released or we leak
      // the encoder embedding (~4 MB per call).
      imageTensor?.release();
      embeddingTensor?.release();
      pointCoords?.release();
      pointLabels?.release();
      maskInput?.release();
      hasMaskInput?.release();
      origImSize?.release();
      encoderOutputs?.forEach((v) => v?.release());
      decoderOutputs?.forEach((v) => v?.release());
      encoderRun?.release();
      decoderRun?.release();
    }
  }

  void dispose() {
    _encoder?.release();
    _decoder?.release();
    _encoderOptions?.release();
    _decoderOptions?.release();
    _encoder = null;
    _decoder = null;
    _encoderOptions = null;
    _decoderOptions = null;
    _warmupOk = false;
  }

  // ── helpers ───────────────────────────────────────────────────────

  /// Build a session with platform-aware execution providers. We
  /// always append CPU last as a guaranteed fallback; the runtime
  /// will try the more optimized providers first when supported.
  static OrtSessionOptions _buildSessionOptions() {
    final opts = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    if (kIsWeb) {
      // No-op — we won't reach here because warmup() will fail at
      // OrtSession.fromBuffer on Web in onnxruntime 1.4.1. Documented
      // for when Web support lands.
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
          // CoreML — Apple's neural engine path. enableOnSubgraph
          // lets the runtime pick which subgraphs go to CoreML vs
          // CPU; for SAM's TinyViT encoder this typically cuts
          // encoder latency by 2–3x on A14+.
          try {
            opts.appendCoreMLProvider(CoreMLFlags.enableOnSubgraph);
          } catch (_) {
            // Older simulator builds sometimes refuse CoreML.
          }
          break;
        case TargetPlatform.android:
          // Try NNAPI (Android's NN delegate) first, fall back to
          // XNNPACK (well-tuned ARM CPU kernels). useNCHW because
          // SAM is NCHW-native.
          try {
            opts.appendNnapiProvider(NnapiFlags.useNCHW);
          } catch (_) {
            try {
              opts.appendXnnpackProvider();
            } catch (_) {}
          }
          break;
        default:
          // Windows / Linux desktop — XNNPACK is still useful but
          // CPU is the simple safe path.
          try {
            opts.appendXnnpackProvider();
          } catch (_) {}
          break;
      }
    }

    opts.appendCPUProvider(CPUFlags.useArena);
    return opts;
  }

  static Future<Uint8List> _loadAssetBytes(String key) async {
    final byteData = await rootBundle.load(key);
    return byteData.buffer
        .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
  }

  /// Resize an RGBA frame to (target × target) and emit HWC uint8 bytes
  /// (R, G, B per pixel, row-major).
  ///
  /// Uses the `image` package's average filter for downsampling — fast
  /// enough to fit inside our 200 ms inference budget on a typical
  /// 1280×720 source frame (~6 ms on an iPhone 14 Pro). Bilinear is the
  /// pub.dev `image` default; we override to `Interpolation.average`
  /// because it produces less aliasing on small text/edges in the
  /// subject silhouette, which directly affects mask quality.
  static Uint8List _resizeRgbaToHwcUint8(
    Uint8List rgbaBytes,
    int srcWidth,
    int srcHeight,
    int target,
  ) {
    // Wrap the raw RGBA buffer as an Image without copying.
    final src = img.Image.fromBytes(
      width: srcWidth,
      height: srcHeight,
      bytes: rgbaBytes.buffer,
      bytesOffset: rgbaBytes.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    final resized = img.copyResize(
      src,
      width: target,
      height: target,
      interpolation: img.Interpolation.average,
    );

    // Emit HWC RGB uint8 — strip the alpha channel SAM doesn't want.
    final out = Uint8List(target * target * 3);
    var w = 0;
    for (final p in resized) {
      out[w++] = p.r.toInt();
      out[w++] = p.g.toInt();
      out[w++] = p.b.toInt();
    }
    return out;
  }

  /// Recursively flatten a possibly-nested numeric list to a Float32List.
  /// The onnxruntime package returns tensor outputs as nested
  /// `List<List<...>>`. For our purposes we always know the total element
  /// count (it's defined by the model contract), so we just walk the
  /// tree and copy floats out in row-major order.
  static Float32List _flattenToFloat32(dynamic value) {
    final out = <double>[];
    void walk(dynamic v) {
      if (v is num) {
        out.add(v.toDouble());
      } else if (v is List) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(value);
    return Float32List.fromList(out);
  }
}
