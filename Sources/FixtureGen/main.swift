// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// main.swift
// FixtureGen
//
// PR1 v2.4 Addendum - Deterministic Fixture Generator
//
// Generates golden fixtures with header validation
//

import Foundation
import Aether3DCore
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// Seeded RNG for deterministic UUID generation
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = (state &* 1103515245 &+ 12345) & 0x7fffffff
        return state
    }
    mutating func nextUInt8() -> UInt8 { return UInt8(next() & 0xFF) }
    mutating func nextUInt16() -> UInt16 { return UInt16(next() & 0xFFFF) }
    mutating func nextUInt32() -> UInt32 { return UInt32(next() & 0xFFFFFFFF) }
    mutating func nextUInt64() -> UInt64 { return (next() << 32) | next() }
    mutating func nextInt64() -> Int64 { return Int64(bitPattern: nextUInt64()) }
}

// Generate UUID from seed
func generateUUID(seed: UInt64) -> UUID {
    var rng = SeededRNG(seed: seed)
    var bytes: [UInt8] = []
    for _ in 0..<16 {
        bytes.append(rng.nextUInt8())
    }
    // Set version (4) and variant bits for valid UUID
    bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 10
    
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

// Generate UUID RFC4122 vectors
func generateUUIDVectors() throws -> String {
    var lines: [String] = []
    
    // Edge cases
    let zeroUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    let allOneUUID = UUID(uuid: (0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF))
    let sequentialUUID = UUID(uuid: (0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF))
    
    var uuids: [(UUID, String)] = []
    uuids.append((zeroUUID, "00000000-0000-0000-0000-000000000000"))
    uuids.append((allOneUUID, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    uuids.append((sequentialUUID, "00112233-4455-6677-8899-AABBCCDDEEFF"))
    
    // Generate deterministic UUIDs using seeded RNG
    for i in 0..<125 {
        let uuid = generateUUID(seed: UInt64(i + 3))
        uuids.append((uuid, uuid.uuidString.uppercased()))
    }
    
    // Generate lines
    for (index, (uuid, uuidString)) in uuids.enumerated() {
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        lines.append("UUID_STRING_\(index+1)=\(uuidString)")
        lines.append("EXPECTED_BYTES_HEX_\(index+1)=\(hex)")
    }
    
    let content = lines.joined(separator: "\n") + "\n"
    let contentData = Data(content.utf8)
    
    // Generate header
    #if canImport(CryptoKit)
    let hash = CryptoKit.SHA256.hash(data: contentData)
    #elseif canImport(Crypto)
    let hash = Crypto.SHA256.hash(data: contentData)
    #else
    #error("No SHA256 implementation available")
    #endif
    let sha256Hex = hash.map { String(format: "%02x", $0) }.joined()
    let len = contentData.count
    let header = "# v=1 sha256=\(sha256Hex) len=\(len)\n"
    
    return header + content
}

// Generate DecisionHash vectors
func generateDecisionHashVectors() throws -> String {
    var lines: [String] = []
    
    var rng = SeededRNG(seed: 54321)
    
    for i in 0..<128 {
        // Generate canonical input
        let policyHash = rng.nextUInt64()
        let sessionStableId = rng.nextUInt64()
        let candidateStableId = rng.nextUInt64()
        let valueScore = rng.nextInt64()
        let flowBucketCount = Int(rng.nextUInt8() % 8) + 1
        var perFlowCounters: [UInt16] = []
        for _ in 0..<flowBucketCount {
            perFlowCounters.append(rng.nextUInt16())
        }
        
        let hasThrottle = rng.nextUInt8() % 2 == 0
        let throttleStats: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)? = hasThrottle ? (
            windowStartTick: rng.nextUInt64(),
            windowDurationTicks: rng.nextUInt32(),
            attemptsInWindow: rng.nextUInt32()
        ) : nil
        
        let degradationLevel = rng.nextUInt8() % 4
        let hasDegradationReason = degradationLevel != 0 && rng.nextUInt8() % 2 == 0
        let degradationReasonCode = hasDegradationReason ? rng.nextUInt8() % 6 + 1 : nil
        
        let metrics = CapacityMetrics(
            candidateId: generateUUID(seed: UInt64(i)),
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: perFlowCounters,
            flowBucketCount: flowBucketCount,
            throttleStats: throttleStats,
            degradationLevel: degradationLevel,
            degradationReasonCode: degradationReasonCode,
            schemaVersion: 0x0204
        )
        
        // Compute DecisionHash
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        let preimageHex = canonicalBytes.map { String(format: "%02x", $0) }.joined()
        let hashHex = decisionHash.hexString
        
        lines.append("CANONICAL_INPUT_HEX_\(i+1)=\(preimageHex)")
        lines.append("EXPECTED_DECISION_HASH_HEX_\(i+1)=\(hashHex)")
    }
    
    let content = lines.joined(separator: "\n") + "\n"
    let contentData = Data(content.utf8)
    
    // Generate header
    #if canImport(CryptoKit)
    let hash = CryptoKit.SHA256.hash(data: contentData)
    #elseif canImport(Crypto)
    let hash = Crypto.SHA256.hash(data: contentData)
    #else
    #error("No SHA256 implementation available")
    #endif
    let sha256Hex = hash.map { String(format: "%02x", $0) }.joined()
    let len = contentData.count
    let header = "# v=1 sha256=\(sha256Hex) len=\(len)\n"
    
    return header + content
}

// Generate AdmissionDecision vectors
func generateAdmissionDecisionVectors() throws -> String {
    var lines: [String] = []
    
    var rng = SeededRNG(seed: 98765)
    
    for i in 0..<32 {
        let candidateId = generateUUID(seed: UInt64(i + 100))
        let policyHash = rng.nextUInt64()
        let sessionStableId = rng.nextUInt64()
        let candidateStableId = rng.nextUInt64()
        let valueScore = rng.nextInt64()
        let degradationLevel = rng.nextUInt8() % 4
        // Compute decision hash from canonical input first
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 1.0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let degradationReasonCode: UInt8? = degradationLevel != 0 ? UInt8(1) : nil
        
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: degradationLevel,
            degradationReasonCode: degradationReasonCode,
            schemaVersion: 0x0204
        )
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        
        // Generate admission record bytes manually (matching AdmissionDecision.admissionRecordBytes format)
        // This ensures we use our precomputed decisionHash
        let writer = CanonicalBytesWriter()
        
        // Layout version
        writer.writeUInt8(1)
        
        // Schema version
        writer.writeUInt16BE(0x0204)
        
        // Policy hash
        writer.writeUInt64BE(policyHash)
        
        // Stable IDs
        writer.writeUInt64BE(sessionStableId)
        writer.writeUInt64BE(candidateStableId)
        
        // Classification (ACCEPTED = 2)
        writer.writeUInt8(2)
        
        // EEB delta (as Int64 BE)
        let eebDeltaFixed: Int64 = 1000 // Fixed point: 1.0 = 1000
        writer.writeInt64BE(eebDeltaFixed)
        
        // Build mode (NORMAL = 0)
        writer.writeUInt8(0)
        
        // Guidance signal (HEAT_COOL_COVERAGE = 0)
        writer.writeUInt8(0)
        
        // Hard fuse trigger (nil = 0)
        writer.writeUInt8(0)
        
        // Degradation level
        writer.writeUInt8(degradationLevel)
        
        // Degradation reason code (presence tag + value)
        if let drc = degradationReasonCode {
            writer.writeUInt8(1) // presence tag
            writer.writeUInt8(drc)
        } else {
            writer.writeUInt8(0) // absence tag
        }
        
        // Value score
        writer.writeInt64BE(valueScore)
        
        // Decision hash (32 bytes)
        writer.writeBytes(decisionHash.bytes)
        
        let recordBytes = writer.toData()
        
        let recordHex = recordBytes.map { String(format: "%02x", $0) }.joined()
        let hashHex = decisionHash.hexString
        
        lines.append("ADMISSION_RECORD_HEX_\(i+1)=\(recordHex)")
        lines.append("EXPECTED_DECISION_HASH_HEX_\(i+1)=\(hashHex)")
    }
    
    let content = lines.joined(separator: "\n") + "\n"
    let contentData = Data(content.utf8)
    
    // Generate header
    #if canImport(CryptoKit)
    let hash = CryptoKit.SHA256.hash(data: contentData)
    #elseif canImport(Crypto)
    let hash = Crypto.SHA256.hash(data: contentData)
    #else
    #error("No SHA256 implementation available")
    #endif
    let sha256Hex = hash.map { String(format: "%02x", $0) }.joined()
    let len = contentData.count
    let header = "# v=1 sha256=\(sha256Hex) len=\(len)\n"
    
    return header + content
}

// Main
let fixturesDir = URL(fileURLWithPath: "Tests/Fixtures")
try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

// Generate UUID vectors
let uuidContent = try generateUUIDVectors()
try uuidContent.write(to: fixturesDir.appendingPathComponent("uuid_rfc4122_vectors_v1.txt"), atomically: true, encoding: .utf8)

// Generate DecisionHash vectors
let decisionHashContent = try generateDecisionHashVectors()
try decisionHashContent.write(to: fixturesDir.appendingPathComponent("decision_hash_v1.txt"), atomically: true, encoding: .utf8)

// Generate AdmissionDecision vectors
let admissionContent = try generateAdmissionDecisionVectors()
try admissionContent.write(to: fixturesDir.appendingPathComponent("admission_decision_v1.txt"), atomically: true, encoding: .utf8)

print("Generated fixtures:")
print("  - uuid_rfc4122_vectors_v1.txt")
print("  - decision_hash_v1.txt")
print("  - admission_decision_v1.txt")
