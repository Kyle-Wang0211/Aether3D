//
// WedgeGeometryGenerator.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Wedge Geometry Generator
// Geometry and persistent style state are delegated to core C++ runtime.
//

import Foundation
#if canImport(simd)
import simd
#endif
import CAetherNativeBridge

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
        case full = 0
        case medium = 1
        case low = 2
        case flat = 3
    }

    private let nativeStyleRuntime: OpaquePointer?
    private var lastResolvedStyles: [aether_capture_style_output_t] = []

    public init() {
        var config = aether_capture_style_runtime_config_t()
        var runtime: OpaquePointer?
        if aether_capture_style_runtime_default_config(&config) == 0 {
            config.smoothing_alpha = 0.2
            config.freeze_threshold = Float(ScanGuidanceConstants.s3ToS4Threshold)
            config.min_thickness = Float(ScanGuidanceConstants.wedgeMinThicknessM)
            config.max_thickness = Float(ScanGuidanceConstants.wedgeBaseThicknessM)
            config.min_border_width = Float(ScanGuidanceConstants.borderMinWidthPx)
            config.max_border_width = Float(ScanGuidanceConstants.borderMaxWidthPx)
            if aether_capture_style_runtime_create(&config, &runtime) == 0 {
                self.nativeStyleRuntime = runtime
            } else {
                self.nativeStyleRuntime = nil
            }
        } else {
            self.nativeStyleRuntime = nil
        }
    }

    deinit {
        if let nativeStyleRuntime {
            _ = aether_capture_style_runtime_destroy(nativeStyleRuntime)
        }
    }

    public func resetPersistentVisualState() {
        if let nativeStyleRuntime {
            _ = aether_capture_style_runtime_reset(nativeStyleRuntime)
        }
        lastResolvedStyles.removeAll()
    }

    public func borderWidthsForLastGenerate() -> [Float] {
        lastResolvedStyles.map { $0.border_width }
    }

    public func grayscaleForLastGenerate() -> [(Float, Float, Float)] {
        lastResolvedStyles.map { style in
            let gray = min(max(style.grayscale, 0.0), 1.0)
            return (gray, gray, gray)
        }
    }

    public func generate(
        triangles: [ScanTriangle],
        displayValues: [String: Double],
        lod: LODLevel
    ) -> WedgeVertexData {
        guard !triangles.isEmpty else {
            lastResolvedStyles = []
            return WedgeVertexData(vertices: [], indices: [], triangleCount: 0)
        }

        guard let nativeStyleRuntime else {
            lastResolvedStyles = []
            return generateStateless(
                triangles: triangles,
                displayValues: displayValues,
                lod: lod
            )
        }

        var styleInputs = [aether_capture_style_input_t](
            repeating: aether_capture_style_input_t(),
            count: triangles.count
        )
        for (index, triangle) in triangles.enumerated() {
            let display = Float(min(max(displayValues[triangle.patchId] ?? 0.0, 0.0), 1.0))
            styleInputs[index].patch_key = stablePatchKey(triangle.patchId)
            styleInputs[index].display = display
            styleInputs[index].area_sq_m = max(triangle.areaSqM, 1e-8)
        }

        var styleOutputs = [aether_capture_style_output_t](
            repeating: aether_capture_style_output_t(),
            count: triangles.count
        )
        let styleRC = styleInputs.withUnsafeBufferPointer { inputBuffer in
            styleOutputs.withUnsafeMutableBufferPointer { outputBuffer in
                aether_capture_style_runtime_resolve(
                    nativeStyleRuntime,
                    inputBuffer.baseAddress,
                    Int32(styleInputs.count),
                    outputBuffer.baseAddress
                )
            }
        }
        guard styleRC == 0 else {
            lastResolvedStyles = []
            return generateStateless(
                triangles: triangles,
                displayValues: displayValues,
                lod: lod
            )
        }
        lastResolvedStyles = styleOutputs

        var nativeTriangles = [aether_wedge_input_triangle_t](
            repeating: aether_wedge_input_triangle_t(),
            count: triangles.count
        )
        for (index, triangle) in triangles.enumerated() {
            let style = styleOutputs[index]
            let (v0, v1, v2) = triangle.vertices
            nativeTriangles[index].v0 = aether_float3_t(x: v0.x, y: v0.y, z: v0.z)
            nativeTriangles[index].v1 = aether_float3_t(x: v1.x, y: v1.y, z: v1.z)
            nativeTriangles[index].v2 = aether_float3_t(x: v2.x, y: v2.y, z: v2.z)
            nativeTriangles[index].normal = aether_float3_t(
                x: triangle.normal.x,
                y: triangle.normal.y,
                z: triangle.normal.z
            )
            nativeTriangles[index].metallic = style.metallic
            nativeTriangles[index].roughness = style.roughness
            nativeTriangles[index].display = style.resolved_display
            nativeTriangles[index].thickness = style.thickness
            nativeTriangles[index].triangle_id = UInt32(index)
        }

        return buildGeometry(
            nativeTriangles: nativeTriangles,
            lod: lod,
            triangleCount: triangles.count
        )
    }

    public func thickness(
        display: Double,
        areaSqM: Float,
        medianArea: Float
    ) -> Float {
        let clampedDisplay = Float(min(max(display, 0.0), 1.0))
        let clampedArea = max(areaSqM, 1e-8)
        let clampedMedian = max(medianArea, 1e-6)

        var native = aether_fragment_visual_params_t()
        let rc = aether_compute_fragment_visual_params(
            clampedDisplay,
            1.0,
            clampedArea,
            clampedMedian,
            &native
        )
        guard rc == 0, native.wedge_thickness.isFinite else {
            return Float(ScanGuidanceConstants.wedgeMinThicknessM)
        }
        return min(
            max(native.wedge_thickness, Float(ScanGuidanceConstants.wedgeMinThicknessM)),
            Float(ScanGuidanceConstants.wedgeBaseThicknessM)
        )
    }

    /// Kept for test compatibility.
    public func bevelNormals(
        topFaceNormal: SIMD3<Float>,
        sideFaceNormal: SIMD3<Float>,
        segments: Int
    ) -> [SIMD3<Float>] {
        let safeSegments = max(0, min(segments, Int(Int32.max - 1)))
        var nativeCount = Int32(safeSegments + 1)
        var nativeNormals = [aether_float3_t](
            repeating: aether_float3_t(),
            count: Int(nativeCount)
        )
        let top = aether_float3_t(
            x: topFaceNormal.x,
            y: topFaceNormal.y,
            z: topFaceNormal.z
        )
        let side = aether_float3_t(
            x: sideFaceNormal.x,
            y: sideFaceNormal.y,
            z: sideFaceNormal.z
        )
        let rc = nativeNormals.withUnsafeMutableBufferPointer { normalsBuffer in
            aether_compute_bevel_normals(
                top,
                side,
                Int32(safeSegments),
                normalsBuffer.baseAddress,
                &nativeCount
            )
        }
        if rc == 0, nativeCount > 0 {
            return nativeNormals.prefix(Int(nativeCount)).map { value in
                SIMD3<Float>(value.x, value.y, value.z)
            }
        }

        guard safeSegments > 0 else {
            return [simd_normalize(topFaceNormal)]
        }
        var fallback: [SIMD3<Float>] = []
        fallback.reserveCapacity(safeSegments + 1)
        for i in 0...safeSegments {
            let t = Float(i) / Float(safeSegments)
            let mixed = topFaceNormal * (1.0 - t) + sideFaceNormal * t
            let len = (mixed.x * mixed.x + mixed.y * mixed.y + mixed.z * mixed.z).squareRoot()
            fallback.append(len > 0 ? mixed / len : mixed)
        }
        return fallback
    }

    private func generateStateless(
        triangles: [ScanTriangle],
        displayValues: [String: Double],
        lod: LODLevel
    ) -> WedgeVertexData {
        let areas = triangles.map { max($0.areaSqM, 1e-8) }
        let sortedAreas = areas.sorted()
        let medianArea = max(1e-6, sortedAreas[sortedAreas.count / 2])
        var nativeTriangles = [aether_wedge_input_triangle_t](
            repeating: aether_wedge_input_triangle_t(),
            count: triangles.count
        )

        for (index, triangle) in triangles.enumerated() {
            let display = Float(min(max(displayValues[triangle.patchId] ?? 0.0, 0.0), 1.0))
            var params = aether_fragment_visual_params_t()
            let rc = aether_compute_fragment_visual_params(
                display,
                1.0,
                max(triangle.areaSqM, 1e-8),
                medianArea,
                &params
            )
            let metallic = rc == 0 && params.metallic.isFinite
                ? min(max(params.metallic, 0.0), 1.0)
                : Float(ScanGuidanceConstants.metallicBase)
            let roughness = rc == 0 && params.roughness.isFinite
                ? min(max(params.roughness, 0.0), 1.0)
                : Float(ScanGuidanceConstants.roughnessBase)
            let thickness = rc == 0 && params.wedge_thickness.isFinite
                ? min(
                    max(params.wedge_thickness, Float(ScanGuidanceConstants.wedgeMinThicknessM)),
                    Float(ScanGuidanceConstants.wedgeBaseThicknessM)
                )
                : Float(ScanGuidanceConstants.wedgeMinThicknessM)
            let border = rc == 0 && params.border_width_px.isFinite
                ? min(
                    max(params.border_width_px, Float(ScanGuidanceConstants.borderMinWidthPx)),
                    Float(ScanGuidanceConstants.borderMaxWidthPx)
                )
                : Float(ScanGuidanceConstants.borderMinWidthPx)
            let gray = rc == 0 && params.fill_gray.isFinite
                ? min(max(params.fill_gray, 0.0), 1.0)
                : display

            let (v0, v1, v2) = triangle.vertices
            nativeTriangles[index].v0 = aether_float3_t(x: v0.x, y: v0.y, z: v0.z)
            nativeTriangles[index].v1 = aether_float3_t(x: v1.x, y: v1.y, z: v1.z)
            nativeTriangles[index].v2 = aether_float3_t(x: v2.x, y: v2.y, z: v2.z)
            nativeTriangles[index].normal = aether_float3_t(
                x: triangle.normal.x,
                y: triangle.normal.y,
                z: triangle.normal.z
            )
            nativeTriangles[index].metallic = metallic
            nativeTriangles[index].roughness = roughness
            nativeTriangles[index].display = display
            nativeTriangles[index].thickness = thickness
            nativeTriangles[index].triangle_id = UInt32(index)

            var style = aether_capture_style_output_t()
            style.resolved_display = display
            style.metallic = metallic
            style.roughness = roughness
            style.thickness = thickness
            style.border_width = border
            style.grayscale = gray
            style.visual_should_freeze = display >= Float(ScanGuidanceConstants.s3ToS4Threshold) ? 1 : 0
            style.border_should_freeze = style.visual_should_freeze
            if index < lastResolvedStyles.count {
                lastResolvedStyles[index] = style
            } else {
                lastResolvedStyles.append(style)
            }
        }

        return buildGeometry(
            nativeTriangles: nativeTriangles,
            lod: lod,
            triangleCount: triangles.count
        )
    }

    private func buildGeometry(
        nativeTriangles: [aether_wedge_input_triangle_t],
        lod: LODLevel,
        triangleCount: Int
    ) -> WedgeVertexData {
        var vertexCount: Int32 = 0
        var indexCount: Int32 = 0
        let probeRC = nativeTriangles.withUnsafeBufferPointer { triangleBuffer in
            aether_generate_wedge_geometry(
                triangleBuffer.baseAddress,
                Int32(nativeTriangles.count),
                Int32(lod.rawValue),
                nil,
                &vertexCount,
                nil,
                &indexCount
            )
        }
        guard probeRC == -3 || probeRC == 0 else {
            return WedgeVertexData(vertices: [], indices: [], triangleCount: triangleCount)
        }
        if vertexCount < 0 || indexCount < 0 {
            return WedgeVertexData(vertices: [], indices: [], triangleCount: triangleCount)
        }

        var nativeVertices = [aether_wedge_vertex_t](
            repeating: aether_wedge_vertex_t(),
            count: Int(vertexCount)
        )
        var nativeIndices = [UInt32](repeating: 0, count: Int(indexCount))

        let buildRC = nativeTriangles.withUnsafeBufferPointer { triangleBuffer in
            nativeVertices.withUnsafeMutableBufferPointer { vertexBuffer in
                nativeIndices.withUnsafeMutableBufferPointer { indexBuffer in
                    aether_generate_wedge_geometry(
                        triangleBuffer.baseAddress,
                        Int32(nativeTriangles.count),
                        Int32(lod.rawValue),
                        vertexBuffer.baseAddress,
                        &vertexCount,
                        indexBuffer.baseAddress,
                        &indexCount
                    )
                }
            }
        }
        guard buildRC == 0 else {
            return WedgeVertexData(vertices: [], indices: [], triangleCount: triangleCount)
        }

        let resolvedVertices = nativeVertices.prefix(Int(vertexCount)).map { vertex in
            WedgeVertexCPU(
                position: SIMD3<Float>(vertex.position.x, vertex.position.y, vertex.position.z),
                normal: SIMD3<Float>(vertex.normal.x, vertex.normal.y, vertex.normal.z),
                metallic: vertex.metallic,
                roughness: vertex.roughness,
                display: vertex.display,
                thickness: vertex.thickness,
                triangleId: vertex.triangle_id
            )
        }

        return WedgeVertexData(
            vertices: resolvedVertices,
            indices: Array(nativeIndices.prefix(Int(indexCount))),
            triangleCount: triangleCount
        )
    }

    private func stablePatchKey(_ patchId: String) -> UInt64 {
        let bytes = Array(patchId.utf8)
        let count = Int32(min(bytes.count, Int(Int32.max)))
        var hash: UInt64 = 0
        let rc = bytes.withUnsafeBufferPointer { buffer in
            aether_hash_fnv1a64(
                buffer.baseAddress,
                count,
                &hash
            )
        }
        if rc == 0 {
            return hash
        }
        var fallback: UInt64 = BridgeInteropConstants.fnv1a64OffsetBasis
        for byte in bytes {
            fallback ^= UInt64(byte)
            fallback &*= BridgeInteropConstants.fnv1a64Prime
        }
        return fallback
    }
}
