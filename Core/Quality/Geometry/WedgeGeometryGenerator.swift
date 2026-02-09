//
// WedgeGeometryGenerator.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Wedge Geometry Generator
// Pure algorithm — Foundation + simd only, NO Metal import
//

import Foundation
#if canImport(simd)
import simd
#endif

public struct WedgeVertexData {
    public let vertices: [WedgeVertexCPU]
    public let indices: [UInt32]
    public let triangleCount: Int
    
    public init(vertices: [WedgeVertexCPU], indices: [UInt32], triangleCount: Int) {
        self.vertices = vertices
        self.indices = indices
        self.triangleCount = triangleCount
    }
}

public struct WedgeVertexCPU {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var metallic: Float
    public var roughness: Float
    public var display: Float
    public var thickness: Float
    public var triangleId: UInt32
    
    public init(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        metallic: Float,
        roughness: Float,
        display: Float,
        thickness: Float,
        triangleId: UInt32
    ) {
        self.position = position
        self.normal = normal
        self.metallic = metallic
        self.roughness = roughness
        self.display = display
        self.thickness = thickness
        self.triangleId = triangleId
    }
}

public final class WedgeGeometryGenerator {

    public enum LODLevel: Int, CaseIterable {
        case full = 0    // 44 tri/prism (2-segment bevel)
        case medium = 1  // 26 tri/prism (1-segment bevel)
        case low = 2     // 8 tri/prism (sharp edges)
        case flat = 3    // 2 tri/prism (no extrusion)
    }

    public init() {}

    /// Generate wedge geometry from triangles
    /// Phase 2: Implements LOD0-LOD3 with wedge extrusion and bevels
    public func generate(
        triangles: [ScanTriangle],
        displayValues: [String: Double],
        lod: LODLevel
    ) -> WedgeVertexData {
        var vertices: [WedgeVertexCPU] = []
        var indices: [UInt32] = []
        var vertexIndex: UInt32 = 0
        
        // Calculate median area for thickness normalization
        let areas = triangles.map { $0.areaSqM }
        let sortedAreas = areas.sorted()
        let medianArea = sortedAreas.isEmpty ? 1.0 : sortedAreas[sortedAreas.count / 2]
        
        for (triIndex, triangle) in triangles.enumerated() {
            let display = displayValues[triangle.patchId] ?? 0.0
            let clampedDisplay = min(max(display, 0.0), 1.0)
            
            // Calculate metallic and roughness based on display
            let metallic: Float
            let roughness: Float
            if clampedDisplay >= ScanGuidanceConstants.s3ToS4Threshold {
                metallic = Float(ScanGuidanceConstants.metallicBase + ScanGuidanceConstants.metallicS3Bonus)
                roughness = Float(max(0.0, ScanGuidanceConstants.roughnessBase - ScanGuidanceConstants.roughnessS3Reduction))
            } else {
                metallic = Float(ScanGuidanceConstants.metallicBase)
                roughness = Float(ScanGuidanceConstants.roughnessBase)
            }
            
            // Calculate thickness
            let thickness = self.thickness(
                display: clampedDisplay,
                areaSqM: triangle.areaSqM,
                medianArea: medianArea
            )
            
            let (v0, v1, v2) = triangle.vertices
            let normal = triangle.normal
            
            switch lod {
            case .flat:
                // LOD3: Flat, no extrusion (2 triangles per input triangle)
                generateFlatWedge(
                    v0: v0, v1: v1, v2: v2,
                    normal: normal,
                    metallic: metallic,
                    roughness: roughness,
                    display: Float(clampedDisplay),
                    thickness: thickness,
                    triangleId: UInt32(triIndex),
                    vertices: &vertices,
                    indices: &indices,
                    vertexIndex: &vertexIndex
                )
                
            case .low:
                // LOD2: Sharp edges, 8 triangles per prism
                generateLowLODWedge(
                    v0: v0, v1: v1, v2: v2,
                    normal: normal,
                    thickness: thickness,
                    metallic: metallic,
                    roughness: roughness,
                    display: Float(clampedDisplay),
                    triangleId: UInt32(triIndex),
                    vertices: &vertices,
                    indices: &indices,
                    vertexIndex: &vertexIndex
                )
                
            case .medium:
                // LOD1: 1-segment bevel, 26 triangles per prism
                generateMediumLODWedge(
                    v0: v0, v1: v1, v2: v2,
                    normal: normal,
                    thickness: thickness,
                    metallic: metallic,
                    roughness: roughness,
                    display: Float(clampedDisplay),
                    triangleId: UInt32(triIndex),
                    vertices: &vertices,
                    indices: &indices,
                    vertexIndex: &vertexIndex
                )
                
            case .full:
                // LOD0: 2-segment bevel, 44 triangles per prism
                generateFullLODWedge(
                    v0: v0, v1: v1, v2: v2,
                    normal: normal,
                    thickness: thickness,
                    metallic: metallic,
                    roughness: roughness,
                    display: Float(clampedDisplay),
                    triangleId: UInt32(triIndex),
                    vertices: &vertices,
                    indices: &indices,
                    vertexIndex: &vertexIndex
                )
            }
        }
        
        return WedgeVertexData(
            vertices: vertices,
            indices: indices,
            triangleCount: triangles.count
        )
    }
    
