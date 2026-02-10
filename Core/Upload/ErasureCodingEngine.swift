// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-FEC-1.0
// Module: Upload Infrastructure - Erasure Coding Engine
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

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
            return await encodeReedSolomon(data: data, redundancy: redundancy, field: field)
        case .raptorQ:
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
        // Try RS first (faster for systematic codes)
        if originalCount <= 255 {
            do {
                return try await decodeReedSolomon(blocks: blocks, originalCount: originalCount, field: .gf256)
            } catch {
                // Fall back to RaptorQ
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
        // Simplified RS encoding
        // In production, use proper GF arithmetic with SIMD optimizations
        let k = data.count
        let n = k + Int(Double(k) * redundancy)
        
        var encoded: [Data] = []
        
        // Systematic: first k blocks = original data
        encoded.append(contentsOf: data)
        
        // Generate parity blocks (simplified)
        for i in k..<n {
            var parity = Data()
            // Simplified parity computation (in production, use proper GF multiplication)
            for j in 0..<data.count {
                if let block = data[safe: j] {
                    parity.append(block)
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
