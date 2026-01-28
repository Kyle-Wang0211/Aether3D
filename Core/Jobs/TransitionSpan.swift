// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// OpenTelemetry-compatible span for state transitions.
/// Reference: https://opentelemetry.io/docs/concepts/signals/traces/
public struct TransitionSpan: Codable, Equatable {
    /// Unique span ID (16 hex characters)
    public let spanId: String
    
    /// Parent span ID (for distributed tracing)
    public let parentSpanId: String?
    
    /// Trace ID (32 hex characters)
    public let traceId: String
    
    /// Span name (e.g., "job.transition.pending_to_uploading")
    public let name: String
    
    /// Start timestamp (Unix nanoseconds)
    public let startTimeUnixNano: UInt64
    
    /// End timestamp (Unix nanoseconds)
    public let endTimeUnixNano: UInt64
    
    /// Span status
    public let status: SpanStatus
    
    /// Span attributes
    public let attributes: [String: String]
    
    /// Span events (e.g., errors, retries)
    public let events: [SpanEvent]
    
    public enum SpanStatus: String, Codable {
        case unset
        case ok
        case error
    }
    
    public struct SpanEvent: Codable, Equatable {
        public let name: String
        public let timeUnixNano: UInt64
        public let attributes: [String: String]
        
        public init(name: String, timeUnixNano: UInt64, attributes: [String: String] = [:]) {
            self.name = name
            self.timeUnixNano = timeUnixNano
            self.attributes = attributes
        }
    }
    
    public init(
        spanId: String,
        parentSpanId: String? = nil,
        traceId: String,
        name: String,
        startTimeUnixNano: UInt64,
        endTimeUnixNano: UInt64,
        status: SpanStatus = .ok,
        attributes: [String: String] = [:],
        events: [SpanEvent] = []
    ) {
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.traceId = traceId
        self.name = name
        self.startTimeUnixNano = startTimeUnixNano
        self.endTimeUnixNano = endTimeUnixNano
        self.status = status
        self.attributes = attributes
        self.events = events
    }
}

/// Span builder for state transitions.
public final class TransitionSpanBuilder {
    private var spanId: String
    private var parentSpanId: String?
    private var traceId: String
    private var name: String = ""
    private var startTime: Date
    private var attributes: [String: String] = [:]
    private var events: [TransitionSpan.SpanEvent] = []
    
    public init() {
        // Generate 16-char hex span ID
        self.spanId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        // Generate 32-char hex trace ID
        self.traceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.startTime = Date()
    }
    
    @discardableResult
    public func setName(_ name: String) -> Self {
        self.name = name
        return self
    }
    
    @discardableResult
    public func setParentSpanId(_ id: String?) -> Self {
        self.parentSpanId = id
        return self
    }
    
    @discardableResult
    public func setTraceId(_ id: String) -> Self {
        self.traceId = id
        return self
    }
    
    @discardableResult
    public func setAttribute(_ key: String, value: String) -> Self {
        self.attributes[key] = value
        return self
    }
    
    @discardableResult
    public func addEvent(name: String, attributes: [String: String] = [:]) -> Self {
        let event = TransitionSpan.SpanEvent(
            name: name,
            timeUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
            attributes: attributes
        )
        self.events.append(event)
        return self
    }
    
    public func build(status: TransitionSpan.SpanStatus = .ok) -> TransitionSpan {
        let now = Date()
        return TransitionSpan(
            spanId: spanId,
            parentSpanId: parentSpanId,
            traceId: traceId,
            name: name,
            startTimeUnixNano: UInt64(startTime.timeIntervalSince1970 * 1_000_000_000),
            endTimeUnixNano: UInt64(now.timeIntervalSince1970 * 1_000_000_000),
            status: status,
            attributes: attributes,
            events: events
        )
    }
    
    /// Create span from transition log
    public static func fromTransitionLog(_ log: TransitionLog) -> TransitionSpan {
        let builder = TransitionSpanBuilder()
            .setName("job.transition.\(log.from.rawValue)_to_\(log.to.rawValue)")
            .setAttribute("job.id", value: log.jobId)
            .setAttribute("job.from_state", value: log.from.rawValue)
            .setAttribute("job.to_state", value: log.to.rawValue)
            .setAttribute("job.contract_version", value: log.contractVersion)
            .setAttribute("job.transition_id", value: log.transitionId)
            .setAttribute("job.source", value: log.source.rawValue)
        
        if let retryAttempt = log.retryAttempt {
            builder.setAttribute("job.retry_attempt", value: String(retryAttempt))
        }
        
        if let sessionId = log.sessionId {
            builder.setAttribute("job.session_id", value: sessionId)
        }
        
        if let deviceState = log.deviceState {
            builder.setAttribute("device.state", value: deviceState.rawValue)
        }
        
        if let failureReason = log.failureReason {
            builder.setAttribute("job.failure_reason", value: failureReason.rawValue)
            return builder.build(status: .error)
        }
        
        if let cancelReason = log.cancelReason {
            builder.setAttribute("job.cancel_reason", value: cancelReason.rawValue)
        }
        
        return builder.build(status: .ok)
    }
}
