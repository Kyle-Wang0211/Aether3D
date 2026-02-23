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
    private struct SplatBinaryLayout {
        let binaryChunk: Data
        let bufferViews: [[String: Any]]
        let accessors: [[String: Any]]
        let accessorMap: [String: Int]
        let splatCount: Int
    }
    
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
        let splatCount = try validate(splatData: splatData)

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

        let binaryLayout = try createBinaryChunk(
            splatData: splatData,
            options: options,
            splatCount: splatCount
        )
        
        // Generate GLB format with KHR_gaussian_splatting extension
        // Similar to GLTFExporter but with Gaussian splatting-specific structure
        var glbData = Data()
        
        // Header (12 bytes)
        glbData.append(contentsOf: "glTF".data(using: .utf8)!)
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }) // Version
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // Total length (placeholder)
        
        // JSON chunk with KHR_gaussian_splatting extension
        let jsonChunk = try createJSONChunk(
            binaryLayout: binaryLayout,
            provenanceBundle: provenanceBundle,
            options: options
        )
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(jsonChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "JSON".data(using: .utf8)!)
        glbData.append(jsonChunk)
        
        // Binary chunk with splat data
        let binaryChunk = binaryLayout.binaryChunk
        glbData.append(contentsOf: withUnsafeBytes(of: UInt32(binaryChunk.count).littleEndian) { Data($0) })
        glbData.append(contentsOf: "BIN\0".data(using: .utf8)!)
        glbData.append(binaryChunk)
        
        // Update total length
        let totalLength = UInt32(glbData.count)
        glbData.replaceSubrange(8..<12, with: withUnsafeBytes(of: totalLength.littleEndian) { Data($0) })
        
        return glbData
    }
    
    /// Create JSON chunk with KHR_gaussian_splatting extension
    private func createJSONChunk(
        binaryLayout: SplatBinaryLayout,
        provenanceBundle: ProvenanceBundle,
        options: GLTFGaussianSplattingExportOptions
    ) throws -> Data {
        var splatDescriptor: [String: Any] = [
            "count": binaryLayout.splatCount,
            "attributes": binaryLayout.accessorMap
        ]
        if let shAccessor = binaryLayout.accessorMap["SPHERICAL_HARMONICS"] {
            splatDescriptor["sphericalHarmonicsAccessor"] = shAccessor
        }

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
                        "splat": 0
                    ]
                ]
            ]],
            "accessors": binaryLayout.accessors,
            "bufferViews": binaryLayout.bufferViews,
            "buffers": [[
                "byteLength": binaryLayout.binaryChunk.count
            ]],
            "extensions": [
                "KHR_gaussian_splatting": [
                    "splats": [splatDescriptor]
                ]
            ]
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
    private func createBinaryChunk(
        splatData: GaussianSplatData,
        options: GLTFGaussianSplattingExportOptions,
        splatCount: Int
    ) throws -> SplatBinaryLayout {
        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var accessorMap: [String: Int] = [:]

        func appendAttribute(
            semantic: String,
            values: [Float],
            components: Int,
            includeMinMax: Bool = false
        ) {
            guard !values.isEmpty else { return }
            let offset = binary.count
            values.withUnsafeBytes { binary.append(contentsOf: $0) }
            let byteLength = binary.count - offset

            let bufferViewIndex = bufferViews.count
            bufferViews.append([
                "buffer": 0,
                "byteOffset": offset,
                "byteLength": byteLength,
                "target": 34962
            ])

            let accessorIndex = accessors.count
            var accessor: [String: Any] = [
                "bufferView": bufferViewIndex,
                "componentType": 5126,
                "count": components <= 4 ? splatCount : values.count,
                "type": gltfType(forComponentCount: components)
            ]
            if includeMinMax {
                let (minPos, maxPos) = bounds(values: values, components: components)
                accessor["min"] = minPos
                accessor["max"] = maxPos
            }
            accessors.append(accessor)
            accessorMap[semantic] = accessorIndex

            padTo4Bytes(&binary)
        }

        appendAttribute(
            semantic: "POSITION",
            values: splatData.positions,
            components: 3,
            includeMinMax: true
        )
        appendAttribute(
            semantic: "COLOR_0",
            values: splatData.colors,
            components: 3
        )
        appendAttribute(
            semantic: "OPACITY",
            values: splatData.opacities,
            components: 1
        )
        appendAttribute(
            semantic: "SCALE",
            values: splatData.scales,
            components: 3
        )
        appendAttribute(
            semantic: "ROTATION",
            values: splatData.rotations,
            components: 4
        )
        if let sh = splatData.sphericalHarmonics, !sh.isEmpty {
            let perSplatCount = splatCount == 0 ? 1 : max(1, sh.count / splatCount)
            appendAttribute(
                semantic: "SPHERICAL_HARMONICS",
                values: sh,
                components: perSplatCount
            )
        }

        return SplatBinaryLayout(
            binaryChunk: binary,
            bufferViews: bufferViews,
            accessors: accessors,
            accessorMap: accessorMap,
            splatCount: splatCount
        )
    }

    private func validate(splatData: GaussianSplatData) throws -> Int {
        guard splatData.positions.count % 3 == 0 else {
            throw GLTFGaussianSplattingExporterError.invalidSplatData("positions must contain xyz triplets")
        }
        let splatCount = splatData.positions.count / 3

        func validateCount(_ values: [Float], components: Int, name: String) throws {
            guard values.isEmpty || values.count == splatCount * components else {
                throw GLTFGaussianSplattingExporterError.invalidSplatData("\(name) count mismatch for splat count \(splatCount)")
            }
        }

        try validateCount(splatData.colors, components: 3, name: "colors")
        try validateCount(splatData.opacities, components: 1, name: "opacities")
        try validateCount(splatData.scales, components: 3, name: "scales")
        try validateCount(splatData.rotations, components: 4, name: "rotations")

        if let sh = splatData.sphericalHarmonics, !sh.isEmpty {
            guard splatCount > 0 else {
                throw GLTFGaussianSplattingExporterError.invalidSplatData("sphericalHarmonics requires non-empty positions")
            }
            guard sh.count % splatCount == 0 else {
                throw GLTFGaussianSplattingExporterError.invalidSplatData("sphericalHarmonics must be divisible by splat count")
            }
        }

        return splatCount
    }

    private func gltfType(forComponentCount components: Int) -> String {
        switch components {
        case 1:
            return "SCALAR"
        case 2:
            return "VEC2"
        case 3:
            return "VEC3"
        case 4:
            return "VEC4"
        default:
            // glTF has no VEC>4 type, so large SH payloads are exported as scalar streams.
            return "SCALAR"
        }
    }

    private func bounds(values: [Float], components: Int) -> (min: [Float], max: [Float]) {
        guard components > 0, !values.isEmpty else {
            return ([], [])
        }
        var minValues = Array(repeating: Float.greatestFiniteMagnitude, count: components)
        var maxValues = Array(repeating: -Float.greatestFiniteMagnitude, count: components)

        var index = 0
        while index + components - 1 < values.count {
            for component in 0..<components {
                let value = values[index + component]
                minValues[component] = min(minValues[component], value)
                maxValues[component] = max(maxValues[component], value)
            }
            index += components
        }
        return (minValues, maxValues)
    }

    private func padTo4Bytes(_ data: inout Data) {
        let padding = (4 - (data.count % 4)) % 4
        if padding > 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: padding))
        }
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
