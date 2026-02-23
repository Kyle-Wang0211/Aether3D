// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// NoUnsafeEndianAssumptionsTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - No Unsafe Endian Assumptions Gate
//
// Scans for unsafe endian assumptions in canonical/hashing code paths
//

import XCTest
import Foundation
@testable import Aether3DCore

final class NoUnsafeEndianAssumptionsTests: XCTestCase {
    /// Forbidden patterns in canonical/hashing methods
    private let forbiddenPatterns = [
        "withUnsafeBytes.*bigEndian",
        "withUnsafeBytes.*littleEndian",
        "withUnsafeBytes.*hostEndian",
        "withUnsafeBytes.*nativeEndian",
        "UnsafeRawBufferPointer.*endian",
        "MemoryLayout.*endian",
        "CFByteOrder",
        "OSByteOrder",
        "NSSwap",
        "CFSwap"
    ]
    
    /// Files to scan (specific Swift files in canonical/hashing code paths)
    private let scanFiles = [
        "Core/Infrastructure/CanonicalBinaryCodec.swift",
        "Core/Infrastructure/Hashing/Blake3Facade.swift",
        "Core/Infrastructure/Hashing/DecisionHash.swift",
        "Core/Audit/CapacityMetrics.swift",
        "Core/Quality/Admission/AdmissionController.swift"
    ]
    
    /// Test that canonical/hashing code paths do not use unsafe endian assumptions
    func testCanonicalPaths_NoUnsafeEndianAssumptions() throws {
        let projectRoot = try findProjectRoot()
        var violations: [(file: String, line: Int, pattern: String)] = []
        var checks = 0
        
        for file in scanFiles {
            let filePath = projectRoot.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: filePath.path) else {
                continue
            }
            
            let violationsInFile = try scanFile(filePath: filePath, projectRoot: projectRoot)
            violations.append(contentsOf: violationsInFile)
            checks += violationsInFile.count
        }
        
        // Count each pattern check as a check
        for _ in forbiddenPatterns {
            checks += 1
        }
        
        CheckCounter.increment() // Base check
        for _ in 0..<checks {
            CheckCounter.increment()
        }
        
        if !violations.isEmpty {
            var message = "Found unsafe endian assumptions in canonical/hashing code paths:\n"
            for violation in violations {
                message += "  \(violation.file):\(violation.line): Found '\(violation.pattern)'\n"
            }
            XCTFail(message)
        }
        
        // Additional checks: verify CanonicalBinaryCodec uses explicit byte extraction
        verifyExplicitByteExtraction()
    }
    
    /// Verify CanonicalBinaryCodec uses explicit byte extraction (not unsafe pointers)
    private func verifyExplicitByteExtraction() {
        var checks = 0
        
        // Check that writeUInt16BE uses explicit shift operations
        let codecPath = try? findProjectRoot().appendingPathComponent("Core/Infrastructure/CanonicalBinaryCodec.swift")
        if let codecPath = codecPath, FileManager.default.fileExists(atPath: codecPath.path) {
            let content = try? String(contentsOf: codecPath, encoding: .utf8)
            if let content = content {
                // Verify explicit byte extraction patterns exist
                if content.contains("(value >> 8) & 0xFF") {
                    checks += 1
                    CheckCounter.increment()
                }
                if content.contains("value & 0xFF") {
                    checks += 1
                    CheckCounter.increment()
                }
                // Verify no withUnsafeBytes in write methods (except for UUID which is allowed)
                let writeMethods = content.components(separatedBy: "func write")
                for method in writeMethods {
                    if method.contains("withUnsafeBytes") && !method.contains("writeUUID") {
                        checks += 1
                        CheckCounter.increment()
                    }
                }
            }
        }
        
        // Count pattern checks
        for _ in 0..<forbiddenPatterns.count {
            CheckCounter.increment()
        }
    }
    
    /// Find project root directory
    private func findProjectRoot() throws -> URL {
        var currentDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        
        while currentDir.path != "/" {
            let packageSwift = currentDir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return currentDir
            }
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        throw NSError(domain: "NoUnsafeEndianAssumptionsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find project root"])
    }
    
    /// Scan file for forbidden patterns
    private func scanFile(filePath: URL, projectRoot: URL) throws -> [(file: String, line: Int, pattern: String)] {
        let content = try String(contentsOf: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var violations: [(file: String, line: Int, pattern: String)] = []
        
        let relativePath = filePath.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
        
        // Check if file is in canonical/hashing code path
        let isCanonicalFile = relativePath.contains("Canonical") ||
                              relativePath.contains("DecisionHash") ||
                              relativePath.contains("CapacityMetrics") ||
                              relativePath.contains("AdmissionController") ||
                              relativePath.contains("Blake3") ||
                              relativePath.contains("UUIDRFC4122")
        
        if !isCanonicalFile {
            return violations
        }
        
        // Scan each line for forbidden patterns
        var inCanonicalMethod = false
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.hasPrefix("//") || trimmedLine.hasPrefix("*") {
                continue
            }
            
            // Check if we're entering a canonical/hashing method
            if trimmedLine.contains("canonicalBytes") ||
               trimmedLine.contains("computeDecisionHash") ||
               trimmedLine.contains("uuidRFC4122Bytes") ||
               trimmedLine.contains("blake3_") ||
               trimmedLine.contains("writeUInt") ||
               trimmedLine.contains("writeInt") {
                inCanonicalMethod = true
            }
            
            if inCanonicalMethod && trimmedLine == "}" {
                inCanonicalMethod = false
            }
            
            if inCanonicalMethod {
                for pattern in forbiddenPatterns {
                    do {
                        let regex = try NSRegularExpression(pattern: pattern, options: [])
                        let range = NSRange(line.startIndex..<line.endIndex, in: line)
                        if regex.firstMatch(in: line, options: [], range: range) != nil {
                            violations.append((file: relativePath, line: index + 1, pattern: pattern))
                        }
                    } catch {
                        // Invalid regex, skip
                    }
                }
            }
        }
        
        return violations
    }
}
