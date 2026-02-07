//
// JobEventStore.swift
// Aether3D
//
// Job Event Store - In-memory implementation of event store
// 符合 PR2-02: Event Sourcing with Snapshots
//

import Foundation

/// In-memory implementation of Job Event Store
///
/// Stores events and snapshots in memory.
/// In production, use persistent storage (SQLite, etc.)
public actor InMemoryJobEventStore: JobEventStore {
    
    // MARK: - State
    
    /// Events by job ID
    private var eventsByJobId: [String: [JobStateEvent]] = [:]
    
    /// Snapshots by job ID
    private var snapshotsByJobId: [String: JobStateSnapshot] = [:]
    
    /// Event index by event ID
    private var eventIndex: [String: (jobId: String, index: Int)] = [:]
    
    // MARK: - Event Store Implementation
    
    /// Append event to store
    public func append(_ event: JobStateEvent) async throws {
        var events = eventsByJobId[event.jobId] ?? []
        events.append(event)
        eventsByJobId[event.jobId] = events
        
        // Update index
        eventIndex[event.eventId] = (jobId: event.jobId, index: events.count - 1)
        
        // Check if snapshot should be created
        if JobStateSnapshot.shouldCreateSnapshot(eventCount: events.count) {
            let snapshot = JobStateSnapshot(
                jobId: event.jobId,
                currentState: event.toState,
                eventId: event.eventId,
                eventCount: events.count,
                contractVersion: event.contractVersion
            )
            try await saveSnapshot(snapshot)
        }
    }
    
    /// Get all events for a job
    public func getEvents(jobId: String) async throws -> [JobStateEvent] {
        return eventsByJobId[jobId] ?? []
    }
    
    /// Get events since a specific event ID
    public func getEventsSince(jobId: String, eventId: String) async throws -> [JobStateEvent] {
        guard let events = eventsByJobId[jobId],
              let (_, startIndex) = eventIndex[eventId] else {
            return []
        }
        
        return Array(events[(startIndex + 1)...])
    }
    
    /// Get latest snapshot for a job
    public func getLatestSnapshot(jobId: String) async throws -> JobStateSnapshot? {
        return snapshotsByJobId[jobId]
    }
    
    /// Save snapshot
    public func saveSnapshot(_ snapshot: JobStateSnapshot) async throws {
        snapshotsByJobId[snapshot.jobId] = snapshot
    }
    
    // MARK: - State Reconstruction
    
    /// Reconstruct state from events
    /// 
    /// 符合 PR2-02: Event sourcing - state can be reconstructed from events
    /// - Parameter jobId: Job ID
    /// - Returns: Current state
    /// - Throws: JobStateMachineError if reconstruction fails
    public func reconstructState(jobId: String) async throws -> JobState {
        // Try to get latest snapshot
        if let snapshot = try await getLatestSnapshot(jobId: jobId) {
            // Get events since snapshot
            let events = try await getEventsSince(jobId: jobId, eventId: snapshot.eventId)
            
            // Apply events to snapshot state
            var currentState = snapshot.currentState
            for event in events {
                currentState = event.toState
            }
            return currentState
        } else {
            // No snapshot, replay all events
            let events = try await getEvents(jobId: jobId)
            guard let lastEvent = events.last else {
                throw JobStateMachineError.emptyJobId
            }
            return lastEvent.toState
        }
    }
}
