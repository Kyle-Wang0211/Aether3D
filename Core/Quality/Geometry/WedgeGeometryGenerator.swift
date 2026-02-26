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
    private struct FractureTriangle {
        let stylePatchKey: UInt64
        let parentTriangleIndex: Int
        let vertices: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        let normal: SIMD3<Float>
        let display: Float
        let areaSqM: Float
    }

    public enum LODLevel: Int, CaseIterable {
        case full = 0
        case medium = 1
        case low = 2
        case flat = 3

        /// Compute maximum safe input triangles for given LOD level.
        /// Pure math — no state, no side effects.
        ///
        /// Index buffer = 4MB = 1,048,576 UInt32 slots. Indices per input varies by LOD:
        ///   LOD 0 (full):   ~44 subtriangles × 3 = 132 indices
        ///   LOD 1 (medium): ~22 subtriangles × 3 = 66 indices
        ///   LOD 2 (low):    ~11 subtriangles × 3 = 33 indices
        ///   LOD 3 (flat):   ~3  subtriangles × 3 = 9 indices
        ///
        /// Moved from ScanGuidanceRenderPipeline inline computation.
        ///
        /// - Parameters:
        ///   - maxTrianglesFromTier: Maximum triangles allowed by thermal tier
        ///   - indexBufferCapacity: Index buffer capacity in UInt32 slots (default 1M)
        /// - Returns: Maximum safe input triangle count
        public static func maxSafeInputTriangles(
            lod: LODLevel,
            maxTrianglesFromTier: Int,
            indexBufferCapacity: Int = 1_048_576
        ) -> Int {
            let indicesPerInput: Int
            switch lod {
            case .full:   indicesPerInput = 132
            case .medium: indicesPerInput = 66
            case .low:    indicesPerInput = 33
            case .flat:   indicesPerInput = 9
            }
            return min(maxTrianglesFromTier, indexBufferCapacity / indicesPerInput)
        }
    }

    /// Optional color mapper for perceptual color (Oklab).
    /// When set, overrides C++ grayscale with Oklab-mapped RGB per display value.
    public var colorMapper: ((Double) -> (r: Float, g: Float, b: Float))?

    private let nativeStyleRuntime: OpaquePointer?
    private var lastResolvedStyles: [aether_capture_style_output_t] = []
    private var lastTriangleParentIndices: [Int] = []

    public init() {
        var config = aether_capture_style_runtime_config_t()
        var runtime: OpaquePointer?
        if aether_capture_style_runtime_default_config(&config) == 0 {
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
        lastTriangleParentIndices.removeAll()
    }

    public func borderWidthsForLastGenerate() -> [Float] {
        lastResolvedStyles.map { $0.border_width }
    }

    public func borderAlphasForLastGenerate() -> [Float] {
        lastResolvedStyles.map { min(max($0.border_alpha, 0.0), 1.0) }
    }

    public func shaderThresholdsForLastGenerate() -> [(
        rippleMinAmplitude: Float,
        rippleBoostScale: Float,
        fillDitherStart: Float,
        fillDitherEnd: Float,
        borderMinWidth: Float,
        borderMinAlpha: Float,
        borderAAFactor: Float,
        borderFwidthEpsilon: Float,
        borderDiscardAlpha: Float
    )] {
        lastResolvedStyles.map { style in
            return (
                rippleMinAmplitude: style.ripple_min_amplitude,
                rippleBoostScale: style.ripple_boost_scale,
                fillDitherStart: style.fill_dither_start,
                fillDitherEnd: style.fill_dither_end,
                borderMinWidth: style.border_min_width_px,
                borderMinAlpha: style.border_min_alpha,
                borderAAFactor: style.border_aa_factor,
                borderFwidthEpsilon: style.border_fwidth_epsilon,
                borderDiscardAlpha: style.border_discard_alpha
            )
        }
    }

    public func grayscaleForLastGenerate() -> [(Float, Float, Float)] {
        lastResolvedStyles.map { style in
            if let mapper = colorMapper {
                return mapper(Double(style.resolved_display))
            }
            let gray = min(max(style.grayscale, 0.0), 1.0)
            return (gray, gray, gray)
        }
    }

    public func parentTriangleIndicesForLastGenerate() -> [Int] {
        lastTriangleParentIndices
    }

    public func generate(
        triangles: [ScanTriangle],
        displayValues: [String: Double],
        cameraPosition: SIMD3<Float>? = nil,
        lod: LODLevel
    ) -> WedgeVertexData {
        guard !triangles.isEmpty else {
            lastResolvedStyles = []
            lastTriangleParentIndices = []
            return WedgeVertexData(vertices: [], indices: [], triangleCount: 0)
        }

        let fracturedTriangles = fractureTriangles(
            from: triangles,
            displayValues: displayValues,
            cameraPosition: cameraPosition
        )
        guard !fracturedTriangles.isEmpty else {
            lastResolvedStyles = []
            lastTriangleParentIndices = []
            return WedgeVertexData(vertices: [], indices: [], triangleCount: 0)
        }
        lastTriangleParentIndices = fracturedTriangles.map(\.parentTriangleIndex)

        guard let nativeStyleRuntime else {
            lastResolvedStyles = []
            return generateStateless(
                fracturedTriangles: fracturedTriangles,
                lod: lod
            )
        }

        var styleInputs = [aether_capture_style_input_t](
            repeating: aether_capture_style_input_t(),
            count: fracturedTriangles.count
        )
        for (index, triangle) in fracturedTriangles.enumerated() {
            styleInputs[index].patch_key = triangle.stylePatchKey
            styleInputs[index].display = triangle.display
            styleInputs[index].area_sq_m = max(triangle.areaSqM, 1e-8)
        }

        var styleOutputs = [aether_capture_style_output_t](
            repeating: aether_capture_style_output_t(),
            count: fracturedTriangles.count
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
                fracturedTriangles: fracturedTriangles,
                lod: lod
            )
        }
        lastResolvedStyles = styleOutputs

        var nativeTriangles = [aether_wedge_input_triangle_t](
            repeating: aether_wedge_input_triangle_t(),
            count: fracturedTriangles.count
        )
        for (index, triangle) in fracturedTriangles.enumerated() {
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
            // Safety: fallback to fracture display if C++ returns invalid value.
            let resolvedDisplay = style.resolved_display
            nativeTriangles[index].display = resolvedDisplay.isFinite && resolvedDisplay >= 0
                ? resolvedDisplay
                : triangle.display
            nativeTriangles[index].thickness = style.thickness
            nativeTriangles[index].triangle_id = UInt32(index)
        }

        return buildGeometry(
            nativeTriangles: nativeTriangles,
            lod: lod,
            triangleCount: fracturedTriangles.count
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
        return [simd_normalize(topFaceNormal)]
    }

    private func generateStateless(
        fracturedTriangles: [FractureTriangle],
        lod: LODLevel
    ) -> WedgeVertexData {
        let medianArea = medianArea(of: fracturedTriangles)
        var config = aether_capture_style_runtime_config_t()
        _ = aether_capture_style_runtime_default_config(&config)

        var styleInputs = [aether_capture_style_input_t](
            repeating: aether_capture_style_input_t(),
            count: fracturedTriangles.count
        )
        for (index, triangle) in fracturedTriangles.enumerated() {
            styleInputs[index].patch_key = triangle.stylePatchKey
            styleInputs[index].display = triangle.display
            styleInputs[index].area_sq_m = max(triangle.areaSqM, 1e-8)
        }

        var styleOutputs = [aether_capture_style_output_t](
            repeating: aether_capture_style_output_t(),
            count: fracturedTriangles.count
        )
        let styleRC = styleInputs.withUnsafeBufferPointer { inputBuffer in
            styleOutputs.withUnsafeMutableBufferPointer { outputBuffer in
                aether_capture_style_resolve_stateless(
                    &config,
                    inputBuffer.baseAddress,
                    Int32(styleInputs.count),
                    medianArea,
                    outputBuffer.baseAddress
                )
            }
        }
        if styleRC != 0 {
            lastResolvedStyles = []
            return WedgeVertexData(vertices: [], indices: [], triangleCount: fracturedTriangles.count)
        }
        lastResolvedStyles = styleOutputs

        var nativeTriangles = [aether_wedge_input_triangle_t](
            repeating: aether_wedge_input_triangle_t(),
            count: fracturedTriangles.count
        )

        for (index, triangle) in fracturedTriangles.enumerated() {
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
            // Safety: fallback to fracture display if C++ returns invalid value.
            let resolvedDisplay = style.resolved_display
            nativeTriangles[index].display = resolvedDisplay.isFinite && resolvedDisplay >= 0
                ? resolvedDisplay
                : triangle.display
            nativeTriangles[index].thickness = style.thickness
            nativeTriangles[index].triangle_id = UInt32(index)
        }

        return buildGeometry(
            nativeTriangles: nativeTriangles,
            lod: lod,
            triangleCount: fracturedTriangles.count
        )
    }

    private func fractureTriangles(
        from triangles: [ScanTriangle],
        displayValues: [String: Double],
        cameraPosition: SIMD3<Float>?
    ) -> [FractureTriangle] {
        guard !triangles.isEmpty else { return [] }

        var nativeInputs = [aether_fracture_input_triangle_t](
            repeating: aether_fracture_input_triangle_t(),
            count: triangles.count
        )
        for (index, triangle) in triangles.enumerated() {
            let (v0, v1, v2) = triangle.vertices
            let display = clampedDisplayValue(displayValues[triangle.patchId])
            nativeInputs[index].patch_key = stablePatchKey(triangle.patchId)
            nativeInputs[index].v0 = aether_float3_t(x: v0.x, y: v0.y, z: v0.z)
            nativeInputs[index].v1 = aether_float3_t(x: v1.x, y: v1.y, z: v1.z)
            nativeInputs[index].v2 = aether_float3_t(x: v2.x, y: v2.y, z: v2.z)
            nativeInputs[index].normal = aether_float3_t(
                x: triangle.normal.x,
                y: triangle.normal.y,
                z: triangle.normal.z
            )
            nativeInputs[index].display = display
            let centroid = (v0 + v1 + v2) / 3.0
            let depth: Float
            if let cameraPosition {
                depth = simd_length(centroid - cameraPosition)
            } else {
                depth = simd_length(centroid)
            }
            nativeInputs[index].depth = max(depth, 0.05)
            nativeInputs[index].area_sq_m = max(triangle.areaSqM, 1e-8)
        }

        var outCount: Int32 = 0
        let probeRC = nativeInputs.withUnsafeBufferPointer { inputBuffer in
            aether_generate_fracture_display_triangles(
                inputBuffer.baseAddress,
                Int32(nativeInputs.count),
                nil,
                &outCount
            )
        }
        guard probeRC == -3 || probeRC == 0, outCount > 0 else {
            return fallbackTriangles(from: triangles, displayValues: displayValues)
        }

        var nativeOutputs = [aether_fracture_output_triangle_t](
            repeating: aether_fracture_output_triangle_t(),
            count: Int(outCount)
        )
        let buildRC = nativeInputs.withUnsafeBufferPointer { inputBuffer in
            nativeOutputs.withUnsafeMutableBufferPointer { outputBuffer in
                aether_generate_fracture_display_triangles(
                    inputBuffer.baseAddress,
                    Int32(nativeInputs.count),
                    outputBuffer.baseAddress,
                    &outCount
                )
            }
        }
        guard buildRC == 0, outCount > 0 else {
            return fallbackTriangles(from: triangles, displayValues: displayValues)
        }

        let safeCount = min(Int(outCount), nativeOutputs.count)
        if safeCount <= 0 {
            return fallbackTriangles(from: triangles, displayValues: displayValues)
        }

        var fractured: [FractureTriangle] = []
        fractured.reserveCapacity(safeCount)
        for i in 0..<safeCount {
            let item = nativeOutputs[i]
            let parentIndex = Int(item.parent_triangle_index)
            guard parentIndex >= 0, parentIndex < triangles.count else { continue }
            let v0 = SIMD3<Float>(item.v0.x, item.v0.y, item.v0.z)
            let v1 = SIMD3<Float>(item.v1.x, item.v1.y, item.v1.z)
            let v2 = SIMD3<Float>(item.v2.x, item.v2.y, item.v2.z)
            let normal = SIMD3<Float>(item.normal.x, item.normal.y, item.normal.z)
            let area = max(item.area_sq_m, 1e-8)
            fractured.append(
                FractureTriangle(
                    stylePatchKey: stylePatchKey(
                        basePatchKey: item.patch_key,
                        fragmentIndex: item.fragment_index
                    ),
                    parentTriangleIndex: parentIndex,
                    vertices: (v0, v1, v2),
                    normal: normal,
                    display: min(max(item.display, 0.0), 1.0),
                    areaSqM: area
                )
            )
        }
        return fractured.isEmpty ? fallbackTriangles(from: triangles, displayValues: displayValues) : fractured
    }

    private func fallbackTriangles(
        from triangles: [ScanTriangle],
        displayValues: [String: Double]
    ) -> [FractureTriangle] {
        triangles.enumerated().map { index, triangle in
            let display = clampedDisplayValue(displayValues[triangle.patchId])
            return FractureTriangle(
                stylePatchKey: stylePatchKey(
                    basePatchKey: stablePatchKey(triangle.patchId),
                    fragmentIndex: 0
                ),
                parentTriangleIndex: index,
                vertices: triangle.vertices,
                normal: triangle.normal,
                display: display,
                areaSqM: max(triangle.areaSqM, 1e-8)
            )
        }
    }

    private func stylePatchKey(basePatchKey: UInt64, fragmentIndex: UInt32) -> UInt64 {
        let seed = UInt64(fragmentIndex &+ 1)
        return basePatchKey ^ (seed &* 0x9E3779B97F4A7C15)
    }

    private func medianArea(of triangles: [FractureTriangle]) -> Float {
        guard !triangles.isEmpty else { return 1e-6 }
        let sortedAreas = triangles.map { max($0.areaSqM, 1e-8) }.sorted()
        return max(1e-6, sortedAreas[sortedAreas.count / 2])
    }

    private func clampedDisplayValue(_ value: Double?) -> Float {
        Float(min(max(value ?? 0.0, 0.0), 1.0))
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
        return rc == 0 ? hash : 0
    }
}
