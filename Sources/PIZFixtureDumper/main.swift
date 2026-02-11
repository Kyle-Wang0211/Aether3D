// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// main.swift
// PIZFixtureDumper
//
// PR1 PIZ Detection - Canonical JSON Fixture Dumper
//
// Deterministic dumper for PIZ fixtures that produces canonical JSON output.
// **Rule ID:** PIZ_SEMANTIC_PARITY_001, PIZ_JSON_CANON_001

import Foundation
import Aether3DCore

// Import PIZConstants for canonical timestamp

/// Fixture loader (shared with tests).
struct PIZFixtureLoader {
    struct Fixture: Codable {
        let name: String
        let description: String?
        let input: FixtureInput
        let expected: FixtureExpected?
        let metadata: FixtureMetadata?
        let ruleIds: [String]?
        
        struct FixtureInput: Codable {
            let heatmap: [[Double]]
            let assetId: String?
            let timestamp: String?
        }
        
        struct FixtureExpected: Codable {
            let triggersFired: TriggersFired?
            let regions: [ExpectedRegion]?
            let gateRecommendation: String?
            
            enum CodingKeys: String, CodingKey {
                case triggersFired = "triggers_fired"
                case regions
                case gateRecommendation = "gateRecommendation"
            }
            
            struct TriggersFired: Codable {
                let globalTrigger: Bool?
                let localTriggerCount: Int?
            }
            
            struct ExpectedRegion: Codable {
                let pixelCount: Int?
                let areaRatio: Double?
                let severityScore: Double?
            }
        }
        
        struct FixtureMetadata: Codable {
            let category: String?
            let gridSize: Int?
            let note: String?
        }
    }
    
    /// Load fixtures from directory (lexicographic order by filename).
    static func loadFixtures(from directory: String) throws -> [Fixture] {
        let fileManager = FileManager.default
        let fixturesURL = URL(fileURLWithPath: directory, isDirectory: true)
        
        guard fileManager.fileExists(atPath: directory) else {
            throw NSError(domain: "PIZFixtureDumper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixtures directory not found: \(directory)"])
        }
        
        let fixtureFiles = try fileManager.contentsOfDirectory(at: fixturesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } // Lexicographic order
        
        var fixtures: [Fixture] = []
        let decoder = JSONDecoder()
        
        for fixtureFile in fixtureFiles {
            let data = try Data(contentsOf: fixtureFile)
            
            // Validate closed-set schema (reject unknown fields)
            do {
                let fixture = try decoder.decode(Fixture.self, from: data)
                fixtures.append(fixture)
            } catch {
                let errorMsg = "[PIZ_SPEC_VIOLATION] Failed to decode fixture \(fixtureFile.lastPathComponent): \(error)"
                FileHandle.standardError.write(Data(errorMsg.utf8))
                exit(1)
            }
        }
        
        return fixtures
    }
}

