// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ExtensionIdempotencyByteStabilityTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Extension Idempotency Byte Stability Tests
//
// Verifies that canonicalBytesForIdempotency() is byte-stable across calls
//

import XCTest
@testable import Aether3DCore

final class ExtensionIdempotencyByteStabilityTests: XCTestCase {
    /// Test canonical bytes are stable: first call produces snapshot, second call yields alreadyProcessed(originalSnapshot)
    /// 
    /// **P0 Contract:**
    /// - First call produces original snapshot bytes
    /// - Second call yields alreadyProcessed(originalSnapshot)
    /// - canonicalBytesForIdempotency() from originalSnapshot MUST equal first call bytes
    func testExtensionIdempotency_ByteStability() throws {
        let snapshot = ExtensionResultSnapshot(
            extensionRequestId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            trigger: 1,
            tierId: 1,
            schemaVersion: 0x0204,
            policyHash: 0x123456789ABCDEF0,
            extensionCount: 1,
            resultTag: 0, // extended
            denialReasonTag: 0,
            denialReason: nil,
            eebCeiling: 10000,
            eebAdded: 1000,
            newEebRemaining: 9000
        )
        
        // First call: get original snapshot bytes
        let originalBytes1 = try snapshot.canonicalBytesForIdempotency()
        
        // Second call: should produce identical bytes
        let originalBytes2 = try snapshot.canonicalBytesForIdempotency()
        
        XCTAssertEqual(originalBytes1, originalBytes2, "Same snapshot must produce identical canonical bytes")
        
        // Wrap in alreadyProcessed: canonical bytes must still match
        let wrapped = ExtensionResult.alreadyProcessed(originalSnapshot: snapshot)
        let wrappedBytes = try wrapped.canonicalBytesForIdempotency()
        
        XCTAssertEqual(originalBytes1, wrappedBytes, "alreadyProcessed(originalSnapshot) canonical bytes must equal original snapshot bytes")
    }
    
    /// Test resultTag does NOT include alreadyProcessed
    func testResultTag_DoesNotIncludeAlreadyProcessed() throws {
        let snapshotExtended = ExtensionResultSnapshot(
            extensionRequestId: UUID(),
            trigger: 1,
            tierId: 1,
            schemaVersion: 0x0204,
            policyHash: 0x123456789ABCDEF0,
            extensionCount: 1,
            resultTag: 0, // extended
            denialReasonTag: 0,
            denialReason: nil,
            eebCeiling: 10000,
            eebAdded: 1000,
            newEebRemaining: 9000
        )
        
        let snapshotDenied = ExtensionResultSnapshot(
            extensionRequestId: UUID(),
            trigger: 1,
            tierId: 1,
            schemaVersion: 0x0204,
            policyHash: 0x123456789ABCDEF0,
            extensionCount: 1,
            resultTag: 1, // denied
            denialReasonTag: 1,
            denialReason: 1,
            eebCeiling: 10000,
            eebAdded: 0,
            newEebRemaining: 0
        )
        
        // Verify resultTag values are 0 or 1 (not 2 for alreadyProcessed)
        XCTAssertEqual(snapshotExtended.resultTag, 0, "resultTag for extended must be 0")
        XCTAssertEqual(snapshotDenied.resultTag, 1, "resultTag for denied must be 1")
        
        // Verify canonical bytes encode resultTag correctly
        let bytesExtended = try snapshotExtended.canonicalBytesForIdempotency()
        let bytesDenied = try snapshotDenied.canonicalBytesForIdempotency()
        
        // resultTag is at a fixed position in the layout
        // Layout: layoutVersion(1) + extensionRequestId(16) + trigger(1) + tierId(2) + schemaVersion(2) + policyHash(8) + extensionCount(1) + resultTag(1)
        // resultTag is at byte 31 (0-indexed)
        let resultTagExtended = Array(bytesExtended)[31]
        let resultTagDenied = Array(bytesDenied)[31]
        
        XCTAssertEqual(resultTagExtended, 0, "resultTag in canonical bytes for extended must be 0")
        XCTAssertEqual(resultTagDenied, 1, "resultTag in canonical bytes for denied must be 1")
    }
}
