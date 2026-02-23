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
import CAetherNativeBridge

/// Computes Laplacian variance from a grayscale image buffer.
/// Used by BlurDetector for real blur assessment (replacing placeholder).
public enum LaplacianVarianceComputer {

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

        var nativeVariance = 0.0
        let nativeRC = aether_laplacian_variance_compute(
            bytes.assumingMemoryBound(to: UInt8.self),
            Int32(width),
            Int32(height),
            Int32(rowBytes),
            &nativeVariance
        )
        return nativeRC == 0 ? nativeVariance : 0
    }
}
