// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GLTFGaussianSplattingExporter.swift
// Aether3D
//
// glTF Gaussian Splatting Exporter - KHR_gaussian_splatting extension
// 符合 Phase 5: Format Bridge (GLTFGaussianSplattingExporter)
//

import Foundation

/// Gaussian Splat Data
///
/// Gaussian splatting point cloud data.
public struct GaussianSplatData: Sendable {
    public let positions: [Float]
    public let colors: [Float]
    public let opacities: [Float]
    public let scales: [Float]
    public let rotations: [Float]
    public let sphericalHarmonics: [Float]?
    
    public init(positions: [Float], colors: [Float], opacities: [Float], scales: [Float], rotations: [Float], sphericalHarmonics: [Float]? = nil) {
        self.positions = positions
        self.colors = colors
        self.opacities = opacities
        self.scales = scales
        self.rotations = rotations
        self.sphericalHarmonics = sphericalHarmonics
    }
}

/// GLTF Gaussian Splatting Export Options
///
/// Options for Gaussian splatting export.
public struct GLTFGaussianSplattingExportOptions: Sendable {
    public let enableQuantization: Bool
    public let quantizationBits: Int
    public let compressionLevel: Int
    public let embedProvenanceBundle: Bool
    
    public init(enableQuantization: Bool = true, quantizationBits: Int = 16, compressionLevel: Int = 6, embedProvenanceBundle: Bool = true) {
        self.enableQuantization = enableQuantization
        self.quantizationBits = quantizationBits
        self.compressionLevel = compressionLevel
        self.embedProvenanceBundle = embedProvenanceBundle
    }
}

/// GLTF Gaussian Splatting Exporter
///
/// Exports Gaussian splatting data to glTF 2.0 with KHR_gaussian_splatting extension.
/// 符合 Phase 5: GLTFGaussianSplattingExporter (KHR_gaussian_splatting)
public struct GLTFGaussianSplattingExporter {
    
    /// Initialize GLTF Gaussian Splatting Exporter
    public init() {}
    
    /// Export splat data to GLB format
    /// 
    /// 符合 Phase 5: GLB format with KHR_gaussian_splatting extension
    /// - Parameters:
    ///   - splatData: Gaussian splat data
    ///   - evidence: Evidence data
    ///   - merkleProof: Merkle inclusion proof
    ///   - sth: Signed tree head
    ///   - timeProof: Triple time proof
    ///   - options: Export options
    /// - Returns: GLB data
    /// - Throws: GLTFGaussianSplattingExporterError if export fails
    public func export(splatData: GaussianSplatData, evidence: Data?, merkleProof: InclusionProof?, sth: SignedTreeHead?, timeProof: TripleTimeProof?, options: GLTFGaussianSplattingExportOptions) throws -> Data {
        // Create provenance bundle
        let manifest = ProvenanceManifest(
            format: .gltfGaussianSplatting,
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
        
        // Generate GLB format with KHR_gaussian_splatting extension
        // Similar to GLTFExporter but with Gaussian splatting-specific structure
        var glbData = Data()
        
        // Header (12 bytes)
        glbData.append(contentsOf: "glTF".data(using: .utf8)!)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }) // Version
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // Total length (placeholder)
        
        // JSON chunk with KHR_gaussian_splatting extension
        let jsonChunk = try createJSONChunk(splatData: splatData, provenanceBundle: provenanceBundle, options: options)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(jsonChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "JSON".data(using: .utf8)!)
        glbData.append(jsonChunk)
        
        // Binary chunk with splat data
        let binaryChunk = try createBinaryChunk(splatData: splatData, options: options)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(binaryChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "BIN\0".data(using: .utf8)!)
        glbData.append(binaryChunk)
        
        // Update total length
        let totalLength = UInt32(glbData.count)
        glbData.replaceSubrange(8..<12, with: withUnsafeBytes(of: totalLength.littleEndian) { Data($0) })
        
        return glbData
    }
    
    /// Create JSON chunk with KHR_gaussian_splatting extension
    private func createJSONChunk(splatData: GaussianSplatData, provenanceBundle: ProvenanceBundle, options: GLTFGaussianSplattingExportOptions) throws -> Data {
        var gltf: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "Aether3D"
            ],
            "extensionsUsed": ["KHR_gaussian_splatting"],
            "extensionsRequired": ["KHR_gaussian_splatting"],
            "scenes": [[
                "nodes": [0]
            ]],
            "nodes": [[
                "extensions": [
                    "KHR_gaussian_splatting": [
                        "splats": 0
                    ]
                ]
            ]]
        ]
        
        // Embed provenance bundle if enabled
        if options.embedProvenanceBundle {
            let provenanceJSON = try provenanceBundle.encode()
            gltf["extras"] = [
                "provenanceBundle": String(data: provenanceJSON, encoding: .utf8) ?? ""
            ]
        }
        
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
    
    /// Create binary chunk with splat data
    private func createBinaryChunk(splatData: GaussianSplatData, options: GLTFGaussianSplattingExportOptions) throws -> Data {
        // In production, pack Gaussian splat data into binary chunk
        return Data()
    }
}

/// GLTF Gaussian Splatting Exporter Errors
public enum GLTFGaussianSplattingExporterError: Error, Sendable {
    case invalidSplatData(String)
    case encodingFailed(String)
    case validationFailed(String)
    case provenanceBundleError(ProvenanceBundleError)
    case unsupportedExtensionVersion(String)
    
    public var localizedDescription: String {
        switch self {
        case .invalidSplatData(let reason):
            return "Invalid splat data: \(reason)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        case .provenanceBundleError(let error):
            return "Provenance bundle error: \(error.localizedDescription)"
        case .unsupportedExtensionVersion(let version):
            return "Unsupported extension version: \(version)"
        }
    }
}

// Crypto imports handled in ProvenanceBundle
