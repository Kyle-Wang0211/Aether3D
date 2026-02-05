//
//  CaptureStaticScanTests.swift
//  Aether3D
//
//  Created for PR#4 Capture Recording
//

import XCTest
import Foundation
@testable import Aether3DCore

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
            let lines = content.components(separatedBy: CharacterSet.newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            for (index, line) in lines.enumerated() {
                if line.contains("os_log(") {
                    // Check if same line contains [PR4] prefix
                    if !line.contains("[PR4]") {
                        XCTFail("os_log call missing [PR4] prefix in \(filePath) at line \(index + 1): \(line.trimmingCharacters(in: CharacterSet.whitespaces))")
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
        
        let lines = content.components(separatedBy: CharacterSet.newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
        
        // Closed set allowlist: exact path only
        let allowedExactPaths = ["App/Capture/ClockProvider.swift"]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            // Get exact relative path from repo root
            guard let repoRoot = RepoRootLocator.findRepoRoot() else {
                XCTFail("Could not find repo root")
                return
            }
            let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let isAllowed = allowedExactPaths.contains(relativePath)
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
                    
                    // Check allowlist: only exact path allowed
                    if isAllowed {
                        continue
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
            
            // relativePath intentionally unused - this loop only checks for suspicious numbers
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            for (_, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
        
        // Closed set allowlist: exact path only
        let allowedExactPaths = ["App/Capture/TimerScheduler.swift"]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            // Get exact relative path from repo root
            guard let repoRoot = RepoRootLocator.findRepoRoot() else {
                XCTFail("Could not find repo root")
                return
            }
            let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let isAllowed = allowedExactPaths.contains(relativePath)
            
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            // Check for banned patterns
            for pattern in bannedPatterns {
                if content.contains(pattern) {
                    // Find the line containing the pattern
                    for (index, line) in lines.enumerated() {
                        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                        // Skip comments
                        if trimmed.hasPrefix("//") {
                            continue
                        }
                        
                        if line.contains(pattern) {
                            // Check allowlist: only exact path allowed
                            if isAllowed {
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
                                XCTFail("[PR4][SCAN] banned_timer_scheduledTimer file=\(relativePath) match=Timer\\n.scheduledTimer at line \(index + 1): \(line.trimmingCharacters(in: CharacterSet.whitespaces))")
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
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
    
    // MARK: - Crash Primitives Ban (Rule G)
    // Rule: App/Capture and Tests/CaptureTests must not use crash primitives
    // Allowlist: EMPTY (closed set empty) - no crash primitives allowed in PR4 scope
    
    func test_captureBansCrashPrimitives() {
        // Scan ONLY App/Capture (production code) - do NOT scan Tests/ to avoid self-trigger
        let scanDirs = [
            ("App/Capture", "App/Capture")
        ]
        
        // Closed set allowlist: EMPTY (no exceptions)
        let forbiddenPatterns = [
            "fatalError(",
            "preconditionFailure(",
            "assertionFailure(",
            "precondition(",
            "assert(",
            "dispatchPrecondition("
        ]
        
        for (_, relativePath) in scanDirs {
            guard let scanDir = RepoRootLocator.resolvePath(relativePath) else {
                XCTFail("Could not resolve \(relativePath) directory")
                continue
            }
            
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(at: scanDir, includingPropertiesForKeys: nil) else {
                XCTFail("Could not enumerate \(relativePath) directory")
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    continue
                }
                
                let fileRelativePath = fileURL.path.replacingOccurrences(of: scanDir.path + "/", with: "")
                let lines = content.components(separatedBy: CharacterSet.newlines)
                
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                    // Skip comments
                    if trimmed.hasPrefix("//") {
                        continue
                    }
                    
                    for pattern in forbiddenPatterns {
                        if line.contains(pattern) {
                            XCTFail("[PR4][SCAN] banned_crash_primitive file=\(relativePath)/\(fileRelativePath) match=\(pattern) at line \(index + 1): \(trimmed)")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Duplicate Filename Ban (Rule H)
    // Rule: Repository must not contain duplicate files with " 2.swift" or " * [0-9].swift" suffix
    // Allowlist: EMPTY (closed set empty) - no duplicate files allowed
    
    func test_repoBansDuplicateFilenames() {
        // CI-HARDENED: Use git ls-files -z for safe handling of filenames with spaces.
        // Closed-world: git is required for this test (fail-fast if missing).
        // ANTI-HANG: Filter to *.swift only, read pipes AFTER process exits, truncate output to 1MB max.
        // Rule H / Duplicate filename ban: Ban tracked Swift files ending with numeric suffix (e.g. "Foo 2.swift", "Bar10.swift").
        
        let process = Process()
        // Try common git paths (Linux CI compatible)
        let gitPaths = ["/usr/bin/git", "/usr/local/bin/git", "git"]
        var gitPath: String?
        
        for path in gitPaths {
            if path == "git" {
                // Try to find git in PATH
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["git"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                if (try? whichProcess.run()) != nil {
                    whichProcess.waitUntilExit()
                    if whichProcess.terminationStatus == 0 {
                        let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                        if let pathStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                           !pathStr.isEmpty {
                            gitPath = pathStr
                            break
                        }
                    }
                }
            } else {
                if FileManager.default.fileExists(atPath: path) {
                    gitPath = path
                    break
                }
            }
        }
        
        guard let git = gitPath else {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: git is required. Run inside a git repo / ensure CI provides git.")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: git)
        // Closed set: Filter to Swift files only, -- prevents path from being treated as flag
        process.arguments = ["ls-files", "-z", "--", "*.swift"]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        guard (try? process.run()) != nil else {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: Could not run git ls-files. Ensure git is available and you are in a git repository.")
            return
        }
        
        // ANTI-HANG: Timeout watchdog (5 seconds)
        let timeoutSeconds: TimeInterval = 5.0
        let timeoutTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        var wasTimeout = false
        let timeoutLock = NSLock()
        
        timeoutTimer.schedule(deadline: .now() + timeoutSeconds, repeating: .never)
        timeoutTimer.setEventHandler {
            timeoutLock.lock()
            defer { timeoutLock.unlock() }
            if process.isRunning {
                wasTimeout = true
                process.terminate()
            }
        }
        timeoutTimer.resume()
        
        // ANTI-HANG: Wait for process to exit BEFORE reading pipes (prevents deadlock)
        process.waitUntilExit()
        
        timeoutLock.lock()
        let timedOut = wasTimeout
        timeoutLock.unlock()
        timeoutTimer.cancel()
        
        // ANTI-HANG: Close write ends of pipes after process exits, then read
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        
        // Check for timeout termination
        if timedOut {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: git ls-files timed out after \(timeoutSeconds)s. Process terminated. Ensure repository is not too large or git is responsive.")
            return
        }
        
        guard process.terminationStatus == 0 else {
            // Read stderr with 8KB limit for error reporting
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrLimit = min(stderrData.count, 8192)
            let stderrTruncated = stderrData.prefix(stderrLimit)
            let stderrStr = String(data: stderrTruncated, encoding: .utf8) ?? "<could not decode stderr>"
            let truncatedNote = stderrData.count > 8192 ? " (truncated to 8KB)" : ""
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: git ls-files failed with status \(process.terminationStatus)\(truncatedNote). stderr: \(stderrStr)")
            return
        }
        
        // ANTI-HANG: Read output AFTER process exits and pipes closed, with 1MB limit to prevent memory explosion
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let maxOutputSize = 1024 * 1024  // 1MB limit
        let truncatedData = stdoutData.count > maxOutputSize ? stdoutData.prefix(maxOutputSize) : stdoutData
        
        guard !truncatedData.isEmpty else {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: git ls-files returned empty output")
            return
        }
        
        if stdoutData.count > maxOutputSize {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: git ls-files output exceeded 1MB limit (got \(stdoutData.count) bytes). Repository may be too large for this test.")
            return
        }
        
        // Parse NUL-separated output (closed set: only Swift files)
        let files = truncatedData.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
        
        // Allowlist for valid version-numbered or domain-specific filenames
        // These are NOT duplicates but intentionally named with numbers (e.g., V13 = version 13, Vector3 = 3D vector)
        let allowedPatterns: Set<String> = [
            "HardGatesV13.swift",           // Version 13 of HardGates
            "QuantizerQ01.swift",           // Q01 = quantizer for [0,1] range
            "EvidenceVector3.swift",        // Vector3 = 3D vector type
            "DeterminismDigestV2.swift",    // V2 = version 2 algorithm
            "LUTBinaryFormatV2.swift",      // V2 = version 2 format
            "Int128.swift",                 // Int128 = 128-bit integer type
            "PathDeterminismTraceV2.swift", // V2 = version 2 trace
            "SoftmaxExactSumV2.swift",      // V2 = version 2 algorithm
            "UUIDRFC4122.swift",            // RFC 4122 UUID implementation
            "gen-fixtures-decisionhash-v1.swift", // v1 = version 1 fixture generator script
        ]

        // Ban pattern: any Swift file basename ending with one or more digits + ".swift"
        // Regex: .*[0-9]+\.swift$ (matches "Foo 2.swift", "Foo2.swift", but NOT "Foo2Bar.swift")
        do {
            let regex = try NSRegularExpression(pattern: ".*[0-9]+\\.swift$", options: [])

            var violations: [String] = []
            for file in files {
                // Extract basename for pattern matching (closed set: only check filename, not path)
                let basename = (file as NSString).lastPathComponent

                // Skip allowlisted files
                if allowedPatterns.contains(basename) {
                    continue
                }

                let range = NSRange(basename.startIndex..., in: basename)
                if regex.firstMatch(in: basename, options: [], range: range) != nil {
                    violations.append(file)
                }
            }
            
            if !violations.isEmpty {
                // Output control: only show first 20 violations
                let violationList = violations.prefix(20).joined(separator: ", ")
                let moreCount = violations.count > 20 ? " (+\(violations.count - 20) more)" : ""
                XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: violation_count=\(violations.count). Files matching *[0-9]+.swift pattern: \(violationList)\(moreCount). Delete these duplicate files and merge any unique changes into the canonical files (without the number suffix).")
            }
        } catch {
            XCTFail("[PR4][SCAN] Rule H / Duplicate filename ban: Failed to compile regex pattern: \(error)")
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
        // Note: allowedFiles intentionally empty - no exceptions allowed
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: captureDir.path + "/", with: "")
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            // Check for .asyncAfter(
            if content.contains(".asyncAfter(") {
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
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
    
    // MARK: - New Constants Validation
    
    func test_bitrateEstimatesHaveAllTiers() {
        // Validate that all expected tier/fps combinations return valid bitrates
        // Note: These are the expected keys that should be covered by the test
        // (Previously defined as requiredKeys but validation is done via iteration)
        //   "8K_60", "8K_30", "4K_120", "4K_60", "4K_30",
        //   "1080p_120", "1080p_60", "1080p_30", "720p_60", "720p_30", "default"

        // Access private bitrateEstimates via estimatedBitrate function
        // We'll test that all tiers can be resolved
        let tiers: [ResolutionTier] = [.t8K, .t4K, .t1080p, .t720p, .t2K, .t480p, .lower]
        let fpsValues: [Double] = [120, 60, 30]

        for tier in tiers {
            for fps in fpsValues {
                let bitrate = CaptureRecordingConstants.estimatedBitrate(tier: tier, fps: fps)
                XCTAssertGreaterThan(bitrate, 0, "[PR4][SCAN] missing_bitrate_tier: \(tier.rawValue)@\(fps)fps")
            }
        }
    }
    
    func test_minBitrateFor3DReconstructionIsReasonable() {
        let minBitrate = CaptureRecordingConstants.minBitrateFor3DReconstruction
        XCTAssertGreaterThanOrEqual(minBitrate, 30_000_000, "[PR4][SCAN] Min 3D bitrate should be >= 30 Mbps")
        XCTAssertLessThanOrEqual(minBitrate, 100_000_000, "[PR4][SCAN] Min 3D bitrate should be <= 100 Mbps")
    }
    
    func test_fpsMatchToleranceIsTight() {
        let tolerance = CaptureRecordingConstants.fpsMatchTolerance
        XCTAssertLessThanOrEqual(tolerance, 0.1, "[PR4][SCAN] FPS tolerance should be <= 0.1 for precision")
        XCTAssertGreaterThanOrEqual(tolerance, 0.05, "[PR4][SCAN] FPS tolerance should allow NTSC compatibility")
    }
    
    func test_thermalWeightsAreOrdered() {
        XCTAssertLessThan(
            CaptureRecordingConstants.thermalWeightNominal,
            CaptureRecordingConstants.thermalWeightFair,
            "[PR4][SCAN] Nominal < Fair"
        )
        XCTAssertLessThan(
            CaptureRecordingConstants.thermalWeightFair,
            CaptureRecordingConstants.thermalWeightSerious,
            "[PR4][SCAN] Fair < Serious"
        )
        XCTAssertLessThan(
            CaptureRecordingConstants.thermalWeightSerious,
            CaptureRecordingConstants.thermalWeightCritical,
            "[PR4][SCAN] Serious < Critical"
        )
    }
    
    func test_thermalWeightsAreMonotonic() {
        // Thermal weights must increase with severity
        XCTAssertEqual(CaptureRecordingConstants.thermalWeightNominal, 0, "[PR4][SCAN] Nominal should be 0")
        XCTAssertEqual(CaptureRecordingConstants.thermalWeightFair, 1, "[PR4][SCAN] Fair should be 1")
        XCTAssertEqual(CaptureRecordingConstants.thermalWeightSerious, 2, "[PR4][SCAN] Serious should be 2")
        XCTAssertEqual(CaptureRecordingConstants.thermalWeightCritical, 3, "[PR4][SCAN] Critical should be 3")
    }
    
    func test_storageThresholdsAreReasonable() {
        let base = CaptureRecordingConstants.minFreeSpaceBytesBase
        let warning = CaptureRecordingConstants.lowStorageWarningBytes
        let critical = CaptureRecordingConstants.criticalStorageBytes
        
        XCTAssertGreaterThan(warning, critical, "[PR4][SCAN] Warning threshold should be > critical")
        XCTAssertGreaterThanOrEqual(base, critical, "[PR4][SCAN] Base minimum should be >= critical")
    }
    
    // MARK: - Cross-Platform Compatibility Scan
    
    func test_coreConstantsContainNoPlatformSpecificCode() {
        guard let constantsPath = RepoRootLocator.resolvePath("Core/Constants") else {
            XCTFail("[PR4][SCAN] Could not resolve Core/Constants directory")
            return
        }
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: constantsPath, includingPropertiesForKeys: nil) else {
            XCTFail("[PR4][SCAN] Could not enumerate Core/Constants")
            return
        }
        
        let forbiddenPlatformPatterns = [
            "UIDevice",
            "UIKit",
            "AppKit",
            "ProcessInfo.processInfo.thermalState",
            "Bundle.main",
            "#if os(iOS)",
            "#if os(macOS)",
            "#if targetEnvironment"
        ]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                
                for pattern in forbiddenPlatformPatterns {
                    if line.contains(pattern) {
                        XCTFail("[PR4][SCAN] platform_specific_code file=\(fileURL.lastPathComponent) pattern=\(pattern) line=\(index + 1)")
                    }
                }
            }
        }
    }
    
    // MARK: - Linux CI Compatibility
    
    func test_noAppleOnlyAPIsInCoreConstants() {
        let forbiddenAPIs = [
            "CMTime(",
            "AVAsset",
            "AVCapture",
            "CIImage",
            "CGImage",
            "UIImage",
            "NSImage"
        ]
        
        // This test validates Core/Constants can compile on Linux
        guard let path = RepoRootLocator.resolvePath("Core/Constants") else {
            XCTFail("[PR4][SCAN] Could not resolve path")
            return
        }
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil) else {
            return
        }
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            for api in forbiddenAPIs {
                if content.contains(api) {
                    XCTFail("[PR4][SCAN] apple_only_api file=\(fileURL.lastPathComponent) api=\(api)")
                }
            }
        }
    }
    
    func test_coreConstantsHaveNoPlatformConditionals() {
        guard let path = RepoRootLocator.resolvePath("Core/Constants") else {
            XCTFail("[PR4][SCAN] Could not resolve path")
            return
        }
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil) else {
            return
        }
        
        let forbiddenPatterns = [
            "#if os(iOS)",
            "#if os(macOS)",
            "#if targetEnvironment",
            "#if canImport(UIKit)",
            "#if canImport(AppKit)"
        ]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            for pattern in forbiddenPatterns {
                if content.contains(pattern) {
                    XCTFail("[PR4][SCAN] platform_conditional file=\(fileURL.lastPathComponent) pattern=\(pattern)")
                }
            }
        }
    }
    
    func test_resolutionTierFrozenCaseOrderHash() {
        // Verify ResolutionTier case order hasn't changed
        let caseNames = ResolutionTier.allCases.map { $0.rawValue }
        XCTAssertEqual(caseNames.count, 7, "[PR4][SCAN] ResolutionTier should have 7 cases after enhancement")
        
        // Verify order: original 5 cases first, then new ones appended
        let expectedOrder = ["8K", "4K", "1080p", "720p", "lower", "2K", "480p"]
        XCTAssertEqual(caseNames, expectedOrder, "[PR4][SCAN] ResolutionTier cases must maintain append-only order")
    }
    
    func test_captureQualityPresetFrozenCaseOrderHash() {
        let caseNames = CaptureQualityPreset.allCases.map { $0.rawValue }
        XCTAssertEqual(caseNames.count, 6, "[PR4][SCAN] CaptureQualityPreset should have 6 cases")
        
        let expectedOrder = ["economy", "standard", "high", "ultra", "proRes", "proResMax"]
        XCTAssertEqual(caseNames, expectedOrder, "[PR4][SCAN] CaptureQualityPreset cases must maintain order")
    }
    
    func test_constantsAreCompileTimeDeterministic() {
        // These constants must be identical across runs
        let bitrate1 = CaptureRecordingConstants.estimatedBitrate(tier: .t4K, fps: 60)
        let bitrate2 = CaptureRecordingConstants.estimatedBitrate(tier: .t4K, fps: 60)
        XCTAssertEqual(bitrate1, bitrate2, "[PR4][SCAN] Constants must be deterministic")
        
        // Verify constants exist at compile time
        XCTAssertGreaterThan(bitrate1, 0, "[PR4][SCAN] 4K_60 bitrate must exist at compile time")
    }
    
    func test_proResConstantsAreReasonable() {
        // ProRes 422 HQ at 4K30 should be ~165 Mbps
        let proRes4K30 = CaptureRecordingConstants.proRes422HQBitrate4K30
        XCTAssertGreaterThanOrEqual(proRes4K30, 150_000_000, "[PR4][SCAN] ProRes 4K30 >= 150 Mbps")
        XCTAssertLessThanOrEqual(proRes4K30, 200_000_000, "[PR4][SCAN] ProRes 4K30 <= 200 Mbps")
        
        // ProRes 422 HQ at 4K60 should be ~330 Mbps
        let proRes4K60 = CaptureRecordingConstants.proRes422HQBitrate4K60
        XCTAssertGreaterThanOrEqual(proRes4K60, 300_000_000, "[PR4][SCAN] ProRes 4K60 >= 300 Mbps")
        XCTAssertLessThanOrEqual(proRes4K60, 400_000_000, "[PR4][SCAN] ProRes 4K60 <= 400 Mbps")
        
        // Storage write speed requirement
        let writeSpeed = CaptureRecordingConstants.proResMinStorageWriteSpeedMBps
        XCTAssertGreaterThanOrEqual(writeSpeed, 200, "[PR4][SCAN] ProRes requires >= 200 MB/s write speed")
    }
    
    func test_noHardcodedDeviceModelsInAppCapture() {
        guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
            XCTFail("[PR4][SCAN] Could not resolve App/Capture directory")
            return
        }
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
            return
        }
        
        // Device model strings should be in CaptureRecordingConstants, not hardcoded
        let forbiddenPatterns = [
            "\"iPhone15,2\"",
            "\"iPhone15,3\"",
            "\"iPhone16,1\"",
            "\"iPhone16,2\""
        ]
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard fileURL.lastPathComponent != "CaptureRecordingConstants.swift" else { continue }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            for pattern in forbiddenPatterns {
                if content.contains(pattern) {
                    XCTFail("[PR4][SCAN] hardcoded_device_model file=\(fileURL.lastPathComponent) pattern=\(pattern)")
                }
            }
        }
    }
}

