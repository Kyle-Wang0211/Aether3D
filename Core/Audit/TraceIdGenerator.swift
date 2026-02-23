// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// TraceIdGenerator.swift
// PR#8.5 / v0.0.1

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("No SHA256 implementation available. macOS/iOS: use CryptoKit. Linux: add swift-crypto dependency and import Crypto.")
#endif

/// Generates deterministic trace IDs.
///
/// - Note: Thread-safety: All methods are static and stateless.
public enum TraceIdGenerator {
    
    // MARK: - Error Types
    
    /// ID generation errors.
    public enum IdGenerationError: Error, Equatable, Sendable {
        case policyHashEmpty
        case policyHashInvalidLength(got: Int)
        case policyHashNotLowercaseHex
        case policyHashContainsForbiddenChar
        case pipelineVersionEmpty
        case pipelineVersionContainsForbiddenChar
        case inputPathEmpty(index: Int)
        case inputPathTooLong(index: Int)
        case inputPathContainsForbiddenChar(index: Int)
        case inputContentHashInvalidLength(index: Int, got: Int)
        case inputContentHashNotLowercaseHex(index: Int)
        case inputByteSizeNegative(index: Int)
        case duplicateInputPath(path: String)
        case paramKeyEmpty
        case paramKeyContainsForbiddenChar(key: String)
        case paramValueContainsForbiddenChar(key: String)
        case eventIndexOutOfRange(got: Int)
        case eventIndexInvalidFormat
    }
    
    // MARK: - Public API
    
    /// Generate trace ID.
    ///
    /// Formula: SHA256("WMTRACE/v0.0.1|{policyHash}|{pipelineVersion}|{canonicalInputs}|{canonicalParams}")
    ///
    /// - Parameters:
    ///   - policyHash: Policy hash (64 lowercase hex)
    ///   - pipelineVersion: Pipeline version string
    ///   - inputs: Input descriptors
    ///   - paramsSummary: Parameters dictionary
    /// - Returns: 64 lowercase hex character trace ID, or error
    public static func makeTraceId(
        policyHash: String,
        pipelineVersion: String,
        inputs: [InputDescriptor],
        paramsSummary: [String: String]
    ) -> Result<String, IdGenerationError> {
        
        // Validate policyHash
        if let error = validatePolicyHash(policyHash) {
            return .failure(error)
        }
        
        // Validate pipelineVersion
        if let error = validatePipelineVersion(pipelineVersion) {
            return .failure(error)
        }
        
        // Validate inputs
        if let error = validateInputsForId(inputs) {
            return .failure(error)
        }
        
        // Validate paramsSummary
        if let error = validateParamsSummary(paramsSummary) {
            return .failure(error)
        }
        
        // Build hash input
        let canonicalInputs = canonicalizeInputs(inputs)
        let canonicalParams = CanonicalJSONEncoder.encode(paramsSummary)
        let hashInput = "WMTRACE/v0.0.1|\(policyHash)|\(pipelineVersion)|\(canonicalInputs)|\(canonicalParams)"
        
        // Compute hash
        let hash = sha256Hex(hashInput)
        return .success(hash)
    }
    
    /// Generate scene ID.
    ///
    /// Formula: SHA256("WMSCENE/v0.0.1|{sortedPaths joined by ;}")
    ///
    /// - Parameter inputs: Input descriptors (only paths used)
    /// - Returns: 64 lowercase hex character scene ID, or error
    public static func makeSceneId(
        inputs: [InputDescriptor]
    ) -> Result<String, IdGenerationError> {
        
        // Validate inputs (only path validation, no hash/size)
        for (index, input) in inputs.enumerated() {
            if input.path.isEmpty {
                return .failure(.inputPathEmpty(index: index))
            }
            if input.path.count > 2048 {
                return .failure(.inputPathTooLong(index: index))
            }
            if containsForbiddenChars(input.path) {
                return .failure(.inputPathContainsForbiddenChar(index: index))
            }
        }
        
        // Check duplicates
        if let dup = findDuplicatePath(inputs) {
            return .failure(.duplicateInputPath(path: dup))
        }
        
        // Build hash input (paths only, sorted)
        let sortedPaths = inputs.map(\.path).sorted()
        let canonicalPaths = sortedPaths.joined(separator: ";")
        let hashInput = "WMSCENE/v0.0.1|\(canonicalPaths)"
        
        // Compute hash
        let hash = sha256Hex(hashInput)
        return .success(hash)
    }
    
