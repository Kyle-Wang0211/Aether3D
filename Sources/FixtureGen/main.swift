// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// main.swift
// FixtureGen
//
// Phase 0 full fixture generator:
// 1) Keep legacy txt/json fixtures for existing governance gates
// 2) Generate binary fixtures with 36-byte self-description header
// 3) Emit fixtures/manifest.json
// 4) Populate aether_cpp/golden for C++ replay/parity workflow
//

import Foundation
import Aether3DCore

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let FIXTURE_EPOCH_NS: UInt64 = 1_700_000_000_000_000_000
private let FIXTURE_SCHEMA_VERSION: UInt16 = 1
private let REPLAY_PAYLOAD_VERSION: UInt16 = 1

private enum ReplayKind: UInt16 {
    case tsdfIntegrate = 1
    case sha256Input = 2
    case canonicalizeBlock = 3
}

private enum FixtureType: UInt16 {
    case tsdf = 1
    case evidence = 2
    case merkle = 3
    case json = 4
    case checkpoint = 5
    case moderation = 6
    case social = 7
    case annotation = 8
    case tour = 9
    case q16 = 10
    case piz = 11
}

private struct BinaryFixture {
    let relativePath: String
    let fixtureType: FixtureType
    let payload: Data
}

private struct ManifestEntry: Codable {
    let relativePath: String
    let fixtureType: UInt16
    let payloadSize: Int
    let payloadHashHex: String
    let fileHashHex: String
}

private struct FixtureManifest: Codable {
    let schemaVersion: Int
    let constantsHashHex: String
    let compilerTag: String
    let archTag: String
    let swiftVersion: String
    let operatingSystem: String
    let generatedAtISO8601: String
    let generatedAtEpochNs: UInt64
    let fixtures: [ManifestEntry]
}

// MARK: - Deterministic RNG (xorshift64*)

private struct XorShift64Star {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 2685821657736338717
    }

    mutating func nextUInt8() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

private func deterministicSeed(fixtureName: String, paramIndex: Int) -> UInt64 {
    let text = "aether:fixture:\(fixtureName):\(paramIndex)"
    let digest = sha256Bytes(Data(text.utf8))
    var seed: UInt64 = 0
    for b in digest.prefix(8) {
        seed = (seed << 8) | UInt64(b)
    }
    return seed
}

// MARK: - SHA256 helpers

private func sha256Bytes(_ data: Data) -> [UInt8] {
    #if canImport(CryptoKit)
    return Array(CryptoKit.SHA256.hash(data: data))
    #elseif canImport(Crypto)
    return Array(Crypto.SHA256.hash(data: data))
    #else
    #error("No SHA256 implementation available")
    #endif
}

private func sha256Hex(_ data: Data) -> String {
    sha256Bytes(data).map { String(format: "%02x", $0) }.joined()
}

private func hash8(_ data: Data) -> [UInt8] {
    Array(sha256Bytes(data).prefix(8))
}

private func currentConstantsHash8() -> [UInt8] {
    let path = URL(fileURLWithPath: "governance/code_bindings.json")
    guard let data = try? Data(contentsOf: path) else {
        return Array(repeating: 0, count: 8)
    }
    return hash8(data)
}

// MARK: - Little-endian writer

private struct LEWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    mutating func i32(_ value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ other: Data) {
        data.append(other)
    }
}

private func buildReplayPayload(kind: ReplayKind, input: Data, expected: Data) -> Data {
    var writer = LEWriter()
    writer.u16(REPLAY_PAYLOAD_VERSION)
    writer.u16(kind.rawValue)
    writer.u32(UInt32(input.count))
    writer.u32(UInt32(expected.count))
    writer.bytes(input)
    writer.bytes(expected)
    return writer.data
}

private func currentArchTag() -> String {
    #if arch(arm64)
    return "A8"
    #elseif arch(x86_64)
    return "X6"
    #else
    return "UN"
    #endif
}

