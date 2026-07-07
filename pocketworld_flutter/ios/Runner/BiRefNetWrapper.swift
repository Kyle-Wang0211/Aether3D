// BiRefNetWrapper.swift
//
// Plan H (2026-05-17): BiRefNet lite @ 1024 on .cpuAndGPU — single-track.
//
// Why single-track (HR + LOW-tier branches deleted):
//   iPhone 14 Pro real-device benchmark 2026-05-17 — HR @ 1024 (Swin-Large
//   220M params) crashes on ALL three compute paths:
//     • ANE → KMEM 103KB > 64KB → partial fallback → 3287 MB jetsam
//     • CPU+GPU → Metal shader binary LLVM "No space left on device"
//     • CPU+BNNS → BNNS bnnsir compile "No space left on device" + jetsam
//   HR is physically infeasible on A16. Force lite is the only path.
//
// Why .cpuAndGPU (not ANE, not CPU-only):
//   lite @ 1024 (Swin-Tiny 44M) benchmarks on iPhone 14 Pro:
//     • ANE → ANECompile FAILED → jetsam (even Swin-Tiny conv too big for KMEM)
//     • CPU-only → 13-25 sec/frame (works but slow)
//     • CPU+GPU → 1.1 sec/frame stable, 2.4 GB peak — WINNER
//   300 frames × 1.1s = 5.5 min, fits Plan G's 15-25 min total budget.
//
// Caller usage
//   let session = try BiRefNetWrapper.Session()
//   let result = try session.predictSaliency(image: cgImage)
//   // result.mask           [Float] 1024*1024 sigmoid saliency [0,1]
//   // result.centerNormalized   CGPoint mass-weighted centroid in [0,1]
//   // result.bboxInOriginalCoords  CGRect of mask>0.5 region in orig coords
//   // result.foregroundRatio   Float ratio of mask>0.5 pixels

import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

@available(iOS 16.0, *)
@objc public final class BiRefNetWrapper: NSObject {

    public static let inputSize = 1024
    private static let bundleName = "BiRefNetLite_1024"

    public struct SaliencyResult {
        /// 1024×1024 fp32 saliency probability map in [0,1] (sigmoid applied).
        public let mask: [Float]
        /// Mass-weighted centroid of mask>0.5 region in [0,1]×[0,1] (top-left).
        public let centerNormalized: CGPoint
        /// BBox of mask>0.5 region in ORIGINAL image coordinates.
        /// nil if mask has < 50 foreground pixels (subject undetected).
        public let bboxInOriginalCoords: CGRect?
        /// Foreground pixel ratio of mask>0.5 (0.0–1.0).
        public let foregroundRatio: Float
        public let imageWidth: Int
        public let imageHeight: Int
        public let inferenceTimeMs: Double
    }

    public final class Session {
        public let model: MLModel
        public let inputFeatureName: String
        public let outputFeatureName: String

        public init() throws {
            let bundleURL = try Self.resolveBundleURL()
            let config = MLModelConfiguration()
            // .cpuAndGPU: only viable compute path on iPhone 14 Pro A16 for
            // lite Swin-Tiny @ 1024 (see file header for the 5-way bench).
            config.computeUnits = .cpuAndGPU
            self.model = try MLModel(contentsOf: bundleURL, configuration: config)
            let spec = self.model.modelDescription
            // mlpackage export path may name input "image" or "input_image";
            // output is always "saliency". Discover dynamically to survive
            // either onnx2torch round-trip naming.
            self.inputFeatureName = spec.inputDescriptionsByName.keys.first ?? "image"
            self.outputFeatureName = spec.outputDescriptionsByName.keys.first ?? "saliency"
            NSLog("[BiRefNet] loaded computeUnits=cpuAndGPU input=\(self.inputFeatureName) output=\(self.outputFeatureName)")
        }

        private static func resolveBundleURL() throws -> URL {
            if let compiled = Bundle.main.url(forResource: bundleName, withExtension: "mlmodelc") {
                return compiled
            }
            if let pkg = Bundle.main.url(forResource: bundleName, withExtension: "mlpackage") {
                return pkg
            }
            throw NSError(
                domain: "BiRefNet", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "BiRefNet model \(bundleName) not found in app bundle"]
            )
        }

