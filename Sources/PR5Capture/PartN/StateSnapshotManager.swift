//
// StateSnapshotManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 状态快照管理，周期性检查点
//

import Foundation

/// State snapshot manager
///
/// Manages state snapshots with periodic checkpoints.
/// Enables recovery from saved states.
public actor StateSnapshotManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Snapshots
    private var snapshots: [StateSnapshot] = []
    
    /// Snapshot interval (seconds)
    private let snapshotInterval: TimeInterval = 60.0
    
    /// Last snapshot time
    private var lastSnapshotTime: Date = Date()
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Snapshot Management
    
    /// Create snapshot
    public func createSnapshot(state: [String: Any]) -> SnapshotResult {
        let now = Date()
        
        // Check if interval has passed
        if now.timeIntervalSince(lastSnapshotTime) < snapshotInterval {
            return SnapshotResult(
                created: false,
                reason: "Interval not elapsed"
            )
        }
        
        let snapshot = StateSnapshot(
            id: UUID(),
            timestamp: now,
            state: state
        )
        
        snapshots.append(snapshot)
        lastSnapshotTime = now
        
        // Keep only recent snapshots (last 10)
        if snapshots.count > 10 {
            snapshots.removeFirst()
        }
        
        return SnapshotResult(
            created: true,
            reason: "Snapshot created",
            snapshotId: snapshot.id
        )
    }
    
    /// Get latest snapshot
    public func getLatestSnapshot() -> StateSnapshot? {
        return snapshots.last
    }
    
    // MARK: - Data Types
    
    /// State snapshot
    public struct StateSnapshot: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let state: [String: String]  // NOTE: Basic: use String instead of Any
        
        public init(id: UUID = UUID(), timestamp: Date, state: [String: Any]) {
            self.id = id
            self.timestamp = timestamp
            // Convert Any to String for Sendable
            self.state = state.mapValues { String(describing: $0) }
        }
    }
    
    /// Snapshot result
    public struct SnapshotResult: Sendable {
        public let created: Bool
        public let reason: String
        public let snapshotId: UUID?
        
        public init(created: Bool, reason: String, snapshotId: UUID? = nil) {
            self.created = created
            self.reason = reason
            self.snapshotId = snapshotId
        }
    }
}
