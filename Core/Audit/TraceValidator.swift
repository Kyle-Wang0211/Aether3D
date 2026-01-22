// TraceValidator.swift
// PR#8.5 / v0.0.1

import Foundation

/// Validates audit entries for trace contract compliance.
///
/// Implements two-phase commit: validate updates pending state,
/// commit copies pending to committed, rollback reverts pending.
///
/// - Note: Thread-safety: NOT thread-safe. Caller must serialize access.
/// - Note: Pure in-memory state machine. NO IO, NO retries, NO auto-fixes.
public final class TraceValidator {
    
    // MARK: - Error Types
    
    /// Validation errors with deterministic priority.
    ///
    /// Tests MUST assert error CASE only, NOT associated value strings.
    /// Associated values are for debugging, not contract.
    public enum ValidationError: Error, Equatable, Sendable {
        // Priority 1: Schema errors
        case schemaVersionInvalid(got: Int, expected: Int)
        case policyHashInvalid(reason: String)
        case pipelineVersionInvalid(reason: String)
        case traceIdInvalid(reason: String)
        case sceneIdInvalid(reason: String)
        case eventIdInvalid(reason: String)
        case entryTypeMismatch(expected: String, got: String)
        
        // Priority 2: Deep field errors
        case inputPathInvalid(index: Int, reason: String)
        case inputContentHashInvalid(index: Int, reason: String)
        case inputByteSizeInvalid(index: Int)
        case duplicateInputPath(path: String)
        case metricsElapsedMsInvalid(reason: String)
        case metricsQualityScoreInvalid(reason: String)
        case metricsErrorCodeInvalid(reason: String)
        case artifactRefInvalid(reason: String)
        case paramsSummaryInvalid(reason: String)
        
        // Priority 3: Sequence errors
        case noTraceStarted
        case duplicateTraceStart
        case traceAlreadyEnded
        
        // Priority 4: Field constraint errors
        case metricsRequiredForEnd
        case metricsRequiredForFail
        case metricsForbiddenForStart
        case metricsForbiddenForStep
        case metricsSuccessMismatch(eventType: AuditEventType, success: Bool)
        case errorCodeRequiredForFail
        case errorCodeForbiddenForEnd
        case qualityScoreForbiddenForFail
        case inputsNotEmptyForEnd
        case inputsNotEmptyForFail
        case actionTypeRequiredForStep
        case actionTypeForbiddenForNonStep
        case artifactRefForbiddenForStart
        case artifactRefForbiddenForStep
        case artifactRefForbiddenForFail
        case paramsSummaryNotEmptyForNonStart
        
        // Priority 5: Cross-event consistency errors
        case traceIdMismatch(expected: String, got: String)
        case sceneIdMismatch(expected: String, got: String)
        case policyHashMismatch(expected: String, got: String)
        case eventIndexMismatch(expected: Int, got: Int)
    }
    
    // MARK: - State (Two-Phase)
    
    // Committed state (only updated on commit())
    private var committedEventIndex: Int = 0
    private var committedAnchorTraceId: String? = nil
    private var committedAnchorSceneId: String? = nil
    private var committedAnchorPolicyHash: String? = nil
    private var committedIsEnded: Bool = false
    private var committedLastEventType: AuditEventType? = nil
    
    // Pending state (updated on validate(), copied/reverted on commit/rollback)
    private var pendingEventIndex: Int = 0
    private var pendingAnchorTraceId: String? = nil
    private var pendingAnchorSceneId: String? = nil
    private var pendingAnchorPolicyHash: String? = nil
    private var pendingIsEnded: Bool = false
    private var pendingLastEventType: AuditEventType? = nil
    
    // MARK: - Public API
    
    public init() {}
    
    /// Validate entry and update pending state if valid.
    /// Does NOT modify committed state.
    ///
    /// - Parameter entry: Entry to validate
    /// - Returns: nil if valid, ValidationError if invalid
    public func validate(_ entry: AuditEntry) -> ValidationError? {
        // Priority 1: Schema validation
        if let error = validateSchema(entry) {
            return error
        }
        
        // Priority 2: Deep field validation
        if let error = validateDeepFields(entry) {
            return error
        }
        
        // Priority 3: Sequence validation
        if let error = validateSequence(entry) {
            return error
        }
        
        // Priority 4: Field constraints by event type
        if let error = validateFieldConstraints(entry) {
            return error
        }
        
        // Priority 5: Cross-event consistency
        if let error = validateCrossEventConsistency(entry) {
            return error
        }
        
        // Update pending state
        updatePendingState(entry)
        
        return nil
    }
    
