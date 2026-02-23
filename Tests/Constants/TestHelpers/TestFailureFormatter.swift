// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TestFailureFormatter.swift
// Aether3D
//
// Formatter for test failure messages.
// PATCH E: Does NOT call XCTFail - returns formatted strings only.
//

import Foundation

/// Formatter for test failure messages
public enum TestFailureFormatter {
    /// Format a magic number violation
    public static func formatMagicNumberViolation(
        value: String,
        file: String,
        line: Int,
        column: Int
    ) -> String {
        return "Magic number '\(value)' found at \(file):\(line):\(column). Use SSOT constant instead."
    }
    
    /// Format a prohibition violation
    public static func formatProhibitionViolation(
        pattern: String,
        file: String,
        line: Int,
        reason: String
    ) -> String {
        return "Prohibited pattern '\(pattern)' found at \(file):\(line). \(reason)"
    }
    
    /// Format a missing spec error
    public static func formatMissingSpec(
        constantName: String,
        file: String
    ) -> String {
        return "Constant '\(constantName)' in \(file) is missing a structured spec."
    }
    
    /// Format a duplicate error
    public static func formatDuplicate(
        item: String,
        type: String
    ) -> String {
        return "Duplicate \(type): \(item)"
    }
    
    /// Format a validation error
    public static func formatValidationError(
        item: String,
        errors: [String]
    ) -> String {
        return "Validation failed for \(item):\n  " + errors.joined(separator: "\n  ")
    }
    
    /// Format a document mismatch error
    public static func formatDocumentMismatch(
        item: String,
        expected: String,
        actual: String
    ) -> String {
        return "Document mismatch for \(item): expected '\(expected)', found '\(actual)'"
    }
}

