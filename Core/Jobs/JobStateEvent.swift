// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// JobStateEvent.swift
// Aether3D
//
// Job State Event - Event sourcing events for state machine
// 符合 PR2-02: Event Sourcing with Snapshots
//

import Foundation

/// Job State Event
///
/// Immutable event representing a state change in the job state machine.
/// Used for event sourcing to reconstruct state from events.
public struct JobStateEvent: Codable, Sendable, Equatable {
    /// Unique event ID (UUID)
    public let eventId: String
    
    /// Job ID
    public let jobId: String
    
    /// Previous state
    public let fromState: JobState
    
    /// New state
    public let toState: JobState
    
    /// Failure reason (if transition to failed)
    public let failureReason: FailureReason?
    
    /// Cancel reason (if transition to cancelled)
    public let cancelReason: CancelReason?
    
    /// Timestamp of the event
    public let timestamp: Date
    
    /// Contract version
    public let contractVersion: String
    
    /// Transition source (client/server/system)
    public let source: TransitionSource
    
    /// Transition ID for idempotency
    public let transitionId: String
    
    /// Event version (for schema evolution)
    public let eventVersion: Int
    
    /// Additional metadata (JSON string)
    public let metadata: String?
    
    public init(
        eventId: String = UUID().uuidString,
        jobId: String,
        fromState: JobState,
        toState: JobState,
        failureReason: FailureReason? = nil,
        cancelReason: CancelReason? = nil,
        timestamp: Date = Date(),
        contractVersion: String,
        source: TransitionSource = .client,
        transitionId: String = UUID().uuidString,
        eventVersion: Int = 1,
        metadata: String? = nil
    ) {
        self.eventId = eventId
        self.jobId = jobId
        self.fromState = fromState
        self.toState = toState
        self.failureReason = failureReason
        self.cancelReason = cancelReason
        self.timestamp = timestamp
        self.contractVersion = contractVersion
        self.source = source
        self.transitionId = transitionId
        self.eventVersion = eventVersion
        self.metadata = metadata
    }
    
    /// Create event from transition log
    public init(from transitionLog: TransitionLog) {
        self.eventId = UUID().uuidString
        self.jobId = transitionLog.jobId
        self.fromState = transitionLog.from
        self.toState = transitionLog.to
        self.failureReason = transitionLog.failureReason
        self.cancelReason = transitionLog.cancelReason
        self.timestamp = transitionLog.timestamp
        self.contractVersion = transitionLog.contractVersion
        self.source = transitionLog.source
        self.transitionId = transitionLog.transitionId
        self.eventVersion = 1
        self.metadata = nil
    }
}

/// Event store interface for persistence
public protocol JobEventStore: Sendable {
    /// Append event to store
    func append(_ event: JobStateEvent) async throws
    
    /// Get all events for a job
    func getEvents(jobId: String) async throws -> [JobStateEvent]
    
    /// Get events since a specific event ID
    func getEventsSince(jobId: String, eventId: String) async throws -> [JobStateEvent]
    
    /// Get latest snapshot for a job
    func getLatestSnapshot(jobId: String) async throws -> JobStateSnapshot?
    
    /// Save snapshot
    func saveSnapshot(_ snapshot: JobStateSnapshot) async throws
}
