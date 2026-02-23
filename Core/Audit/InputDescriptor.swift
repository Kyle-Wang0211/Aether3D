// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// InputDescriptor.swift
// PR#8.5 / v0.0.1

import Foundation

/// Describes an input file for audit trace.
///
/// - Note: Thread-safety: Immutable struct, safe for concurrent use.
public struct InputDescriptor: Codable, Sendable, Equatable {
    
    /// Input file path (relative or absolute).
    ///
    /// Constraints:
    /// - Non-empty
    /// - Max 2048 characters
    /// - Forbidden chars: | ; \n \r \t
    /// - MUST NOT contain PII/tokens/secrets (caller responsibility)
    public let path: String
    
    /// SHA256 hash of file content (64 lowercase hex chars).
    /// nil if hash not computed.
    public let contentHash: String?
    
    /// File size in bytes.
    /// nil if size not available.
    public let byteSize: Int?
    
    /// Forbidden characters in path.
    public static let forbiddenPathChars: Set<Character> = ["|", ";", "\n", "\r", "\t"]
    
    /// Create input descriptor.
    ///
    /// - Parameters:
    ///   - path: Input file path (required, non-empty).
    ///   - contentHash: SHA256 hash (optional, must be 64 lowercase hex if provided).
    ///   - byteSize: File size (optional, must be >= 0 if provided).
    ///
    /// - Precondition: path is non-empty and contains no forbidden chars.
    ///   Caller bug if violated (will crash).
    public init(
        path: String,
        contentHash: String? = nil,
        byteSize: Int? = nil
    ) {
        precondition(!path.isEmpty, "path must not be empty")
        precondition(path.count <= 2048, "path must not exceed 2048 characters")
        precondition(!Self.containsForbiddenChars(path), "path contains forbidden characters")
        
        if let size = byteSize {
            precondition(size >= 0, "byteSize must be non-negative")
        }
        
        self.path = path
        self.contentHash = contentHash
        self.byteSize = byteSize
    }
    
    private static func containsForbiddenChars(_ string: String) -> Bool {
        return string.contains { forbiddenPathChars.contains($0) }
    }
}

