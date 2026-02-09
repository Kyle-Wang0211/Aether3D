// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GoldenDiffPrinter.swift
// Aether3D
//
// PR1 v2.4 Addendum - Golden Test Failure Diagnostics
//
// Prints detailed diff information for golden test failures
//

import Foundation

/// Golden diff printer for test failure diagnostics
public struct GoldenDiffPrinter {
    /// Print hex diff between expected and actual
    /// 
    /// **Output:**
    /// - First mismatch index
    /// - Window of bytes around mismatch (16 bytes before, 16 bytes after)
    /// - Expected vs actual hex strings
    public static func diffHex(expected: String, actual: String, label: String) -> String {
        var output = "\n========================================\n"
        output += "GOLDEN DIFF: \(label)\n"
        output += "========================================\n"
        
        // Find first mismatch
        let expectedChars = Array(expected)
        let actualChars = Array(actual)
        let minLen = min(expectedChars.count, actualChars.count)
        
        var firstMismatch: Int? = nil
        for i in 0..<minLen {
            if expectedChars[i] != actualChars[i] {
                firstMismatch = i
                break
            }
        }
        
        if let mismatch = firstMismatch {
            let byteIndex = mismatch / 2 // Convert hex char index to byte index
            
            output += "First mismatch at byte index: \(byteIndex)\n"
            output += "Hex char index: \(mismatch)\n\n"
            
            // Print window around mismatch
            let windowStart = max(0, mismatch - 32)
            let windowEnd = min(expectedChars.count, mismatch + 32)
            
            if windowStart < mismatch {
                output += "Before mismatch:\n"
                output += String(expectedChars[windowStart..<mismatch])
                output += "\n\n"
            }
            
            output += "At mismatch:\n"
            output += "Expected: \(expectedChars[mismatch])\n"
            output += "Actual:   \(actualChars[mismatch])\n\n"
            
            if mismatch + 1 < windowEnd {
                output += "After mismatch:\n"
                output += String(expectedChars[(mismatch + 1)..<windowEnd])
                output += "\n\n"
            }
        } else if expectedChars.count != actualChars.count {
            output += "Length mismatch:\n"
            output += "Expected length: \(expectedChars.count) hex chars (\(expectedChars.count / 2) bytes)\n"
            output += "Actual length:   \(actualChars.count) hex chars (\(actualChars.count / 2) bytes)\n\n"
        }
        
        output += "Full expected (first 128 chars):\n"
        output += String(expectedChars.prefix(128))
        if expectedChars.count > 128 {
            output += "...\n"
        } else {
            output += "\n"
        }
        
        output += "\nFull actual (first 128 chars):\n"
        output += String(actualChars.prefix(128))
        if actualChars.count > 128 {
            output += "...\n"
        } else {
            output += "\n"
        }
        
        output += "========================================\n"
        
        return output
    }
    
    /// Print platform info for diagnostics
    public static func platformInfo() -> String {
        var info = "\n========================================\n"
        info += "PLATFORM INFO\n"
        info += "========================================\n"
        
        #if os(macOS)
        info += "Platform: macOS\n"
        #elseif os(Linux)
        info += "Platform: Linux\n"
        #elseif os(iOS)
        info += "Platform: iOS\n"
        #elseif os(watchOS)
        info += "Platform: watchOS\n"
        #elseif os(tvOS)
        info += "Platform: tvOS\n"
        #else
        info += "Platform: Unknown\n"
        #endif
        
        #if DEBUG
        info += "Build config: Debug\n"
        #else
        info += "Build config: Release\n"
        #endif
        
        // Swift version (best effort)
        let swiftVersion = ProcessInfo.processInfo.environment["SWIFT_VERSION"] ?? "unknown"
        info += "Swift version: \(swiftVersion)\n"
        
        info += "========================================\n"
        
        return info
    }
    
    /// Print DecisionHash diagnostic bundle
    public static func decisionHashDiagnostics(
        domainTagHex: String,
        canonicalBytesHex: String,
        computedHashHex: String,
        expectedHashHex: String
    ) -> String {
        var output = platformInfo()
        output += "\n"
        output += "========================================\n"
        output += "DECISION HASH DIAGNOSTICS\n"
        output += "========================================\n"
        output += "Domain tag hex: \(domainTagHex)\n"
        output += "Canonical bytes hex (first 128 chars): \(String(canonicalBytesHex.prefix(128)))\n"
        if canonicalBytesHex.count > 128 {
            output += "... (total \(canonicalBytesHex.count / 2) bytes)\n"
        }
        output += "\n"
        output += diffHex(expected: expectedHashHex, actual: computedHashHex, label: "DecisionHash")
        output += "\n"
        output += "========================================\n"
        
        return output
    }
}
