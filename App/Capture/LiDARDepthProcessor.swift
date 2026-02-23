// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// LiDARDepthProcessor.swift
// Aether3D
//
// LiDAR Depth Processor - LiDAR depth processing for depth-enhanced capture
// 符合 PR4-02: LiDAR + RGB Fusion
//

import Foundation
import AVFoundation
import CoreVideo
#if canImport(ARKit)
import ARKit
#endif

/// LiDAR Depth Processor
///
/// Processes LiDAR depth data synchronized with RGB frames.
/// 符合 PR4-02: LiDAR + RGB Fusion
///
/// Two input paths:
///   1. processSceneDepth(frame:) — NEW: accepts ARFrame.sceneDepth CVPixelBuffer directly
///      Used by PR#6 TSDF fusion pipeline (zero-copy, no Data conversion overhead)
///   2. processDepthFrame(depthMap:...) — LEGACY: accepts serialized Data
///      Used by PR#4 recording pipeline for offline storage
public actor LiDARDepthProcessor {

    // MARK: - State

    private var depthFrames: [LiDARDepthFrame] = []
    private var isProcessing: Bool = false

    /// Most recent scene depth for real-time consumers (PR#6 TSDF)
    /// Not stored in depthFrames array — only latest frame matters for fusion
    private var _latestSceneDepth: SceneDepthFrame?

    // MARK: - Real-time Depth Input (PR#6 TSDF dependency)

    #if canImport(ARKit)
    /// Extract and store scene depth from an ARFrame
    ///
    /// Called every frame (~60fps) from ARSessionDelegate.
    /// Zero-copy: retains CVPixelBuffer reference, no Data conversion.
    ///
    /// - Parameter frame: Current ARFrame with sceneDepth attached
    public func processSceneDepth(frame: ARFrame) {
        guard let sceneDepth = frame.sceneDepth else { return }

        let depthMap = sceneDepth.depthMap  // CVPixelBuffer, Float32, 256×192
        let confidenceMap = sceneDepth.confidenceMap  // CVPixelBuffer, UInt8, 256×192

        _latestSceneDepth = SceneDepthFrame(
            timestamp: frame.timestamp,
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            camera: frame.camera
        )
    }
    #endif

    /// Get the most recent scene depth frame (for TSDF fusion)
    ///
    /// Returns nil if no LiDAR depth is available (non-LiDAR device or not yet received)
    public func latestSceneDepth() -> SceneDepthFrame? {
        return _latestSceneDepth
    }

    // MARK: - Legacy Serialized Depth Input (PR#4 recording)

    /// Process depth frame synchronized with RGB frame (legacy Data path)
    ///
    /// 符合 PR4-02: LiDAR depth synchronized with RGB frames
    /// - Parameters:
    ///   - depthMap: Depth map data (serialized)
    ///   - confidenceMap: Confidence map (optional, serialized)
    ///   - timestamp: Frame timestamp
    public func processDepthFrame(depthMap: Data, confidenceMap: Data?, timestamp: Date) {
        let frame = LiDARDepthFrame(
            timestamp: timestamp,
            depthMap: depthMap,
            confidenceMap: confidenceMap
        )

        depthFrames.append(frame)
    }

    /// Get depth frames
    ///
    /// - Returns: Array of depth frames
    public func getDepthFrames() -> [LiDARDepthFrame] {
        return depthFrames
    }

    /// Clear depth frames
    public func clearFrames() {
        depthFrames.removeAll()
        _latestSceneDepth = nil
    }

    /// Get depth frame for timestamp
    ///
    /// - Parameter timestamp: Frame timestamp
    /// - Returns: Depth frame if found
    public func getDepthFrame(for timestamp: Date) -> LiDARDepthFrame? {
        // Find closest depth frame to timestamp
        let tolerance: TimeInterval = 0.033 // ~30fps tolerance

        return depthFrames.first { frame in
            abs(frame.timestamp.timeIntervalSince(timestamp)) <= tolerance
        }
    }
}

// MARK: - Scene Depth Frame (real-time, zero-copy)

/// Real-time depth frame from ARKit sceneDepth — retains CVPixelBuffer directly
///
/// Unlike LiDARDepthFrame (which stores serialized Data for recording),
/// this struct holds CVPixelBuffer references for zero-copy GPU access.
/// PR#6 TSDF fusion reads depthMap directly via CVPixelBufferGetBaseAddress.
public struct SceneDepthFrame: @unchecked Sendable {
    /// ARFrame.timestamp (mach_absolute_time based, monotonic)
    public let timestamp: TimeInterval

    /// Depth map: CVPixelBuffer, kCVPixelFormatType_DepthFloat32, 256×192
    /// Each pixel = distance in meters from camera plane
    public let depthMap: CVPixelBuffer

    /// Confidence map: CVPixelBuffer, kCVPixelFormatType_OneComponent8, 256×192
    /// Values: 0 (low), 1 (medium), 2 (high)
    public let confidenceMap: CVPixelBuffer?

    #if canImport(ARKit)
    /// Camera intrinsics + extrinsics for this frame
    /// Needed by TSDF to project depth pixels → world coordinates
    public let camera: ARCamera
    #endif
}