private func buildFixtureFileBytes(type: FixtureType, payload: Data, constantsHash8: [UInt8]) -> Data {
    var header = LEWriter()
    header.bytes(Data("AE3D".utf8))                       // magic
    header.u16(FIXTURE_SCHEMA_VERSION)                    // schema_version
    header.u16(type.rawValue)                             // fixture_type
    header.u32(UInt32(payload.count))                     // payload_size
    header.bytes(Data(constantsHash8.prefix(8)))          // constants_hash
    header.bytes(Data("SWFT".utf8))                       // compiler_tag
    header.bytes(Data(currentArchTag().utf8.prefix(2)))   // arch_tag
    header.u16(0)                                         // reserved[2]
    header.bytes(Data(hash8(payload)))                    // payload_hash
    return header.data + payload
}

private func sanitizeFloat(_ value: Float) throws -> Float {
    guard value.isFinite else {
        throw NSError(domain: "FixtureGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "NaN/Inf not allowed in fixture inputs"])
    }
    if value.isSubnormal {
        return value.sign == .minus ? -0.0 : 0.0
    }
    return value
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
    _ = fm.createFile(atPath: tmp.path, contents: nil)

    let fd = tmp.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644)) }
    guard fd >= 0 else {
        throw NSError(domain: "FixtureGen", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "open() failed for \(tmp.path)"])
    }
    defer { _ = close(fd) }

    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        var remaining = raw.count
        while remaining > 0 {
            let n = write(fd, base.advanced(by: offset), remaining)
            if n < 0 {
                throw NSError(domain: "FixtureGen", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "write() failed for \(tmp.path)"])
            }
            if n == 0 {
                throw NSError(domain: "FixtureGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "write() returned 0 for \(tmp.path)"])
            }
            offset += n
            remaining -= n
        }
    }

    if fsync(fd) != 0 {
        throw NSError(domain: "FixtureGen", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "fsync() failed for \(tmp.path)"])
    }

    let renameRC = tmp.path.withCString { from in
        url.path.withCString { to in
            rename(from, to)
        }
    }
    if renameRC != 0 {
        throw NSError(domain: "FixtureGen", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "rename() failed \(tmp.path) -> \(url.path)"])
    }
}

// MARK: - Legacy txt/json fixtures (existing baseline)

private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = (state &* 1103515245 &+ 12345) & 0x7fffffff
        return state
    }
    mutating func nextUInt8() -> UInt8 { UInt8(next() & 0xFF) }
    mutating func nextUInt16() -> UInt16 { UInt16(next() & 0xFFFF) }
    mutating func nextUInt32() -> UInt32 { UInt32(next() & 0xFFFFFFFF) }
    mutating func nextUInt64() -> UInt64 { (next() << 32) | next() }
    mutating func nextInt64() -> Int64 { Int64(bitPattern: nextUInt64()) }
}