    /// Commit pending state to committed state.
    /// Call after successful append.
    public func commit() {
        committedEventIndex = pendingEventIndex
        committedAnchorTraceId = pendingAnchorTraceId
        committedAnchorSceneId = pendingAnchorSceneId
        committedAnchorPolicyHash = pendingAnchorPolicyHash
        committedIsEnded = pendingIsEnded
        committedLastEventType = pendingLastEventType
    }
    
    /// Rollback pending state to committed state.
    /// Call after failed append.
    public func rollback() {
        pendingEventIndex = committedEventIndex
        pendingAnchorTraceId = committedAnchorTraceId
        pendingAnchorSceneId = committedAnchorSceneId
        pendingAnchorPolicyHash = committedAnchorPolicyHash
        pendingIsEnded = committedIsEnded
        pendingLastEventType = committedLastEventType
    }
    
    /// Current committed event count.
    public var eventCount: Int {
        return committedEventIndex
    }
    
    /// Whether trace is complete (end or fail committed).
    public var isComplete: Bool {
        return committedIsEnded
    }
    
    /// Whether trace has started.
    public var hasStarted: Bool {
        return committedAnchorTraceId != nil
    }
    
    /// Last committed event type (for orphan report).
    public var lastCommittedEventType: AuditEventType? {
        return committedLastEventType
    }
    
    // MARK: - Priority 1: Schema Validation
    
    private func validateSchema(_ entry: AuditEntry) -> ValidationError? {
        // schemaVersion
        if entry.schemaVersion != 1 {
            return .schemaVersionInvalid(got: entry.schemaVersion, expected: 1)
        }
        
        // policyHash
        if entry.policyHash.isEmpty {
            return .policyHashInvalid(reason: "empty")
        }
        if entry.policyHash.count != 64 {
            return .policyHashInvalid(reason: "length \(entry.policyHash.count) != 64")
        }
        if !isLowercaseHex(entry.policyHash) {
            return .policyHashInvalid(reason: "not lowercase hex")
        }
        if entry.policyHash.contains("|") {
            return .policyHashInvalid(reason: "contains forbidden char |")
        }
        
        // pipelineVersion
        if entry.pipelineVersion.isEmpty {
            return .pipelineVersionInvalid(reason: "empty")
        }
        if entry.pipelineVersion.contains("|") {
            return .pipelineVersionInvalid(reason: "contains forbidden char |")
        }
        // Check for control characters (< 0x20 OR == 0x7F)
        for scalar in entry.pipelineVersion.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F {
                return .pipelineVersionInvalid(reason: "contains control character")
            }
        }
        
        // traceId
        if entry.traceId.isEmpty {
            return .traceIdInvalid(reason: "empty")
        }
        if entry.traceId.count != 64 {
            return .traceIdInvalid(reason: "length \(entry.traceId.count) != 64")
        }
        if !isLowercaseHex(entry.traceId) {
            return .traceIdInvalid(reason: "not lowercase hex")
        }
        
        // sceneId
        if entry.sceneId.isEmpty {
            return .sceneIdInvalid(reason: "empty")
        }
        if entry.sceneId.count != 64 {
            return .sceneIdInvalid(reason: "length \(entry.sceneId.count) != 64")
        }
        if !isLowercaseHex(entry.sceneId) {
            return .sceneIdInvalid(reason: "not lowercase hex")
        }
        
        // eventId format: "{traceId}:{index}"
        if !entry.eventId.hasPrefix(entry.traceId + ":") {
            return .eventIdInvalid(reason: "does not start with traceId:")
        }
        let indexPart = String(entry.eventId.dropFirst(entry.traceId.count + 1))
        
        // Parse and validate index
        guard let parsedIndex = Int(indexPart) else {
            return .eventIdInvalid(reason: "index part not integer")
        }
        
        // Check for leading zeros and negative
        if parsedIndex < 0 {
            return .eventIdInvalid(reason: "index is negative")
        }
        if parsedIndex > 1_000_000 {
            return .eventIdInvalid(reason: "index out of range")
        }
        if indexPart != "0" && indexPart.hasPrefix("0") {
            return .eventIdInvalid(reason: "index has leading zeros")
        }
        if indexPart.hasPrefix("+") {
            return .eventIdInvalid(reason: "index has + prefix")
        }
        
        // entryType consistency
        if entry.entryType != entry.pr85EventType.rawValue {
            return .entryTypeMismatch(expected: entry.pr85EventType.rawValue, got: entry.entryType)
        }
        
