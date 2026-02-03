//
// FrameContext.swift
// PR4Ownership
//
// PR4 V10 - Pillar 2: Frame-scoped state with ownership semantics (Hard-13)
//

import Foundation
import PR4Math
import PR4PathTrace
import PR4Protocols

/// Frame context - owns all mutable state for a single frame
///
/// V10 RULE: FrameContext is the ONLY container for frame-scoped mutable state.
public final class FrameContextLegacy {
    
    /// Unique frame identifier
    public let frameId: FrameID
    
    /// Session this frame belongs to
    public let sessionId: UUID
    
    /// Whether this context has been consumed
    private var isConsumed: Bool = false
    
    /// Lock for thread-safe consumption check
    private let consumeLock = NSLock()
    
    /// Input data (immutable)
    public let depthSamples: [SourceDepthSamples]
    public let confidences: [SourceConfidence]
    public let timestamp: TimeInterval
    
    /// Mutable state (owned by this frame)
    public var computedQualities: [SourceID: Any] = [:]
    public var gateDecisions: [SourceID: Any] = [:]
    public var fusionResult: Any?
    public var overflowEvents: [OverflowEvent] = []
    public var pathTrace: PathDeterminismTraceV2
    
    public init(
        sessionId: UUID,
        depthSamples: [SourceDepthSamples],
        confidences: [SourceConfidence],
        timestamp: TimeInterval
    ) {
        self.frameId = FrameID.next()
        self.sessionId = sessionId
        self.depthSamples = depthSamples
        self.confidences = confidences
        self.timestamp = timestamp
        self.pathTrace = PathDeterminismTraceV2()
    }
    
    /// Consume this context (mark as used)
    public func consume() {
        consumeLock.lock()
        defer { consumeLock.unlock() }
        
        precondition(!isConsumed, "FrameContext \(frameId) already consumed!")
        isConsumed = true
    }
    
    /// Check if context is still valid
    public var isValid: Bool {
        consumeLock.lock()
        defer { consumeLock.unlock() }
        return !isConsumed
    }
    
    /// Assert context is valid before any access
    @inline(__always)
    public func assertValid(caller: String = #function) {
        consumeLock.lock()
        defer { consumeLock.unlock() }
        
        #if DETERMINISM_STRICT
        precondition(!isConsumed, "Accessing consumed FrameContext \(frameId) from \(caller)")
        #else
        if isConsumed {
            FrameLeakLogger.shared.log(frameId: frameId, caller: caller)
        }
        #endif
    }
    
    public func validate() throws {
        guard !depthSamples.isEmpty else {
            throw FrameContextError.noDepthSamples
        }
    }
}

/// Logger for frame leaks
final class FrameLeakLogger {
    static let shared = FrameLeakLogger()
    
    private var leaks: [(expected: FrameID?, actual: FrameID?, caller: String, time: Date)] = []
    private let lock = NSLock()
    
    func log(frameId: FrameID, caller: String) {
        lock.lock()
        defer { lock.unlock() }
        
        leaks.append((nil, frameId, caller, Date()))
        
        if leaks.count <= 10 || leaks.count % 100 == 0 {
            print("⚠️ Consumed frame access #\(leaks.count): \(frameId) from \(caller)")
        }
    }
    
    func log(expectedFrame: FrameID, actualFrame: FrameID, caller: String) {
        lock.lock()
        defer { lock.unlock() }
        
        leaks.append((expectedFrame, actualFrame, caller, Date()))
        
        if leaks.count <= 10 || leaks.count % 100 == 0 {
            print("⚠️ Cross-frame leak #\(leaks.count): expected \(expectedFrame), got \(actualFrame) in \(caller)")
        }
    }
}

/// Supporting types
public struct SourceDepthSamples {
    public let sourceId: SourceID
    public let samples: [DepthSample]
}

public struct SourceConfidence {
    public let sourceId: SourceID
    public let confidence: Double
}

// QualityResult moved to PR4Quality module

// GateDecision moved to PR4Gate module - use Any type here for compatibility

// FusionResult moved to PR4Fusion module

public struct OverflowEvent {
    public let field: String
    public let value: Int64
    public let direction: String
}

public struct FrameResult {
    public let frameId: FrameID
    public let sessionId: UUID
    public let qualities: [SourceID: Any]
    public let gateDecisions: [SourceID: Any]
    public let fusion: Any?
    public let overflows: [OverflowEvent]
    public let pathSignature: UInt64
    
    public init(frameId: FrameID, sessionId: UUID, qualities: [SourceID: Any], gateDecisions: [SourceID: Any], fusion: Any?, overflows: [OverflowEvent], pathSignature: UInt64) {
        self.frameId = frameId
        self.sessionId = sessionId
        self.qualities = qualities
        self.gateDecisions = gateDecisions
        self.fusion = fusion
        self.overflows = overflows
        self.pathSignature = pathSignature
    }
}

public enum FrameContextError: Error {
    case noDepthSamples
    case invalidSession
    case alreadyConsumed
}

// Type aliases are defined in PR4Protocols module:
// - SourceID = String
// - DepthSample = Double
// - CalibrationData = [String: Double]

// SoftGateState moved to PR4Gate module
