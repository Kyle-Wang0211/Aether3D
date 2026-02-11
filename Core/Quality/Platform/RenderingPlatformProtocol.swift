//
// RenderingPlatformProtocol.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Cross-Platform Rendering Protocol
// Pure protocol — Foundation only, compiles on macOS + Linux
// Phase 6: Cross-platform interface
//
// Note: simd_float4x4 is Apple-only. We use a 16-element Float array
// as the cross-platform transform representation.
//

import Foundation

/// Cross-platform rendering interface (for Android/HarmonyOS future ports)
/// This protocol allows platform-specific implementations while keeping Core/ code platform-agnostic
public protocol RenderingPlatformProtocol {

    /// Render wedge geometry
    /// - Parameters:
    ///   - vertices: Vertex data
    ///   - indices: Index data
    ///   - transform: Camera transform matrix (column-major 4×4, 16 floats)
    func renderWedges(
        vertices: [WedgeVertexCPU],
        indices: [UInt32],
        transform: [Float]
    )

    /// Render border strokes
    /// - Parameters:
    ///   - vertices: Vertex data
    ///   - borderWidths: Per-triangle border widths
    func renderBorders(
        vertices: [WedgeVertexCPU],
        borderWidths: [Float]
    )

    /// Apply lighting
    /// - Parameters:
    ///   - lightDirection: Primary light direction (3 floats: x, y, z)
    ///   - lightIntensity: Light intensity
    ///   - shCoefficients: Spherical harmonics coefficients (9 × 3 = 27 floats)
    func applyLighting(
        lightDirection: (Float, Float, Float),
        lightIntensity: Float,
        shCoefficients: [Float]
    )
}

/// Default implementation (no-op for platforms without rendering)
public struct DefaultRenderingPlatform: RenderingPlatformProtocol {
    public init() {}

    public func renderWedges(
        vertices: [WedgeVertexCPU],
        indices: [UInt32],
        transform: [Float]
    ) {
        // No-op: platform doesn't support rendering
    }

    public func renderBorders(
        vertices: [WedgeVertexCPU],
        borderWidths: [Float]
    ) {
        // No-op: platform doesn't support rendering
    }

    public func applyLighting(
        lightDirection: (Float, Float, Float),
        lightIntensity: Float,
        shCoefficients: [Float]
    ) {
        // No-op: platform doesn't support rendering
    }
}
