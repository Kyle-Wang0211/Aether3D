// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PolicyEpochConcurrencyTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - PolicyEpoch Concurrency Stress Tests (>=100 tasks)
//
// Actor concurrency stress and rollback detection
//

import XCTest
@testable import Aether3DCore

final class PolicyEpochConcurrencyTests: XCTestCase {
    /// Concurrency stress: 100 tasks updating epochs for same tier
    func testPolicyEpoch_ConcurrentUpdates() async throws {
        let registry = PolicyEpochRegistry.shared
        await registry.reset()
        
        let tierId: UInt16 = 1
        var checks = 0
        let taskCount = 100
        
        // Launch concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    CheckCounter.increment()
                    do {
                        try await registry.validateAndUpdate(
                            tierId: tierId,
                            policyEpoch: UInt32(i + 1),
                            schemaVersion: 0x0204
                        )
                    } catch {
                        // Some may fail if epoch decreases, that's expected
                    }
                }
            }
        }
        
        // Verify final max epoch
        let maxEpoch = await registry.maxEpoch(for: tierId)
        CheckCounter.increment()
        checks += 1
        XCTAssertNotNil(maxEpoch, "Max epoch must be recorded")
        
        CheckCounter.increment()
        checks += 1
        XCTAssertGreaterThanOrEqual(maxEpoch ?? 0, UInt32(taskCount), "Max epoch must be at least taskCount")
        
        print("PolicyEpoch Concurrency: \(taskCount) tasks, \(checks) checks")
    }
    
    /// Rollback detection: rollback attempts must fail-closed
    func testPolicyEpoch_RollbackDetection() async throws {
        let registry = PolicyEpochRegistry.shared
        await registry.reset()

        let tierId: UInt16 = 1
        var checks = 0

        // Set initial epoch to 100
        try await registry.validateAndUpdate(
            tierId: tierId,
            policyEpoch: 100,
            schemaVersion: 0x0204
        )

        // Attempt rollback to epochs 0-49 (all < 100, should fail)
        var rollbackFailures = 0
        let rollbackAttempts = 50
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<rollbackAttempts {
                group.addTask {
                    CheckCounter.increment()
                    do {
                        // Attempt rollback to lower epoch (all < 100)
                        try await registry.validateAndUpdate(
                            tierId: tierId,
                            policyEpoch: UInt32(i), // 0-49, all < 100
                            schemaVersion: 0x0204
                        )
                        return false // Should not succeed
                    } catch {
                        return true // Expected failure
                    }
                }
            }

            for await failed in group {
                if failed {
                    rollbackFailures += 1
                }
            }
        }

        // All rollback attempts (to epochs < 100) must fail
        CheckCounter.increment()
        checks += 1
        XCTAssertEqual(rollbackFailures, rollbackAttempts, "All rollback attempts must fail-closed")

        print("PolicyEpoch Rollback Detection: \(rollbackFailures) failures, \(checks) checks")
    }
}
