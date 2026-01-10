// AuditTraceEmitter.swift
// PR#8.5 / v0.0.1

import Foundation

/// Emits audit trace events with validation and two-phase commit.
///
/// Lifecycle: Create one emitter per trace. Do not reuse.
///
/// - Note: Thread-safety: NOT thread-safe. Caller must serialize access.
public final class AuditTraceEmitter {
    
    // MARK: - Error Types
    
    /// Emitter operation errors.
    public enum EmitterError: Error, Equatable, Sendable {
        case validationFailed(TraceValidator.ValidationError)
        case idGenerationFailed(TraceIdGenerator.IdGenerationError)
        case writeFailed(underlyingError: String)
        case traceNotStarted
        case traceAlreadyEnded
    }
    
    // MARK: - Dependencies (injected)
    
    private let appendEntry: (AuditEntry) throws -> Void
    private let policyHash: String
    private let pipelineVersion: String
    private let buildMeta: BuildMeta
    private let wallClock: () -> Date
    
    // MARK: - State
    
    private let validator = TraceValidator()
    private var _traceId: String? = nil
    private var _sceneId: String? = nil
    private var _isEnded: Bool = false
    private var _eventIndex: Int = 0
    
    // MARK: - Public Properties
    
    /// Trace ID (nil until start committed).
    public var traceId: String? { _traceId }
    
    /// Scene ID (nil until start committed).
    public var sceneId: String? { _sceneId }
    
    /// Whether trace has ended (end or fail committed, or write failed after validation).
    public var isEnded: Bool { _isEnded }
    
    /// Whether trace is complete (end or fail committed successfully).
    public var isTraceComplete: Bool { validator.isComplete }
    
    /// Whether trace is orphan (started but not complete).
    public var isTraceOrphan: Bool {
        return validator.hasStarted && !validator.isComplete
    }
    
    // MARK: - Initialization
    
    /// Initialize emitter.
    ///
    /// - Parameters:
    ///   - appendEntry: Closure to append entry to log. Throws on IO failure.
    ///   - policyHash: Policy hash (64 lowercase hex chars).
    ///   - pipelineVersion: Pipeline version string.
    ///   - buildMeta: Build metadata.
    ///   - wallClock: Clock for timestamps. Default: WallClock.now().
    public init(
        appendEntry: @escaping (AuditEntry) throws -> Void,
        policyHash: String,
        pipelineVersion: String,
        buildMeta: BuildMeta,
        wallClock: @escaping () -> Date = { WallClock.now() }
    ) {
        self.appendEntry = appendEntry
        self.policyHash = policyHash
        self.pipelineVersion = pipelineVersion
        self.buildMeta = buildMeta
        self.wallClock = wallClock
    }
    
    // MARK: - Emit API
    
