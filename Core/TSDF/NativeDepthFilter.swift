// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

struct NativeDepthFilterQuality: Sendable {
    var noiseResidual: Float
    var validRatio: Float
    var edgeRiskScore: Float
}

struct NativeDepthFilterOutput: Sendable {
    var depth: [Float]
    var quality: NativeDepthFilterQuality
}

final class NativeDepthFilter {
    private var handle: OpaquePointer?
    private let pixelCount: Int

    init(width: Int, height: Int) {
        pixelCount = width * height
        var config = aether_depth_filter_config_t(
            sigma_spatial: 1.5,
            sigma_range: 0.03,
            kernel_radius: 2,
            max_fill_radius: 1,
            min_valid_depth: 0.1,
            max_valid_depth: 5.0
        )
        var ptr: OpaquePointer?
        let rc = aether_depth_filter_create(Int32(width), Int32(height), &config, &ptr)
        if rc == 0 {
            handle = ptr
        }
    }

    deinit {
        if let handle = handle {
            aether_depth_filter_destroy(handle)
        }
    }

    func reset() {
        if let handle = handle {
            aether_depth_filter_reset(handle)
        }
    }

    func run(
        depthIn: [Float],
        confidenceIn: [UInt8],
        angularVelocity: Float
    ) -> NativeDepthFilterOutput? {
        guard let handle = handle,
              depthIn.count == pixelCount,
              confidenceIn.count == pixelCount else {
            return nil
        }

        var depthOut = [Float](repeating: 0, count: pixelCount)
        var quality = aether_depth_filter_quality_t(
            noise_residual: 0,
            valid_ratio: 0,
            edge_risk_score: 0
        )

        let rc = depthIn.withUnsafeBufferPointer { depthPtr in
            confidenceIn.withUnsafeBufferPointer { confPtr in
                depthOut.withUnsafeMutableBufferPointer { outPtr in
                    aether_depth_filter_run(
                        handle,
                        depthPtr.baseAddress,
                        confPtr.baseAddress,
                        angularVelocity,
                        outPtr.baseAddress,
                        &quality
                    )
                }
            }
        }

        guard rc == 0 else {
            return nil
        }

        return NativeDepthFilterOutput(
            depth: depthOut,
            quality: NativeDepthFilterQuality(
                noiseResidual: quality.noise_residual,
                validRatio: quality.valid_ratio,
                edgeRiskScore: quality.edge_risk_score
            )
        )
    }
}