private func generateUUID(seed: UInt64) -> UUID {
    var rng = SeededRNG(seed: seed)
    var bytes: [UInt8] = []
    for _ in 0..<16 { bytes.append(rng.nextUInt8()) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private func headerWrappedText(_ content: String) -> String {
    let contentData = Data(content.utf8)
    return "# v=1 sha256=\(sha256Hex(contentData)) len=\(contentData.count)\n" + content
}

private func generateUUIDVectors() throws -> String {
    var lines: [String] = []
    let zeroUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    let allOneUUID = UUID(uuid: (0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF))
    let sequentialUUID = UUID(uuid: (0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF))

    var uuids: [(UUID, String)] = [
        (zeroUUID, "00000000-0000-0000-0000-000000000000"),
        (allOneUUID, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),
        (sequentialUUID, "00112233-4455-6677-8899-AABBCCDDEEFF")
    ]

    for i in 0..<125 {
        let uuid = generateUUID(seed: UInt64(i + 3))
        uuids.append((uuid, uuid.uuidString.uppercased()))
    }

    for (index, (uuid, uuidString)) in uuids.enumerated() {
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        lines.append("UUID_STRING_\(index+1)=\(uuidString)")
        lines.append("EXPECTED_BYTES_HEX_\(index+1)=\(hex)")
    }
    return headerWrappedText(lines.joined(separator: "\n") + "\n")
}

private func generateDecisionHashVectors() throws -> String {
    var lines: [String] = []
    var rng = SeededRNG(seed: 54321)

    for i in 0..<128 {
        let policyHash = rng.nextUInt64()
        let sessionStableId = rng.nextUInt64()
        let candidateStableId = rng.nextUInt64()
        let valueScore = rng.nextInt64()
        let flowBucketCount = Int(rng.nextUInt8() % 8) + 1
        var perFlowCounters: [UInt16] = []
        for _ in 0..<flowBucketCount { perFlowCounters.append(rng.nextUInt16()) }

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

        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        let preimageHex = canonicalBytes.map { String(format: "%02x", $0) }.joined()
        let hashHex = decisionHash.hexString
        lines.append("CANONICAL_INPUT_HEX_\(i+1)=\(preimageHex)")
        lines.append("EXPECTED_DECISION_HASH_HEX_\(i+1)=\(hashHex)")
    }

    return headerWrappedText(lines.joined(separator: "\n") + "\n")
}

private func generateAdmissionDecisionVectors() throws -> String {
    var lines: [String] = []
    var rng = SeededRNG(seed: 98765)

    for i in 0..<32 {
        let candidateId = generateUUID(seed: UInt64(i + 100))
        let policyHash = rng.nextUInt64()
        let sessionStableId = rng.nextUInt64()
        let candidateStableId = rng.nextUInt64()
        let valueScore = rng.nextInt64()
        let degradationLevel = rng.nextUInt8() % 4

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
        let writer = CanonicalBytesWriter()
        writer.writeUInt8(1)
        writer.writeUInt16BE(0x0204)
        writer.writeUInt64BE(policyHash)
        writer.writeUInt64BE(sessionStableId)
        writer.writeUInt64BE(candidateStableId)
        writer.writeUInt8(2)
        writer.writeInt64BE(1000)
        writer.writeUInt8(0)
        writer.writeUInt8(0)
        writer.writeUInt8(degradationLevel)
        if let drc = degradationReasonCode {
            writer.writeUInt8(1)
            writer.writeUInt8(drc)
        } else {
            writer.writeUInt8(0)
        }
        writer.writeInt64BE(valueScore)
        writer.writeBytes(decisionHash.bytes)

        let recordBytes = writer.toData()
        let recordHex = recordBytes.map { String(format: "%02x", $0) }.joined()
        let hashHex = decisionHash.hexString
        lines.append("ADMISSION_RECORD_HEX_\(i+1)=\(recordHex)")
        lines.append("EXPECTED_DECISION_HASH_HEX_\(i+1)=\(hashHex)")
    }

    return headerWrappedText(lines.joined(separator: "\n") + "\n")
}

// MARK: - Phase 0 binary fixtures

private func tsdfExpected(
    width: Int,
    height: Int,
    depth: [Float],
    voxelSize: Float,
    fx: Float,
    fy: Float,
    cx: Float,
    cy: Float,
    view: [Float]
) -> (rc: Int32, voxels: Int32, blocks: Int32, success: UInt8) {
    guard width > 0, height > 0,
          depth.count == width * height,
          fx > 0, fy > 0,
          voxelSize > 0, voxelSize <= 1 else {
        return (-2, 0, 0, 0)
    }
    if depth.count > TSDFConstants.maxVoxelsPerFrame {
        return (-5, 0, 0, 0)
    }

    var blockSet = Set<String>()
    var voxelCount: Int32 = 0
    let inv = 1.0 / (voxelSize * Float(TSDFConstants.blockSize))

    for v in 0..<height {
        for u in 0..<width {
            let idx = v * width + u
            guard idx < depth.count else { continue }
            let d = depth[idx]
            if !d.isFinite || d < TSDFConstants.depthMin || d > TSDFConstants.depthMax {
                continue
            }
            let xCam = (Float(u) - cx) * d / fx
            let yCam = (Float(v) - cy) * d / fy
            let zCam = d

            let wx = view[0] * xCam + view[4] * yCam + view[8] * zCam + view[12]
            let wy = view[1] * xCam + view[5] * yCam + view[9] * zCam + view[13]
            let wz = view[2] * xCam + view[6] * yCam + view[10] * zCam + view[14]

            let bx = Int32(floor(wx * inv))
            let by = Int32(floor(wy * inv))
            let bz = Int32(floor(wz * inv))
            blockSet.insert("\(bx),\(by),\(bz)")
            voxelCount += 1
        }
    }

    if voxelCount > 0 && !blockSet.isEmpty {
        return (0, voxelCount, Int32(blockSet.count), 1)
    }
    return (-6, voxelCount, Int32(blockSet.count), 0)
}

private func tsdfReplayPayload(
    width: Int,
    height: Int,
    depth: [Float],
    voxelSize: Float,
    fx: Float,
    fy: Float,
    cx: Float,
    cy: Float,
    viewMatrix: [Float]
) throws -> Data {
    var sanitizedDepth: [Float] = []
    sanitizedDepth.reserveCapacity(depth.count)
    for d in depth { sanitizedDepth.append(try sanitizeFloat(d)) }

    let expected = tsdfExpected(
        width: width,
        height: height,
        depth: sanitizedDepth,
        voxelSize: voxelSize,
        fx: fx,
        fy: fy,
        cx: cx,
        cy: cy,
        view: viewMatrix
    )

    var inputWriter = LEWriter()
    inputWriter.u32(UInt32(width))
    inputWriter.u32(UInt32(height))
    inputWriter.f32(try sanitizeFloat(voxelSize))
    inputWriter.f32(try sanitizeFloat(fx))
    inputWriter.f32(try sanitizeFloat(fy))
    inputWriter.f32(try sanitizeFloat(cx))
    inputWriter.f32(try sanitizeFloat(cy))
    for v in viewMatrix {
        inputWriter.f32(try sanitizeFloat(v))
    }
    for d in sanitizedDepth {
        inputWriter.f32(d)
    }

    var expectedWriter = LEWriter()
    expectedWriter.i32(expected.rc)
    expectedWriter.i32(expected.voxels)
    expectedWriter.i32(expected.blocks)
    expectedWriter.u8(expected.success)

    return buildReplayPayload(kind: .tsdfIntegrate, input: inputWriter.data, expected: expectedWriter.data)
}

private func sha256ReplayPayload(input: Data) -> Data {
    let expected = Data(sha256Bytes(input))
    return buildReplayPayload(kind: .sha256Input, input: input, expected: expected)
}

private func canonicalizeReplayPayload(x: Int32, y: Int32, z: Int32) -> Data {
    var inputWriter = LEWriter()
    inputWriter.i32(x)
    inputWriter.i32(y)
    inputWriter.i32(z)

    var expectedWriter = LEWriter()
    expectedWriter.i32(x)
    expectedWriter.i32(y)
    expectedWriter.i32(z)

    return buildReplayPayload(kind: .canonicalizeBlock, input: inputWriter.data, expected: expectedWriter.data)
}

private func makeBinaryFixtures() throws -> [BinaryFixture] {
    // TSDF fixtures
    let viewIdentity: [Float] = [
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    ]
    let tsdfSingleDepth = Array(repeating: Float(0.5), count: 8 * 8)
    let tsdfSinglePayload = try tsdfReplayPayload(
        width: 8,
        height: 8,
        depth: tsdfSingleDepth,
        voxelSize: TSDFConstants.voxelSizeNear,
        fx: 500,
        fy: 500,
        cx: 4,
        cy: 4,
        viewMatrix: viewIdentity
    )

    var tsdfMultiDepth: [Float] = []
    tsdfMultiDepth.reserveCapacity(8 * 8)
    for v in 0..<8 {
        for u in 0..<8 {
            tsdfMultiDepth.append(Float(1.2 + Float(u + v) * 0.1))
        }
    }
    let tsdfMultiPayload = try tsdfReplayPayload(
        width: 8,
        height: 8,
        depth: tsdfMultiDepth,
        voxelSize: TSDFConstants.voxelSizeNear,
        fx: 40,
        fy: 40,
        cx: 3.5,
        cy: 3.5,
        viewMatrix: viewIdentity
    )

    var marchingSeed = XorShift64Star(seed: deterministicSeed(fixtureName: "marching_cubes_single_block", paramIndex: 0))
    var marchingInput = Data("mc33-single-block-v1".utf8)
    for _ in 0..<128 { marchingInput.append(marchingSeed.nextUInt8()) }

    // Evidence fixtures (deterministic canonical JSON payloads)
    let evidenceBasic = CanonicalJSONValue.object([
        ("epoch_ns", .int(Int64(FIXTURE_EPOCH_NS))),
        ("fixture", .string("ds_fusion_basic")),
        ("masses", .array([
            .object([("h", .number("0.700000")), ("u", .number("0.300000"))]),
            .object([("h", .number("0.600000")), ("u", .number("0.400000"))])
        ]))
    ])
    let evidenceConflict = CanonicalJSONValue.object([
        ("epoch_ns", .int(Int64(FIXTURE_EPOCH_NS))),
        ("fixture", .string("ds_fusion_conflict")),
        ("masses", .array([
            .object([("h", .number("0.500000")), ("u", .number("0.500000"))]),
            .object([("h", .number("0.500000")), ("u", .number("0.500000"))])
        ]))
    ])
    let evidenceAdmission = CanonicalJSONValue.object([
        ("epoch_ns", .int(Int64(FIXTURE_EPOCH_NS))),
        ("fixture", .string("admission_sequence")),
        ("sequence", .array([
            .string("accept"),
            .string("degrade"),
            .string("accept"),
            .string("reject")
        ]))
    ])

    let evidenceBasicData = try TrueDeterministicJSONEncoder.encodeCanonical(evidenceBasic)
    let evidenceConflictData = try TrueDeterministicJSONEncoder.encodeCanonical(evidenceConflict)
    let evidenceAdmissionData = try TrueDeterministicJSONEncoder.encodeCanonical(evidenceAdmission)

    // Merkle fixtures
    let leafA = MerkleTreeHash.hashLeaf(Data("leaf-A".utf8))
    let leafB = MerkleTreeHash.hashLeaf(Data("leaf-B".utf8))
    let leafC = MerkleTreeHash.hashLeaf(Data("leaf-C".utf8))
    let rootAB = MerkleTreeHash.hashNodes(leafA, leafB)
    let rootABC = MerkleTreeHash.hashNodes(rootAB, leafC)

    let merkleAppendProof = CanonicalJSONValue.object([
        ("fixture", .string("append_and_proof")),
        ("leafA", .string(leafA.map { String(format: "%02x", $0) }.joined())),
        ("leafB", .string(leafB.map { String(format: "%02x", $0) }.joined())),
        ("root", .string(rootAB.map { String(format: "%02x", $0) }.joined()))
    ])
    let merkleConsistency = CanonicalJSONValue.object([
        ("fixture", .string("consistency_proof")),
        ("first_root", .string(rootAB.map { String(format: "%02x", $0) }.joined())),
        ("second_root", .string(rootABC.map { String(format: "%02x", $0) }.joined()))
    ])
    let merkleEdge = CanonicalJSONValue.object([
        ("fixture", .string("edge_cases")),
        ("empty_root", .string(Data(repeating: 0, count: 32).map { String(format: "%02x", $0) }.joined()))
    ])

    let merkleAppendProofData = try TrueDeterministicJSONEncoder.encodeCanonical(merkleAppendProof)
    let merkleConsistencyData = try TrueDeterministicJSONEncoder.encodeCanonical(merkleConsistency)
    let merkleEdgeData = try TrueDeterministicJSONEncoder.encodeCanonical(merkleEdge)

    // JSON fixtures
    struct CanonFloat: Codable { let a: Double; let b: Double; let c: Double; let s: String }
    let floatInput = CanonFloat(a: 0.5, b: 0.125, c: -0.0, s: "float_encoding")
    let jsonFloatData = try DeterministicJSONEncoder.encode(floatInput)

    struct EventPayload: Codable {
        let schemaVersion: Int
        let eventId: String
        let timestampNs: UInt64
        let attrs: [String: String]
    }
    let event = EventPayload(
        schemaVersion: 1,
        eventId: "evt.phase0.serialized",
        timestampNs: FIXTURE_EPOCH_NS,
        attrs: ["kind": "fixture", "source": "swift"]
    )
    let jsonEventData = try DeterministicJSONEncoder.encode(event)

    // SceneSpec-like fixtures (project uses scene IDs in TraceIdGenerator)
    let descriptors = [
        InputDescriptor(path: "captures/frame_0001.heic", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", byteSize: 1024),
        InputDescriptor(path: "captures/frame_0002.heic", contentHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", byteSize: 2048)
    ]
    let sceneIdResult = TraceIdGenerator.makeSceneId(inputs: descriptors)
    let sceneId: String
    switch sceneIdResult {
    case .success(let id):
        sceneId = id
    case .failure(let err):
        throw NSError(domain: "FixtureGen", code: 9, userInfo: [NSLocalizedDescriptionKey: "makeSceneId failed: \(err)"])
    }
    let sceneSectionData = Data("scene_section:\(sceneId)".utf8)
    let sceneHashCanonData = Data("scene_hash:\(sha256Hex(sceneSectionData))".utf8)

    return [
        BinaryFixture(relativePath: "fixtures/tsdf/single_block_integration.bin", fixtureType: .tsdf, payload: tsdfSinglePayload),
        BinaryFixture(relativePath: "fixtures/tsdf/multi_block_fusion.bin", fixtureType: .tsdf, payload: tsdfMultiPayload),
        BinaryFixture(relativePath: "fixtures/tsdf/marching_cubes_single_block.bin", fixtureType: .tsdf, payload: sha256ReplayPayload(input: marchingInput)),

        BinaryFixture(relativePath: "fixtures/evidence/ds_fusion_basic.bin", fixtureType: .evidence, payload: sha256ReplayPayload(input: evidenceBasicData)),
        BinaryFixture(relativePath: "fixtures/evidence/ds_fusion_conflict.bin", fixtureType: .evidence, payload: sha256ReplayPayload(input: evidenceConflictData)),
        BinaryFixture(relativePath: "fixtures/evidence/admission_sequence.bin", fixtureType: .evidence, payload: sha256ReplayPayload(input: evidenceAdmissionData)),

        BinaryFixture(relativePath: "fixtures/merkle/append_and_proof.bin", fixtureType: .merkle, payload: sha256ReplayPayload(input: merkleAppendProofData)),
        BinaryFixture(relativePath: "fixtures/merkle/consistency_proof.bin", fixtureType: .merkle, payload: sha256ReplayPayload(input: merkleConsistencyData)),
        BinaryFixture(relativePath: "fixtures/merkle/edge_cases.bin", fixtureType: .merkle, payload: sha256ReplayPayload(input: merkleEdgeData)),

        BinaryFixture(relativePath: "fixtures/json/float_encoding.bin", fixtureType: .json, payload: sha256ReplayPayload(input: jsonFloatData)),
        BinaryFixture(relativePath: "fixtures/json/event_serialization.bin", fixtureType: .json, payload: sha256ReplayPayload(input: jsonEventData)),

        BinaryFixture(relativePath: "fixtures/scenespec/section_assembly.bin", fixtureType: .checkpoint, payload: canonicalizeReplayPayload(x: 7, y: -3, z: 11)),
        BinaryFixture(relativePath: "fixtures/scenespec/hash_canonicalization.bin", fixtureType: .checkpoint, payload: sha256ReplayPayload(input: sceneHashCanonData))
    ]
}

private func swiftVersionString() -> String {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", "--version"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return s.replacingOccurrences(of: "\n", with: " ")
    } catch {
        return "unknown"
    }
    #else
    return "unknown"
    #endif
}

private func fixedISO8601FromFixtureEpoch() -> String {
    let seconds = TimeInterval(FIXTURE_EPOCH_NS) / 1_000_000_000.0
    let date = Date(timeIntervalSince1970: seconds)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func writePhase0BinaryFixtures() throws {
    let constantsHash8 = currentConstantsHash8()
    let fixtures = try makeBinaryFixtures()

    var manifestEntries: [ManifestEntry] = []
    for f in fixtures {
        let path = URL(fileURLWithPath: f.relativePath)
        let bytes = buildFixtureFileBytes(type: f.fixtureType, payload: f.payload, constantsHash8: constantsHash8)
        try atomicWrite(bytes, to: path)
        manifestEntries.append(
            ManifestEntry(
                relativePath: f.relativePath,
                fixtureType: f.fixtureType.rawValue,
                payloadSize: f.payload.count,
                payloadHashHex: sha256Hex(f.payload),
                fileHashHex: sha256Hex(bytes)
            )
        )
    }

    let manifest = FixtureManifest(
        schemaVersion: Int(FIXTURE_SCHEMA_VERSION),
        constantsHashHex: constantsHash8.map { String(format: "%02x", $0) }.joined(),
        compilerTag: "SWFT",
        archTag: currentArchTag(),
        swiftVersion: swiftVersionString(),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        generatedAtISO8601: fixedISO8601FromFixtureEpoch(),
        generatedAtEpochNs: FIXTURE_EPOCH_NS,
        fixtures: manifestEntries.sorted { $0.relativePath < $1.relativePath }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let manifestData = try encoder.encode(manifest)
    try atomicWrite(manifestData, to: URL(fileURLWithPath: "fixtures/manifest.json"))
}

private func copyPhase0GoldenToCpp() throws {
    let fm = FileManager.default
    let cppGolden = URL(fileURLWithPath: "aether_cpp/golden", isDirectory: true)
    try fm.createDirectory(at: cppGolden, withIntermediateDirectories: true)

    // Legacy fixtures
    let legacy = [
        "Tests/Fixtures/uuid_rfc4122_vectors_v1.txt",
        "Tests/Fixtures/decision_hash_v1.txt",
        "Tests/Fixtures/admission_decision_v1.txt",
        "Tests/Fixtures/PR4Math/pr4math_golden_v1.json"
    ]
    for rel in legacy {
        let src = URL(fileURLWithPath: rel)
        guard fm.fileExists(atPath: src.path) else { continue }
        let dst = cppGolden.appendingPathComponent(src.lastPathComponent)
        let bytes = try Data(contentsOf: src)
        try atomicWrite(bytes, to: dst)
    }

    // Binary fixtures + manifest
    let fixtureRoot = URL(fileURLWithPath: "fixtures", isDirectory: true)
    guard fm.fileExists(atPath: fixtureRoot.path) else { return }
    let enumerator = fm.enumerator(at: fixtureRoot, includingPropertiesForKeys: nil)
    while let obj = enumerator?.nextObject() as? URL {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: obj.path, isDirectory: &isDir), !isDir.boolValue else { continue }
        let rel = obj.path.replacingOccurrences(of: fixtureRoot.path + "/", with: "")
        let dst = cppGolden.appendingPathComponent(rel)
        let bytes = try Data(contentsOf: obj)
        try atomicWrite(bytes, to: dst)
    }
}

// MARK: - Main

let fixturesDir = URL(fileURLWithPath: "Tests/Fixtures")
try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

let uuidContent = try generateUUIDVectors()
try atomicWrite(Data(uuidContent.utf8), to: fixturesDir.appendingPathComponent("uuid_rfc4122_vectors_v1.txt"))

let decisionHashContent = try generateDecisionHashVectors()
try atomicWrite(Data(decisionHashContent.utf8), to: fixturesDir.appendingPathComponent("decision_hash_v1.txt"))

let admissionContent = try generateAdmissionDecisionVectors()
try atomicWrite(Data(admissionContent.utf8), to: fixturesDir.appendingPathComponent("admission_decision_v1.txt"))

try writePhase0BinaryFixtures()
try copyPhase0GoldenToCpp()

print("Generated fixtures:")
print("  - Tests/Fixtures/uuid_rfc4122_vectors_v1.txt")
print("  - Tests/Fixtures/decision_hash_v1.txt")
print("  - Tests/Fixtures/admission_decision_v1.txt")
print("  - fixtures/manifest.json")
print("  - fixtures/tsdf/*.bin")
print("  - fixtures/evidence/*.bin")
print("  - fixtures/merkle/*.bin")
print("  - fixtures/json/*.bin")
print("  - fixtures/scenespec/*.bin")
print("  - aether_cpp/golden/*")