    /// Emit trace_start event.
    ///
    /// - Parameters:
    ///   - inputs: Baseline inputs for this trace.
    ///   - paramsSummary: Debug parameters.
    /// - Returns: Success with traceId, or failure.
    public func emitStart(
        inputs: [InputDescriptor],
        paramsSummary: [String: String] = [:]
    ) -> Result<String, EmitterError> {
        
        // Generate IDs
        let traceIdResult = TraceIdGenerator.makeTraceId(
            policyHash: policyHash,
            pipelineVersion: pipelineVersion,
            inputs: inputs,
            paramsSummary: paramsSummary
        )
        
        let generatedTraceId: String
        switch traceIdResult {
        case .success(let id):
            generatedTraceId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        let sceneIdResult = TraceIdGenerator.makeSceneId(inputs: inputs)
        let generatedSceneId: String
        switch sceneIdResult {
        case .success(let id):
            generatedSceneId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        // For traceStart, eventIndex must always be 0
        let eventIdResult = TraceIdGenerator.makeEventId(traceId: generatedTraceId, eventIndex: 0)
        let eventId: String
        switch eventIdResult {
        case .success(let id):
            eventId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        // Build entry with all fields explicitly set
        let entry = AuditEntry(
            timestamp: wallClock(),
            eventType: AuditEventType.traceStart.rawValue,  // Legacy field for backward compat
            detailsJson: nil,  // Legacy field, unused in PR#8.5
            detailsSchemaVersion: "1.0",  // Legacy field
            schemaVersion: 1,
            pr85EventType: .traceStart,
            entryType: AuditEventType.traceStart.rawValue,
            actionType: nil,
            traceId: generatedTraceId,
            sceneId: generatedSceneId,
            eventId: eventId,
            policyHash: policyHash,
            pipelineVersion: pipelineVersion,
            inputs: inputs,
            paramsSummary: paramsSummary,
            metrics: nil,
            artifactRef: nil,
            buildMeta: buildMeta
        )
        
        // Phase 1: Validate
        if let validationError = validator.validate(entry) {
            // Validation failed: do NOT set isEnded, allow retry with fixed params
            return .failure(.validationFailed(validationError))
        }
        
        // Phase 2: Commit
        do {
            try appendEntry(entry)
            validator.commit()
            _traceId = generatedTraceId
            _sceneId = generatedSceneId
            _eventIndex += 1
            return .success(generatedTraceId)
        } catch {
            validator.rollback()
            return .failure(.writeFailed(underlyingError: String(describing: error)))
        }
    }
    
    /// Emit action_step event.
    ///
    /// - Parameters:
    ///   - actionType: Type of action performed.
    ///   - inputs: Incremental inputs for this step.
    /// - Returns: Success or failure.
    public func emitStep(
        actionType: AuditActionType,
        inputs: [InputDescriptor] = []
    ) -> Result<Void, EmitterError> {
        
        guard let currentTraceId = _traceId, let currentSceneId = _sceneId else {
            return .failure(.traceNotStarted)
        }
        
        if _isEnded {
            return .failure(.traceAlreadyEnded)
        }
        
        let eventIdResult = TraceIdGenerator.makeEventId(traceId: currentTraceId, eventIndex: _eventIndex)
        let eventId: String
        switch eventIdResult {
        case .success(let id):
            eventId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        let entry = AuditEntry(
            timestamp: wallClock(),
            eventType: AuditEventType.actionStep.rawValue,  // Legacy field
            detailsJson: nil,  // Legacy field
            detailsSchemaVersion: "1.0",  // Legacy field
            schemaVersion: 1,
            pr85EventType: .actionStep,
            entryType: AuditEventType.actionStep.rawValue,
            actionType: actionType,
            traceId: currentTraceId,
            sceneId: currentSceneId,
            eventId: eventId,
            policyHash: policyHash,
            pipelineVersion: pipelineVersion,
            inputs: inputs,
            paramsSummary: [:],  // Must be empty for step
            metrics: nil,
            artifactRef: nil,
            buildMeta: buildMeta
        )
        
        if let validationError = validator.validate(entry) {
            return .failure(.validationFailed(validationError))
        }
        
        do {
            try appendEntry(entry)
            validator.commit()
            _eventIndex += 1
            return .success(())
        } catch {
            validator.rollback()
            return .failure(.writeFailed(underlyingError: String(describing: error)))
        }
    }
    
    /// Emit trace_end event.
    ///
    /// - Parameters:
    ///   - elapsedMs: Elapsed time in milliseconds.
    ///   - qualityScore: Optional quality score [0.0, 1.0].
    ///   - artifactRef: Optional artifact reference.
    /// - Returns: Success or failure.
    public func emitEnd(
        elapsedMs: Int,
        qualityScore: Double? = nil,
        artifactRef: String? = nil
    ) -> Result<Void, EmitterError> {
        
        guard let currentTraceId = _traceId, let currentSceneId = _sceneId else {
            return .failure(.traceNotStarted)
        }
        
        if _isEnded {
            return .failure(.traceAlreadyEnded)
        }
        
        let eventIdResult = TraceIdGenerator.makeEventId(traceId: currentTraceId, eventIndex: _eventIndex)
        let eventId: String
        switch eventIdResult {
        case .success(let id):
            eventId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        let metrics = TraceMetrics(
            elapsedMs: elapsedMs,
            success: true,
            qualityScore: qualityScore,
            errorCode: nil
        )
        
        let entry = AuditEntry(
            timestamp: wallClock(),
            eventType: AuditEventType.traceEnd.rawValue,  // Legacy field
            detailsJson: nil,  // Legacy field
            detailsSchemaVersion: "1.0",  // Legacy field
            schemaVersion: 1,
            pr85EventType: .traceEnd,
            entryType: AuditEventType.traceEnd.rawValue,
            actionType: nil,
            traceId: currentTraceId,
            sceneId: currentSceneId,
            eventId: eventId,
            policyHash: policyHash,
            pipelineVersion: pipelineVersion,
            inputs: [],  // Must be empty for end
            paramsSummary: [:],  // Must be empty for end
            metrics: metrics,
            artifactRef: artifactRef,
            buildMeta: buildMeta
        )
        
        // Phase 1: Validate
        if let validationError = validator.validate(entry) {
            // Validation failed: do NOT set isEnded, allow retry with fixed params
            return .failure(.validationFailed(validationError))
        }
        
        // Phase 2: Commit
        // Set isEnded AFTER validation passes, BEFORE write attempt
        // This prevents re-entry even if write fails
        _isEnded = true
        
        do {
            try appendEntry(entry)
            validator.commit()
            _eventIndex += 1
            return .success(())
        } catch {
            validator.rollback()
            // isEnded remains true: trace is orphan, cannot retry
            return .failure(.writeFailed(underlyingError: String(describing: error)))
        }
    }
    
    /// Emit trace_fail event.
    ///
    /// - Parameters:
    ///   - elapsedMs: Elapsed time in milliseconds.
    ///   - errorCode: Error code (required, non-empty).
    /// - Returns: Success or failure.
    public func emitFail(
        elapsedMs: Int,
        errorCode: String
    ) -> Result<Void, EmitterError> {
        
        guard let currentTraceId = _traceId, let currentSceneId = _sceneId else {
            return .failure(.traceNotStarted)
        }
        
        if _isEnded {
            return .failure(.traceAlreadyEnded)
        }
        
        let eventIdResult = TraceIdGenerator.makeEventId(traceId: currentTraceId, eventIndex: _eventIndex)
        let eventId: String
        switch eventIdResult {
        case .success(let id):
            eventId = id
        case .failure(let error):
            return .failure(.idGenerationFailed(error))
        }
        
        let metrics = TraceMetrics(
            elapsedMs: elapsedMs,
            success: false,
            qualityScore: nil,
            errorCode: errorCode
        )
        
        let entry = AuditEntry(
            timestamp: wallClock(),
            eventType: AuditEventType.traceFail.rawValue,  // Legacy field
            detailsJson: nil,  // Legacy field
            detailsSchemaVersion: "1.0",  // Legacy field
            schemaVersion: 1,
            pr85EventType: .traceFail,
            entryType: AuditEventType.traceFail.rawValue,
            actionType: nil,
            traceId: currentTraceId,
            sceneId: currentSceneId,
            eventId: eventId,
            policyHash: policyHash,
            pipelineVersion: pipelineVersion,
            inputs: [],  // Must be empty for fail
            paramsSummary: [:],  // Must be empty for fail
            metrics: metrics,
            artifactRef: nil,
            buildMeta: buildMeta
        )
        
        // Phase 1: Validate
        if let validationError = validator.validate(entry) {
            // Validation failed: do NOT set isEnded, allow retry with fixed params
            return .failure(.validationFailed(validationError))
        }
        
        // Phase 2: Commit
        // Set isEnded AFTER validation passes, BEFORE write attempt
        _isEnded = true
        
        do {
            try appendEntry(entry)
            validator.commit()
            _eventIndex += 1
            return .success(())
        } catch {
            validator.rollback()
            // isEnded remains true: trace is orphan, cannot retry
            return .failure(.writeFailed(underlyingError: String(describing: error)))
        }
    }
    
    /// Generate orphan report for incomplete traces.
    ///
    /// - Returns: Report if trace is orphan, nil if complete or not started.
    public func orphanReport() -> OrphanTraceReport? {
        guard isTraceOrphan, let traceId = _traceId else {
            return nil
        }
        
        return OrphanTraceReport(
            traceId: traceId,
            committedEventCount: validator.eventCount,
            lastEventType: validator.lastCommittedEventType
        )
    }
}

