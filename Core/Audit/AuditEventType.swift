// AuditEventType.swift
// PR#8.5 / v0.0.1

import Foundation

/// Event types for audit trace.
///
/// This is a CLOSED set. Adding cases requires schemaVersion bump.
/// Removing cases is forbidden (breaking change).
///
/// - Note: NO @unknown default. Exhaustive switching required.
public enum AuditEventType: String, Codable, Sendable, Equatable {
    case traceStart = "trace_start"
    case actionStep = "action_step"
    case traceEnd = "trace_end"
    case traceFail = "trace_fail"
}

