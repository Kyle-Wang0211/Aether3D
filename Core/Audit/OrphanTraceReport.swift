// OrphanTraceReport.swift
// PR#8.5 / v0.0.1

import Foundation

/// Report for orphan (incomplete) traces.
///
/// An orphan trace has started but not ended (no trace_end or trace_fail committed).
/// This is a normal occurrence (crash, cancel, timeout, etc.), NOT an error.
///
/// - Note: Thread-safety: Immutable struct, safe for concurrent use.
/// - Note: Read-only data structure. No IO, no fixes, no writes. No side effects.
public struct OrphanTraceReport: Codable, Sendable, Equatable {
    
    /// Trace ID of the orphan trace.
    public let traceId: String
    
    /// Number of events committed before abandonment.
    public let committedEventCount: Int
    
    /// Type of last committed event.
    public let lastEventType: AuditEventType?
    
    public init(
        traceId: String,
        committedEventCount: Int,
        lastEventType: AuditEventType?
    ) {
        self.traceId = traceId
        self.committedEventCount = committedEventCount
        self.lastEventType = lastEventType
    }
}

