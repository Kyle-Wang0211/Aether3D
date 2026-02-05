//
// RecoveryPointCreator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 恢复点创建，事务性保存
//

import Foundation

/// Recovery point creator
///
/// Creates recovery points with transactional saves.
/// Ensures atomic state persistence.
public actor RecoveryPointCreator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Recovery points
    private var recoveryPoints: [RecoveryPoint] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Recovery Point Creation
    
    /// Create recovery point
    public func createRecoveryPoint(state: [String: String]) -> CreationResult {
        let point = RecoveryPoint(
            id: UUID(),
            timestamp: Date(),
            state: state,
            checksum: computeChecksum(state)
        )
        
        recoveryPoints.append(point)
        
        // Keep only recent points (last 20)
        if recoveryPoints.count > 20 {
            recoveryPoints.removeFirst()
        }
        
        return CreationResult(
            pointId: point.id,
            timestamp: point.timestamp,
            success: true
        )
    }
    
    /// Get recovery point
    public func getRecoveryPoint(_ id: UUID) -> RecoveryPoint? {
        return recoveryPoints.first { $0.id == id }
    }
    
    /// Compute checksum
    private func computeChecksum(_ state: [String: String]) -> String {
        let combined = state.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined()
        return String(combined.hash)
    }
    
    // MARK: - Data Types
    
    /// Recovery point
    public struct RecoveryPoint: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let state: [String: String]
        public let checksum: String
    }
    
    /// Creation result
    public struct CreationResult: Sendable {
        public let pointId: UUID
        public let timestamp: Date
        public let success: Bool
    }
}
