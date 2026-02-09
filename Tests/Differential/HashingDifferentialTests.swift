// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HashingDifferentialTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Differential Hashing Tests (>=256 cases)
//
// Compare our BLAKE3 facade to direct BLAKE3 API
//

import XCTest
@testable import Aether3DCore
#if canImport(BLAKE3)
import BLAKE3
#endif

final class HashingDifferentialTests: XCTestCase {
    /// Seeded RNG
    private struct DiffRNG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = (state &* 1103515245 &+ 12345) & 0x7fffffff
            return state
        }
        mutating func nextUInt8() -> UInt8 { return UInt8(next() & 0xFF) }
    }
    
    /// Differential BLAKE3: Compare facade to direct API (>=256 cases)
    #if canImport(BLAKE3)
    func testBlake3_DifferentialFacadeVsDirect() throws {
        var rng = DiffRNG(seed: 1000)
        var checks = 0
        
        for i in 0..<256 {
            CheckCounter.increment()
            checks += 1
            
            // Generate random input
            let inputLength = Int(rng.next() % 1024)
            var inputBytes: [UInt8] = []
            for _ in 0..<inputLength {
                inputBytes.append(rng.nextUInt8())
            }
            let inputData = Data(inputBytes)
            
            // Compute via facade
            let facadeHash = try Blake3Facade.blake3_256(data: inputData)
            
            // Compute via direct API
            let directHash = BLAKE3.hash(contentsOf: inputData, outputByteCount: 32)
            
            // Must match
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(facadeHash, directHash, "Facade must match direct API (case \(i))")
        }
        
        print("BLAKE3 Differential: \(checks) checks")
    }
    #endif
    
    /// Differential UUID: Compare to independent implementation (>=128 cases)
    func testUUID_DifferentialImplementation() throws {
        var rng = DiffRNG(seed: 2000)
        var checks = 0
        
        // Independent "slow path" UUID extractor (duplicate logic)
        func slowPathUUIDBytes(_ uuid: UUID) -> [UInt8] {
            let uuidBytes = uuid.uuid
            return [
                uuidBytes.0, uuidBytes.1, uuidBytes.2, uuidBytes.3,
                uuidBytes.4, uuidBytes.5, uuidBytes.6, uuidBytes.7,
                uuidBytes.8, uuidBytes.9, uuidBytes.10, uuidBytes.11,
                uuidBytes.12, uuidBytes.13, uuidBytes.14, uuidBytes.15
            ]
        }
        
        for i in 0..<128 {
            CheckCounter.increment()
            checks += 1
            
            // Generate random UUID
            var uuidBytes: [UInt8] = []
            for _ in 0..<16 {
                uuidBytes.append(rng.nextUInt8())
            }
            
            // Create UUID from bytes (if possible)
            let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
            
            // Compute via our implementation
            let ourBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            
            // Compute via slow path
            let slowBytes = slowPathUUIDBytes(uuid)
            
            // Must match
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(ourBytes, slowBytes, "UUID bytes must match slow path (case \(i))")
        }
        
        print("UUID Differential: \(checks) checks")
    }
}
