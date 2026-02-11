// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MeshOutput.swift
// Aether3D
//
// Mesh extraction types and integration input/output types

import Foundation

/// Per-vertex data extracted by Marching Cubes.
/// 32 bytes per vertex (naturally aligned for GPU vertex buffer).
public struct MeshVertex: Sendable {
    public var position: TSDFFloat3    // World-space position (12 bytes)
    public var normal: TSDFFloat3      // SDF-gradient normal (12 bytes)
    public var alpha: Float            // Fade-in from UX-8: 0→1 (4 bytes)
    public var quality: Float          // Block convergence: weight/maxWeight 0→1 (4 bytes)

    public init(position: TSDFFloat3, normal: TSDFFloat3, alpha: Float, quality: Float) {
        self.position = position; self.normal = normal
        self.alpha = alpha; self.quality = quality
    }
}

/// Single triangle — 3 vertex indices into MeshOutput.vertices array.
public struct MeshTriangle: Sendable {
    public var i0: UInt32  // Index into vertices array
    public var i1: UInt32
    public var i2: UInt32

    public init(_ i0: UInt32, _ i1: UInt32, _ i2: UInt32) {
        self.i0 = i0; self.i1 = i1; self.i2 = i2
    }
}

/// Complete mesh output from one extraction cycle.
/// Double-buffered: extraction writes to back, renderer reads front, swap atomically.
public struct MeshOutput: Sendable {
    public var vertices: ContiguousArray<MeshVertex>
    public var triangles: ContiguousArray<MeshTriangle>
    public var triangleCount: Int { triangles.count }
    public var vertexCount: Int { vertices.count }

    /// Metadata for consumers
    public var extractionTimestamp: TimeInterval = 0
    public var dirtyBlocksRemaining: Int = 0

    public init() {
        vertices = ContiguousArray()
        triangles = ContiguousArray()
    }

    /// Check degenerate triangle by vertex positions (for rejection)
    public func isDegenerate(triangle t: MeshTriangle) -> Bool {
        let v0 = vertices[Int(t.i0)].position
        let v1 = vertices[Int(t.i1)].position
        let v2 = vertices[Int(t.i2)].position
        let area = cross(v1 - v0, v2 - v0).length() * 0.5
        if area < TSDFConstants.minTriangleArea { return true }
        let edges = [(v1 - v0).length(), (v2 - v1).length(), (v0 - v2).length()]
        let maxEdge = edges.max()!
        let minEdge = max(edges.min()!, 1e-10)
        return maxEdge / minEdge > TSDFConstants.maxTriangleAspectRatio
    }
}

/// Platform-agnostic integration input — constructed by App/ layer from SceneDepthFrame
public struct IntegrationInput: Sendable {
    public let timestamp: TimeInterval
    public let intrinsics: TSDFMatrix3x3      // Camera intrinsics (fx,fy,cx,cy)
    public let cameraToWorld: TSDFMatrix4x4   // Camera extrinsics (pose)
    public let depthWidth: Int                 // 256 (for valid pixel ratio calculation)
    public let depthHeight: Int                // 192
    public let trackingState: Int              // 0=notAvailable, 1=limited, 2=normal
}

/// Integration result for telemetry and guardrail feedback.
public enum IntegrationResult {
    case success(IntegrationStats)
    case skipped(SkipReason)

    public struct IntegrationStats {
        public let blocksUpdated: Int
        public let blocksAllocated: Int
        public let voxelsUpdated: Int
        public let gpuTimeMs: Double
        public let totalTimeMs: Double
    }

    public enum SkipReason {
        case trackingLost
        case poseTeleport          // Guardrail #10: position delta > maxPoseDeltaPerFrame
        case poseJitter            // UX-7: camera nearly still, skip to preserve quality
        case thermalThrottle       // Guardrail #2: AIMD skip
        case frameTimeout          // Guardrail #3: integration > integrationTimeoutMs
        case lowValidPixels        // Guardrail #15: valid pixel ratio < minValidPixelRatio
        case memoryPressure        // Guardrail #1: memory warning
    }
}
