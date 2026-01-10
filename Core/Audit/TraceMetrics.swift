// TraceMetrics.swift
// PR#8.5 / v0.0.1

import Foundation

/// Metrics for trace completion.
///
/// - Note: Thread-safety: Immutable struct, safe for concurrent use.
public struct TraceMetrics: Codable, Sendable, Equatable {
    
    /// Elapsed time in milliseconds.
    ///
    /// Constraints:
    /// - Range: [0, 604800000] (0 to 7 days in ms)
    public let elapsedMs: Int
    
    /// Whether trace succeeded.
    ///
    /// Constraints:
    /// - true for trace_end
    /// - false for trace_fail
    public let success: Bool
    
    /// Quality score for successful traces.
    ///
    /// Constraints:
    /// - Range: [0.0, 1.0], must be finite
    /// - Only for trace_end (nil for trace_fail)
    public let qualityScore: Double?
    
    /// Error code for failed traces.
    ///
    /// Constraints:
    /// - Required and non-empty for trace_fail
    /// - Must be nil for trace_end
    /// - Max 64 characters
    /// - Recommended format: [A-Z0-9_]+
    public let errorCode: String?
    
    /// Create trace metrics.
    ///
    /// - Precondition: elapsedMs >= 0. Caller bug if violated.
    public init(
        elapsedMs: Int,
        success: Bool,
        qualityScore: Double?,
        errorCode: String?
    ) {
        precondition(elapsedMs >= 0, "elapsedMs must be non-negative")
        precondition(elapsedMs <= 604_800_000, "elapsedMs must not exceed 604800000")
        
        if let score = qualityScore {
            precondition(score.isFinite, "qualityScore must be finite")
            precondition(score >= 0.0 && score <= 1.0, "qualityScore must be in [0.0, 1.0]")
        }
        
        if let code = errorCode {
            precondition(!code.isEmpty, "errorCode must not be empty if present")
            precondition(code.count <= 64, "errorCode must not exceed 64 characters")
        }
        
        self.elapsedMs = elapsedMs
        self.success = success
        self.qualityScore = qualityScore
        self.errorCode = errorCode
    }
}

