// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  LaplacianVarianceComputer.swift
//  Aether3D
//
//  Methodology breakthrough: Real Laplacian variance for blur detection.
//  REF: PyImageSearch, TheAILearner, renor.it — Laplacian variance as sharpness metric.
//  Sharp images → high variance; blur → low variance (low-pass attenuates high-freq).
//

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Computes Laplacian variance from a grayscale image buffer.
/// Used by BlurDetector for real blur assessment (replacing placeholder).
public enum LaplacianVarianceComputer {

    /// Laplacian 3×3 kernel (row-major): [[0,1,0],[1,-4,1],[0,1,0]]
    private static let laplacianKernel3x3Float: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
    private static let laplacianKernel3x3Int16: [Int16] = [0, 1, 0, 1, -4, 1, 0, 1, 0]

    /// Compute Laplacian variance from grayscale buffer.
    /// - Parameters:
    ///   - bytes: Pointer to grayscale bytes (8-bit, 0-255)
    ///   - width: Image width
    ///   - height: Image height
    ///   - rowBytes: Bytes per row (≥ width; may include padding)
    /// - Returns: Variance of Laplacian response. High = sharp, low = blurry.
    ///            Returns 0 on error (e.g. invalid dimensions).
    public static func compute(
        bytes: UnsafeRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int
    ) -> Double {
        guard width >= 3, height >= 3, rowBytes >= width else {
            return 0
        }
        let count = height * rowBytes
        guard count > 0 else { return 0 }

        #if canImport(Accelerate)
        return computeAccelerate(bytes: bytes.assumingMemoryBound(to: UInt8.self), width: width, height: height, rowBytes: rowBytes)
        #else
        return computeSwift(bytes: bytes.assumingMemoryBound(to: UInt8.self), width: width, height: height, rowBytes: rowBytes)
        #endif
    }

    #if canImport(Accelerate)
    private static func computeAccelerate(bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> Double {
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: bytes),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        let destCount = width * height
        let destPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: destCount)
        defer { destPtr.deallocate() }
        var destBuffer = vImage_Buffer(
            data: destPtr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        laplacianKernel3x3Int16.withUnsafeBufferPointer { kBuf in
            _ = vImageConvolve_Planar8(
                &srcBuffer,
                &destBuffer,
                nil,
                0, 0,
                kBuf.baseAddress!,
                UInt32(3), UInt32(3),
                1,
                UInt8(0),
                vImage_Flags(kvImageEdgeExtend)
            )
        }
        var destFloat = [Float](repeating: 0, count: destCount)
        for i in 0..<destCount {
            destFloat[i] = Float(destPtr[i])
        }
        var mean: Float = 0
        var meanOfSquares: Float = 0
        destFloat.withUnsafeBufferPointer { buf in
            vDSP_meanv(buf.baseAddress!, 1, &mean, vDSP_Length(destCount))
            vDSP_measqv(buf.baseAddress!, 1, &meanOfSquares, vDSP_Length(destCount))
        }
        let variance = Double(max(0, meanOfSquares - mean * mean))
        return variance
    }
    #endif

    private static func computeSwift(bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> Double {
        var lapValues: [Double] = []
        lapValues.reserveCapacity((height - 2) * (width - 2))
        let k = laplacianKernel3x3Float
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let base = y * rowBytes + x
                let v = Double(bytes[base - rowBytes - 1]) * Double(k[0])
                    + Double(bytes[base - rowBytes]) * Double(k[1])
                    + Double(bytes[base - rowBytes + 1]) * Double(k[2])
                    + Double(bytes[base - 1]) * Double(k[3])
                    + Double(bytes[base]) * Double(k[4])
                    + Double(bytes[base + 1]) * Double(k[5])
                    + Double(bytes[base + rowBytes - 1]) * Double(k[6])
                    + Double(bytes[base + rowBytes]) * Double(k[7])
                    + Double(bytes[base + rowBytes + 1]) * Double(k[8])
                lapValues.append(v)
            }
        }
        guard !lapValues.isEmpty else { return 0 }
        let mean = lapValues.reduce(0, +) / Double(lapValues.count)
        let variance = lapValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lapValues.count)
        return variance
    }
}
