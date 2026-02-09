// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ArtifactManifest.swift
//  progect2
//
//  Created for PR#10.5.9 Artifact Contract
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
typealias _SHA256 = CryptoKit.SHA256
#elseif canImport(Crypto)
import Crypto
typealias _SHA256 = Crypto.SHA256
#else
#error("No SHA256 implementation available. macOS/iOS: use CryptoKit. Linux: add swift-crypto dependency and import Crypto.")
#endif

// MARK: - Type Aliases

public typealias BuildMetaMap = [String: String]

// MARK: - Error Types

public enum ArtifactError: Error, Sendable {
    case unknownFields(keys: [String])
    case unsupportedSchemaVersion(Int, supported: Int)
    
    case stringContainsNullByte(field: String)
    case stringNotNFC(field: String)
    
    case invalidPolicyHash(String)
    case invalidSHA256(String)
    
    case invalidPath(String)
    case duplicatePath(String)
    
    case invalidBytes(Int)
    case invalidContentType(String)
    case invalidRole(String)
    
    case invalidUpAxis(String)
    case invalidUnitScale(Double)
    
    case emptyFiles
    case emptyLODs
    case missingLODEntryFile(String)
    case missingFallbackFile(String)
    case fallbackRoleMismatch(path: String, expectedRole: String)
    
    case other(reason: String)
}

// MARK: - DynamicCodingKey Helper

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - String Validation Helpers

internal func _validateString(_ s: String, field: String) throws {
    if s.contains("\u{0000}") {
        throw ArtifactError.stringContainsNullByte(field: field)
    }
    if s != s.precomposedStringWithCanonicalMapping {
        throw ArtifactError.stringNotNFC(field: field)
    }
}

internal func _validatePath(_ path: String) throws {
    try _validateString(path, field: "path")
    
    // ASCII only: bytes in 0x20...0x7E
    let asciiRange = 0x20...0x7E
    for byte in path.utf8 {
        if !asciiRange.contains(Int(byte)) {
            throw ArtifactError.invalidPath("Non-ASCII character in path: \(path)")
        }
    }
    
    // Must match regex: ^[A-Za-z0-9._/-]+$
    let validPattern = "^[A-Za-z0-9._/-]+$"
    if path.range(of: validPattern, options: .regularExpression) == nil {
        throw ArtifactError.invalidPath("Path does not match allowed pattern: \(path)")
    }
    
    // Must NOT contain: .., leading /, \, //, trailing /
    if path.contains("..") {
        throw ArtifactError.invalidPath("Path contains '..': \(path)")
    }
    if path.hasPrefix("/") {
        throw ArtifactError.invalidPath("Path has leading slash: \(path)")
    }
    if path.contains("\\") {
        throw ArtifactError.invalidPath("Path contains backslash: \(path)")
    }
    if path.contains("//") {
        throw ArtifactError.invalidPath("Path contains double slash: \(path)")
    }
    if path.hasSuffix("/") {
        throw ArtifactError.invalidPath("Path has trailing slash: \(path)")
    }
    
    // Max length: 512 bytes
    if path.utf8.count > 512 {
        throw ArtifactError.invalidPath("Path exceeds 512 bytes: \(path)")
    }
}

internal func _validateSHA256(_ hex: String) throws {
    if hex.count != 64 {
        throw ArtifactError.invalidSHA256("SHA256 must be exactly 64 hex characters, got \(hex.count)")
    }
    let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
    if hex.unicodeScalars.contains(where: { !hexChars.contains($0) }) {
        throw ArtifactError.invalidSHA256("SHA256 contains invalid characters (must be lowercase hex): \(hex)")
    }
}

internal func _hexLowercase(_ bytes: some Sequence<UInt8>) -> String {
    let hexChars: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var out = ""
    out.reserveCapacity(64)
    for b in bytes {
        out.append(hexChars[Int((b >> 4) & 0x0F)])
        out.append(hexChars[Int(b & 0x0F)])
    }
    return out
}

// MARK: - Content Type and Role Whitelists

let allowedContentTypes: Set<String> = [
    "application/octet-stream",
    "application/x-aether-splat",
    "application/x-aether-ply",
    "model/gltf-binary",
    "image/png",
    "image/jpeg",
    "video/mp4"
]

let allowedRoles: Set<String> = [
    "lod_entry",
    "asset",
    "thumbnail",
    "preview_video",
    "metadata"
]

// MARK: - CoordinateSystem

public struct CoordinateSystem: Codable, Sendable {
    public let upAxis: String
    public let unitScale: Double
    
