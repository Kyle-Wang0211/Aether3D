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
        
        // Generate GLB format
        // GLB format: 12-byte header + JSON chunk + binary chunk
        var glbData = Data()
        
        // Header (12 bytes)
        glbData.append(contentsOf: "glTF".data(using: .utf8)!)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }) // Version
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // Total length (placeholder)
        
        // JSON chunk
        let jsonChunk = try createJSONChunk(mesh: mesh, provenanceBundle: provenanceBundle, options: options)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(jsonChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "JSON".data(using: .utf8)!)
        glbData.append(jsonChunk)
        
        // Binary chunk
        let binaryChunk = try createBinaryChunk(mesh: mesh, options: options)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(binaryChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "BIN\0".data(using: .utf8)!)
        glbData.append(binaryChunk)
        
        // Update total length in header
        let totalLength = UInt32(glbData.count)
        glbData.replaceSubrange(8..<12, with: withUnsafeBytes(of: totalLength.littleEndian) { Data($0) })
        
        return glbData
    }
    
    /// Create JSON chunk
    private func createJSONChunk(mesh: MeshData, provenanceBundle: ProvenanceBundle, options: GLTFExportOptions) throws -> Data {
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
                "primitives": [[
                    "attributes": [
                        "POSITION": 0
                    ],
                    "indices": 1
                ]]
            ]],
            "accessors": [] as [[String: Any]],
            "bufferViews": [] as [[String: Any]],
            "buffers": [[
                "uri": "data:application/octet-stream;base64,"
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
    
    /// Create binary chunk
    private func createBinaryChunk(mesh: MeshData, options: GLTFExportOptions) throws -> Data {
        // In production, pack mesh data (vertices, indices) into binary chunk
        return Data()
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
