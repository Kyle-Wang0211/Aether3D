// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CorruptionDetector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 数据损坏检测，校验和验证
//

import Foundation
import SharedSecurity

/// Corruption detector
///
/// Detects data corruption with checksum verification.
/// Validates data integrity.
public actor CorruptionDetector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Detection history
    private var detectionHistory: [(timestamp: Date, corrupted: Bool)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Corruption Detection
    
    /// Detect corruption
    public func detectCorruption(_ data: Data, expectedChecksum: String) -> DetectionResult {
        let actualChecksum = computeChecksum(data)
        let isCorrupted = actualChecksum != expectedChecksum
        
        // Record detection
        detectionHistory.append((timestamp: Date(), corrupted: isCorrupted))
        
        // Keep only recent history (last 100)
        if detectionHistory.count > 100 {
            detectionHistory.removeFirst()
        }
        
        return DetectionResult(
            isCorrupted: isCorrupted,
            expectedChecksum: expectedChecksum,
            actualChecksum: actualChecksum
        )
    }
    
    /// Compute checksum
    /// 
    /// 使用密码学安全的SHA256哈希，符合INV-SEC-066: 损坏检测必须使用加密哈希。
    private func computeChecksum(_ data: Data) -> String {
        return CryptoHasher.sha256(data)
    }
    
    // MARK: - Result Types
    
    /// Detection result
    public struct DetectionResult: Sendable {
        public let isCorrupted: Bool
        public let expectedChecksum: String
        public let actualChecksum: String
    }
}
