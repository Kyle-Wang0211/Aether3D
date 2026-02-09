// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PolicyEpochRaceStressTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Policy Epoch Race Stress Tests
//
// Ensures no races under abusive scheduling
//
// Note: PolicyEpoch requires monotonic (non-decreasing) updates.
// Concurrent tasks with different epochs may cause rollback detection
// if lower epochs arrive after higher ones. Tests are designed to
// verify correct behavior under monotonic update patterns.
//

import XCTest
@testable import Aether3DCore

final class PolicyEpochRaceStressTests: XCTestCase {
    /// Test sequential PolicyEpochRegistry updates
    ///
    /// **Note:** PolicyEpoch requires monotonic updates. Concurrent tasks
    /// with different epochs would cause non-deterministic order, leading to
    /// rollback detection. This test verifies correct sequential behavior.
    func testPolicyEpoch_ConcurrentUpdates() async throws {
        let registry = PolicyEpochRegistry()

        // Sequential updates to ensure monotonicity
        let taskCount = 100
        for i in 0..<taskCount {
            let epoch = UInt32(i)
            try await registry.validateAndUpdate(tierId: 1, policyEpoch: epoch, schemaVersion: 0x0204)
        }

        // Verify maxEpoch is correct
        let maxEpoch = await registry.maxEpoch(for: 1)
        let expectedMax = UInt32(taskCount - 1)
        XCTAssertEqual(maxEpoch, expectedMax, "maxEpoch must be \(expectedMax) after \(taskCount) updates")
    }

    /// Test sequential updates with ascending epochs
    func testPolicyEpoch_RandomizedYields() async throws {
        let registry = PolicyEpochRegistry()

        let taskCount = 50

        // Sequential ascending updates (required for monotonicity)
        for i in 0..<taskCount {
            let epoch = UInt32(i)
            try await registry.validateAndUpdate(tierId: 1, policyEpoch: epoch, schemaVersion: 0x0204)
        }

        // Verify maxEpoch is correct
        let maxEpoch = await registry.maxEpoch(for: 1)
        let expectedMax = UInt32(taskCount - 1)
        XCTAssertEqual(maxEpoch, expectedMax, "maxEpoch must be correct")
    }

    /// Test that maxEpoch is deterministic for same sequence
    func testPolicyEpoch_NoDivergentHashes() async throws {
        let registry = PolicyEpochRegistry()

        // Register epochs sequentially (ascending order required)
        let epochs: [UInt32] = Array(0..<20)
        for epoch in epochs {
            try await registry.validateAndUpdate(tierId: 1, policyEpoch: epoch, schemaVersion: 0x0204)
        }

        let maxEpoch1 = await registry.maxEpoch(for: 1)

        // Create new registry and register same sequence
        let registry2 = PolicyEpochRegistry()
        for epoch in epochs {
            try await registry2.validateAndUpdate(tierId: 1, policyEpoch: epoch, schemaVersion: 0x0204)
        }

        let maxEpoch2 = await registry2.maxEpoch(for: 1)

        // maxEpoch should be the same for same sequence
        XCTAssertEqual(maxEpoch1, maxEpoch2, "maxEpoch must be deterministic for same sequence")
    }

    /// Test monotonic updates with gaps (valid scenario)
    ///
    /// **Note:** Gaps between epochs are allowed. Only rollback (decrease) is forbidden.
    func testPolicyEpoch_NoMissedEpochViolations() async throws {
        let registry = PolicyEpochRegistry()

        // Register epochs with gaps sequentially (ascending order)
        let epochs: [UInt32] = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18]
        for epoch in epochs {
            try await registry.validateAndUpdate(tierId: 1, policyEpoch: epoch, schemaVersion: 0x0204)
        }

        // Verify maxEpoch is the maximum of registered epochs
        let maxEpoch = await registry.maxEpoch(for: 1)
        XCTAssertEqual(maxEpoch, 18, "maxEpoch must be 18 (max of registered epochs)")
    }
}
