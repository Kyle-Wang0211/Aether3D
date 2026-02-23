// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFIntegrationBackend.swift
// Aether3D
//
// Abstraction over depth-to-voxel integration computation.

/// Abstraction over depth-to-voxel integration computation.
///
/// TSDFVolume (Core/ actor) handles: gates, AIMD thermal, ring buffer, keyframe marking.
/// Backend handles: actual depth pixel processing and voxel SDF/weight updates.
///
/// Three implementations:
///   1. CPUIntegrationBackend (Core/) — pure Swift, pixel-by-pixel. For tests + Mac Catalyst fallback.
///   2. MetalIntegrationBackend (App/) — GPU compute shaders. Production path on iOS.
///   3. MockIntegrationBackend (Tests/) — returns preset results. For unit testing gates/AIMD.
public protocol TSDFIntegrationBackend: Sendable {
    /// Process one frame's depth data into the voxel volume.
    ///
    /// - Parameters:
    ///   - input: Camera matrices and metadata (from TSDFVolume gate chain)
    ///   - depthData: Pixel-level depth and confidence access
    ///   - volume: Read/write access to voxel block storage
    ///   - activeBlocks: (BlockIndex, poolIndex) pairs to update (from TSDFVolume allocation)
    /// - Returns: Per-frame statistics for AIMD thermal feedback
    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]
    ) async -> IntegrationResult.IntegrationStats
}

/// Read/write access to voxel block storage.
/// Abstracts over ManagedVoxelStorage — both CPU and GPU backends use this.
public protocol VoxelBlockAccessor: Sendable {
    func readBlock(at poolIndex: Int) -> VoxelBlock
    func writeBlock(at poolIndex: Int, _ block: VoxelBlock)
    /// Stable base address for Metal makeBuffer(bytesNoCopy:).
    /// CPU backend ignores this. GPU backend uses it for zero-copy binding.
    var baseAddress: UnsafeMutableRawPointer { get }
    var byteCount: Int { get }
    var capacity: Int { get }
}

/// Depth pixel data access — abstraction over CVPixelBuffer (App/) and [Float] (Core/Tests/).
public protocol DepthDataProvider: Sendable {
    var width: Int { get }     // 256
    var height: Int { get }    // 192
    func depthAt(x: Int, y: Int) -> Float       // Meters, NaN if invalid
    func confidenceAt(x: Int, y: Int) -> UInt8   // 0=low, 1=mid, 2=high
}

/// Concrete implementation for CPU backend and tests.
/// App/ layer constructs this by copying CVPixelBuffer contents.
public struct ArrayDepthData: DepthDataProvider, Sendable {
    public let width: Int
    public let height: Int
    private let depths: [Float]       // row-major, width × height
    private let confidences: [UInt8]  // row-major, width × height

    public init(width: Int, height: Int, depths: [Float], confidences: [UInt8]) {
        precondition(depths.count == width * height)
        precondition(confidences.count == width * height)
        self.width = width; self.height = height
        self.depths = depths; self.confidences = confidences
    }

    public func depthAt(x: Int, y: Int) -> Float { depths[y * width + x] }
    public func confidenceAt(x: Int, y: Int) -> UInt8 { confidences[y * width + x] }
}
