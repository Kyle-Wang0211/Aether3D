// EdgeTAMWrapper.swift
//
// 3-stage SAM 2 (mobile, distilled) inference: image encoder + prompt encoder
// + mask decoder. EdgeTAM = Meta Reality Labs distilled SAM 2 for on-device
// (Apache 2.0, paper arxiv 2501.07256, 16 FPS iPhone 15 Pro Max).
//
// Plan G W2 D1: PocketWorld dome capture subject mask. Replaces MobileSAM in
// the existing capture flow. For dome capture, subject is always centered in
// frame (user orbits camera around object), so default prompt = image center.
//
// Architecture
// ------------
//   Stage 1 (image encoder, run once per frame):
//     CGImage → resize to 1024×1024 → CVPixelBuffer (BGRA) → CoreML
//     Outputs: vision_features (1,256,64,64), high_res_feat_0 (1,32,256,256),
//              high_res_feat_1 (1,64,128,128). All fp16.
//
//   Stage 2 (prompt encoder, run once per prompt — we pass single point):
//     Inputs: point_coords (1,4,2) fp16 — up to 4 points in 1024×1024 space
//             point_labels (1,4) fp16 — 1=fg, 0=bg, -1=ignore
//             boxes (1,4) fp16 — bbox (x1,y1,x2,y2)
//             mask_input (1,1,256,256) fp16 — previous mask for refinement
//     Outputs: sparse_embeddings (1,5,256) fp16
//              dense_embeddings (1,256,64,64) fp16
//
//   Stage 3 (mask decoder, run once per prompt):
//     Inputs: image_embeddings + image_pe + sparse[:1] + dense + high_res
//             + multimask_output (1,) — scalar 1.0 to get 3 mask hypotheses
//     Outputs: masks (1,3,256,256) fp16 — 3 hypotheses
//              iou_pred (1,3) fp16 — IoU for each hypothesis
//
//   Post-process: argmax(iou_pred) → pick best hypothesis → sigmoid → resize
//                 256×256 → original frame size.
//
// image_pe is a fixed positional encoding (1,256,64,64) extracted offline from
// the PyTorch model via `sam_prompt_encoder.get_dense_pe()`. Bundled as
// edgetam_image_pe.float32.bin (4 MB). Converted to fp16 MLMultiArray at load
// time via vImage.

import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

@available(iOS 16.0, *)
@objc public final class EdgeTAMWrapper: NSObject {

    public static let inputSize = 1024
    public static let embedSpatial = 64
    public static let embedDim = 256
    public static let maskOutSize = 256

    public struct MaskResult {
        /// 256×256 fp32 mask logits, post-sigmoid → [0, 1] foreground probability.
        public let mask: [Float]
        public let iou: Float
        public let bestHypothesis: Int  // 0, 1, or 2
        public let allIoUs: [Float]     // 3-element
        public let inferenceTimeMs: Double
        public let promptPoint: CGPoint  // in original image coords
        public let imageWidth: Int
        public let imageHeight: Int
    }

    public final class Session {
        public let imageEncoder: MLModel
        public let promptEncoder: MLModel
        public let maskDecoder: MLModel
        public let imagePe: MLMultiArray   // (1, 256, 64, 64) fp16, loaded once
        private let zeroMaskInput: MLMultiArray  // (1, 1, 256, 256) fp16 zeros
        private let multimaskOnFlag: MLMultiArray  // (1,) fp16 = [1]
        private let emptyBox: MLMultiArray  // (1, 4) fp16 zeros

        public init(
            imageEncoderURL: URL,
            promptEncoderURL: URL,
            maskDecoderURL: URL,
            imagePeURL: URL
        ) throws {
            let config = MLModelConfiguration()
            // Plan G W2 D1 default: CPU_ONLY. W7 may switch to ANE/ALL after
            // memory mgmt lands (per W1 D2 finding ANE doesn't crash bare).
            config.computeUnits = .cpuOnly
            self.imageEncoder = try MLModel(contentsOf: imageEncoderURL, configuration: config)
            self.promptEncoder = try MLModel(contentsOf: promptEncoderURL, configuration: config)
            self.maskDecoder = try MLModel(contentsOf: maskDecoderURL, configuration: config)
            self.imagePe = try Self.loadImagePeFromBin(imagePeURL)
            self.zeroMaskInput = try Self.makeFp16Array(shape: [1, 1, 256, 256])
            self.emptyBox = try Self.makeFp16Array(shape: [1, 4])
            self.multimaskOnFlag = try Self.makeFp16Array(shape: [1], fillFloat32: 1.0)
        }

