// MaterialClassifierPlugin.swift
//
// SigLIP-base/16-224 raw material score executor.
//
// Dart owns MaterialDescriptorSpec/Report: thresholds, prompt-set version,
// cache scope, and how the score affects highlight policy. This Swift file
// only loads the bundled model, runs the forward pass, and returns
// p_reflective/infer_ms.
//
// Pipeline
// --------
// Dart side passes RGBA bytes + width/height → resize to 224×224 → ImageNet-style
// normalize ([-1, 1]) → SigLIP vision encoder → 768-dim L2-normalized embedding
// → dot product with 6 pre-computed text prompt embeddings → SigLIP sigmoid
// scoring (logit_scale + logit_bias from training) → mean over reflective vs
// diffuse prompts → final P(reflective) ∈ [0, 1].
//
// Why pre-computed text embeddings instead of running the text encoder at
// runtime: the 6 prompts ("a photo of a reflective shiny mirror-like ...")
// are fixed at ship time. Running text encoder per inference would double the
// model size in the bundle (text encoder is also ~80M params). We compute
// the embeddings once at conversion time and ship them as a 128 KB JSON.
//
// Bundle (ODR `tier:high` group, shared with DA3 K=3 multi-view):
//   SigLIPBase_vision_fp16.mlpackage  (~176 MB on disk)
//   text_embeddings.json              (~128 KB; 6 × 768 floats + logit_scale + logit_bias)
//
// Grounded numbers (Mac CPU_ONLY, 2026-05-20 spike):
//   - AUC 0.997 on 75 Ref-NeRF Shiny Blender + NeRF Synthetic lego images
//   - 0 false positives (perfect specificity at threshold 0.5)
//   - 75% recall (TP=45 / FN=15 at threshold 0.5)
//   - 40 ms / image on Mac M3 Pro CPU
//   - Estimated 44 ms / image on iPhone 14 Pro CPU (DA3 ratio extrapolation)

import CoreML
import Flutter
import Foundation
import UIKit

@objc public final class MaterialClassifierPlugin: NSObject {

    // MARK: Cached state

    /// SigLIP vision encoder. Loaded lazily on first classify() call.
    private var visionModel: MLModel?

    /// Pre-computed text prompt embeddings + SigLIP logit calibration.
    private struct TextCalibration {
        let embeddings: [[Float]]   // (6, 768) L2-normalized
        let nReflective: Int        // 3
        let nDiffuse: Int           // 3
        let embedDim: Int           // 768
        let logitScale: Float       // ~117.3
        let logitBias: Float        // ~-12.9
    }
    private var textCal: TextCalibration?