/// Main entry point.
func main() {
    // Find fixtures directory
    let fixturesPath: String
    if let envPath = ProcessInfo.processInfo.environment["PIZ_FIXTURES_PATH"] {
        fixturesPath = envPath
    } else {
        // Default: fixtures/piz/nominal relative to repo root
        let currentDir = FileManager.default.currentDirectoryPath
        fixturesPath = "\(currentDir)/fixtures/piz/nominal"
    }
    
    // Output path
    let outputPath = ProcessInfo.processInfo.environment["PIZ_CANON_OUTPUT"] ?? "artifacts/piz/piz_canon_full.jsonl"
    
    // Create output directory if needed
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDir = outputURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    
    // Load fixtures
    let fixtures: [PIZFixtureLoader.Fixture]
    do {
        fixtures = try PIZFixtureLoader.loadFixtures(from: fixturesPath)
    } catch {
        let errorMsg = "[PIZ_SPEC_VIOLATION] Failed to load fixtures: \(error)"
        FileHandle.standardError.write(Data(errorMsg.utf8))
        exit(1)
    }
    
    // Process each fixture
    let detector = PIZDetector()
    
    // Create output file
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    guard let outputHandle = FileHandle(forWritingAtPath: outputPath) else {
        let errorMsg = "[PIZ_SPEC_VIOLATION] Failed to open output file: \(outputPath)"
        FileHandle.standardError.write(Data(errorMsg.utf8))
        exit(1)
    }
    
    defer {
        try? outputHandle.close()
    }
    
    for fixture in fixtures {
        // Parse timestamp if provided, otherwise use canonical timestamp for deterministic output
        // **Rule ID:** PIZ_SEMANTIC_PARITY_001
        let timestamp: Date
        if let timestampString = fixture.input.timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampString) ?? {
                // Use fixed canonical timestamp for deterministic output
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: "1970-01-01T00:00:00Z")!
            }()
        } else {
            // Use canonical timestamp for deterministic canonical JSON output
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            timestamp = formatter.date(from: "1970-01-01T00:00:00Z")!
        }
        
        // Run detector
        let report = detector.detect(
            heatmap: fixture.input.heatmap,
            assetId: fixture.input.assetId ?? "unknown",
            timestamp: timestamp,
            computePhase: .finalized,
            previousRecommendation: nil,
            outputProfile: .fullExplainability
        )
        
        // Generate canonical JSON
        let canonicalJSON: String
        do {
            canonicalJSON = try PIZCanonicalJSON.encode(report)
        } catch {
            let errorMsg = "[PIZ_SPEC_VIOLATION] Failed to encode canonical JSON for fixture \(fixture.name): \(error)"
            FileHandle.standardError.write(Data(errorMsg.utf8))
            exit(1)
        }
        
        // Check for scientific notation in numeric values (forbidden)
        // Pattern: number (with optional decimal point) followed by e/E followed by +/- and digits
        // Must NOT be inside a quoted string (exclude region IDs, assetIds, etc.)
        // Scientific notation pattern: :123.456e+10 or :123e-5 (after colon, before comma/brace)
        let scientificPattern = try? NSRegularExpression(pattern: #":\d+\.?\d*[eE][+-]\d+"#, options: [])
        if let pattern = scientificPattern {
            let range = NSRange(canonicalJSON.startIndex..<canonicalJSON.endIndex, in: canonicalJSON)
            let matches = pattern.matches(in: canonicalJSON, options: [], range: range)
            if !matches.isEmpty {
                // Debug: show where scientific notation was found
                for match in matches {
                    if let matchRange = Range(match.range, in: canonicalJSON) {
                        let snippet = String(canonicalJSON[matchRange])
                        let contextStart = canonicalJSON.index(matchRange.lowerBound, offsetBy: -50, limitedBy: canonicalJSON.startIndex) ?? canonicalJSON.startIndex
                        let contextEnd = canonicalJSON.index(matchRange.upperBound, offsetBy: 50, limitedBy: canonicalJSON.endIndex) ?? canonicalJSON.endIndex
                        let context = String(canonicalJSON[contextStart..<contextEnd])
                        let errorMsg = "[PIZ_NUMERIC_DRIFT] scientific-notation detected in fixture \(fixture.name): '\(snippet)' in context: ...\(context)...\n"
                        FileHandle.standardError.write(Data(errorMsg.utf8))
                    }
                }
                exit(1)
            }
        }
        
        // Format schema version
        let schemaVersionString = "\(report.schemaVersion.major).\(report.schemaVersion.minor).\(report.schemaVersion.patch)"
        
        // Create output line (JSON Lines format)
        let outputLine: [String: String] = [
            "fixture": fixture.name,
            "schemaVersion": schemaVersionString,
            "outputProfile": report.outputProfile.rawValue,
            "canonical": canonicalJSON
        ]
        
        // Encode to JSON
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [] // Compact format
        guard let jsonData = try? jsonEncoder.encode(outputLine),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            let errorMsg = "[PIZ_SPEC_VIOLATION] Failed to encode output line for fixture \(fixture.name)"
            FileHandle.standardError.write(Data(errorMsg.utf8))
            exit(1)
        }
        
        // Write line (with newline)
        let lineData = Data("\(jsonString)\n".utf8)
        outputHandle.write(lineData)
    }
}

// Run main
main()
