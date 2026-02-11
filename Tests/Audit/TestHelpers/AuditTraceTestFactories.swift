// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// AuditTraceTestFactories.swift
// PR#8.5 / v0.0.1

import Foundation
@testable import Aether3DCore

/// Shared test helper factories for audit trace tests.
enum AuditTraceTestFactories {
    
    static func makeTestBuildMeta() -> BuildMeta {
        return BuildMeta(
            version: "test",
            buildId: "test-build",
            gitCommit: "test-commit",
            buildTime: "test-time"
        )
    }
    
    static func makeTestPolicyHash() -> String {
        return String(repeating: "a", count: 64)
    }
    
    static func makeEmitter(
        log: InMemoryAuditLog,
        policyHash: String? = nil,
        pipelineVersion: String = "B1"
    ) -> AuditTraceEmitter {
        return AuditTraceEmitter(
            appendEntry: log.makeAppendClosure(),
            policyHash: policyHash ?? makeTestPolicyHash(),
            pipelineVersion: pipelineVersion,
            buildMeta: makeTestBuildMeta(),
            wallClock: { Date(timeIntervalSince1970: 1000) }
        )
    }
}