    public init(upAxis: String, unitScale: Double) throws {
        try _validateString(upAxis, field: "upAxis")
        
        let allowedUpAxis = ["X", "-X", "Y", "-Y", "Z", "-Z"]
        if !allowedUpAxis.contains(upAxis) {
            throw ArtifactError.invalidUpAxis("Invalid upAxis: \(upAxis). Must be one of: \(allowedUpAxis.joined(separator: ", "))")
        }
        
        // GATE #9: unitScale validation
        if !unitScale.isFinite {
            throw ArtifactError.invalidUnitScale(unitScale)
        }
        if unitScale.isNaN {
            throw ArtifactError.invalidUnitScale(unitScale)
        }
        if unitScale.isInfinite {
            throw ArtifactError.invalidUnitScale(unitScale)
        }
        if unitScale <= 0 {
            throw ArtifactError.invalidUnitScale(unitScale)
        }
        if unitScale < 0.001 || unitScale > 1000.0 {
            throw ArtifactError.invalidUnitScale(unitScale)
        }
        
        self.upAxis = upAxis
        self.unitScale = unitScale
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allKeys = container.allKeys
        let knownKeys = Set(["upAxis", "unitScale"])
        let unknownKeys = allKeys.filter { !knownKeys.contains($0.stringValue) }
        if !unknownKeys.isEmpty {
            throw ArtifactError.unknownFields(keys: unknownKeys.map { $0.stringValue })
        }
        
        let upAxisValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "upAxis")!)
        let unitScaleValue = try container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "unitScale")!)
        
        try _validateString(upAxisValue, field: "upAxis")
        
        let allowedUpAxis = ["X", "-X", "Y", "-Y", "Z", "-Z"]
        if !allowedUpAxis.contains(upAxisValue) {
            throw ArtifactError.invalidUpAxis("Invalid upAxis: \(upAxisValue)")
        }
        
        // GATE #9: unitScale validation
        if !unitScaleValue.isFinite {
            throw ArtifactError.invalidUnitScale(unitScaleValue)
        }
        if unitScaleValue.isNaN {
            throw ArtifactError.invalidUnitScale(unitScaleValue)
        }
        if unitScaleValue.isInfinite {
            throw ArtifactError.invalidUnitScale(unitScaleValue)
        }
        if unitScaleValue <= 0 {
            throw ArtifactError.invalidUnitScale(unitScaleValue)
        }
        if unitScaleValue < 0.001 || unitScaleValue > 1000.0 {
            throw ArtifactError.invalidUnitScale(unitScaleValue)
        }
        
        self.upAxis = upAxisValue
        self.unitScale = unitScaleValue
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upAxis, forKey: .upAxis)
        try container.encode(unitScale, forKey: .unitScale)
    }
    
    enum CodingKeys: String, CodingKey {
        case upAxis
        case unitScale
    }
}

// MARK: - LODDescriptor

public struct LODDescriptor: Codable, Sendable {
    public let lodId: String
    public let qualityTier: String
    public let approxSplatCount: Int
    public let entryFile: String
    
    public init(lodId: String, qualityTier: String, approxSplatCount: Int, entryFile: String) throws {
        try _validateString(lodId, field: "lodId")
        try _validateString(qualityTier, field: "qualityTier")
        try _validateString(entryFile, field: "entryFile")
        
        let allowedTiers = ["low", "medium", "high"]
        if !allowedTiers.contains(qualityTier) {
            throw ArtifactError.other(reason: "Invalid qualityTier: \(qualityTier). Must be one of: \(allowedTiers.joined(separator: ", "))")
        }
        
        if approxSplatCount <= 0 {
            throw ArtifactError.other(reason: "approxSplatCount must be > 0, got \(approxSplatCount)")
        }
        
        self.lodId = lodId
        self.qualityTier = qualityTier
        self.approxSplatCount = approxSplatCount
        self.entryFile = entryFile
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allKeys = container.allKeys
        let knownKeys = Set(["lodId", "qualityTier", "approxSplatCount", "entryFile"])
        let unknownKeys = allKeys.filter { !knownKeys.contains($0.stringValue) }
        if !unknownKeys.isEmpty {
            throw ArtifactError.unknownFields(keys: unknownKeys.map { $0.stringValue })
        }
        
        let lodIdValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "lodId")!)
        let qualityTierValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "qualityTier")!)
        let approxSplatCountValue = try container.decode(Int.self, forKey: DynamicCodingKey(stringValue: "approxSplatCount")!)
        let entryFileValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "entryFile")!)
        
        try _validateString(lodIdValue, field: "lodId")
        try _validateString(qualityTierValue, field: "qualityTier")
        try _validateString(entryFileValue, field: "entryFile")
        
        let allowedTiers = ["low", "medium", "high"]
        if !allowedTiers.contains(qualityTierValue) {
            throw ArtifactError.other(reason: "Invalid qualityTier: \(qualityTierValue)")
        }
        
        if approxSplatCountValue <= 0 {
            throw ArtifactError.other(reason: "approxSplatCount must be > 0")
        }
        
        self.lodId = lodIdValue
        self.qualityTier = qualityTierValue
        self.approxSplatCount = approxSplatCountValue
        self.entryFile = entryFileValue
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lodId, forKey: .lodId)
        try container.encode(qualityTier, forKey: .qualityTier)
        try container.encode(approxSplatCount, forKey: .approxSplatCount)
        try container.encode(entryFile, forKey: .entryFile)
    }
    
    enum CodingKeys: String, CodingKey {
        case lodId
        case qualityTier
        case approxSplatCount
        case entryFile
    }
}

// MARK: - FileDescriptor

