// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GLTFExporter.swift
// Aether3D
//
// glTF 2.0 Exporter with ProvenanceBundle Embedding
// 符合 Phase 5: Format Bridge (GLTFExporter with ProvenanceBundle Embedding)
//

import Foundation

/// GLTF Export Options
///
/// Options for glTF export.
public struct GLTFExportOptions: Sendable {
    public let enableQuantization: Bool
    public let enableDraco: Bool
    public let embedTextures: Bool
    public let quantizationBits: Int
    
    public init(enableQuantization: Bool = true, enableDraco: Bool = false, embedTextures: Bool = true, quantizationBits: Int = 16) {
        self.enableQuantization = enableQuantization
        self.enableDraco = enableDraco
        self.embedTextures = embedTextures
        self.quantizationBits = quantizationBits
    }
}

/// GLTF Exporter
///
/// Exports mesh data to glTF 2.0 format with ProvenanceBundle embedding.
/// 符合 Phase 5: GLTFExporter with ProvenanceBundle Embedding
public struct GLTFExporter {
    private struct MeshBinaryLayout {
        let binaryChunk: Data
        let bufferViews: [[String: Any]]
        let accessors: [[String: Any]]
        let positionAccessorIndex: Int?
        let normalAccessorIndex: Int?
        let indexAccessorIndex: Int?
    }
    
    /// Initialize GLTF Exporter
    public init() {}
    
