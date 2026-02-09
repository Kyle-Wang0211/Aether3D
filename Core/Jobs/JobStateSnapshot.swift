// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// JobStateSnapshot.swift
// Aether3D
//
// Job State Snapshot - Snapshot for event sourcing optimization
// 符合 PR2-02: Event Sourcing with Snapshots (snapshot every 100 events)
//

import Foundation

/// Job State Snapshot
///
/// Snapshot of job state at a specific point in time.
/// Used to optimize event sourcing by avoiding replaying all events.
/// 符合 PR2-02: Snapshot creation every 100 events
public struct JobStateSnapshot: Codable, Sendable, Equatable {
    /// Job ID
    public let jobId: String
    
    /// Current state
    public let currentState: JobState
    
    /// Event ID this snapshot is based on
    public let eventId: String
    
    /// Event count at snapshot time
    public let eventCount: Int
    
    /// Timestamp of snapshot
    public let timestamp: Date
    
    /// Contract version
    public let contractVersion: String
    
    /// Snapshot version (for schema evolution)
    public let snapshotVersion: Int
    
    /// Additional state data (JSON string)
    public let stateData: String?
    
    public init(
        jobId: String,
        currentState: JobState,
        eventId: String,
        eventCount: Int,
        timestamp: Date = Date(),
        contractVersion: String,
        snapshotVersion: Int = 1,
        stateData: String? = nil
    ) {
        self.jobId = jobId
        self.currentState = currentState
        self.eventId = eventId
        self.eventCount = eventCount
        self.timestamp = timestamp
        self.contractVersion = contractVersion
        self.snapshotVersion = snapshotVersion
        self.stateData = stateData
    }
    
    /// Check if snapshot should be created (every 100 events)
    /// 
    /// 符合 PR2-02: Snapshot creation every 100 events
    /// - Parameter eventCount: Current event count
    /// - Returns: True if snapshot should be created
    public static func shouldCreateSnapshot(eventCount: Int) -> Bool {
        return eventCount > 0 && eventCount % 100 == 0
    }
}
