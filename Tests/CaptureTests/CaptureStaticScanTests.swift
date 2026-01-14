//
//  CaptureStaticScanTests.swift
//  Aether3D
//
//  Created for PR#4 Capture Recording
//

import XCTest
import Foundation

final class CaptureStaticScanTests: XCTestCase {
    
    // MARK: - Scan Targets
    
    private let pr4Files: [String] = [
        "App/Capture/CaptureMetadata.swift",
        "Core/Constants/CaptureRecordingConstants.swift",
        "App/Capture/CameraSession.swift",
        "App/Capture/InterruptionHandler.swift",
        "App/Capture/RecordingController.swift"
    ]
    
    // MARK: - File Resolution
    
    private func readFileContent(_ path: String) -> String? {
        guard let url = RepoRootLocator.resolvePath(path) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    
    // MARK: - Privacy / Path Leakage Scans
    
    func test_noPathLeakageInPR4Files() {
        let forbiddenTokens = [
            "file://",
            "/Users/",
            "/var/",
            "localizedDescription",
            "NSLocalizedDescriptionKey",
            "NSError",
            "AVError"
        ]
        
        let forbiddenInterpolations = [
            "\\(error)",
            "\\(err)",
            "\\(nsError)"
        ]
        
        for filePath in pr4Files {
            guard let content = readFileContent(filePath) else {
                XCTFail("Could not read file: \(filePath)")
                continue
            }
            
            // Check forbidden tokens
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                for token in forbiddenTokens {
                    if line.contains(token) {
                        // Allow NSError/AVError in type annotations and casts only
                        if token == "NSError" || token == "AVError" {
                            // Check if it's in a type annotation context (simplified check)
                            let isTypeAnnotation = line.contains(": NSError") || line.contains(": AVError") ||
                                                   line.contains("as NSError") || line.contains("as AVError") ||
                                                   line.contains("NSError?") || line.contains("AVError?") ||
                                                   line.contains("NSError)") || line.contains("AVError)")
                            if !isTypeAnnotation {
                                XCTFail("Forbidden token '\(token)' found in \(filePath) at line \(index + 1): \(trimmed)")
                            }
                        } else {
                            XCTFail("Forbidden token '\(token)' found in \(filePath) at line \(index + 1): \(trimmed)")
                        }
                    }
                }
            }
            
            // Check forbidden string interpolations
            for interpolation in forbiddenInterpolations {
                if content.contains(interpolation) {
                    XCTFail("Forbidden string interpolation '\(interpolation)' found in \(filePath)")
                }
            }
        }
    }
    
    // MARK: - Determinism Scans
    