        return nil
    }
    
    // MARK: - Priority 2: Deep Field Validation
    
    private func validateDeepFields(_ entry: AuditEntry) -> ValidationError? {
        // Validate inputs (sorted for deterministic error reporting)
        let sortedInputs = entry.inputs.sorted { $0.path < $1.path }
        
        // Check for duplicates using sorted array
        var previousPath: String? = nil
        for input in sortedInputs {
            if let prev = previousPath, prev == input.path {
                return .duplicateInputPath(path: input.path)
            }
            previousPath = input.path
        }
        
        // Validate each input (using original indices for error reporting)
        let indexedInputs = entry.inputs.enumerated().sorted { $0.element.path < $1.element.path }
        for (originalIndex, input) in indexedInputs {
            if input.path.isEmpty {
                return .inputPathInvalid(index: originalIndex, reason: "empty")
            }
            if input.path.count > 2048 {
                return .inputPathInvalid(index: originalIndex, reason: "length > 2048")
            }
            // Check forbidden chars
            for char in ["|", ";", "\n", "\r", "\t"] {
                if input.path.contains(char) {
                    return .inputPathInvalid(index: originalIndex, reason: "contains forbidden char")
                }
            }
            
            if let hash = input.contentHash {
                if hash.count != 64 {
                    return .inputContentHashInvalid(index: originalIndex, reason: "length != 64")
                }
                if !isLowercaseHex(hash) {
                    return .inputContentHashInvalid(index: originalIndex, reason: "not lowercase hex")
                }
            }
            
            if let size = input.byteSize, size < 0 {
                return .inputByteSizeInvalid(index: originalIndex)
            }
        }
        
        // Validate metrics if present
        if let metrics = entry.metrics {
            if metrics.elapsedMs < 0 {
                return .metricsElapsedMsInvalid(reason: "negative")
            }
            if metrics.elapsedMs > 604_800_000 {
                return .metricsElapsedMsInvalid(reason: "> 604800000")
            }
            
            if let score = metrics.qualityScore {
                if !score.isFinite {
                    return .metricsQualityScoreInvalid(reason: "not finite")
                }
                if score < 0.0 || score > 1.0 {
                    return .metricsQualityScoreInvalid(reason: "not in [0,1]")
                }
            }
            
            if let code = metrics.errorCode {
                if code.isEmpty {
                    return .metricsErrorCodeInvalid(reason: "empty")
                }
                if code.count > 64 {
                    return .metricsErrorCodeInvalid(reason: "length > 64")
                }
            }
        }
        
        // Validate artifactRef if present
        if let ref = entry.artifactRef {
            if ref.isEmpty {
                return .artifactRefInvalid(reason: "empty string")
            }
            if ref.trimmingCharacters(in: .whitespaces).isEmpty {
                return .artifactRefInvalid(reason: "whitespace only")
            }
            if ref.count > 2048 {
                return .artifactRefInvalid(reason: "length > 2048")
            }
            // Check for control characters (tab 0x09 allowed)
            for scalar in ref.unicodeScalars {
                let value = scalar.value
                if value < 32 && value != 9 {
                    return .artifactRefInvalid(reason: "contains control character")
                }
            }
        }
        
        // Validate paramsSummary
        let sortedKeys = entry.paramsSummary.keys.sorted()
        for key in sortedKeys {
            if key.isEmpty {
                return .paramsSummaryInvalid(reason: "empty key")
            }
            if key.contains("|") {
                return .paramsSummaryInvalid(reason: "key contains |")
            }
            if let value = entry.paramsSummary[key], value.contains("|") {
                return .paramsSummaryInvalid(reason: "value contains |")
            }
        }
        
        return nil
    }
    
    // MARK: - Priority 3: Sequence Validation
    
    private func validateSequence(_ entry: AuditEntry) -> ValidationError? {
        switch entry.pr85EventType {
        case .traceStart:
            if committedAnchorTraceId != nil {
                return .duplicateTraceStart
            }
            
        case .actionStep:
            if committedAnchorTraceId == nil {
                return .noTraceStarted
            }
            if committedIsEnded {
                return .traceAlreadyEnded
            }
            
        case .traceEnd, .traceFail:
            if committedAnchorTraceId == nil {
                return .noTraceStarted
            }
            if committedIsEnded {
                return .traceAlreadyEnded
            }
        }
        
        return nil
    }
    
    // MARK: - Priority 4: Field Constraints
    
    private func validateFieldConstraints(_ entry: AuditEntry) -> ValidationError? {
        switch entry.pr85EventType {
        case .traceStart:
            if entry.metrics != nil {
                return .metricsForbiddenForStart
            }
            if entry.actionType != nil {
                return .actionTypeForbiddenForNonStep
            }
            if entry.artifactRef != nil {
                return .artifactRefForbiddenForStart
            }
            // paramsSummary allowed to be non-empty for start
            
        case .actionStep:
            if entry.metrics != nil {
                return .metricsForbiddenForStep
            }
            if entry.actionType == nil {
                return .actionTypeRequiredForStep
            }
            if entry.artifactRef != nil {
                return .artifactRefForbiddenForStep
            }
            // paramsSummary must be empty for step
            if !entry.paramsSummary.isEmpty {
                return .paramsSummaryNotEmptyForNonStart
            }
            
        case .traceEnd:
            guard let metrics = entry.metrics else {
                return .metricsRequiredForEnd
            }
            if !metrics.success {
                return .metricsSuccessMismatch(eventType: .traceEnd, success: false)
            }
            if metrics.errorCode != nil {
                return .errorCodeForbiddenForEnd
            }
            if entry.actionType != nil {
                return .actionTypeForbiddenForNonStep
            }
            if !entry.inputs.isEmpty {
                return .inputsNotEmptyForEnd
            }
            // paramsSummary must be empty for end
            if !entry.paramsSummary.isEmpty {
                return .paramsSummaryNotEmptyForNonStart
            }
            
        case .traceFail:
            guard let metrics = entry.metrics else {
                return .metricsRequiredForFail
            }
            if metrics.success {
                return .metricsSuccessMismatch(eventType: .traceFail, success: true)
            }
            if metrics.errorCode == nil {
                return .errorCodeRequiredForFail
            }
            if metrics.qualityScore != nil {
                return .qualityScoreForbiddenForFail
            }
            if entry.actionType != nil {
                return .actionTypeForbiddenForNonStep
            }
            if entry.artifactRef != nil {
                return .artifactRefForbiddenForFail
            }
            if !entry.inputs.isEmpty {
                return .inputsNotEmptyForEnd
            }
            // paramsSummary must be empty for fail
            if !entry.paramsSummary.isEmpty {
                return .paramsSummaryNotEmptyForNonStart
            }
        }
        
        return nil
    }
    
    // MARK: - Priority 5: Cross-Event Consistency
    
    private func validateCrossEventConsistency(_ entry: AuditEntry) -> ValidationError? {
        // For traceStart, there are no previous events to check consistency against
        // Skip cross-event consistency check for traceStart - eventId format is validated in schema validation
        if entry.pr85EventType == .traceStart {
            return nil
        }
        
        // For non-start events, check against COMMITTED anchors (not pending)
        guard let anchorTraceId = committedAnchorTraceId else {
            // This should have been caught in sequence validation, but handle defensively
            return nil
        }
        
        if entry.traceId != anchorTraceId {
            return .traceIdMismatch(expected: anchorTraceId, got: entry.traceId)
        }
        
        if let anchorSceneId = committedAnchorSceneId {
            if entry.sceneId != anchorSceneId {
                return .sceneIdMismatch(expected: anchorSceneId, got: entry.sceneId)
            }
        }
        
        if let anchorPolicyHash = committedAnchorPolicyHash {
            if entry.policyHash != anchorPolicyHash {
                return .policyHashMismatch(expected: anchorPolicyHash, got: entry.policyHash)
            }
        }
        
        // Check eventId index matches committed count
        let expectedIndex = committedEventIndex
        let expectedEventIdResult = TraceIdGenerator.makeEventId(traceId: entry.traceId, eventIndex: expectedIndex)
        
        guard case .success(let expectedEventId) = expectedEventIdResult else {
            // This should not happen if traceId is valid, but handle gracefully
            return .eventIndexMismatch(expected: expectedIndex, got: -1)
        }
        
        if entry.eventId != expectedEventId {
            // Parse actual index for error message
            let actualIndex = parseEventIndex(entry.eventId) ?? -1
            return .eventIndexMismatch(expected: expectedIndex, got: actualIndex)
        }
        
        return nil
    }
    
    // MARK: - State Update
    
    private func updatePendingState(_ entry: AuditEntry) {
        pendingEventIndex = committedEventIndex + 1
        pendingLastEventType = entry.pr85EventType
        
        if entry.pr85EventType == .traceStart {
            pendingAnchorTraceId = entry.traceId
            pendingAnchorSceneId = entry.sceneId
            pendingAnchorPolicyHash = entry.policyHash
        }
        
        if entry.pr85EventType == .traceEnd || entry.pr85EventType == .traceFail {
            pendingIsEnded = true
        }
    }
    
    // MARK: - Helpers
    
    private func isLowercaseHex(_ string: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    
    private func parseEventIndex(_ eventId: String) -> Int? {
        guard let colonIndex = eventId.lastIndex(of: ":") else { return nil }
        let afterColonIndex = eventId.index(after: colonIndex)
        guard afterColonIndex < eventId.endIndex else { return nil }
        let indexPart = String(eventId[afterColonIndex...])
        guard !indexPart.isEmpty else { return nil }
        return Int(indexPart)
    }
}