    // MARK: - LOD Generation Helpers
    
    private func generateFlatWedge(
        v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
        normal: SIMD3<Float>,
        metallic: Float,
        roughness: Float,
        display: Float,
        thickness: Float,
        triangleId: UInt32,
        vertices: inout [WedgeVertexCPU],
        indices: inout [UInt32],
        vertexIndex: inout UInt32
    ) {
        // Flat: just the original triangle (no extrusion)
        let baseIndex = vertexIndex
        
        vertices.append(WedgeVertexCPU(
            position: v0,
            normal: normal,
            metallic: metallic,
            roughness: roughness,
            display: display,
            thickness: thickness,
            triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: v1,
            normal: normal,
            metallic: metallic,
            roughness: roughness,
            display: display,
            thickness: thickness,
            triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: v2,
            normal: normal,
            metallic: metallic,
            roughness: roughness,
            display: display,
            thickness: thickness,
            triangleId: triangleId
        ))
        
        indices.append(baseIndex)
        indices.append(baseIndex + 1)
        indices.append(baseIndex + 2)
        
        vertexIndex += 3
    }
    
    private func generateLowLODWedge(
        v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
        normal: SIMD3<Float>,
        thickness: Float,
        metallic: Float,
        roughness: Float,
        display: Float,
        triangleId: UInt32,
        vertices: inout [WedgeVertexCPU],
        indices: inout [UInt32],
        vertexIndex: inout UInt32
    ) {
        // LOD2: Sharp edges, simple extrusion without bevels
        // Top face (original triangle)
        let top0 = v0
        let top1 = v1
        let top2 = v2
        
        // Bottom face (extruded downward along normal)
        let bottom0 = v0 - normal * thickness
        let bottom1 = v1 - normal * thickness
        let bottom2 = v2 - normal * thickness
        
        let baseIndex = vertexIndex
        
        // Top face vertices
        vertices.append(WedgeVertexCPU(
            position: top0, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: top1, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: top2, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        
        // Bottom face vertices
        vertices.append(WedgeVertexCPU(
            position: bottom0, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: bottom1, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: bottom2, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        
        // Top face (counter-clockwise)
        indices.append(baseIndex)
        indices.append(baseIndex + 1)
        indices.append(baseIndex + 2)
        
        // Bottom face (clockwise)
        indices.append(baseIndex + 5)
        indices.append(baseIndex + 4)
        indices.append(baseIndex + 3)
        
        // Side faces (3 edges)
        // Edge 0-1
        indices.append(baseIndex)      // top0
        indices.append(baseIndex + 3)  // bottom0
        indices.append(baseIndex + 1)  // top1
        
        indices.append(baseIndex + 1)  // top1
        indices.append(baseIndex + 3)  // bottom0
        indices.append(baseIndex + 4)  // bottom1
        

        // Edge 1-2
        indices.append(baseIndex + 1)  // top1
        indices.append(baseIndex + 4)  // bottom1
        indices.append(baseIndex + 2)  // top2
        
        indices.append(baseIndex + 2)  // top2
        indices.append(baseIndex + 4)  // bottom1
        indices.append(baseIndex + 5)  // bottom2
        
        // Edge 2-0
        indices.append(baseIndex + 2)  // top2
        indices.append(baseIndex + 5)  // bottom2
        indices.append(baseIndex)      // top0
        
        indices.append(baseIndex)      // top0
        indices.append(baseIndex + 5)  // bottom2
        indices.append(baseIndex + 3)  // bottom0
        
        vertexIndex += 6
    }
    
    private func generateMediumLODWedge(
        v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
        normal: SIMD3<Float>,
        thickness: Float,
        metallic: Float,
        roughness: Float,
        display: Float,
        triangleId: UInt32,
        vertices: inout [WedgeVertexCPU],
        indices: inout [UInt32],
        vertexIndex: inout UInt32
    ) {
        // LOD1: 1-segment bevel, 26 triangles per prism
        let bevelSegments = ScanGuidanceConstants.bevelSegmentsLOD1
        let bevelRadius = Float(ScanGuidanceConstants.bevelRadiusRatio) * thickness
        
        let baseIndex = vertexIndex
        
        // Top face (original triangle)
        let top0 = v0
        let top1 = v1
        let top2 = v2
        
        // Bottom face (extruded)
        let bottom0 = v0 - normal * thickness
        let bottom1 = v1 - normal * thickness
        let bottom2 = v2 - normal * thickness
        
        // Bevel vertices: offset inward from edges
        let bevelOffset = normal * bevelRadius
        
        // Top bevel vertices (offset inward from top face)
        let topBevel0 = top0 - bevelOffset
        let topBevel1 = top1 - bevelOffset
        let topBevel2 = top2 - bevelOffset
        
        // Bottom bevel vertices (offset inward from bottom face)
        let bottomBevel0 = bottom0 + bevelOffset
        let bottomBevel1 = bottom1 + bevelOffset
        let bottomBevel2 = bottom2 + bevelOffset
        
        // Top face (center triangle)
        vertices.append(WedgeVertexCPU(
            position: topBevel0, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: topBevel1, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: topBevel2, normal: normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        
        // Top bevel segments (3 edges × 1 segment = 3 quads = 6 triangles)
        let topBevelNormals = bevelNormals(topFaceNormal: normal, sideFaceNormal: normalize(cross(normal, top1 - top0)), segments: bevelSegments)
        // Edge 0-1 bevel
        vertices.append(WedgeVertexCPU(position: top0, normal: topBevelNormals[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel0, normal: topBevelNormals[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: top1, normal: topBevelNormals[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel1, normal: topBevelNormals[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 1-2 bevel
        let topBevelNormals12 = bevelNormals(topFaceNormal: normal, sideFaceNormal: normalize(cross(normal, top2 - top1)), segments: bevelSegments)
        vertices.append(WedgeVertexCPU(position: top1, normal: topBevelNormals12[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel1, normal: topBevelNormals12[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: top2, normal: topBevelNormals12[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel2, normal: topBevelNormals12[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 2-0 bevel
        let topBevelNormals20 = bevelNormals(topFaceNormal: normal, sideFaceNormal: normalize(cross(normal, top0 - top2)), segments: bevelSegments)
        vertices.append(WedgeVertexCPU(position: top2, normal: topBevelNormals20[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel2, normal: topBevelNormals20[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: top0, normal: topBevelNormals20[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel0, normal: topBevelNormals20[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Bottom face (center triangle)
        vertices.append(WedgeVertexCPU(
            position: bottomBevel0, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: bottomBevel1, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        vertices.append(WedgeVertexCPU(
            position: bottomBevel2, normal: -normal, metallic: metallic, roughness: roughness,
            display: display, thickness: thickness, triangleId: triangleId
        ))
        
        // Bottom bevel segments (3 edges × 1 segment = 3 quads = 6 triangles)
        let bottomBevelNormals = bevelNormals(topFaceNormal: -normal, sideFaceNormal: normalize(cross(-normal, bottom1 - bottom0)), segments: bevelSegments)
        // Edge 0-1 bevel
        vertices.append(WedgeVertexCPU(position: bottom0, normal: bottomBevelNormals[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel0, normal: bottomBevelNormals[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottom1, normal: bottomBevelNormals[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel1, normal: bottomBevelNormals[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 1-2 bevel
        let bottomBevelNormals12 = bevelNormals(topFaceNormal: -normal, sideFaceNormal: normalize(cross(-normal, bottom2 - bottom1)), segments: bevelSegments)
        vertices.append(WedgeVertexCPU(position: bottom1, normal: bottomBevelNormals12[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel1, normal: bottomBevelNormals12[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottom2, normal: bottomBevelNormals12[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel2, normal: bottomBevelNormals12[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 2-0 bevel
        let bottomBevelNormals20 = bevelNormals(topFaceNormal: -normal, sideFaceNormal: normalize(cross(-normal, bottom0 - bottom2)), segments: bevelSegments)
        vertices.append(WedgeVertexCPU(position: bottom2, normal: bottomBevelNormals20[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel2, normal: bottomBevelNormals20[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottom0, normal: bottomBevelNormals20[0], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel0, normal: bottomBevelNormals20[1], metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Side faces (3 edges connecting top and bottom bevels)
        // Edge 0-1 side
        let sideNormal01 = normalize(cross(normal, top1 - top0))
        vertices.append(WedgeVertexCPU(position: topBevel0, normal: sideNormal01, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel0, normal: sideNormal01, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel1, normal: sideNormal01, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel1, normal: sideNormal01, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 1-2 side
        let sideNormal12 = normalize(cross(normal, top2 - top1))
        vertices.append(WedgeVertexCPU(position: topBevel1, normal: sideNormal12, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel1, normal: sideNormal12, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel2, normal: sideNormal12, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel2, normal: sideNormal12, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Edge 2-0 side
        let sideNormal20 = normalize(cross(normal, top0 - top2))
        vertices.append(WedgeVertexCPU(position: topBevel2, normal: sideNormal20, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel2, normal: sideNormal20, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: topBevel0, normal: sideNormal20, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        vertices.append(WedgeVertexCPU(position: bottomBevel0, normal: sideNormal20, metallic: metallic, roughness: roughness, display: display, thickness: thickness, triangleId: triangleId))
        
        // Indices: Top face (1 triangle)
        indices.append(baseIndex)
        indices.append(baseIndex + 1)
        indices.append(baseIndex + 2)
        
        // Top bevel quads (3 edges × 1 segment × 2 triangles = 6 triangles)
        var idx = baseIndex + 3
        for _ in 0..<3 {
            indices.append(idx)
            indices.append(idx + 1)
            indices.append(idx + 2)
            indices.append(idx + 2)
            indices.append(idx + 1)
            indices.append(idx + 3)
            idx += 4
        }
        
        // Bottom face (1 triangle)
        indices.append(baseIndex + 15)
        indices.append(baseIndex + 16)
        indices.append(baseIndex + 17)
        
        // Bottom bevel quads (3 edges × 1 segment × 2 triangles = 6 triangles)
        idx = baseIndex + 18
        for _ in 0..<3 {
            indices.append(idx)
            indices.append(idx + 2)
            indices.append(idx + 1)
            indices.append(idx + 1)
            indices.append(idx + 2)
            indices.append(idx + 3)
            idx += 4
        }
        
        // Side faces (3 edges × 1 segment × 2 triangles = 6 triangles)
        idx = baseIndex + 30
        for _ in 0..<3 {
            indices.append(idx)
            indices.append(idx + 1)
            indices.append(idx + 2)
            indices.append(idx + 2)
            indices.append(idx + 1)
            indices.append(idx + 3)
            idx += 4
        }
        
        vertexIndex += 42  // 3 + 12 + 3 + 12 + 12 = 42 vertices for LOD1
    }
    
    private func generateFullLODWedge(
        v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
        normal: SIMD3<Float>,
        thickness: Float,
        metallic: Float,
        roughness: Float,
        display: Float,
        triangleId: UInt32,
        vertices: inout [WedgeVertexCPU],
        indices: inout [UInt32],
        vertexIndex: inout UInt32
    ) {
        // LOD0: 2-segment bevel (simplified - uses low LOD for now)
        // Phase 2: Simplified implementation, full bevel in Phase 3
        generateLowLODWedge(
            v0: v0, v1: v1, v2: v2,
            normal: normal,
            thickness: thickness,
            metallic: metallic,
            roughness: roughness,
            display: display,
            triangleId: triangleId,
            vertices: &vertices,
            indices: &indices,
            vertexIndex: &vertexIndex
        )
    }

    /// Calculate wedge thickness based on display value and area
    public func thickness(
        display: Double,
        areaSqM: Float,
        medianArea: Float
    ) -> Float {
        let base = Float(ScanGuidanceConstants.wedgeBaseThicknessM)
        let minT = Float(ScanGuidanceConstants.wedgeMinThicknessM)
        let exponent = Float(ScanGuidanceConstants.thicknessDecayExponent)
        let decayFactor = pow(1.0 - Float(display), exponent)
        let areaFactor = sqrt(areaSqM / max(medianArea, 1e-6))
        let clampedAreaFactor = min(max(areaFactor, 0.5), 2.0)
        return max(minT, base * decayFactor * clampedAreaFactor)
    }

    /// Generate bevel normals for smooth edge transitions
    public func bevelNormals(
        topFaceNormal: SIMD3<Float>,
        sideFaceNormal: SIMD3<Float>,
        segments: Int
    ) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments)
            let mixed = topFaceNormal * (1.0 - t) + sideFaceNormal * t
            let len = (mixed.x * mixed.x + mixed.y * mixed.y + mixed.z * mixed.z).squareRoot()
            normals.append(len > 0 ? mixed / len : mixed)
        }
        return normals
    }
}
