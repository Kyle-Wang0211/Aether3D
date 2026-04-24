// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CaptureFrame.swift
// Aether3D
//
// Immutable per-frame snapshot broadcast by CaptureSession to every
// CaptureFrameObserver. Replaces the ad-hoc `ARFrame` + `pose + intrinsics`
// tuples that used to travel through `onXxx` closures on coordinators.
//
// THREADING CONTRACT
// ──────────────────
// A `CaptureFrame` is **not** guaranteed to outlive the synchronous body
// of `observer.receive(_:)`. If an observer needs to process the pixel
// buffer off-queue, it MUST retain the buffer explicitly (CVPixelBufferRef
// is CoreFoundation-refcounted, `var pb = frame.pixelBuffer` retains it
// for the life of `pb`). Not retaining and then using the buffer later is
// a use-after-free.

import Foundation

#if canImport(simd)
import simd
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

public struct CaptureFrame: @unchecked Sendable {

    /// ARFrame.timestamp — monotonically increasing seconds tied to the
    /// AR session clock. Same timescale as `CACurrentMediaTime()` but may
    /// start from a non-zero baseline.
    public let timestamp: TimeInterval

    /// 4×4 camera-to-world transform (ARKit convention: -Z is forward in
    /// camera space). Immutable copy; safe to hold indefinitely.
    #if canImport(simd)
    public let cameraTransform: simd_float4x4

    /// 3×3 camera intrinsic matrix (fx, 0, cx / 0, fy, cy / 0, 0, 1).
    /// Immutable copy; safe to hold indefinitely.
    public let cameraIntrinsics: simd_float3x3
    #endif

    /// True when `frame.camera.trackingState == .normal`. `.limited` or
    /// `.notAvailable` → false. Observers use this to gate ingestion.
    public let trackingOK: Bool

    /// The raw camera pixel buffer from `ARFrame.capturedImage`. Typically
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` on iOS 14+.
    /// Observers MUST retain this themselves if used beyond `receive()`.
    #if canImport(CoreVideo)
    public let pixelBuffer: CVPixelBuffer?
    #endif

    #if canImport(simd) && canImport(CoreVideo)
    public init(
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        trackingOK: Bool,
        pixelBuffer: CVPixelBuffer?
    ) {
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.trackingOK = trackingOK
        self.pixelBuffer = pixelBuffer
    }
    #endif
}