public struct FileDescriptor: Codable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let contentType: String
    public let role: String
    
    public init(path: String, sha256: String, bytes: Int, contentType: String, role: String) throws {
        try _validatePath(path)
        try _validateSHA256(sha256)
        try _validateString(contentType, field: "contentType")
        try _validateString(role, field: "role")
        
        if bytes < 1 || bytes > 5_000_000_000 {
            throw ArtifactError.invalidBytes(bytes)
        }
        
        if !allowedContentTypes.contains(contentType) {
            throw ArtifactError.invalidContentType("Invalid contentType: \(contentType)")
        }
        
        if !allowedRoles.contains(role) {
            throw ArtifactError.invalidRole("Invalid role: \(role)")
        }
        
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.contentType = contentType
        self.role = role
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allKeys = container.allKeys
        let knownKeys = Set(["path", "sha256", "bytes", "contentType", "role"])
        let unknownKeys = allKeys.filter { !knownKeys.contains($0.stringValue) }
        if !unknownKeys.isEmpty {
            throw ArtifactError.unknownFields(keys: unknownKeys.map { $0.stringValue })
        }
        
        let pathValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "path")!)
        let sha256Value = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "sha256")!)
        let bytesValue = try container.decode(Int.self, forKey: DynamicCodingKey(stringValue: "bytes")!)
        let contentTypeValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "contentType")!)
        let roleValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "role")!)
        
        try _validatePath(pathValue)
        try _validateSHA256(sha256Value)
        try _validateString(contentTypeValue, field: "contentType")
        try _validateString(roleValue, field: "role")
        
        if bytesValue < 1 || bytesValue > 5_000_000_000 {
            throw ArtifactError.invalidBytes(bytesValue)
        }
        
        if !allowedContentTypes.contains(contentTypeValue) {
            throw ArtifactError.invalidContentType("Invalid contentType: \(contentTypeValue)")
        }
        
        if !allowedRoles.contains(roleValue) {
            throw ArtifactError.invalidRole("Invalid role: \(roleValue)")
        }
        
        self.path = pathValue
        self.sha256 = sha256Value
        self.bytes = bytesValue
        self.contentType = contentTypeValue
        self.role = roleValue
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(role, forKey: .role)
    }
    
    enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case bytes
        case contentType
        case role
    }
}

// MARK: - Fallbacks

public struct Fallbacks: Codable, Sendable {
    public let thumbnail: String?
    public let previewVideo: String?
    
    public init(thumbnail: String?, previewVideo: String?) throws {
        if let thumb = thumbnail {
            try _validateString(thumb, field: "fallbacks.thumbnail")
        }
        if let video = previewVideo {
            try _validateString(video, field: "fallbacks.previewVideo")
        }
        
        self.thumbnail = thumbnail
        self.previewVideo = previewVideo
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allKeys = container.allKeys
        let knownKeys = Set(["thumbnail", "previewVideo"])
        let unknownKeys = allKeys.filter { !knownKeys.contains($0.stringValue) }
        if !unknownKeys.isEmpty {
            throw ArtifactError.unknownFields(keys: unknownKeys.map { $0.stringValue })
        }
        
        let thumbnailValue = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "thumbnail")!)
        let previewVideoValue = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "previewVideo")!)
        
        if let thumb = thumbnailValue {
            try _validateString(thumb, field: "fallbacks.thumbnail")
        }
        if let video = previewVideoValue {
            try _validateString(video, field: "fallbacks.previewVideo")
        }
        
        self.thumbnail = thumbnailValue
        self.previewVideo = previewVideoValue
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // GATE #10: Only encode present fields, no null keys
        if let thumb = thumbnail {
            try container.encode(thumb, forKey: .thumbnail)
        }
        if let video = previewVideo {
            try container.encode(video, forKey: .previewVideo)
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case thumbnail
        case previewVideo
    }
}

// MARK: - Canonical JSON Encoding (Pure Swift, No JSONEncoder)

internal func _encodeJSONString(_ s: String) -> String {
    var result = "\""
    for char in s {
        switch char {
        case "\\":
            result += "\\\\"
        case "\"":
            result += "\\\""
        case "\u{0000}"..."\u{001F}":
            // Pure Swift hex encoding (no String(format:))
            let code = char.unicodeScalars.first!.value
            let hexChars: [Character] = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]
            result += "\\u"
            result.append(hexChars[Int((code >> 12) & 0x0F)])
            result.append(hexChars[Int((code >> 8) & 0x0F)])
            result.append(hexChars[Int((code >> 4) & 0x0F)])
            result.append(hexChars[Int(code & 0x0F)])
        default:
            result.append(char)
        }
    }
    result += "\""
    return result
}

internal func _encodeUnitScale(_ value: Double) -> String {
    // SEAL FIX #1: Fixed-point Int64 (1e9) + pure Swift decimal string builder
    // NO String(format:), NO NumberFormatter
    let scaled = Int64((value * 1_000_000_000).rounded())
    let intPart = scaled / 1_000_000_000
    let fracPart = abs(scaled % 1_000_000_000)
    
    if fracPart == 0 {
        return String(intPart)
    }
    
    // Format fracPart as 9 digits with leading zeros
    var fracStr = String(fracPart)
    while fracStr.count < 9 {
        fracStr = "0" + fracStr
    }
    
    // Trim trailing zeros
    while fracStr.hasSuffix("0") {
        fracStr.removeLast()
    }
    
    return String(intPart) + "." + fracStr
}

// MARK: - ArtifactManifest

public struct ArtifactManifest: Codable, Sendable {
    // SEALED: Domain separation prefix for artifact hashing
    // Prefix: "aether.artifact.manifest.v1\0" (ASCII bytes including NUL terminator 0x00)
    // Used for both artifactHash and artifactId computation
    private static let domainSeparationPrefix = "aether.artifact.manifest.v1\0"
    
    public let schemaVersion: Int
    public let artifactId: String
    public let buildMeta: BuildMetaMap
    public let coordinateSystem: CoordinateSystem
    public let lods: [LODDescriptor]
    public let files: [FileDescriptor]
    public let fallbacks: Fallbacks?
    public let policyHash: String
    public let artifactHash: String
    
