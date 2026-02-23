// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Thread-safe runtime counter for evidence invariant violations.
/// This is consumed by PureVision runtime audits to avoid test-only injection.
public final class EvidenceInvariantMonitor: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let totalViolationCount: Int
        public let violationCountsByRule: [String: Int]

        public init(totalViolationCount: Int, violationCountsByRule: [String: Int]) {
            self.totalViolationCount = totalViolationCount
            self.violationCountsByRule = violationCountsByRule
        }
    }

    public static let shared = EvidenceInvariantMonitor()

    private let lock = NSLock()
    private var totalViolationCount: Int = 0
    private var violationCountsByRule: [String: Int] = [:]

    private init() {}

    public func recordViolation(rule: String) {
        lock.lock()
        totalViolationCount += 1
        violationCountsByRule[rule, default: 0] += 1
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            totalViolationCount: totalViolationCount,
            violationCountsByRule: violationCountsByRule
        )
        lock.unlock()
        return snapshot
    }

    public func reset() {
        lock.lock()
        totalViolationCount = 0
        violationCountsByRule.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
