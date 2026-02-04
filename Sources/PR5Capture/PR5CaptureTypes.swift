//
// PR5CaptureTypes.swift
// PR5Capture
//
// PR5 v1.8.1 - 基础类型和协议定义
//

import Foundation
import PR4Math
import PR4Ownership
import PR4Quality
import PR4Gate

// MARK: - Core Data Structures

/// Frame metadata for PR5Capture
public struct PR5FrameMetadata: Codable, Sendable {
    public let frameId: UInt64
    public let timestamp: TimeInterval
    public let sessionId: UUID
    public let captureState: CaptureState
    public let quality: Double?
    public let disposition: FrameDisposition?
    
    public init(
        frameId: UInt64,
        timestamp: TimeInterval,
        sessionId: UUID,
        captureState: CaptureState,
        quality: Double? = nil,
        disposition: FrameDisposition? = nil
    ) {
        self.frameId = frameId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.captureState = captureState
        self.quality = quality
        self.disposition = disposition
    }
}

/// Capture state enumeration
public enum CaptureState: String, Codable, Sendable, CaseIterable {
    case idle
    case capturing
    case processing
    case paused
    case error
}

/// Frame disposition decision
public enum FrameDisposition: String, Codable, Sendable, CaseIterable {
    case accept
    case `defer`
    case reject
    case pending
}

/// ISP strength classification
public enum ISPStrength: String, Codable, Sendable, CaseIterable {
    case none
    case low
    case medium
    case high
    case extreme
}

/// Extended capture state (for PART C enhancements)
public enum ExtendedCaptureState: String, Codable, Sendable, CaseIterable {
    case idle
    case capturing
    case processing
    case paused
    case error
    case relocalizing
    case emergencyTransition
}

// MARK: - Protocols

/// Protocol for domain-owned types
public protocol DomainOwned {
    var domain: CaptureDomain { get }
}

/// Protocol for quality-measurable types
public protocol QualityMeasurable {
    var quality: Double { get }
    var uncertainty: Double { get }
}

/// Protocol for anchorable types
public protocol Anchorable {
    var anchorValue: Double { get }
    var timestamp: Date { get }
}

// MARK: - Error Types

/// PR5Capture error types
public enum PR5CaptureError: Error, Sendable {
    case domainBoundaryViolation(from: CaptureDomain, to: CaptureDomain)
    case anchorDriftExceeded(threshold: Double, actual: Double)
    case qualityGateFailed(phase: QualityGatePhase, threshold: Double, actual: Double)
    case stateTransitionBlocked(reason: String)
    case configurationError(message: String)
    case invalidInput(message: String)
    
    public enum QualityGatePhase: String, Sendable {
        case frameGate
        case patchGate
    }
}

// MARK: - Result Types

/// Generic result type for PR5Capture operations
public typealias PR5Result<T> = Result<T, PR5CaptureError>

// MARK: - Event Types

/// Audit event for PR5Capture operations
public struct PR5AuditEvent: Codable, Sendable {
    public let eventId: UUID
    public let timestamp: Date
    public let eventType: AuditEventType
    public let domain: CaptureDomain
    public let metadata: [String: String]
    
    public enum AuditEventType: String, Codable, Sendable, CaseIterable {
        case domainBoundaryCross
        case anchorUpdate
        case qualityGateDecision
        case stateTransition
        case configurationChange
        case error
    }
    
    public init(
        eventId: UUID = UUID(),
        timestamp: Date = Date(),
        eventType: AuditEventType,
        domain: CaptureDomain,
        metadata: [String: String] = [:]
    ) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.eventType = eventType
        self.domain = domain
        self.metadata = metadata
    }
}