    public init(
        buildMeta: BuildMetaMap,
        coordinateSystem: CoordinateSystem,
        lods: [LODDescriptor],
        files: [FileDescriptor],
        fallbacks: Fallbacks?,
        policyHash: String
    ) throws {
        // Validate inputs
        if files.isEmpty {
            throw ArtifactError.emptyFiles
        }
        if lods.isEmpty {
            throw ArtifactError.emptyLODs
        }
        
        // Validate policyHash
        try _validateSHA256(policyHash)
        
        // Validate buildMeta keys and values
        for (key, value) in buildMeta {
            try _validateString(key, field: "buildMeta.key")
            try _validateString(value, field: "buildMeta.value")
        }
        
        // Validate LOD entry files exist
        for lod in lods {
            if !files.contains(where: { $0.path == lod.entryFile }) {
                throw ArtifactError.missingLODEntryFile(lod.entryFile)
            }
        }
        
        // Validate path uniqueness (case-insensitive)
        var pathSet = Set<String>()
        for file in files {
            let normalized = file.path.lowercased()
            if pathSet.contains(normalized) {
                throw ArtifactError.duplicatePath(file.path)
            }
            pathSet.insert(normalized)
        }
        
        // Validate fallbacks
        if let fb = fallbacks {
            if let thumb = fb.thumbnail {
                guard let thumbFile = files.first(where: { $0.path == thumb }) else {
                    throw ArtifactError.missingFallbackFile(thumb)
                }
                if thumbFile.role != "thumbnail" {
                    throw ArtifactError.fallbackRoleMismatch(path: thumb, expectedRole: "thumbnail")
                }
            }
            if let video = fb.previewVideo {
                guard let videoFile = files.first(where: { $0.path == video }) else {
                    throw ArtifactError.missingFallbackFile(video)
                }
                if videoFile.role != "preview_video" {
                    throw ArtifactError.fallbackRoleMismatch(path: video, expectedRole: "preview_video")
                }
            }
        }
        
        self.schemaVersion = 1
        self.buildMeta = buildMeta
        self.coordinateSystem = coordinateSystem
        self.lods = lods
        self.files = files
        self.fallbacks = fallbacks
        self.policyHash = policyHash
        
        // Compute artifactId and canonical bytes for hashing
        let (computedArtifactId, canonicalBytes) = try Self._computeArtifactIdAndCanonicalBytes(
            schemaVersion: 1,
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: lods,
            files: files,
            fallbacks: fallbacks,
            policyHash: policyHash
        )
        
        self.artifactId = computedArtifactId
        
        // Compute artifactHash (SHA256(prefix + canonicalBytes))
        let hash = _SHA256.hash(data: Self.domainSeparationPrefix.data(using: .ascii)! + canonicalBytes)
        self.artifactHash = _hexLowercase(hash)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allKeys = container.allKeys
        let knownKeys = Set(["schemaVersion", "artifactId", "buildMeta", "coordinateSystem", "lods", "files", "fallbacks", "policyHash", "artifactHash"])
        let unknownKeys = allKeys.filter { !knownKeys.contains($0.stringValue) }
        if !unknownKeys.isEmpty {
            throw ArtifactError.unknownFields(keys: unknownKeys.map { $0.stringValue })
        }
        
        let schemaVersionValue = try container.decode(Int.self, forKey: DynamicCodingKey(stringValue: "schemaVersion")!)
        if schemaVersionValue != 1 {
            throw ArtifactError.unsupportedSchemaVersion(schemaVersionValue, supported: 1)
        }
        
        let artifactIdValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "artifactId")!)
        let buildMetaValue = try container.decode(BuildMetaMap.self, forKey: DynamicCodingKey(stringValue: "buildMeta")!)
        let coordinateSystemValue = try container.decode(CoordinateSystem.self, forKey: DynamicCodingKey(stringValue: "coordinateSystem")!)
        let lodsValue = try container.decode([LODDescriptor].self, forKey: DynamicCodingKey(stringValue: "lods")!)
        let filesValue = try container.decode([FileDescriptor].self, forKey: DynamicCodingKey(stringValue: "files")!)
        let fallbacksValue = try container.decodeIfPresent(Fallbacks.self, forKey: DynamicCodingKey(stringValue: "fallbacks")!)
        let policyHashValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "policyHash")!)
        let artifactHashValue = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "artifactHash")!)
        
        // Validate policyHash
        try _validateSHA256(policyHashValue)
        try _validateSHA256(artifactHashValue)
        
        // Validate buildMeta keys and values
        for (key, value) in buildMetaValue {
            try _validateString(key, field: "buildMeta.key")
            try _validateString(value, field: "buildMeta.value")
        }
        
        // Validate LOD entry files exist
        for lod in lodsValue {
            if !filesValue.contains(where: { $0.path == lod.entryFile }) {
                throw ArtifactError.missingLODEntryFile(lod.entryFile)
            }
        }
        
        // Validate path uniqueness (case-insensitive)
        var pathSet = Set<String>()
        for file in filesValue {
            let normalized = file.path.lowercased()
            if pathSet.contains(normalized) {
                throw ArtifactError.duplicatePath(file.path)
            }
            pathSet.insert(normalized)
        }
        
        // Validate fallbacks
        if let fb = fallbacksValue {
            if let thumb = fb.thumbnail {
                guard let thumbFile = filesValue.first(where: { $0.path == thumb }) else {
                    throw ArtifactError.missingFallbackFile(thumb)
                }
                if thumbFile.role != "thumbnail" {
                    throw ArtifactError.fallbackRoleMismatch(path: thumb, expectedRole: "thumbnail")
                }
            }
            if let video = fb.previewVideo {
                guard let videoFile = filesValue.first(where: { $0.path == video }) else {
                    throw ArtifactError.missingFallbackFile(video)
                }
                if videoFile.role != "preview_video" {
                    throw ArtifactError.fallbackRoleMismatch(path: video, expectedRole: "preview_video")
                }
            }
        }
        
        self.schemaVersion = schemaVersionValue
        self.artifactId = artifactIdValue
        self.buildMeta = buildMetaValue
        self.coordinateSystem = coordinateSystemValue
        self.lods = lodsValue
        self.files = filesValue
        self.fallbacks = fallbacksValue
        self.policyHash = policyHashValue
        self.artifactHash = artifactHashValue
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(artifactId, forKey: .artifactId)
        // SEAL FIX #6: buildMeta always present, even if empty
        try container.encode(buildMeta, forKey: .buildMeta)
        try container.encode(coordinateSystem, forKey: .coordinateSystem)
        try container.encode(lods, forKey: .lods)
        try container.encode(files, forKey: .files)
        // SEAL FIX #7 / GATE #10: fallbacks nil omits key, present includes key
        if let fb = fallbacks {
            try container.encode(fb, forKey: .fallbacks)
        }
        try container.encode(policyHash, forKey: .policyHash)
        try container.encode(artifactHash, forKey: .artifactHash)
    }
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case artifactId
        case buildMeta
        case coordinateSystem
        case lods
        case files
        case fallbacks
        case policyHash
        case artifactHash
    }
    
    // MARK: - Canonical Encoding
    
    internal func canonicalBytesForHashing() throws -> Data {
        return try Self._canonicalBytesForHashing(
            schemaVersion: schemaVersion,
            artifactId: artifactId,
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: lods,
            files: files,
            fallbacks: fallbacks,
            policyHash: policyHash
        )
    }
    
    internal func canonicalBytesForStorage() throws -> Data {
        // Full manifest including artifactHash
        // Note: Storage encoding doesn't require sorting, but we use the same encoding helpers
        // for consistency. The spec says storage order is irrelevant; canonical bytes must sort.
        var result = Data()
        
        // Field order: schemaVersion, artifactId, buildMeta, coordinateSystem, lods, files, fallbacks?, policyHash, artifactHash
        result.append("{\"schemaVersion\":".data(using: .utf8)!)
        result.append(String(schemaVersion).data(using: .utf8)!)
        result.append(",\"artifactId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(artifactId).data(using: .utf8)!)
        result.append(",\"buildMeta\":".data(using: .utf8)!)
        result.append(try Self._encodeBuildMeta(buildMeta))
        result.append(",\"coordinateSystem\":".data(using: .utf8)!)
        result.append(try Self._encodeCoordinateSystem(coordinateSystem))
        result.append(",\"lods\":".data(using: .utf8)!)
        // Storage encoding: use original order (not sorted)
        result.append(try Self._encodeLODs(lods))
        result.append(",\"files\":".data(using: .utf8)!)
        // Storage encoding: use original order (not sorted)
        result.append(try Self._encodeFiles(files))
        if let fb = fallbacks {
            result.append(",\"fallbacks\":".data(using: .utf8)!)
            result.append(try Self._encodeFallbacks(fb))
        }
        result.append(",\"policyHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        result.append(",\"artifactHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(artifactHash).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        
        return result
    }
    
    private static func _computeArtifactIdAndCanonicalBytes(
        schemaVersion: Int,
        buildMeta: BuildMetaMap,
        coordinateSystem: CoordinateSystem,
        lods: [LODDescriptor],
        files: [FileDescriptor],
        fallbacks: Fallbacks?,
        policyHash: String
    ) throws -> (artifactId: String, canonicalBytes: Data) {
        // SEAL FIX #2: Sort arrays before encoding
        let sortedLODs = lods.sorted { $0.lodId.utf8.lexicographicallyPrecedes($1.lodId.utf8) }
        let sortedFiles = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        
        // Step 1: Compute temporary canonical bytes WITHOUT artifactId
        var tempBytes = Data()
        tempBytes.append("{\"schemaVersion\":".data(using: .utf8)!)
        tempBytes.append(String(schemaVersion).data(using: .utf8)!)
        tempBytes.append(",\"buildMeta\":".data(using: .utf8)!)
        tempBytes.append(try _encodeBuildMeta(buildMeta))
        tempBytes.append(",\"coordinateSystem\":".data(using: .utf8)!)
        tempBytes.append(try _encodeCoordinateSystem(coordinateSystem))
        tempBytes.append(",\"lods\":".data(using: .utf8)!)
        tempBytes.append(try _encodeLODs(sortedLODs))
        tempBytes.append(",\"files\":".data(using: .utf8)!)
        tempBytes.append(try _encodeFiles(sortedFiles))
        if let fb = fallbacks {
            tempBytes.append(",\"fallbacks\":".data(using: .utf8)!)
            tempBytes.append(try _encodeFallbacks(fb))
        }
        tempBytes.append(",\"policyHash\":".data(using: .utf8)!)
        tempBytes.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        tempBytes.append("}".data(using: .utf8)!)
        
        // Step 2: Compute artifactId from tempBytes (SEAL FIX #5: uses same prefix)
        let artifactIdHash = _SHA256.hash(data: Self.domainSeparationPrefix.data(using: .ascii)! + tempBytes)
        let artifactId = String(_hexLowercase(artifactIdHash).prefix(32))
        
        // Step 3: Compute final canonical bytes WITH artifactId (but without artifactHash)
        var canonicalBytes = Data()
        canonicalBytes.append("{\"schemaVersion\":".data(using: .utf8)!)
        canonicalBytes.append(String(schemaVersion).data(using: .utf8)!)
        canonicalBytes.append(",\"artifactId\":".data(using: .utf8)!)
        canonicalBytes.append(_encodeJSONString(artifactId).data(using: .utf8)!)
        canonicalBytes.append(",\"buildMeta\":".data(using: .utf8)!)
        canonicalBytes.append(try _encodeBuildMeta(buildMeta))
        canonicalBytes.append(",\"coordinateSystem\":".data(using: .utf8)!)
        canonicalBytes.append(try _encodeCoordinateSystem(coordinateSystem))
        canonicalBytes.append(",\"lods\":".data(using: .utf8)!)
        canonicalBytes.append(try _encodeLODs(sortedLODs))
        canonicalBytes.append(",\"files\":".data(using: .utf8)!)
        canonicalBytes.append(try _encodeFiles(sortedFiles))
        if let fb = fallbacks {
            canonicalBytes.append(",\"fallbacks\":".data(using: .utf8)!)
            canonicalBytes.append(try _encodeFallbacks(fb))
        }
        canonicalBytes.append(",\"policyHash\":".data(using: .utf8)!)
        canonicalBytes.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        canonicalBytes.append("}".data(using: .utf8)!)
        
        return (artifactId, canonicalBytes)
    }
    
    private static func _canonicalBytesForHashing(
        schemaVersion: Int,
        artifactId: String,
        buildMeta: BuildMetaMap,
        coordinateSystem: CoordinateSystem,
        lods: [LODDescriptor],
        files: [FileDescriptor],
        fallbacks: Fallbacks?,
        policyHash: String
    ) throws -> Data {
        // SEAL FIX #2: Sort arrays before encoding
        let sortedLODs = lods.sorted { $0.lodId.utf8.lexicographicallyPrecedes($1.lodId.utf8) }
        let sortedFiles = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        
        var result = Data()
        
        // Field order: schemaVersion, artifactId, buildMeta, coordinateSystem, lods, files, fallbacks?, policyHash
        // NOTE: artifactHash is EXCLUDED from canonical bytes for hashing
        result.append("{\"schemaVersion\":".data(using: .utf8)!)
        result.append(String(schemaVersion).data(using: .utf8)!)
        result.append(",\"artifactId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(artifactId).data(using: .utf8)!)
        result.append(",\"buildMeta\":".data(using: .utf8)!)
        result.append(try _encodeBuildMeta(buildMeta))
        result.append(",\"coordinateSystem\":".data(using: .utf8)!)
        result.append(try _encodeCoordinateSystem(coordinateSystem))
        result.append(",\"lods\":".data(using: .utf8)!)
        result.append(try _encodeLODs(sortedLODs))
        result.append(",\"files\":".data(using: .utf8)!)
        result.append(try _encodeFiles(sortedFiles))
        if let fb = fallbacks {
            result.append(",\"fallbacks\":".data(using: .utf8)!)
            result.append(try _encodeFallbacks(fb))
        }
        result.append(",\"policyHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        
        return result
    }
    
    // Helper encoding functions
    
    private static func _encodeBuildMeta(_ meta: BuildMetaMap) throws -> Data {
        // Sort keys by Unicode scalar lexicographic
        let sortedKeys = meta.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        var result = Data()
        result.append("{".data(using: .utf8)!)
        var first = true
        for key in sortedKeys {
            if !first {
                result.append(",".data(using: .utf8)!)
            }
            first = false
            result.append(_encodeJSONString(key).data(using: .utf8)!)
            result.append(":".data(using: .utf8)!)
            result.append(_encodeJSONString(meta[key]!).data(using: .utf8)!)
        }
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeCoordinateSystem(_ cs: CoordinateSystem) throws -> Data {
        var result = Data()
        result.append("{\"upAxis\":".data(using: .utf8)!)
        result.append(_encodeJSONString(cs.upAxis).data(using: .utf8)!)
        result.append(",\"unitScale\":".data(using: .utf8)!)
        result.append(_encodeUnitScale(cs.unitScale).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeLODs(_ lods: [LODDescriptor]) throws -> Data {
        var result = Data()
        result.append("[".data(using: .utf8)!)
        var first = true
        for lod in lods {
            if !first {
                result.append(",".data(using: .utf8)!)
            }
            first = false
            result.append("{".data(using: .utf8)!)
            result.append("\"lodId\":".data(using: .utf8)!)
            result.append(_encodeJSONString(lod.lodId).data(using: .utf8)!)
            result.append(",\"qualityTier\":".data(using: .utf8)!)
            result.append(_encodeJSONString(lod.qualityTier).data(using: .utf8)!)
            result.append(",\"approxSplatCount\":".data(using: .utf8)!)
            result.append(String(lod.approxSplatCount).data(using: .utf8)!)
            result.append(",\"entryFile\":".data(using: .utf8)!)
            result.append(_encodeJSONString(lod.entryFile).data(using: .utf8)!)
            result.append("}".data(using: .utf8)!)
        }
        result.append("]".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeFiles(_ files: [FileDescriptor]) throws -> Data {
        var result = Data()
        result.append("[".data(using: .utf8)!)
        var first = true
        for file in files {
            if !first {
                result.append(",".data(using: .utf8)!)
            }
            first = false
            result.append("{".data(using: .utf8)!)
            result.append("\"path\":".data(using: .utf8)!)
            result.append(_encodeJSONString(file.path).data(using: .utf8)!)
            result.append(",\"sha256\":".data(using: .utf8)!)
            result.append(_encodeJSONString(file.sha256).data(using: .utf8)!)
            result.append(",\"bytes\":".data(using: .utf8)!)
            result.append(String(file.bytes).data(using: .utf8)!)
            result.append(",\"contentType\":".data(using: .utf8)!)
            result.append(_encodeJSONString(file.contentType).data(using: .utf8)!)
            result.append(",\"role\":".data(using: .utf8)!)
            result.append(_encodeJSONString(file.role).data(using: .utf8)!)
            result.append("}".data(using: .utf8)!)
        }
        result.append("]".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeFallbacks(_ fb: Fallbacks) throws -> Data {
        // GATE #10: Only encode present fields, no null keys
        var result = Data()
        result.append("{".data(using: .utf8)!)
        var parts: [Data] = []
        if let thumb = fb.thumbnail {
            var thumbData = Data()
            thumbData.append("\"thumbnail\":".data(using: .utf8)!)
            thumbData.append(_encodeJSONString(thumb).data(using: .utf8)!)
            parts.append(thumbData)
        }
        if let video = fb.previewVideo {
            var videoData = Data()
            videoData.append("\"previewVideo\":".data(using: .utf8)!)
            videoData.append(_encodeJSONString(video).data(using: .utf8)!)
            parts.append(videoData)
        }
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(",".data(using: .utf8)!)
            }
            result.append(part)
        }
        result.append("}".data(using: .utf8)!)
        return result
    }
}

// MARK: - Whitebox Artifact Manifest (PR#13)

public struct WhiteboxFileDescriptor: Codable, Equatable, Sendable {
    public let bytes: Int
    public let path: String
    public let sha256: String
    
    public init(bytes: Int, path: String, sha256: String) {
        self.bytes = bytes
        self.path = path
        self.sha256 = sha256
    }
}

public struct WhiteboxArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifactId: String
    public let policyHash: String
    public let artifactHash: String
    public let files: [WhiteboxFileDescriptor]
    
    public init(
        schemaVersion: Int,
        artifactId: String,
        policyHash: String,
        artifactHash: String,
        files: [WhiteboxFileDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.artifactId = artifactId
        self.policyHash = policyHash
        self.artifactHash = artifactHash
        self.files = files
    }
}

// MARK: - PolicyHash Bridge (PR#13)

public func getCurrentPolicyHash() -> String {
    return GOLDEN_POLICY_HASH
}

// MARK: - Artifact Hash Computation (PR#13)

public func computeArtifactHash(
    policyHash: String,
    schemaVersion: Int,
    files: [WhiteboxFileDescriptor]
) -> String {
    var data = Data()
    
    data.append("A3D_ARTIFACT_V1\n".data(using: .utf8)!)
    data.append((policyHash + "\n").data(using: .utf8)!)
    data.append("\(schemaVersion)\n".data(using: .utf8)!)
    data.append("\(files.count)\n".data(using: .utf8)!)
    
    for file in files.sorted(by: { $0.path < $1.path }) {
        data.append((file.path + "\n").data(using: .utf8)!)
        data.append((file.sha256 + "\n").data(using: .utf8)!)
    }
    
    let hash = _SHA256.hash(data: data)
    return _hexLowercase(hash)
}

// MARK: - Canonical Encoder (PR#13)

public struct CanonicalEncoder {
    public static func encode(_ manifest: WhiteboxArtifactManifest) -> Data {
        var json = "{"
        
        json += "\"artifactHash\":\"\(escape(manifest.artifactHash))\","
        json += "\"artifactId\":\"\(escape(manifest.artifactId))\","
        json += "\"files\":["
        
        let sorted = manifest.files.sorted { $0.path < $1.path }
        for (i, file) in sorted.enumerated() {
            if i > 0 { json += "," }
            json += "{\"bytes\":\(file.bytes),"
            json += "\"path\":\"\(escape(file.path))\","
            json += "\"sha256\":\"\(escape(file.sha256))\"}"
        }
        
        json += "],"
        json += "\"policyHash\":\"\(escape(manifest.policyHash))\","
        json += "\"schemaVersion\":\(manifest.schemaVersion)"
        json += "}\n"
        
        return json.data(using: .utf8)!
    }
    
    private static func escape(_ s: String) -> String {
        var r = ""
        for c in s {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if let ascii = c.asciiValue, ascii < 32 {
                    let hexChars: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
                    r += "\\u"
                    r.append(hexChars[Int((ascii >> 12) & 0x0F)])
                    r.append(hexChars[Int((ascii >> 8) & 0x0F)])
                    r.append(hexChars[Int((ascii >> 4) & 0x0F)])
                    r.append(hexChars[Int(ascii & 0x0F)])
                } else {
                    r.append(c)
                }
            }
        }
        return r
    }
}

// MARK: - Validation Errors (PR#13)

public enum WhiteboxArtifactError: Error, Equatable {
    case missingManifest
    case invalidSchemaVersion(Int)
    case invalidArtifactId(expected: String, actual: String)
    case invalidHash(field: String, value: String, reason: String)
    case invalidPath(String, reason: String)
    case missingFile(String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case hashMismatch(path: String, expected: String, actual: String)
    case unreferencedFile(String)
    case symlinkNotAllowed(String)
    case hiddenFileFound(String)
    case duplicatePath(String)
    case filesNotSorted
    case filesEmpty
}

// MARK: - Validation Functions (PR#13)

private func validateHex64(_ value: String, field: String) throws {
    guard value.count == 64 else {
        throw WhiteboxArtifactError.invalidHash(field: field, value: value, reason: "length != 64")
    }
    guard value.allSatisfy({ $0.isHexDigit }) else {
        throw WhiteboxArtifactError.invalidHash(field: field, value: value, reason: "non-hex character")
    }
    guard value == value.lowercased() else {
        throw WhiteboxArtifactError.invalidHash(field: field, value: value, reason: "not lowercase")
    }
}

private func findDuplicate(_ paths: [String]) -> String? {
    var seen = Set<String>()
    for path in paths {
        if seen.contains(path) {
            return path
        }
        seen.insert(path)
    }
    return nil
}

public func validateManifest(_ m: WhiteboxArtifactManifest) throws {
    guard m.schemaVersion == 1 else {
        throw WhiteboxArtifactError.invalidSchemaVersion(m.schemaVersion)
    }
    
    let expectedId = String(m.artifactHash.prefix(8))
    guard m.artifactId == expectedId, m.artifactId.count == 8 else {
        throw WhiteboxArtifactError.invalidArtifactId(expected: expectedId, actual: m.artifactId)
    }
    
    try validateHex64(m.policyHash, field: "policyHash")
    try validateHex64(m.artifactHash, field: "artifactHash")
    
    guard !m.files.isEmpty else {
        throw WhiteboxArtifactError.filesEmpty
    }
    
    let paths = m.files.map { $0.path }
    guard paths == paths.sorted() else {
        throw WhiteboxArtifactError.filesNotSorted
    }
    
    if let dup = findDuplicate(paths) {
        throw WhiteboxArtifactError.duplicatePath(dup)
    }
    
    for file in m.files {
        guard file.path.hasPrefix("artifacts/") else {
            throw WhiteboxArtifactError.invalidPath(file.path, reason: "must start with artifacts/")
        }
        guard !file.path.contains("..") else {
            throw WhiteboxArtifactError.invalidPath(file.path, reason: "contains ..")
        }
        guard !file.path.contains("\\") else {
            throw WhiteboxArtifactError.invalidPath(file.path, reason: "contains backslash")
        }
        guard file.path.allSatisfy({ ($0.asciiValue ?? 0) >= 32 }) else {
            throw WhiteboxArtifactError.invalidPath(file.path, reason: "contains control character")
        }
        guard !file.path.contains("//"), !file.path.hasSuffix("/") else {
            throw WhiteboxArtifactError.invalidPath(file.path, reason: "invalid path format")
        }
        guard file.bytes > 0 else {
            throw WhiteboxArtifactError.sizeMismatch(path: file.path, expected: 1, actual: file.bytes)
        }
        try validateHex64(file.sha256, field: "sha256 of \(file.path)")
    }
}

private func relativePath(_ url: URL, to root: URL) -> String {
    let rootStd = root.resolvingSymlinksInPath()
    let urlStd = url.resolvingSymlinksInPath()
    var rel = urlStd.path.replacingOccurrences(of: rootStd.path + "/", with: "")
    if rel.hasPrefix("/") {
        rel.removeFirst()
    }
    return rel
}

public func validatePackage(at root: URL, manifest: WhiteboxArtifactManifest) throws {
    let fm = FileManager.default
    
    let manifestURL = root.appendingPathComponent("manifest.json")
    guard fm.fileExists(atPath: manifestURL.path) else {
        throw WhiteboxArtifactError.missingManifest
    }
    
    var allFiles: [String] = []
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else {
        throw WhiteboxArtifactError.missingManifest
    }
    
    while let url = enumerator.nextObject() as? URL {
        let rv = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        
        if rv.isSymbolicLink == true {
            let rel = relativePath(url, to: root)
            throw WhiteboxArtifactError.symlinkNotAllowed(rel)
        }
        
        if rv.isRegularFile == true {
            let rel = relativePath(url, to: root)
            let name = url.lastPathComponent
            
            if name.hasPrefix(".") || name.hasPrefix("._") {
                throw WhiteboxArtifactError.hiddenFileFound(rel)
            }
            if name == "__MACOSX" || name == ".DS_Store" || name == "Thumbs.db" {
                throw WhiteboxArtifactError.hiddenFileFound(rel)
            }
            
            allFiles.append(rel)
        }
    }
    allFiles.sort()
    
    for file in manifest.files {
        let fileURL = root.appendingPathComponent(file.path)
        
        guard fm.fileExists(atPath: fileURL.path) else {
            throw WhiteboxArtifactError.missingFile(file.path)
        }
        
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let actualSize = attrs[.size] as! Int
        guard actualSize == file.bytes else {
            throw WhiteboxArtifactError.sizeMismatch(path: file.path, expected: file.bytes, actual: actualSize)
        }
        
        let data = try Data(contentsOf: fileURL)
        let actualHash = _hexLowercase(_SHA256.hash(data: data))
        guard actualHash == file.sha256 else {
            throw WhiteboxArtifactError.hashMismatch(path: file.path, expected: file.sha256, actual: actualHash)
        }
    }
    
    let referenced = Set(manifest.files.map { $0.path }).union(["manifest.json"])
    for file in allFiles {
        guard referenced.contains(file) else {
            throw WhiteboxArtifactError.unreferencedFile(file)
        }
    }
    
    let rootItems = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    for item in rootItems {
        let name = item.lastPathComponent
        guard name == "manifest.json" || name == "artifacts" else {
            throw WhiteboxArtifactError.unreferencedFile(name)
        }
    }
}