        /// Run a full mask prediction.
        ///
        /// Prompt selection (per SAM 2 official: box prompt is non-ambiguous,
        /// gives best mask quality):
        /// - `promptBox` provided → SAM 2 segments the bbox region (recommended
        ///   for Plan G W6: caller pulls bbox from PocketWorld curated frame
        ///   `_target_zone_metrics`).
        /// - `promptPoint` provided → SAM 2 segments region around the point.
        ///   Caller picks the point on the subject.
        /// - Both provided → point + box combined (most informative).
        /// - Neither provided → point defaults to image center. Plan G W2 D1
        ///   bench showed this is unreliable on real dome captures (subject
        ///   not always centered); rely on it only for tightly-framed fixtures.
        public func predictMask(
            image: CGImage,
            promptPoint: CGPoint? = nil,
            promptBox: CGRect? = nil
        ) throws -> MaskResult {
            let origW = image.width
            let origH = image.height
            let scaleX = Float(EdgeTAMWrapper.inputSize) / Float(origW)
            let scaleY = Float(EdgeTAMWrapper.inputSize) / Float(origH)

            // Pick effective prompt point. If only box given, use box center.
            let effectivePoint: CGPoint = {
                if let p = promptPoint { return p }
                if let b = promptBox { return CGPoint(x: b.midX, y: b.midY) }
                return CGPoint(x: origW / 2, y: origH / 2)
            }()
            let promptX = Float(effectivePoint.x) * scaleX
            let promptY = Float(effectivePoint.y) * scaleY

            let t0 = CFAbsoluteTimeGetCurrent()

            // Stage 1: image encoder
            let pixelBuf = try Self.cgImageToBGRAPixelBuffer1024(image)
            let enc = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: pixelBuf)
            ])
            let encOut = try imageEncoder.prediction(from: enc)
            guard let visionFeats = encOut.featureValue(for: "vision_features")?.multiArrayValue,
                  let highRes0 = encOut.featureValue(for: "high_res_feat_0")?.multiArrayValue,
                  let highRes1 = encOut.featureValue(for: "high_res_feat_1")?.multiArrayValue else {
                throw NSError(domain: "EdgeTAM", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "image_encoder missing outputs"])
            }

            // Stage 2: prompt encoder. Single foreground point + 3 ignored.
            let pointCoords = try Self.makeFp16Array(shape: [1, 4, 2])
            try Self.writeFp16(pointCoords, index: [0, 0, 0], float32: promptX)
            try Self.writeFp16(pointCoords, index: [0, 0, 1], float32: promptY)
            // Other 3 points stay 0.

            let pointLabels = try Self.makeFp16Array(shape: [1, 4])
            try Self.writeFp16(pointLabels, index: [0, 0], float32: 1.0)   // foreground
            try Self.writeFp16(pointLabels, index: [0, 1], float32: -1.0)  // ignore
            try Self.writeFp16(pointLabels, index: [0, 2], float32: -1.0)
            try Self.writeFp16(pointLabels, index: [0, 3], float32: -1.0)

            // Box prompt: SAM 2 prompt_encoder `boxes` shape is (1, 4) =
            // (x1, y1, x2, y2) in 1024-space. When caller provides a CGRect,
            // map from original-image coords → 1024 coords and overwrite the
            // shared `emptyBox` MLMultiArray for this call (predictMask is
            // not thread-safe; per Plan G W2 D1 the engine is single-call).
            // When no box is provided, leave it zero — SAM 2 prompt_encoder
            // treats all-zero box as "no box" and uses point prompt only.
            if let b = promptBox {
                let x1 = Float(b.minX) * scaleX
                let y1 = Float(b.minY) * scaleY
                let x2 = Float(b.maxX) * scaleX
                let y2 = Float(b.maxY) * scaleY
                try Self.writeFp16(emptyBox, index: [0, 0], float32: x1)
                try Self.writeFp16(emptyBox, index: [0, 1], float32: y1)
                try Self.writeFp16(emptyBox, index: [0, 2], float32: x2)
                try Self.writeFp16(emptyBox, index: [0, 3], float32: y2)
            } else {
                // Restore zero box if a prior call set it (single-threaded API,
                // so we own it).
                try Self.writeFp16(emptyBox, index: [0, 0], float32: 0)
                try Self.writeFp16(emptyBox, index: [0, 1], float32: 0)
                try Self.writeFp16(emptyBox, index: [0, 2], float32: 0)
                try Self.writeFp16(emptyBox, index: [0, 3], float32: 0)
            }

            let promptIn = try MLDictionaryFeatureProvider(dictionary: [
                "point_coords": pointCoords,
                "point_labels": pointLabels,
                "boxes": emptyBox,
                "mask_input": zeroMaskInput,
            ])
            let promptOut = try promptEncoder.prediction(from: promptIn)
            guard let sparseEmb = promptOut.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                  let denseEmb = promptOut.featureValue(for: "dense_embeddings")?.multiArrayValue else {
                throw NSError(domain: "EdgeTAM", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "prompt_encoder missing outputs"])
            }

            // prompt_encoder.sparse_embeddings is (1, 5, 256); mask_decoder wants (1, 1, 256).
            // Slice the first sparse embedding (the single point's encoding).
            let sparseFirst = try Self.sliceFirstSparse(sparseEmb)

            // Stage 3: mask decoder
            let decIn = try MLDictionaryFeatureProvider(dictionary: [
                "image_embeddings": visionFeats,
                "image_pe": imagePe,
                "sparse_prompt_embeddings": sparseFirst,
                "dense_prompt_embeddings": denseEmb,
                "high_res_feat_0": highRes0,
                "high_res_feat_1": highRes1,
                "multimask_output": multimaskOnFlag,
            ])
            let decOut = try maskDecoder.prediction(from: decIn)
            guard let masks = decOut.featureValue(for: "masks")?.multiArrayValue,
                  let iouPred = decOut.featureValue(for: "iou_pred")?.multiArrayValue else {
                throw NSError(domain: "EdgeTAM", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "mask_decoder missing outputs"])
            }

            // Pick best hypothesis by IoU + extract plane + sigmoid via C++
            // `aether_edgetam_post_process` (aether_cpp/src/pipeline/mask_post.cpp).
            // Cross-platform shared math, bit-equal verified vs prior Swift impl
            // in W2 D1 parity bench (max |Δmask|=0.0, perfect).
            let iouArr = Self.fp16ArrayToFloat32(iouPred)
            let maskFlat = Self.fp16ArrayToFloat32(masks)  // 3*256*256 = 196608 floats
            let planeSize = EdgeTAMWrapper.maskOutSize * EdgeTAMWrapper.maskOutSize
            var maskLogits = [Float](repeating: 0, count: planeSize)
            var bestIdxC: Int32 = 0
            _ = maskFlat.withUnsafeBufferPointer { mlBuf in
                iouArr.withUnsafeBufferPointer { iBuf in
                    maskLogits.withUnsafeMutableBufferPointer { outBuf in
                        aether_edgetam_post_process(
                            mlBuf.baseAddress, iBuf.baseAddress,
                            3, Int32(EdgeTAMWrapper.maskOutSize), Int32(EdgeTAMWrapper.maskOutSize),
                            outBuf.baseAddress, &bestIdxC
                        )
                    }
                }
            }
            let bestIdx = Int(bestIdxC)
            let bestIoU = iouArr[bestIdx]

            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return MaskResult(
                mask: maskLogits,
                iou: bestIoU,
                bestHypothesis: bestIdx,
                allIoUs: iouArr,
                inferenceTimeMs: elapsed,
                promptPoint: effectivePoint,
                imageWidth: origW,
                imageHeight: origH
            )
        }

        // ── Helpers ────────────────────────────────────────────────────────

        /// Load 4 MB fp32 file → fp16 MLMultiArray (1, 256, 64, 64).
        private static func loadImagePeFromBin(_ url: URL) throws -> MLMultiArray {
            let data = try Data(contentsOf: url)
            let count = data.count / MemoryLayout<Float32>.size
            let expected = 1 * 256 * 64 * 64
            guard count == expected else {
                throw NSError(domain: "EdgeTAM", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "image_pe.bin size mismatch: got \(count), expected \(expected)"])
            }
            let array = try MLMultiArray(
                shape: [1, 256, 64, 64],
                dataType: .float16
            )
            // Use vImage to convert fp32 → fp16 in one pass.
            try data.withUnsafeBytes { rawBuf in
                guard let srcPtr = rawBuf.baseAddress else {
                    throw NSError(domain: "EdgeTAM", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "data baseAddress nil"])
                }
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcPtr),
                    height: 1,
                    width: UInt(count),
                    rowBytes: count * 4
                )
                var dstBuf = vImage_Buffer(
                    data: array.dataPointer,
                    height: 1,
                    width: UInt(count),
                    rowBytes: count * 2
                )
                let err = vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
                if err != kvImageNoError {
                    throw NSError(domain: "EdgeTAM", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "fp32→fp16 conversion failed: \(err)"])
                }
            }
            return array
        }

        /// Build fp16 MLMultiArray of given shape, all zeros by default. Optionally fill
        /// with a single float32 value (replicated to every element).
        private static func makeFp16Array(shape: [Int], fillFloat32: Float = 0.0) throws -> MLMultiArray {
            let nsShape = shape.map { NSNumber(value: $0) }
            let array = try MLMultiArray(shape: nsShape, dataType: .float16)
            let count = shape.reduce(1, *)
            if fillFloat32 == 0.0 {
                memset(array.dataPointer, 0, count * 2)
            } else {
                var src = [Float](repeating: fillFloat32, count: count)
                src.withUnsafeMutableBufferPointer { srcBuf in
                    var s = vImage_Buffer(
                        data: UnsafeMutableRawPointer(srcBuf.baseAddress!),
                        height: 1, width: UInt(count), rowBytes: count * 4
                    )
                    var d = vImage_Buffer(
                        data: array.dataPointer,
                        height: 1, width: UInt(count), rowBytes: count * 2
                    )
                    _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
                }
            }
            return array
        }

        /// Write a single float32 value at a given multi-index into an fp16 MLMultiArray.
        private static func writeFp16(_ array: MLMultiArray, index: [Int], float32 value: Float) throws {
            // Compute flat offset
            var offset = 0
            for (i, idx) in index.enumerated() {
                offset = offset * array.shape[i].intValue + idx
            }
            // Convert float32 → fp16 using vImage.
            var src = [Float](repeating: value, count: 1)
            var dst = [UInt16](repeating: 0, count: 1)
            src.withUnsafeMutableBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    var s = vImage_Buffer(data: sp.baseAddress!, height: 1, width: 1, rowBytes: 4)
                    var d = vImage_Buffer(data: dp.baseAddress!, height: 1, width: 1, rowBytes: 2)
                    _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
                }
            }
            // Write at offset.
            let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            ptr[offset] = dst[0]
        }

        /// Slice prompt_encoder.sparse_embeddings (1, 5, 256) → (1, 1, 256) keeping
        /// only the first sparse embedding (single point's encoding).
        private static func sliceFirstSparse(_ src: MLMultiArray) throws -> MLMultiArray {
            let dst = try MLMultiArray(shape: [1, 1, 256], dataType: .float16)
            // Source (1, 5, 256) — first 256 elements = first sparse embedding.
            let srcPtr = src.dataPointer.bindMemory(to: UInt16.self, capacity: src.count)
            let dstPtr = dst.dataPointer.bindMemory(to: UInt16.self, capacity: dst.count)
            for i in 0..<256 {
                dstPtr[i] = srcPtr[i]
            }
            return dst
        }

        /// Convert an fp16 MLMultiArray to a flat [Float] (fp32) buffer.
        private static func fp16ArrayToFloat32(_ array: MLMultiArray) -> [Float] {
            let count = array.count
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(
                    data: array.dataPointer,
                    height: 1, width: UInt(count), rowBytes: count * 2
                )
                var d = vImage_Buffer(
                    data: UnsafeMutableRawPointer(dst.baseAddress!),
                    height: 1, width: UInt(count), rowBytes: count * 4
                )
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
            return out
        }

        /// Resize CGImage to 1024×1024 and produce a BGRA CVPixelBuffer.
        /// EdgeTAM image_encoder expects 1024×1024 BGR (colorSpace=20 = BGR).
        /// CoreML accepts BGRA pixel buffers — it ignores the A channel for BGR input.
        private static func cgImageToBGRAPixelBuffer1024(_ image: CGImage) throws -> CVPixelBuffer {
            let size = EdgeTAMWrapper.inputSize
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                size, size,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buf = pixelBuffer else {
                throw NSError(domain: "EdgeTAM", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate fail: \(status)"])
            }
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }

            guard let base = CVPixelBufferGetBaseAddress(buf) else {
                throw NSError(domain: "EdgeTAM", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "pixel buffer baseAddress nil"])
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo: UInt32 =
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(
                data: base,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ) else {
                throw NSError(domain: "EdgeTAM", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "CGContext create fail"])
            }
            // Draw scaled image into the 1024×1024 context.
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return buf
        }
    }
}