        public func predictSaliency(image: CGImage) throws -> SaliencyResult {
            let origW = image.width
            let origH = image.height

            let t0 = CFAbsoluteTimeGetCurrent()

            let pixelBuf = try Self.cgImageToBGRAPixelBuffer1024(image)
            let input = try MLDictionaryFeatureProvider(dictionary: [
                inputFeatureName: MLFeatureValue(pixelBuffer: pixelBuf)
            ])

            let output = try model.prediction(from: input)
            guard let salFp16 = output.featureValue(for: outputFeatureName)?.multiArrayValue else {
                throw NSError(
                    domain: "BiRefNet", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "model output \(outputFeatureName) missing"]
                )
            }

            let salFp32 = Self.fp16ToFloat32(salFp16)
            let inferenceMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

            let stats = Self.computeMaskStats(
                mask: salFp32, w: BiRefNetWrapper.inputSize, h: BiRefNetWrapper.inputSize,
                threshold: 0.5
            )
            let centerNorm = CGPoint(
                x: CGFloat(stats.centerX) / CGFloat(BiRefNetWrapper.inputSize),
                y: CGFloat(stats.centerY) / CGFloat(BiRefNetWrapper.inputSize)
            )
            let bbox: CGRect? = {
                guard stats.fgCount >= 50, let bb = stats.bbox else { return nil }
                let scaleX = CGFloat(origW) / CGFloat(BiRefNetWrapper.inputSize)
                let scaleY = CGFloat(origH) / CGFloat(BiRefNetWrapper.inputSize)
                return CGRect(
                    x: bb.minX * scaleX, y: bb.minY * scaleY,
                    width: bb.width * scaleX, height: bb.height * scaleY
                )
            }()
            return SaliencyResult(
                mask: salFp32,
                centerNormalized: centerNorm,
                bboxInOriginalCoords: bbox,
                foregroundRatio: Float(stats.fgCount) / Float(BiRefNetWrapper.inputSize * BiRefNetWrapper.inputSize),
                imageWidth: origW,
                imageHeight: origH,
                inferenceTimeMs: inferenceMs
            )
        }

        // MARK: - helpers

        private static func fp16ToFloat32(_ array: MLMultiArray) -> [Float] {
            let count = array.count
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: array.dataPointer, height: 1,
                                       width: UInt(count), rowBytes: count * 2)
                var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst.baseAddress!),
                                       height: 1, width: UInt(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
            return out
        }

        private struct MaskStats {
            let centerX: Float
            let centerY: Float
            let bbox: CGRect?
            let fgCount: Int
        }

        private static func computeMaskStats(mask: [Float], w: Int, h: Int, threshold: Float) -> MaskStats {
            var sumW: Double = 0, sumX: Double = 0, sumY: Double = 0
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            var fgCount = 0
            for y in 0..<h {
                let rowOffset = y * w
                for x in 0..<w {
                    let v = mask[rowOffset + x]
                    if v >= threshold {
                        fgCount &+= 1
                        if x < minX { minX = x }
                        if y < minY { minY = y }
                        if x > maxX { maxX = x }
                        if y > maxY { maxY = y }
                        let weight = Double(v)
                        sumW += weight
                        sumX += weight * Double(x)
                        sumY += weight * Double(y)
                    }
                }
            }
            let cx: Float = sumW > 0 ? Float(sumX / sumW) : Float(w) / 2.0
            let cy: Float = sumW > 0 ? Float(sumY / sumW) : Float(h) / 2.0
            let bbox: CGRect? = (maxX >= minX && maxY >= minY)
                ? CGRect(x: CGFloat(minX), y: CGFloat(minY),
                         width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
                : nil
            return MaskStats(centerX: cx, centerY: cy, bbox: bbox, fgCount: fgCount)
        }

        private static func cgImageToBGRAPixelBuffer1024(_ image: CGImage) throws -> CVPixelBuffer {
            let size = BiRefNetWrapper.inputSize
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                attrs as CFDictionary, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buf = pixelBuffer else {
                throw NSError(
                    domain: "BiRefNet", code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate fail: \(status)"]
                )
            }
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            guard let base = CVPixelBufferGetBaseAddress(buf) else {
                throw NSError(
                    domain: "BiRefNet", code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "pixel buffer baseAddress nil"]
                )
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo: UInt32 =
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(
                data: base, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: bitmapInfo
            ) else {
                throw NSError(
                    domain: "BiRefNet", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "CGContext create fail"]
                )
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return buf
        }
    }
}