    /// Export mesh to GLB format
    /// 
    /// 符合 Phase 5: GLB format generation with ProvenanceBundle embedding
    /// - Parameters:
    ///   - mesh: Mesh data
    ///   - evidence: Evidence data
    ///   - merkleProof: Merkle inclusion proof
    ///   - sth: Signed tree head
    ///   - timeProof: Triple time proof
    ///   - options: Export options
    /// - Returns: GLB data
    /// - Throws: GLTFExporterError if export fails
    public func export(mesh: MeshData, evidence: Data?, merkleProof: InclusionProof?, sth: SignedTreeHead?, timeProof: TripleTimeProof?, options: GLTFExportOptions) throws -> Data {
        try validate(mesh: mesh)

        // Create provenance bundle
        let manifest = ProvenanceManifest(
            format: .gltf,
            version: "2.0",
            exportedAt: Date(),
            exporterVersion: "1.0"
        )
        
        let provenanceBundle = ProvenanceBundle(
            manifest: manifest,
            sth: sth,
            timeProof: timeProof,
            merkleProof: merkleProof,
            deviceAttestation: nil
        )

        let binaryLayout = try createBinaryChunk(mesh: mesh, options: options)
        
        // Generate GLB format
        // GLB format: 12-byte header + JSON chunk + binary chunk
        var glbData = Data()
        
        // Header (12 bytes)
        glbData.append(contentsOf: "glTF".data(using: .utf8)!)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }) // Version
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // Total length (placeholder)
        
        // JSON chunk
        let jsonChunk = try createJSONChunk(
            binaryLayout: binaryLayout,
            provenanceBundle: provenanceBundle,
            options: options
        )
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(jsonChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "JSON".data(using: .utf8)!)
        glbData.append(jsonChunk)
        
        // Binary chunk
        let binaryChunk = binaryLayout.binaryChunk
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(binaryChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "BIN\0".data(using: .utf8)!)
        glbData.append(binaryChunk)
        
        // Update total length in header
        let totalLength = UInt32(glbData.count)
        glbData.replaceSubrange(8..<12, with: withUnsafeBytes(of: totalLength.littleEndian) { Data($0) })
        
        return glbData
    }
    
    /// Create JSON chunk
    private func createJSONChunk(
        binaryLayout: MeshBinaryLayout,
        provenanceBundle: ProvenanceBundle,
        options: GLTFExportOptions
    ) throws -> Data {
        var attributes: [String: Int] = [:]
        if let positionAccessorIndex = binaryLayout.positionAccessorIndex {
            attributes["POSITION"] = positionAccessorIndex
        }
        if let normalAccessorIndex = binaryLayout.normalAccessorIndex {
            attributes["NORMAL"] = normalAccessorIndex
        }

        var primitive: [String: Any] = [
            "attributes": attributes
        ]
        if let indexAccessorIndex = binaryLayout.indexAccessorIndex {
            primitive["indices"] = indexAccessorIndex
        }

        // Use JSONSerialization instead of Encodable for [String: Any]
        var gltf: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "Aether3D"
            ],
            "scenes": [[
                "nodes": [0]
            ]],
            "nodes": [[
                "mesh": 0
            ]],
            "meshes": [[
                "primitives": [primitive]
            ]],
            "accessors": binaryLayout.accessors,
            "bufferViews": binaryLayout.bufferViews,
            "buffers": [[
                "byteLength": binaryLayout.binaryChunk.count
            ]]
        ]
        
        // Embed provenance bundle in extras
        let provenanceJSON = try provenanceBundle.encode()
        gltf["extras"] = [
            "provenanceBundle": String(data: provenanceJSON, encoding: .utf8) ?? ""
        ]
        
        // Use JSONSerialization with sorted keys for canonical output
        let jsonData = try JSONSerialization.data(
            withJSONObject: gltf,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        
        // Pad to 4-byte alignment per glTF spec
        let padding = (4 - (jsonData.count % 4)) % 4
        var paddedData = jsonData
        paddedData.append(contentsOf: [UInt8](repeating: 0x20, count: padding))
        
        return paddedData
    }
    
    /// Create binary chunk and glTF buffer metadata.
    private func createBinaryChunk(mesh: MeshData, options: GLTFExportOptions) throws -> MeshBinaryLayout {
        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var positionAccessorIndex: Int?
        var normalAccessorIndex: Int?
        var indexAccessorIndex: Int?

        // POSITION (float32 vec3)
        if !mesh.vertices.isEmpty {
            let positionOffset = binary.count
            appendFloatArray(mesh.vertices, to: &binary)
            let positionByteLength = binary.count - positionOffset

            let positionBufferViewIndex = bufferViews.count
            bufferViews.append([
                "buffer": 0,
                "byteOffset": positionOffset,
                "byteLength": positionByteLength,
                "target": 34962
            ])

            let (minPos, maxPos) = positionBounds(mesh.vertices)
            let accessorIndex = accessors.count
            accessors.append([
                "bufferView": positionBufferViewIndex,
                "componentType": 5126,
                "count": mesh.vertices.count / 3,
                "type": "VEC3",
                "min": minPos,
                "max": maxPos
            ])
            positionAccessorIndex = accessorIndex
            padTo4Bytes(&binary)
        }

        // NORMAL (optional float32 vec3)
        if let normals = mesh.normals, !normals.isEmpty {
            let normalOffset = binary.count
            appendFloatArray(normals, to: &binary)
            let normalByteLength = binary.count - normalOffset

            let normalBufferViewIndex = bufferViews.count
            bufferViews.append([
                "buffer": 0,
                "byteOffset": normalOffset,
                "byteLength": normalByteLength,
                "target": 34962
            ])

            let accessorIndex = accessors.count
            accessors.append([
                "bufferView": normalBufferViewIndex,
                "componentType": 5126,
                "count": normals.count / 3,
                "type": "VEC3"
            ])
            normalAccessorIndex = accessorIndex
            padTo4Bytes(&binary)
        }

        // INDICES (optional uint16/uint32 scalar)
        if !mesh.indices.isEmpty {
            let indexOffset = binary.count
            let maxIndex = mesh.indices.max() ?? 0

            let componentType: Int
            if maxIndex <= UInt32(UInt16.max) {
                componentType = BridgeInteropConstants.gltfComponentTypeUInt16
                let u16 = mesh.indices.map(UInt16.init)
                u16.withUnsafeBytes { binary.append(contentsOf: $0) }
            } else {
                componentType = BridgeInteropConstants.gltfComponentTypeUInt32
                mesh.indices.withUnsafeBytes { binary.append(contentsOf: $0) }
            }
            let indexByteLength = binary.count - indexOffset

            let indexBufferViewIndex = bufferViews.count
            bufferViews.append([
                "buffer": 0,
                "byteOffset": indexOffset,
                "byteLength": indexByteLength,
                "target": 34963
            ])

            let accessorIndex = accessors.count
            accessors.append([
                "bufferView": indexBufferViewIndex,
                "componentType": componentType,
                "count": mesh.indices.count,
                "type": "SCALAR"
            ])
            indexAccessorIndex = accessorIndex
            padTo4Bytes(&binary)
        }

        return MeshBinaryLayout(
            binaryChunk: binary,
            bufferViews: bufferViews,
            accessors: accessors,
            positionAccessorIndex: positionAccessorIndex,
            normalAccessorIndex: normalAccessorIndex,
            indexAccessorIndex: indexAccessorIndex
        )
    }

    private func validate(mesh: MeshData) throws {
        guard mesh.vertices.count % 3 == 0 else {
            throw GLTFExporterError.invalidMeshData("Vertex array must contain xyz triplets")
        }
        if let normals = mesh.normals {
            guard normals.count == mesh.vertices.count else {
                throw GLTFExporterError.invalidMeshData("Normal count must match vertex count")
            }
        }
        guard mesh.indices.count % 3 == 0 else {
            throw GLTFExporterError.invalidMeshData("Index array must contain triangle triplets")
        }
        let vertexCount = mesh.vertices.count / 3
        if vertexCount == 0 {
            guard mesh.indices.isEmpty else {
                throw GLTFExporterError.invalidMeshData("Indices require non-empty vertices")
            }
        } else if let maxIndex = mesh.indices.max(), Int(maxIndex) >= vertexCount {
            throw GLTFExporterError.invalidMeshData("Index out of bounds for provided vertex array")
        }
    }

    private func appendFloatArray(_ values: [Float], to data: inout Data) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private func positionBounds(_ vertices: [Float]) -> (min: [Float], max: [Float]) {
        guard !vertices.isEmpty else {
            return ([0, 0, 0], [0, 0, 0])
        }

        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        var i = 0
        while i + 2 < vertices.count {
            let x = vertices[i]
            let y = vertices[i + 1]
            let z = vertices[i + 2]
            minX = min(minX, x)
            minY = min(minY, y)
            minZ = min(minZ, z)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            maxZ = max(maxZ, z)
            i += 3
        }

        return ([minX, minY, minZ], [maxX, maxY, maxZ])
    }

    private func padTo4Bytes(_ data: inout Data) {
        let padding = (4 - (data.count % 4)) % 4
        if padding > 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: padding))
        }
    }
}

/// Mesh Data
///
/// Mesh data for export.
public struct MeshData: Sendable {
    public let vertices: [Float]
    public let indices: [UInt32]
    public let normals: [Float]?
    
    public init(vertices: [Float], indices: [UInt32], normals: [Float]? = nil) {
        self.vertices = vertices
        self.indices = indices
        self.normals = normals
    }
}

/// GLTF Exporter Errors
public enum GLTFExporterError: Error, Sendable {
    case invalidMeshData(String)
    case encodingFailed(String)
    case validationFailed(String)
    case provenanceBundleError(ProvenanceBundleError)
    
    public var localizedDescription: String {
        switch self {
        case .invalidMeshData(let reason):
            return "Invalid mesh data: \(reason)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        case .provenanceBundleError(let error):
            return "Provenance bundle error: \(error.localizedDescription)"
        }
    }
}

// Crypto imports handled in ProvenanceBundle
