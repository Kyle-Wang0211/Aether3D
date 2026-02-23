//
// MeshExtractor.swift
// Aether3D
//
// PR#7 Scan Guidance UI — ARKit Mesh Extractor
// Bridges ARMeshAnchor geometry → [ScanTriangle] for Core/ algorithms
// Apple-platform only (ARKit)
//

import Foundation

#if canImport(ARKit)
import ARKit
import simd
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Extracts ScanTriangle array from ARMeshAnchor geometry
///
/// This is the critical bridge between ARKit's mesh data and Core/ algorithms.
/// Each ARMeshAnchor contains geometry with vertices, face indices, and normals.
/// This extractor transforms them to world space and produces ScanTriangle structs
/// that WedgeGeometryGenerator, FlipAnimationController, RipplePropagationEngine,
/// and AdaptiveBorderCalculator can consume.
///
/// Safety:
///   - Bounds checking on ALL buffer accesses
///   - Degenerate triangle rejection (area < 1e-8)
///   - Performance cap: maxTrianglesPerExtraction = 10000
///   - Stable patchId via core spatial quantization (prevents flicker)
public struct MeshExtractor {

    /// Maximum triangles to extract per frame (performance guard)
    private static let maxTrianglesPerExtraction: Int = 10000
    /// Patch identity quantization cell size (meters).
    private static let patchIdentityCellSizeM: Double = 0.02

    public init() {}

    /// Extract triangles from ARMeshAnchors
    ///
    /// - Parameters:
    ///   - anchors: Array of ARMeshAnchor from ARFrame
    ///   - worldTransform: Transform to apply to vertices (default: identity)
    /// - Returns: Array of ScanTriangle for Core/ consumption
    public func extract(
        from anchors: [ARMeshAnchor],
        worldTransform: simd_float4x4 = matrix_identity_float4x4
    ) -> [ScanTriangle] {
        var triangles: [ScanTriangle] = []
        triangles.reserveCapacity(2000)  // Typical LiDAR mesh size

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            let faceCount = geometry.faces.count

            // Safety: Skip if geometry is empty
            guard vertexCount >= 3, faceCount >= 1 else { continue }

            // Get vertex buffer
            let vertexBuffer = geometry.vertices
            let vertexStride = vertexBuffer.stride
            let vertexData = vertexBuffer.buffer.contents()

            // Get face buffer (UInt32 indices, 3 per face for triangles)
            let faceBuffer = geometry.faces
            let faceStride = faceBuffer.bytesPerIndex
            let faceData = faceBuffer.buffer.contents()
            let indicesPerFace = faceBuffer.indexCountPerPrimitive

            guard indicesPerFace == 3 else { continue }  // Only triangles

            // Get normal buffer if available
            let normalBuffer = geometry.normals
            let normalStride = normalBuffer.stride
            let normalData = normalBuffer.buffer.contents()

            // Extract transform
            let anchorTransform = anchor.transform
            let combinedTransform = worldTransform * anchorTransform

            for faceIndex in 0..<faceCount {
                // Performance guard
                if triangles.count >= Self.maxTrianglesPerExtraction { break }

                // Read face indices
                let faceOffset = faceIndex * indicesPerFace * faceStride
                let i0 = Int(faceData.load(fromByteOffset: faceOffset, as: UInt32.self))
                let i1 = Int(faceData.load(fromByteOffset: faceOffset + faceStride, as: UInt32.self))
                let i2 = Int(faceData.load(fromByteOffset: faceOffset + 2 * faceStride, as: UInt32.self))

                // Safety bounds check
                guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }

                // Read vertices
                let v0Local = vertexData.load(fromByteOffset: i0 * vertexStride, as: SIMD3<Float>.self)
                let v1Local = vertexData.load(fromByteOffset: i1 * vertexStride, as: SIMD3<Float>.self)
                let v2Local = vertexData.load(fromByteOffset: i2 * vertexStride, as: SIMD3<Float>.self)

                // Transform to world space
                let v0 = (combinedTransform * SIMD4<Float>(v0Local, 1.0)).xyz
                let v1 = (combinedTransform * SIMD4<Float>(v1Local, 1.0)).xyz
                let v2 = (combinedTransform * SIMD4<Float>(v2Local, 1.0)).xyz

                // Read normal
                let n0 = normalData.load(fromByteOffset: i0 * normalStride, as: SIMD3<Float>.self)
                let transformedNormal = simd_normalize(
                    (combinedTransform * SIMD4<Float>(n0, 0.0)).xyz
                )

                // Calculate area (half cross product magnitude)
                let edge1 = v1 - v0
                let edge2 = v2 - v0
                let crossProduct = simd_cross(edge1, edge2)
                let area = simd_length(crossProduct) * 0.5

                // Skip degenerate triangles
                guard area > 1e-8 else { continue }

                // Generate stable patch identity from centroid position.
                let centroid = (v0 + v1 + v2) / 3.0
                let identity = Self.stablePatchIdentity(centroid: centroid)

                triangles.append(ScanTriangle(
                    patchId: identity.patchId,
                    vertices: (v0, v1, v2),
                    normal: transformedNormal,
                    areaSqM: area,
                    blockIndex: identity.blockIndex
                ))
            }
        }

        return triangles
    }

    /// Generate stable patch identity from centroid position.
    ///
    /// Preferred path: C++ core quantizer (`aether_spatial_quantize_world_position`).
    /// Fallback path: deterministic 2cm rounding if native bridge is unavailable.
    private static func stablePatchIdentity(
        centroid: SIMD3<Float>
    ) -> (patchId: String, blockIndex: (Int32, Int32, Int32)) {
        #if canImport(CAetherNativeBridge)
        var q = aether_quantized_position_t()
        let rc = aether_spatial_quantize_world_position(
            Double(centroid.x),
            Double(centroid.y),
            Double(centroid.z),
            0.0,
            0.0,
            0.0,
            patchIdentityCellSizeM,
            &q
        )
        if rc == 0 {
            let patchId = "\(q.x)_\(q.y)_\(q.z)"
            return (patchId, (q.x, q.y, q.z))
        }
        #endif

        let scale = 1.0 / patchIdentityCellSizeM
        let qx = Int32((Double(centroid.x) * scale).rounded())
        let qy = Int32((Double(centroid.y) * scale).rounded())
        let qz = Int32((Double(centroid.z) * scale).rounded())
        let patchId = "\(qx)_\(qy)_\(qz)"
        return (patchId, (qx, qy, qz))
    }
}

// MARK: - SIMD4 → xyz Helper

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

#endif
