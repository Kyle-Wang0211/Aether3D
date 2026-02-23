// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Adaptive Chunk Sizer
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Chunk sizing strategy enumeration.
public enum ChunkSizingStrategy: String, Codable {
    case fixed = "fixed"
    case adaptive = "adaptive"
    case aggressive = "aggressive"
}

/// Adaptive chunk sizer configuration.
public struct AdaptiveChunkConfig: Codable, Equatable {
    public let strategy: ChunkSizingStrategy
    public let minChunkSize: Int
    public let maxChunkSize: Int
    public let targetUploadTime: TimeInterval

    public init(
        strategy: ChunkSizingStrategy = .adaptive,
        minChunkSize: Int = UploadConstants.CHUNK_SIZE_MIN_BYTES,
        maxChunkSize: Int = UploadConstants.CHUNK_SIZE_MAX_BYTES,
        targetUploadTime: TimeInterval = 10.0
    ) {
        self.strategy = strategy
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize
        self.targetUploadTime = targetUploadTime
    }
}

/// Adaptive chunk sizer for network-aware chunk sizing.
public final class AdaptiveChunkSizer {

    private let config: AdaptiveChunkConfig
    private let speedMonitor: NetworkSpeedMonitor

    public init(config: AdaptiveChunkConfig = AdaptiveChunkConfig(), speedMonitor: NetworkSpeedMonitor) {
        self.config = config
        self.speedMonitor = speedMonitor
    }

    /// Calculate optimal chunk size based on current network conditions.
    public func calculateChunkSize() -> Int {
        switch config.strategy {
        case .fixed:
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        case .adaptive:
            return speedMonitor.getRecommendedChunkSize()
        case .aggressive:
            let speedClass = speedMonitor.getSpeedClass()
            return speedClass.allowsAggressiveOptimization
                ? config.maxChunkSize
                : speedMonitor.getRecommendedChunkSize()
        }
    }

    /// Calculate optimal chunk size for a specific file size.
    public func calculateChunkSize(forFileSize fileSize: Int64) -> Int {
        let baseSize = calculateChunkSize()

        // For small files, use smaller chunks
        if fileSize < Int64(baseSize * 2) {
            return max(config.minChunkSize, Int(fileSize / 2))
        }

        return baseSize
    }

    /// Get recommended parallel upload count.
    public func getRecommendedParallelCount() -> Int {
        return speedMonitor.getRecommendedParallelCount()
    }
}
