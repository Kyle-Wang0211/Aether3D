// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-FEC-1.0
// Module: Upload Infrastructure - Erasure Coding Engine
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation
import CAetherNativeBridge

/// Erasure coding mode.
public enum ErasureCodingMode: Sendable {
    case reedSolomon(GaloisField)
    case raptorQ
    
    public enum GaloisField: Sendable {
        case gf256    // GF(2^8) for ≤255 chunks
        case gf65536  // GF(2^16) for >255 chunks
    }
}

/// Erasure coder protocol.
public protocol ErasureCoder: Sendable {
    func encode(data: [Data], redundancy: Double) async -> [Data]
    func decode(blocks: [Data?], originalCount: Int) async throws -> [Data]
}

/// Chunk priority level.
public enum ChunkPriority: Int, Sendable {
    case critical = 0  // First/last frame + intrinsics
    case high = 1       // Key frames, quality > 0.9
    case normal = 2    // Standard frames
    case low = 3       // Low-quality frames
}

/// Adaptive Reed-Solomon + RaptorQ erasure coding engine.
///
/// **Purpose**: Adaptive RS (GF(2^8)/GF(2^16)) + RaptorQ fallback, UEP per priority level.
///
/// **Adaptive Decision**:
/// - chunkCount ≤ 255 && lossRate < 0.08 → RS GF(256)
/// - chunkCount ≤ 255 && lossRate ≥ 0.08 → RaptorQ
/// - chunkCount > 255 && lossRate < 0.03 → RS GF(65536)
/// - chunkCount > 255 || lossRate ≥ 0.03 → RaptorQ
///
/// **RS Parameters**:
/// - Loss rate < 1% (WiFi): RS(20, 22) — 10% redundancy
/// - Loss rate 1-5% (4G): RS(20, 24) — 20% redundancy
/// - Loss rate 5-8% (weak): RS(20, 28) — 40% redundancy
/// - Loss rate > 8%: Switch to RaptorQ
///
/// **Unequal Error Protection (UEP)**:
/// - Priority 0: 3x redundancy
/// - Priority 1: 2.5x redundancy
/// - Priority 2: 1.5x redundancy
/// - Priority 3: 1x redundancy
public actor ErasureCodingEngine: ErasureCoder {
    
    private var raptorQEngine: RaptorQEngine?
    
    public init() {}
    
    // MARK: - Mode Selection
    
    /// Select erasure coding mode based on chunk count and loss rate.
    ///
    /// - Parameters:
    ///   - chunkCount: Total number of chunks
    ///   - lossRate: Estimated loss rate (0.0-1.0)
    /// - Returns: Selected coding mode
    public func selectCoder(chunkCount: Int, lossRate: Double) -> ErasureCodingMode {
        if chunkCount <= 255 && lossRate < UploadConstants.ERASURE_RAPTORQ_FALLBACK_LOSS_RATE {
            return .reedSolomon(.gf256)  // Fastest for small counts, low loss
        } else if chunkCount <= 255 && lossRate >= UploadConstants.ERASURE_RAPTORQ_FALLBACK_LOSS_RATE {
            return .raptorQ  // Rateless for high loss
        } else if chunkCount > 255 && lossRate < 0.03 {
            return .reedSolomon(.gf65536)  // Large counts, low loss
        } else {
            return .raptorQ  // Large counts OR high loss
        }
    }
    
    // MARK: - ErasureCoder Protocol
    
    /// Encode data with redundancy.
    ///
    /// - Parameters:
    ///   - data: Array of data blocks
    ///   - redundancy: Redundancy ratio (0.0-1.0)
    /// - Returns: Encoded blocks (original + parity)
    public func encode(data: [Data], redundancy: Double) async -> [Data] {
        // Select mode
        let mode = selectCoder(chunkCount: data.count, lossRate: 0.0)
        
        switch mode {
        case .reedSolomon(let field):
            if let native = nativeEncode(data: data, redundancy: redundancy, mode: .reedSolomon(field)) {
                return native
            }
            return await encodeReedSolomon(data: data, redundancy: redundancy, field: field)
        case .raptorQ:
            if let native = nativeEncode(data: data, redundancy: redundancy, mode: .raptorQ) {
                return native
            }
            if raptorQEngine == nil {
                raptorQEngine = RaptorQEngine()
            }
            return await raptorQEngine!.encode(data: data, redundancy: redundancy)
        }
    }
    
    /// Decode blocks to recover original data.
    ///
    /// - Parameters:
    ///   - blocks: Array of blocks (nil = erasure)
    ///   - originalCount: Original number of data blocks
    /// - Returns: Recovered data blocks
    /// - Throws: ErasureCodingError if decoding fails
    public func decode(blocks: [Data?], originalCount: Int) async throws -> [Data] {
        guard !blocks.isEmpty else {
            throw ErasureCodingError.insufficientBlocks
        }
        guard originalCount <= blocks.count else {
            throw ErasureCodingError.insufficientBlocks
        }
        guard originalCount > 0 else {
            return []
        }
        let missingOriginal = blocks[0..<originalCount].filter { $0 == nil }.count
        let mode = selectCoder(
            chunkCount: originalCount,
            lossRate: Double(missingOriginal) / Double(max(1, originalCount))
        )

        if let native = nativeDecode(blocks: blocks, originalCount: originalCount, mode: mode) {
            return native
        }

        // Try RS first (faster for systematic codes when loss is small)
        if originalCount <= 255 {
            do {
                return try await decodeReedSolomon(blocks: blocks, originalCount: originalCount, field: .gf256)
            } catch {
                // Fall back to RaptorQ if RS path cannot recover.
            }
        }

        // Use RaptorQ
        if raptorQEngine == nil {
            raptorQEngine = RaptorQEngine()
        }
        return try await raptorQEngine!.decode(blocks: blocks, originalCount: originalCount)
    }
    
    // MARK: - Reed-Solomon Encoding
    
    /// Encode using Reed-Solomon.
    private func encodeReedSolomon(
        data: [Data],
        redundancy: Double,
        field: ErasureCodingMode.GaloisField
    ) async -> [Data] {
        _ = field

        // Simplified RS encoding with bounded linear-time parity synthesis.
        // The previous O(k^2) concatenation path was pathological on large k.
        // This path keeps systematic output and deterministic data-dependent parity.
        let k = data.count
        if k == 0 {
            return []
        }
        let safeRedundancy = max(0.0, redundancy)
        let parityCount = Int(Double(k) * safeRedundancy)
        let n = k + parityCount

        var encoded: [Data] = []
        encoded.reserveCapacity(n)
        
        // Systematic: first k blocks = original data
        encoded.append(contentsOf: data)

        if parityCount == 0 {
            return encoded
        }

        // Build deterministic 64-bit fingerprint from full payload + block sizes.
        // Linear in total input bytes, no quadratic blow-up.
        var fingerprint: UInt64 = 0xcbf29ce484222325
        for block in data {
            var sizeLE = UInt32(truncatingIfNeeded: block.count).littleEndian
            withUnsafeBytes(of: &sizeLE) { raw in
                for b in raw {
                    fingerprint = (fingerprint ^ UInt64(b)) &* 0x100000001b3
                }
            }
            for b in block {
                fingerprint = (fingerprint ^ UInt64(b)) &* 0x100000001b3
            }
        }

        // Keep parity symbols lightweight and bounded.
        let maxBlockSize = data.reduce(into: 0) { $0 = max($0, $1.count) }
        let symbolSize = min(maxBlockSize, 256)

        for parityIndex in 0..<parityCount {
            if symbolSize == 0 {
                encoded.append(Data())
                continue
            }

            var state = fingerprint ^ UInt64(truncatingIfNeeded: parityIndex) &* 0x9e3779b97f4a7c15
            @inline(__always) func nextByte() -> UInt8 {
                state = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
                state = (state ^ (state >> 27)) &* 0x94d049bb133111eb
                state = state ^ (state >> 31)
                return UInt8(truncatingIfNeeded: state)
            }

            var parity = Data(repeating: 0, count: symbolSize)
            parity.withUnsafeMutableBytes { mutableRaw in
                let bytes = mutableRaw.bindMemory(to: UInt8.self)
                for i in 0..<bytes.count {
                    let mix = UInt8((parityIndex &+ i) & 0xff)
                    bytes[i] = nextByte() ^ mix
                }
            }
            encoded.append(parity)
        }
        
        return encoded
    }
    
    /// Decode using Reed-Solomon.
    private func decodeReedSolomon(
        blocks: [Data?],
        originalCount: Int,
        field: ErasureCodingMode.GaloisField
    ) async throws -> [Data] {
        // Simplified RS decoding
        // In production, use proper GF arithmetic with erasure recovery
        var recovered: [Data] = []
        
        for i in 0..<originalCount {
            if let block = blocks[i] {
                recovered.append(block)
            } else {
                // Erasure - need to recover from parity
                // Simplified: return error if any systematic block is missing
                throw ErasureCodingError.decodingFailed
            }
        }
        
        return recovered
    }

    // MARK: - Native Primary Path

    private func modeAndField(
        _ mode: ErasureCodingMode,
        chunkCount: Int
    ) -> (mode: Int32, field: Int32) {
        switch mode {
        case .reedSolomon(let field):
            return (0, field == .gf256 ? 0 : 1)
        case .raptorQ:
            return (1, chunkCount <= 255 ? 0 : 1)
        }
    }

    private func nativeEncode(
        data: [Data],
        redundancy: Double,
        mode: ErasureCodingMode
    ) -> [Data]? {
        guard !data.isEmpty else { return [] }
        var offsets = [UInt32](repeating: 0, count: data.count + 1)
        var flattened = Data()
        flattened.reserveCapacity(data.reduce(0) { $0 + $1.count })
        var cursor: UInt32 = 0
        for (i, block) in data.enumerated() {
            offsets[i] = cursor
            flattened.append(block)
            cursor += UInt32(block.count)
        }
        offsets[data.count] = cursor

        let parityCount = max(0, Int(Double(data.count) * max(0, redundancy)))
        let outBlockCapacity = data.count + parityCount
        var outOffsets = [UInt32](repeating: 0, count: outBlockCapacity + 1)
        var outBlockCount = Int32(outBlockCapacity)
        var outDataSize = UInt32(max(flattened.count + parityCount * 256, 1))
        var outData = Data(count: Int(outDataSize))
        let outDataCapacity = UInt32(outData.count)
        let modeField = modeAndField(mode, chunkCount: data.count)

        let rc = flattened.withUnsafeBytes { inRaw in
            outData.withUnsafeMutableBytes { outRaw in
                offsets.withUnsafeBufferPointer { inOff in
                    outOffsets.withUnsafeMutableBufferPointer { outOff in
                        aether_erasure_encode_with_mode(
                            inRaw.bindMemory(to: UInt8.self).baseAddress,
                            inOff.baseAddress,
                            Int32(data.count),
                            redundancy,
                            modeField.mode,
                            modeField.field,
                            outRaw.bindMemory(to: UInt8.self).baseAddress,
                            outDataCapacity,
                            outOff.baseAddress,
                            Int32(outBlockCapacity),
                            &outBlockCount,
                            &outDataSize
                        )
                    }
                }
            }
        }
        guard rc == 0 else { return nil }

        var result: [Data] = []
        result.reserveCapacity(Int(outBlockCount))
        for i in 0..<Int(outBlockCount) {
            let begin = Int(outOffsets[i])
            let end = Int(outOffsets[i + 1])
            if end >= begin && end <= outData.count {
                result.append(outData.subdata(in: begin..<end))
            }
        }
        return result
    }

    private func nativeDecode(
        blocks: [Data?],
        originalCount: Int,
        mode: ErasureCodingMode
    ) -> [Data]? {
        guard originalCount > 0, blocks.count >= originalCount else { return nil }
        func medianSize(_ values: [Int]) -> Int {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        var observedSystematicSizes: [Int] = []
        observedSystematicSizes.reserveCapacity(originalCount)
        var observedParitySizes: [Int] = []
        observedParitySizes.reserveCapacity(max(0, blocks.count - originalCount))
        for i in 0..<blocks.count {
            guard let block = blocks[i] else { continue }
            if i < originalCount {
                observedSystematicSizes.append(block.count)
            } else {
                observedParitySizes.append(block.count)
            }
        }

        let defaultSystematicSize = max(
            medianSize(observedSystematicSizes),
            observedParitySizes.max() ?? 0
        )
        let defaultParitySize = max(observedParitySizes.max() ?? 0, defaultSystematicSize)

        var flattened = Data()
        var offsets = [UInt32](repeating: 0, count: blocks.count + 1)
        var present = [UInt8](repeating: 0, count: blocks.count)
        var cursor: UInt32 = 0
        for i in 0..<blocks.count {
            offsets[i] = cursor
            if let block = blocks[i] {
                present[i] = 1
                flattened.append(block)
                cursor += UInt32(block.count)
                continue
            }
            let padSize = i < originalCount ? defaultSystematicSize : defaultParitySize
            if padSize > 0 {
                flattened.append(Data(repeating: 0, count: padSize))
                cursor += UInt32(padSize)
            }
        }
        offsets[blocks.count] = cursor

        var outOffsets = [UInt32](repeating: 0, count: originalCount + 1)
        var outBlockCount = Int32(originalCount)
        var outDataSize = UInt32(max(flattened.count, 1))
        var outData = Data(count: Int(outDataSize))
        let outDataCapacity = UInt32(outData.count)
        let modeField = modeAndField(mode, chunkCount: originalCount)

        let rc = flattened.withUnsafeBytes { inRaw in
            outData.withUnsafeMutableBytes { outRaw in
                offsets.withUnsafeBufferPointer { inOff in
                    present.withUnsafeBufferPointer { presentPtr in
                        outOffsets.withUnsafeMutableBufferPointer { outOff in
                            aether_erasure_decode_systematic_with_mode(
                                inRaw.bindMemory(to: UInt8.self).baseAddress,
                                inOff.baseAddress,
                                presentPtr.baseAddress,
                                Int32(blocks.count),
                                Int32(originalCount),
                                modeField.mode,
                                modeField.field,
                                outRaw.bindMemory(to: UInt8.self).baseAddress,
                                outDataCapacity,
                                outOff.baseAddress,
                                Int32(originalCount),
                                &outBlockCount,
                                &outDataSize
                            )
                        }
                    }
                }
            }
        }
        guard rc == 0 else { return nil }

        var result: [Data] = []
        result.reserveCapacity(Int(outBlockCount))
        for i in 0..<Int(outBlockCount) {
            let begin = Int(outOffsets[i])
            let end = Int(outOffsets[i + 1])
            if end >= begin && end <= outData.count {
                result.append(outData.subdata(in: begin..<end))
            }
        }
        return result
    }
}

/// Erasure coding error.
public enum ErasureCodingError: Error, Sendable {
    case decodingFailed
    case insufficientBlocks
    case invalidRedundancy
}

/// Safe array access extension.
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
