// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PartialResultSalvager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 部分结果抢救，最大化数据保留
//

import Foundation

/// Partial result salvager
///
/// Salvages partial results to maximize data retention.
/// Recovers usable data from incomplete operations.
public actor PartialResultSalvager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Salvaged results
    private var salvagedResults: [SalvagedResult] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Salvaging
    
    /// Salvage partial result
    public func salvage(_ data: Data, completeness: Double) -> SalvageResult {
        // Only salvage if completeness is above threshold
        let threshold = 0.5
        
        guard completeness >= threshold else {
            return SalvageResult(
                success: false,
                reason: "Completeness \(completeness) below threshold \(threshold)"
            )
        }
        
        let result = SalvagedResult(
            id: UUID(),
            data: data,
            completeness: completeness,
            timestamp: Date()
        )
        
        salvagedResults.append(result)
        
        // Keep only recent results (last 100)
        if salvagedResults.count > 100 {
            salvagedResults.removeFirst()
        }
        
        return SalvageResult(
            success: true,
            reason: "Salvaged with completeness \(completeness)",
            resultId: result.id
        )
    }
    
    // MARK: - Data Types
    
    /// Salvaged result
    public struct SalvagedResult: Sendable {
        public let id: UUID
        public let data: Data
        public let completeness: Double
        public let timestamp: Date
    }
    
    /// Salvage result
    public struct SalvageResult: Sendable {
        public let success: Bool
        public let reason: String
        public let resultId: UUID?
        
        public init(success: Bool, reason: String, resultId: UUID? = nil) {
            self.success = success
            self.reason = reason
            self.resultId = resultId
        }
    }
}