    /// Generate event ID.
    ///
    /// Format: "{traceId}:{eventIndex}"
    ///
    /// - Parameters:
    ///   - traceId: Trace ID (64 lowercase hex chars)
    ///   - eventIndex: Event index (0...1_000_000, no leading zeros except "0")
    /// - Returns: Event ID string, or error
    public static func makeEventId(traceId: String, eventIndex: Int) -> Result<String, IdGenerationError> {
        // Validate eventIndex range
        if eventIndex < 0 || eventIndex > 1_000_000 {
            return .failure(.eventIndexOutOfRange(got: eventIndex))
        }
        
        // Validate traceId format (64 lowercase hex)
        if traceId.count != 64 {
            return .failure(.policyHashInvalidLength(got: traceId.count))
        }
        if !isLowercaseHex(traceId) {
            return .failure(.policyHashNotLowercaseHex)
        }
        
        // Format eventIndex as decimal string (no leading zeros except "0")
        let indexString: String
        if eventIndex == 0 {
            indexString = "0"
        } else {
            indexString = String(eventIndex)
        }
        
        // Validate format matches regex: ^(0|[1-9][0-9]*)$
        if eventIndex != 0 && indexString.hasPrefix("0") {
            return .failure(.eventIndexInvalidFormat)
        }
        
        return .success("\(traceId):\(indexString)")
    }
    
    // MARK: - Validation Helpers
    
    private static func validatePolicyHash(_ hash: String) -> IdGenerationError? {
        if hash.isEmpty {
            return .policyHashEmpty
        }
        if hash.count != 64 {
            return .policyHashInvalidLength(got: hash.count)
        }
        if !isLowercaseHex(hash) {
            return .policyHashNotLowercaseHex
        }
        if hash.contains("|") {
            return .policyHashContainsForbiddenChar
        }
        return nil
    }
    
    private static func validatePipelineVersion(_ version: String) -> IdGenerationError? {
        if version.isEmpty {
            return .pipelineVersionEmpty
        }
        if version.contains("|") {
            return .pipelineVersionContainsForbiddenChar
        }
        // Check for control characters (< 0x20 OR == 0x7F)
        for scalar in version.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F {
                return .pipelineVersionContainsForbiddenChar
            }
        }
        return nil
    }
    
    private static func validateInputsForId(_ inputs: [InputDescriptor]) -> IdGenerationError? {
        // Sort by path for deterministic error reporting
        let sortedInputs = inputs.enumerated().sorted { $0.element.path < $1.element.path }
        
        // Check for duplicates first (using sorted order)
        var previousPath: String? = nil
        for (_, input) in sortedInputs {
            if let prev = previousPath, prev == input.path {
                return .duplicateInputPath(path: input.path)
            }
            previousPath = input.path
        }
        
        // Validate each input (in sorted order for deterministic first-error)
        for (originalIndex, input) in sortedInputs {
            if input.path.isEmpty {
                return .inputPathEmpty(index: originalIndex)
            }
            if input.path.count > 2048 {
                return .inputPathTooLong(index: originalIndex)
            }
            if containsForbiddenChars(input.path) {
                return .inputPathContainsForbiddenChar(index: originalIndex)
            }
            
            if let hash = input.contentHash {
                if hash.count != 64 {
                    return .inputContentHashInvalidLength(index: originalIndex, got: hash.count)
                }
                if !isLowercaseHex(hash) {
                    return .inputContentHashNotLowercaseHex(index: originalIndex)
                }
            }
            
            if let size = input.byteSize, size < 0 {
                return .inputByteSizeNegative(index: originalIndex)
            }
        }
        
        return nil
    }
    
    private static func validateParamsSummary(_ params: [String: String]) -> IdGenerationError? {
        // Sort keys for deterministic error
        let sortedKeys = params.keys.sorted()
        
        for key in sortedKeys {
            if key.isEmpty {
                return .paramKeyEmpty
            }
            if key.contains("|") {
                return .paramKeyContainsForbiddenChar(key: key)
            }
            if let value = params[key], value.contains("|") {
                return .paramValueContainsForbiddenChar(key: key)
            }
        }
        
        return nil
    }
    
    // MARK: - Canonicalization
    
    private static func canonicalizeInputs(_ inputs: [InputDescriptor]) -> String {
        let sorted = inputs.sorted { $0.path < $1.path }
        return sorted.map { input in
            let hash = input.contentHash ?? ""
            let size = input.byteSize.map { String($0) } ?? ""
            return "\(input.path)|\(hash)|\(size);"
        }.joined()
    }
    
    // MARK: - Helpers
    
    private static let forbiddenChars: Set<Character> = ["|", ";", "\n", "\r", "\t"]
    
    private static func containsForbiddenChars(_ string: String) -> Bool {
        return string.contains { forbiddenChars.contains($0) }
    }
    
    private static func isLowercaseHex(_ string: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    
    private static func findDuplicatePath(_ inputs: [InputDescriptor]) -> String? {
        let sorted = inputs.map(\.path).sorted()
        guard sorted.count > 1 else { return nil }  // Need at least 2 items to have duplicates
        for i in 1..<sorted.count {
            if sorted[i] == sorted[i-1] {
                return sorted[i]
            }
        }
        return nil
    }
    
    private static func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

