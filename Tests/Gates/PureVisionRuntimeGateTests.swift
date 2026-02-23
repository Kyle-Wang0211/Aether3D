// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import XCTest
@testable import Aether3DCore

final class PureVisionRuntimeGateTests: XCTestCase {
    private struct Fixture: Decodable {
        struct GateCase: Decodable {
            let name: String
            let metrics: PureVisionRuntimeMetrics
            let expected_failed_gates: [String]
        }

        struct Expected: Decodable {
            let target_success_rate: Double
            let target_replay_stable_rate: Double
            let max_hard_cap_violations: Int
            let expected_failure_reason: String
            let expected_failure_count: Int
        }

        let gate_cases: [GateCase]
        let first_scan_samples: [FirstScanReplaySample]
        let expected: Expected
    }

    func testPureVisionGateCasesMatchExpectedFailures() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.gate_cases.isEmpty)

        for gateCase in fixture.gate_cases {
            let failed = Set(PureVisionRuntimeGateEvaluator.failedGateIDs(gateCase.metrics).map(\.rawValue))
            XCTAssertEqual(
                failed,
                Set(gateCase.expected_failed_gates),
                "Gate mismatch for case: \(gateCase.name)"
            )
        }
    }

    func testFirstScanKPIReplayFixturePassesAndWritesRuntimeReport() throws {
        let fixture = try loadFixture()
        let report = FirstScanKPIEvaluator.evaluate(samples: fixture.first_scan_samples)

        XCTAssertGreaterThanOrEqual(report.firstScanSuccessRate, fixture.expected.target_success_rate)
        XCTAssertGreaterThanOrEqual(report.replayStableRate, fixture.expected.target_replay_stable_rate)
        XCTAssertLessThanOrEqual(report.hardCapViolations, fixture.expected.max_hard_cap_violations)
        XCTAssertEqual(
            report.failureReasons[fixture.expected.expected_failure_reason, default: 0],
            fixture.expected.expected_failure_count
        )
        XCTAssertTrue(report.passesGate)

        try writeRuntimeReport(report)
    }

    private func loadFixture() throws -> Fixture {
        let repoRoot = try resolveRepoRoot()
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/pure_vision_runtime_replay_v1.json")
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func resolveRepoRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        throw NSError(domain: "PureVisionRuntimeGateTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to locate repository root (Package.swift not found)."
        ])
    }

    private func writeRuntimeReport(_ report: FirstScanKPIReport) throws {
        let repoRoot = try resolveRepoRoot()
        let outURL = repoRoot.appendingPathComponent("governance/generated/first_scan_runtime_metrics.json")
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: outURL, options: .atomic)
    }
}

