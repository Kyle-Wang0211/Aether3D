// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CryptoBackendPolicyTests.swift
//  Aether3D
//
//  PR#1 SSOT Foundation v1.1.1 - Crypto Backend Policy Tests
//  Enforces deterministic backend selection policy via executable assertions
//

import XCTest
@testable import Aether3DCore

/// Tests for crypto backend policy enforcement.
///
/// **Purpose:** Validates that backend selection matches policy:
/// - Linux Gate 2: SSOT_PURE_SWIFT_SHA256=1 → PURE_SWIFT backend
/// - macOS: No SSOT_PURE_SWIFT_SHA256 → NATIVE backend (CryptoKit)
///
/// **Rule ID:** Backend selection policy (Linux SIGILL mitigation)
/// **Status:** IMMUTABLE
///
/// This test runs early in Gate 2 to fail fast if backend selection violates policy.
final class CryptoBackendPolicyTests: XCTestCase {
    
    /// Enforces backend selection policy: Linux with SSOT_PURE_SWIFT_SHA256=1 must use PURE_SWIFT
    func test_linuxGate2BackendPolicy() {
        #if os(Linux)
        let envValue = ProcessInfo.processInfo.environment["SSOT_PURE_SWIFT_SHA256"]
        let backendName = CryptoShim.activeBackendName()
        
        if envValue == "1" {
            // Policy: SSOT_PURE_SWIFT_SHA256=1 → PURE_SWIFT backend (required for Gate 2 stability)
            XCTAssertEqual(backendName, "PURE_SWIFT", 
                          "Linux Gate 2 with SSOT_PURE_SWIFT_SHA256=1 must use PURE_SWIFT backend (policy enforcement)")
        } else {
            // If env is not set, backend selection is not constrained by this test
            // (This test only enforces policy when SSOT_PURE_SWIFT_SHA256=1 is explicitly set)
            XCTAssertTrue(backendName == "PURE_SWIFT" || backendName == "NATIVE",
                         "Backend must be either PURE_SWIFT or NATIVE")
        }
        #else
        // Non-Linux platforms: skip this policy check
        XCTAssertTrue(true, "Backend policy test applies only to Linux")
        #endif
    }
    
    /// Enforces backend selection policy: macOS must use NATIVE backend (CryptoKit)
    func test_macosBackendPolicy() {
        #if os(macOS)
        let backendName = CryptoShim.activeBackendName()
        // Policy: macOS → NATIVE backend (CryptoKit)
        XCTAssertEqual(backendName, "NATIVE",
                      "macOS must use NATIVE backend (CryptoKit) - policy enforcement")
        #else
        // Non-macOS platforms: skip this policy check
        XCTAssertTrue(true, "Backend policy test applies only to macOS")
        #endif
    }
    
    /// Validates that activeBackendName() returns a stable, non-empty identifier
    func test_backendNameStability() {
        let backendName = CryptoShim.activeBackendName()
        XCTAssertFalse(backendName.isEmpty, "Backend name must not be empty")
        XCTAssertTrue(backendName == "PURE_SWIFT" || backendName == "NATIVE",
                     "Backend name must be exactly 'PURE_SWIFT' or 'NATIVE', got: '\(backendName)'")
        
        // Ensure consistency: multiple calls return the same value
        let secondCall = CryptoShim.activeBackendName()
        XCTAssertEqual(backendName, secondCall, "Backend name must be stable across multiple calls")
    }
}
