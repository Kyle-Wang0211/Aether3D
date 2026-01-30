//
// EvidenceLogger.swift
// Aether3D
//
// PR2 Patch V4 - Structured Evidence Logging
// Structured events for observability and forensics
//

import Foundation
import os.log

/// Structured evidence event
public protocol EvidenceEvent: Codable, Sendable {
    var eventType: String { get }
    var timestampMs: Int64 { get }
    var patchId: String? { get }
}

/// Admission decision event
public struct AdmissionDecisionEvent: EvidenceEvent {
    public let eventType = "admission_decision"
    public let timestampMs: Int64
    public let patchId: String?
    public let allowed: Bool
    public let qualityScale: Double
    public let reasons: [String]
    
    public init(
        timestampMs: Int64,
        patchId: String?,
        allowed: Bool,
        qualityScale: Double,
        reasons: [String]
    ) {
        self.timestampMs = timestampMs
        self.patchId = patchId
        self.allowed = allowed
        self.qualityScale = qualityScale
        self.reasons = reasons
    }
}

/// Ledger update event
public struct LedgerUpdateEvent: EvidenceEvent {
    public let eventType = "ledger_update"
    public let timestampMs: Int64
    public let patchId: String?
    public let previousEvidence: Double
    public let newEvidence: Double
    public let verdict: String
    public let isLocked: Bool
    
    public init(
        timestampMs: Int64,
        patchId: String?,
        previousEvidence: Double,
        newEvidence: Double,
        verdict: String,
        isLocked: Bool
    ) {
        self.timestampMs = timestampMs
        self.patchId = patchId
        self.previousEvidence = previousEvidence
        self.newEvidence = newEvidence
        self.verdict = verdict
        self.isLocked = isLocked
    }
}

/// Display update event
public struct DisplayUpdateEvent: EvidenceEvent {
    public let eventType = "display_update"
    public let timestampMs: Int64
    public let patchId: String?
    public let previousDisplay: Double
    public let newDisplay: Double
    public let delta: Double
    
    public init(
        timestampMs: Int64,
        patchId: String?,
        previousDisplay: Double,
        newDisplay: Double,
        delta: Double
    ) {
        self.timestampMs = timestampMs
        self.patchId = patchId
        self.previousDisplay = previousDisplay
        self.newDisplay = newDisplay
        self.delta = delta
    }
}

/// Delta update event
public struct DeltaUpdateEvent: EvidenceEvent {
    public let eventType = "delta_update"
    public let timestampMs: Int64
    public let patchId: String?
    public let rawDelta: Double
    public let smoothedDelta: Double
    public let gateDelta: Double
    public let softDelta: Double
    
    public init(
        timestampMs: Int64,
        patchId: String?,
        rawDelta: Double,
        smoothedDelta: Double,
        gateDelta: Double,
        softDelta: Double
    ) {
        self.timestampMs = timestampMs
        self.patchId = patchId
        self.rawDelta = rawDelta
        self.smoothedDelta = smoothedDelta
        self.gateDelta = gateDelta
        self.softDelta = softDelta
    }
}

/// Aggregator update event
public struct AggregatorUpdateEvent: EvidenceEvent {
    public let eventType = "aggregator_update"
    public let timestampMs: Int64
    public let patchId: String?
    public let totalEvidence: Double
    public let patchCount: Int
    public let bucketCount: Int
    
    public init(
        timestampMs: Int64,
        patchId: String?,
        totalEvidence: Double,
        patchCount: Int,
        bucketCount: Int
    ) {
        self.timestampMs = timestampMs
        self.patchId = patchId
        self.totalEvidence = totalEvidence
        self.patchCount = patchCount
        self.bucketCount = bucketCount
    }
}

/// Evidence logger with structured events
public enum EvidenceLogger {
    
    private static let log = OSLog(subsystem: "com.aether3d.evidence", category: "Evidence")
    
    /// Log structured event
    public static func logEvent<T: EvidenceEvent>(_ event: T) {
        #if DEBUG
        if let jsonData = try? JSONEncoder().encode(event),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            os_log("%{public}@", log: log, type: .info, jsonString)
        }
        #endif
    }
    
    /// Log warning
    public static func warn(_ message: String, file: StaticString = #file, line: UInt = #line) {
        os_log("%{public}@", log: log, type: .error, "[WARN] \(file):\(line) - \(message)")
    }
    
    /// Log error
    public static func error(_ message: String, file: StaticString = #file, line: UInt = #line) {
        os_log("%{public}@", log: log, type: .fault, "[ERROR] \(file):\(line) - \(message)")
    }
    
    /// Log info
    public static func info(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