    /// Lazy load — pay the ~600 ms model load cost once per app lifetime.
    private func ensureLoaded() throws {
        if visionModel != nil && textCal != nil {
            return
        }

        // 1) Locate mlpackage (or its compiled .mlmodelc) in Bundle.main.
        //    Xcode auto-compiles .mlpackage to .mlmodelc at build time, so
        //    .mlmodelc is what's actually in the app bundle.
        let modelName = "SigLIPBase_vision_fp16"
        var resolvedURL: URL?
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: modelName, withExtension: ext) {
                resolvedURL = url
                break
            }
        }
        guard let mlURL = resolvedURL else {
            throw NSError(
                domain: "MaterialClassifier", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "SigLIPBase_vision_fp16.mlmodelc not found in Bundle.main — " +
                    "did ODR tier:high download complete?"]
            )
        }

        let config = MLModelConfiguration()
        // .cpuOnly matches DA3 production lock (see memory
        // feedback_iphone_da3_multiview_grounded.md). ANE is fp16-only and
        // SigLIP base fits, but we keep cpuOnly for predictable memory profile
        // and unified scheduling with DA3 inference passes.
        config.computeUnits = .cpuOnly
        self.visionModel = try MLModel(contentsOf: mlURL, configuration: config)

        // 2) Load pre-computed text embeddings JSON.
        guard let jsonURL = Bundle.main.url(forResource: "text_embeddings",
                                            withExtension: "json") else {
            throw NSError(
                domain: "MaterialClassifier", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "text_embeddings.json not in bundle"]
            )
        }
        let data = try Data(contentsOf: jsonURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embRaw = json["embeddings"] as? [[Any]],
              let nRefl = json["n_reflective"] as? Int,
              let nDiff = json["n_diffuse"] as? Int,
              let embedDim = json["embed_dim"] as? Int,
              let logitScale = json["logit_scale"] as? Double,
              let logitBias = json["logit_bias"] as? Double else {
            throw NSError(
                domain: "MaterialClassifier", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "text_embeddings.json schema mismatch"]
            )
        }
        var emb: [[Float]] = []
        emb.reserveCapacity(embRaw.count)
        for row in embRaw {
            emb.append(row.compactMap { ($0 as? NSNumber)?.floatValue })
        }
        self.textCal = TextCalibration(
            embeddings: emb,
            nReflective: nRefl,
            nDiffuse: nDiff,
            embedDim: embedDim,
            logitScale: Float(logitScale),
            logitBias: Float(logitBias)
        )
        NSLog("[MaterialClassifier] loaded SigLIP vision encoder + %d prompt embeddings (logit_scale=%.2f)",
              emb.count, logitScale)
    }

    // MARK: Image preprocessing
    //
    // SigLIP standard preprocessing: resize 224×224 bilinear, normalize to
    // [-1, 1] via (x/255 - 0.5) / 0.5. Then NCHW layout (1, 3, 224, 224) fp32.

    private static func preprocessSigLIP(rgba: Data, width: Int, height: Int) throws -> MLMultiArray {
        let side = 224
        // 1. Resize via CGContext (sRGB sample, bilinear default for CoreGraphics).
        let bytesPerPixel = 4
        let srcBytesPerRow = width * bytesPerPixel
        guard rgba.count >= srcBytesPerRow * height else {
            throw NSError(
                domain: "MaterialClassifier", code: 10,
                userInfo: [NSLocalizedDescriptionKey:
                    "rgba buffer too small: \(rgba.count) bytes for \(width)x\(height)"]
            )
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "MaterialClassifier", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "no sRGB color space"])
        }
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue

        // Create source CGImage from raw RGBA
        var srcBytes = [UInt8](repeating: 0, count: rgba.count)
        rgba.copyBytes(to: &srcBytes, count: rgba.count)
        guard let provider = CGDataProvider(data: NSData(bytes: srcBytes, length: srcBytes.count)),
              let srcImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: srcBytesPerRow,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw NSError(domain: "MaterialClassifier", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "CGImage from raw RGBA failed"])
        }

        // Resize to 224×224 in fresh RGBA buffer.
        let dstBytesPerRow = side * bytesPerPixel
        var dstBytes = [UInt8](repeating: 0, count: dstBytesPerRow * side)
        guard let ctx = CGContext(
            data: &dstBytes,
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: dstBytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "MaterialClassifier", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext create failed"])
        }
        ctx.interpolationQuality = .high
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 2. Normalize + write to (1, 3, side, side) MLMultiArray fp32.
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        )
        let planeSize = side * side
        let dataPtr = array.dataPointer.bindMemory(
            to: Float32.self, capacity: 3 * planeSize
        )
        let mean: Float = 0.5
        let std: Float = 0.5
        for y in 0..<side {
            for x in 0..<side {
                let srcOff = y * dstBytesPerRow + x * bytesPerPixel
                let r = Float(dstBytes[srcOff + 0]) / 255.0
                let g = Float(dstBytes[srcOff + 1]) / 255.0
                let b = Float(dstBytes[srcOff + 2]) / 255.0
                let dstOff = y * side + x
                dataPtr[0 * planeSize + dstOff] = (r - mean) / std
                dataPtr[1 * planeSize + dstOff] = (g - mean) / std
                dataPtr[2 * planeSize + dstOff] = (b - mean) / std
            }
        }
        return array
    }

    // MARK: SigLIP scoring

    /// Run vision encoder + dot product with text embeddings + sigmoid scoring.
    /// Returns P(reflective) ∈ [0, 1].
    private func scoreReflective(rgba: Data, width: Int, height: Int) throws -> (
        pReflective: Double, inferMs: Double
    ) {
        try ensureLoaded()
        guard let model = self.visionModel, let cal = self.textCal else {
            throw NSError(domain: "MaterialClassifier", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "model not loaded"])
        }

        // 1. Preprocess
        let inputArray = try Self.preprocessSigLIP(rgba: rgba, width: width, height: height)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputArray])

        // 2. Vision encoder forward
        let t0 = CFAbsoluteTimeGetCurrent()
        let output = try model.prediction(from: provider)
        let inferMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        // 3. Extract image embedding (768-dim L2-normalized)
        guard let embArr = output.featureValue(for: "image_embedding")?.multiArrayValue else {
            throw NSError(domain: "MaterialClassifier", code: 21,
                          userInfo: [NSLocalizedDescriptionKey:
                            "image_embedding not in output (have: \(output.featureNames))"])
        }
        let dim = cal.embedDim
        guard embArr.count == dim else {
            throw NSError(domain: "MaterialClassifier", code: 22,
                          userInfo: [NSLocalizedDescriptionKey:
                            "embedding dim mismatch: got \(embArr.count) expected \(dim)"])
        }

        let imgEmb: [Float] = {
            var buf = [Float](repeating: 0, count: dim)
            // Output dtype is declared fp32 at conversion time
            // (ct.TensorType dtype=np.float32 in convert_siglip_coreml.py).
            // CoreML may still emit fp16 internally if compute_precision is FP16,
            // but the OUTPUT tensor is cast back to fp32 by CoreML's epilogue.
            // Read via fast fp32 path; fall back to NSNumber boxing for any
            // other dtype the runtime might produce.
            if embArr.dataType == .float32 {
                let p = embArr.dataPointer.bindMemory(to: Float32.self, capacity: dim)
                for i in 0..<dim { buf[i] = p[i] }
            } else {
                for i in 0..<dim { buf[i] = Float(truncating: embArr[i]) }
            }
            return buf
        }()

        // 4. Cosine sim with each prompt + SigLIP scoring
        //    sims[k] = sum_d img[d] * text[k][d]
        //    logits[k] = sims[k] * logit_scale + logit_bias
        //    probs[k] = sigmoid(logits[k])
        //    P(reflective_group) = mean(probs[0..nReflective])
        //    P(diffuse_group)    = mean(probs[nReflective..])
        //    P(reflective) = P(reflective_group) / (P(reflective_group) + P(diffuse_group))
        let nRefl = cal.nReflective
        let nDiff = cal.nDiffuse
        let scale = cal.logitScale
        let bias = cal.logitBias
        var sumRefl: Double = 0
        var sumDiff: Double = 0
        for k in 0..<(nRefl + nDiff) {
            let textK = cal.embeddings[k]
            var sim: Float = 0
            for d in 0..<dim {
                sim += imgEmb[d] * textK[d]
            }
            let logit = sim * scale + bias
            // Sigmoid: 1 / (1 + exp(-logit))
            let prob = 1.0 / (1.0 + exp(-Double(logit)))
            if k < nRefl {
                sumRefl += prob
            } else {
                sumDiff += prob
            }
        }
        let meanRefl = sumRefl / Double(nRefl)
        let meanDiff = sumDiff / Double(nDiff)
        let pReflective = meanRefl / max(meanRefl + meanDiff, 1e-6)
        return (pReflective: pReflective, inferMs: inferMs)
    }

    // MARK: Plugin registration

    @objc public static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "pocketworld/material_classifier",
            binaryMessenger: messenger
        )
        let plugin = MaterialClassifierPlugin()
        channel.setMethodCallHandler { call, result in
            plugin.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "classify":
            handleClassify(call: call, result: result)
        case "warmup":
            handleWarmup(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// `classify({rgba: Uint8List, width: int, height: int})` →
    /// raw {p_reflective, infer_ms}. No thresholding or product policy here.
    private func handleClassify(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let rgbaTyped = args["rgba"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int else {
            result(FlutterError(code: "BAD_ARGS",
                                message: "classify needs {rgba, width, height}",
                                details: nil))
            return
        }
        let rgba = rgbaTyped.data
        // Copy to a Data we own across the dispatch boundary (same fix as
        // pocketworld_onnx_bench K=5 spike — FlutterStandardTypedData buffer
        // is owned by Flutter and may go invalid after handler returns).
        let rgbaCopy = Data(rgba)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let r = try self.scoreReflective(rgba: rgbaCopy, width: width, height: height)
                result([
                    "p_reflective": r.pReflective,
                    "infer_ms": r.inferMs,
                ])
            } catch {
                NSLog("[MaterialClassifier] classify failed: \(error)")
                result(FlutterError(code: "CLASSIFY_FAILED",
                                    message: "\(error)", details: nil))
            }
        }
    }

    /// `warmup()` → loads the model so the first real classify() call doesn't
    /// pay the ~600 ms load cost. Caller should fire-and-forget at app launch
    /// or capture-page mount.
    private func handleWarmup(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureLoaded()
                result(["loaded": true])
            } catch {
                NSLog("[MaterialClassifier] warmup failed: \(error)")
                result(FlutterError(code: "WARMUP_FAILED",
                                    message: "\(error)", details: nil))
            }
        }
    }
}
