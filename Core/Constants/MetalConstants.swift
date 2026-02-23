// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// MetalConstants.swift
// Aether3D
//
// Metal GPU pipeline constants for TSDF integration and rendering.
// Shared Metal pipeline configuration — single source of truth for ALL PRs.

import Foundation

/// Shared Metal pipeline configuration — single source of truth for ALL PRs.
public enum MetalConstants {

    // MARK: - Buffer Management

    /// Triple-buffer count for per-frame GPU data
    /// Standard Apple recommendation (WWDC "Modern Rendering with Metal").
    /// Absorbs CPU/GPU frame time variance without pipeline stalls.
    /// Used by: PR#6 TSDF integration, PR#7 rendering, future Metal PRs.
    public static let inflightBufferCount: Int = 3

    // MARK: - Compute Pipeline

    /// Default threadgroup width for compute kernels
    /// 8×8 = 64 threads = 2 SIMD-groups on Apple GPU.
    /// Optimal for high-register-pressure kernels (TSDF, image processing).
    /// Low-register kernels may prefer 16×16 or 32×1.
    public static let defaultThreadgroupSize: Int = 8

    // MARK: - SSOT Registration
    public static let allSpecs: [AnyConstantSpec] = [
        .fixedConstant(FixedConstantSpec(
            ssotId: "MetalConstants.inflightBufferCount",
            name: "Inflight Buffer Count",
            unit: .count,
            value: inflightBufferCount,
            documentation: "Triple-buffer count for all Metal per-frame data. Shared across all PRs."
        )),
        .fixedConstant(FixedConstantSpec(
            ssotId: "MetalConstants.defaultThreadgroupSize",
            name: "Default Threadgroup Size",
            unit: .count,
            value: defaultThreadgroupSize,
            documentation: "Default compute threadgroup edge size (8×8=64 threads)"
        ))
    ]
}