    func test_noNonDeterministicPatternsInRecordingController() {
        let determinismFiles = [
            "App/Capture/RecordingController.swift",
            "App/Capture/CaptureMetadata.swift"
        ]
        
        let forbiddenTokens = [
            "Date()",
            "DispatchQueue.global",
            "Task {",
            "async let",
            "await "
        ]
        
        for filePath in determinismFiles {
            guard let content = readFileContent(filePath) else {
                XCTFail("Could not read file: \(filePath)")
                continue
            }
            
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                for token in forbiddenTokens {
                    if line.contains(token) {
                        XCTFail("Forbidden token '\(token)' found in \(filePath) at line \(index + 1): \(trimmed)")
                    }
                }
            }
        }
    }
    
    // MARK: - Audio Prevention Scans
    
    func test_noAudioAPIsInPR4Files() {
        let forbiddenTokens = [
            "requestAccess(for: .audio",
            "AVCaptureDevice.default(for: .audio",
            "builtInMicrophone",
            "AVAudioSession"
        ]
        
        for filePath in pr4Files {
            guard let content = readFileContent(filePath) else {
                XCTFail("Could not read file: \(filePath)")
                continue
            }
            
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                for token in forbiddenTokens {
                    if line.contains(token) {
                        XCTFail("Forbidden audio API '\(token)' found in \(filePath) at line \(index + 1): \(trimmed)")
                    }
                }
                
                // Check for .audio in AVCaptureDeviceInput creation (best-effort)
                if line.contains("AVCaptureDeviceInput") && (line.contains(".audio") || line.contains("mediaType: .audio")) {
                    XCTFail("Forbidden audio input creation found in \(filePath) at line \(index + 1): \(trimmed)")
                }
            }
        }
    }
    
    // MARK: - Print and Log Prefix Scans
    
    func test_noPrintStatementsInPR4Files() {
        for filePath in pr4Files {
            guard let content = readFileContent(filePath) else {
                XCTFail("Could not read file: \(filePath)")
                continue
            }
            
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                if line.contains("print(") {
                    XCTFail("Forbidden 'print(' found in \(filePath) at line \(index + 1): \(trimmed)")
                }
            }
        }
    }
    
    func test_osLogContainsPR4Prefix() {
        for filePath in pr4Files {
            guard let content = readFileContent(filePath) else {
                XCTFail("Could not read file: \(filePath)")
                continue
            }
            
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if line.contains("os_log(") {
                    // Check if same line contains [PR4] prefix
                    if !line.contains("[PR4]") {
                        XCTFail("os_log call missing [PR4] prefix in \(filePath) at line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
    }
    
    // MARK: - Magic Numbers Scan
    
    func test_noMagicNumbersInRecordingController() {
        let filePath = "App/Capture/RecordingController.swift"
        guard let content = readFileContent(filePath) else {
            XCTFail("Could not read file: \(filePath)")
            return
        }
        
        let forbiddenNumbers = [
            "900",
            "1.5",
            "2.0",
            "0.5",
            "1.0"
        ]
        
        let forbiddenExpressions = [
            "100 * 1024 * 1024",
            "1024 * 1024"
        ]
        
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments
            if trimmed.hasPrefix("//") {
                continue
            }
            
            // Check simple numbers (best-effort, avoid false positives)
            for number in forbiddenNumbers {
                if line.contains(number) {
                    // Skip if in comment, string literal, or constant reference
                    let isInComment = trimmed.hasPrefix("//")
                    let isInString = line.contains("\"\(number)\"")
                    let isConstantReference = line.contains("CaptureRecordingConstants") || line.contains("Constants.")
                    
                    if !isInComment && !isInString && !isConstantReference {
                        // Simple check: if number appears as literal (not part of larger number)
                        // This is best-effort; may have false positives but catches most cases
                        let patterns = [" \(number)", "=\(number)", ":\(number)", "(\(number)", ",\(number)"]
                        let hasPattern = patterns.contains { line.contains($0) }
                        if hasPattern {
                            XCTFail("Forbidden magic number '\(number)' found in \(filePath) at line \(index + 1): \(trimmed)")
                        }
                    }
                }
            }
            
            // Check expressions (best-effort)
            for expr in forbiddenExpressions {
                if line.contains(expr) {
                    // Skip if in comment or string
                    if !trimmed.hasPrefix("//") && !line.contains("\"\(expr)\"") {
                        // Check if it's a constant reference
                        if !line.contains("CaptureRecordingConstants") {
                            XCTFail("Forbidden magic expression '\(expr)' found in \(filePath) at line \(index + 1): \(trimmed)")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Date() Ban Scan (Phase A - Rule A)
    // Rule: Fail if "Date()" appears in any App/Capture/*.swift
    // Allowlist: Only if file path ends with "DefaultClockProvider" (closed set)
    
    func test_captureBansDateConstructor() {
        // Enumerate all Swift files under App/Capture/ recursively
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            XCTFail("Could not resolve App/Capture directory")
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate App/Capture directory")
            return
        }
        
        // Closed set allowlist: files ending with "DefaultClockProvider"
        let allowedFiles = ["DefaultClockProvider"]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let fileName = fileURL.lastPathComponent
            let isAllowed = allowedFiles.contains { fileName.contains($0) }
            
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                // Check for Date() constructor
                if line.contains("Date()") {
                    // Allow DateFormatter and ISO8601DateFormatter (they contain "Date" but are not Date())
                    if line.contains("DateFormatter") || line.contains("ISO8601DateFormatter") {
                        continue
                    }
                    
                    // For CaptureMetadata.swift, allow "Date" as type annotation but still ban "Date()"
                    if relativePath == "CaptureMetadata.swift" {
                        // Check if it's a type annotation (e.g., "var x: Date")
                        if line.contains(": Date") && !line.contains("Date()") {
                            continue
                        }
                    }
                    
                    // Check allowlist: only DefaultClockProvider files allowed
                    if isAllowed {
                        // Verify it's actually in DefaultClockProvider struct
                        if line.contains("DefaultClockProvider") || line.contains("struct DefaultClockProvider") {
                            continue
                        }
                    }
                    
                    XCTFail("[PR4][SCAN] banned_date_ctor file=\(relativePath) match=Date() at line \(index + 1): \(trimmed)")
                }
                
                // Check for "Date (" with weird spacing
                if line.contains("Date (") {
                    if !isAllowed {
                        XCTFail("[PR4][SCAN] banned_date_ctor file=\(relativePath) match=Date ( at line \(index + 1): \(trimmed)")
                    }
                }
            }
        }
    }
    
    // MARK: - Required Constants Usage
    
    func test_keyFilesMustReferenceCaptureRecordingConstants() {
        // Test A: RecordingController.swift must contain CaptureRecordingConstants. at least 5 times
        let recordingControllerPath = "App/Capture/RecordingController.swift"
        guard let rcContent = readFileContent(recordingControllerPath) else {
            XCTFail("Could not read \(recordingControllerPath)")
            return
        }
        
        let constantPrefixCount = rcContent.components(separatedBy: "CaptureRecordingConstants.").count - 1
        if constantPrefixCount < 5 {
            XCTFail("[PR4][SCAN] missing_constants_prefix_count file=\(recordingControllerPath) found=\(constantPrefixCount) required>=5")
        }
        
        // Test B: RecordingController.swift must contain required tokens (Phase A - Rule D)
        // Exact constant names from CaptureRecordingConstants.swift
        let requiredTokensRC = [
            "CaptureRecordingConstants.minDurationSeconds",
            "CaptureRecordingConstants.maxDurationSeconds",
            "CaptureRecordingConstants.maxBytes",
            "CaptureRecordingConstants.fileSizePollIntervalSmallFile",
            "CaptureRecordingConstants.fileSizePollIntervalLargeFile",
            "CaptureRecordingConstants.fileSizeLargeThresholdBytes",
            "CaptureRecordingConstants.assetCheckTimeoutSeconds"
        ]
        
        for token in requiredTokensRC {
            if !rcContent.contains(token) {
                XCTFail("[PR4][SCAN] missing_constants_ref file=\(recordingControllerPath) token=\(token)")
            }
        }
        
        // Test C: CameraSession.swift must contain required tokens
        let cameraSessionPath = "App/Capture/CameraSession.swift"
        guard let csContent = readFileContent(cameraSessionPath) else {
            XCTFail("Could not read \(cameraSessionPath)")
            return
        }
        
        let requiredTokensCS = [
            "CaptureRecordingConstants.maxDurationSeconds",
            "CaptureRecordingConstants.maxBytes"
        ]
        
        for token in requiredTokensCS {
            if !csContent.contains(token) {
                XCTFail("[PR4][SCAN] missing_constants_ref file=\(cameraSessionPath) token=\(token)")
            }
        }
        
        // Test D: Soft scan for suspicious numeric literals in App/Capture/*.swift
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            return
        }
        
        let suspiciousNumbers = ["900", "100", "24", "0.5", "1.0", "1.5", "2"]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard fileURL.lastPathComponent != "CaptureRecordingConstants.swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                // Skip if line contains constant reference
                if line.contains("CaptureRecordingConstants") {
                    continue
                }
                
                for number in suspiciousNumbers {
                    // Simple check for suspicious patterns
                    let patterns = [" \(number)", "=\(number)", ":\(number)", "(\(number)", ",\(number)"]
                    for pattern in patterns {
                        if line.contains(pattern) && !line.contains("\"\(number)\"") {
                            // This is a warning, not a hard failure
                            // Could add to a warning list if needed
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Timer.scheduledTimer Ban Scan (Phase A - Rule B)
    // Rule: Fail if "Timer.scheduledTimer" OR ".scheduledTimer(" appears in App/Capture/*.swift
    // Allowlist: Only in DefaultTimerScheduler (closed set)
    
    func test_captureBansDirectTimerScheduledTimer() {
        // Enumerate all Swift files under App/Capture/ recursively
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            XCTFail("Could not resolve App/Capture directory")
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate App/Capture directory")
            return
        }
        
        let bannedPatterns = [
            "Timer.scheduledTimer",
            "Foundation.Timer.scheduledTimer",
            "Timer .scheduledTimer",
            ".scheduledTimer("
        ]
        
        // Closed set allowlist: files containing "DefaultTimerScheduler"
        let allowedFiles = ["DefaultTimerScheduler"]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let fileName = fileURL.lastPathComponent
            let isAllowed = allowedFiles.contains { fileName.contains($0) || content.contains("struct \($0)") }
            
            let lines = content.components(separatedBy: .newlines)
            
            // Check for banned patterns
            for pattern in bannedPatterns {
                if content.contains(pattern) {
                    // Find the line containing the pattern
                    for (index, line) in lines.enumerated() {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        // Skip comments
                        if trimmed.hasPrefix("//") {
                            continue
                        }
                        
                        if line.contains(pattern) {
                            // Check allowlist: only DefaultTimerScheduler files allowed
                            if isAllowed && (line.contains("DefaultTimerScheduler") || line.contains("struct DefaultTimerScheduler")) {
                                continue
                            }
                            
                            XCTFail("[PR4][SCAN] banned_timer_scheduledTimer file=\(relativePath) match=\(pattern) at line \(index + 1): \(trimmed)")
                        }
                    }
                }
            }
            
            // Check for newline variant: "Timer\n.scheduledTimer" (across line boundaries)
            let normalizedContent = content.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            if normalizedContent.contains("Timer .scheduledTimer") {
                if !isAllowed {
                    // Find approximate line
                    for (index, line) in lines.enumerated() {
                        if line.contains("Timer") {
                            if index < lines.count - 1 && lines[index + 1].contains(".scheduledTimer") {
                                XCTFail("[PR4][SCAN] banned_timer_scheduledTimer file=\(relativePath) match=Timer\\n.scheduledTimer at line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Core Portability Guard (Rule E)
    // Rule: Core/Constants must not import AVFoundation or use AVFoundation types
    // Allowlist: EMPTY (closed set empty) - Core must never use AVFoundation
    
    func test_coreMustNotImportAVFoundation() {
        // Scan ONLY Core/Constants/*.swift files
        guard let coreConstantsDir = RepoRootLocator.resolvePath("Core/Constants") else {
            XCTFail("Could not resolve Core/Constants directory")
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: coreConstantsDir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate Core/Constants directory")
            return
        }
        
        // Closed set allowlist: EMPTY (no exceptions)
        let forbiddenPatterns = [
            "import AVFoundation",
            "CMTime",
            "AVCapture",
            "canImport(AVFoundation)",
            "#if canImport(AVFoundation)",
            "#if os(iOS)",
            "#if os(macOS)"
        ]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: coreConstantsDir.path + "/", with: "")
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                for pattern in forbiddenPatterns {
                    if line.contains(pattern) {
                        XCTFail("[PR4][SCAN] banned_avfoundation_in_core file=Core/Constants/\(relativePath) match=\(pattern) at line \(index + 1): \(trimmed)")
                    }
                }
            }
        }
    }
    
    // MARK: - CMTime PreferredTimescale Hardcoding Ban (Rule F)
    // Rule: App/Capture must not hardcode preferredTimescale: 600
    // Allowlist: EMPTY (closed set empty) - must use CaptureRecordingConstants.cmTimePreferredTimescale
    
    func test_captureBansHardcodedPreferredTimescale() {
        // Enumerate all Swift files under App/Capture/ recursively
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            XCTFail("Could not resolve App/Capture directory")
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate App/Capture directory")
            return
        }
        
        // Closed set allowlist: EMPTY (no exceptions)
        let forbiddenPatterns = [
            "preferredTimescale: 600",
            "preferredTimescale:600",
            "preferredTimescale = 600",
            "preferredTimescale=600"
        ]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") {
                    continue
                }
                
                for pattern in forbiddenPatterns {
                    if line.contains(pattern) {
                        XCTFail("[PR4][SCAN] banned_hardcoded_timescale file=\(relativePath) match=\(pattern) at line \(index + 1): \(trimmed)")
                    }
                }
            }
        }
    }
    
    // MARK: - asyncAfter Ban Scan (Phase A - Rule C)
    // Rule: Fail if ".asyncAfter(" appears in App/Capture/*.swift
    // Allowlist: NONE (closed set empty)
    
    func test_captureBansAsyncAfter() {
        // Enumerate all Swift files under App/Capture/ recursively
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            XCTFail("Could not resolve App/Capture directory")
            return
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate App/Capture directory")
            return
        }
        
        // Closed set allowlist: EMPTY (no exceptions)
        let allowedFiles: [String] = []
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let lines = content.components(separatedBy: .newlines)
            
            // Check for .asyncAfter(
            if content.contains(".asyncAfter(") {
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Skip comments
                    if trimmed.hasPrefix("//") {
                        continue
                    }
                    
                    if line.contains(".asyncAfter(") {
                        // No allowlist - fail immediately
                        XCTFail("[PR4][SCAN] banned_asyncAfter file=\(relativePath) match=.asyncAfter( at line \(index + 1): \(trimmed)")
                    }
                }
            }
        }
    }
}

