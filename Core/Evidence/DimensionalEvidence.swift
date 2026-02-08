//
// DimensionalEvidence.swift
// Aether3D
//
// PR6 Evidence Grid System - Dimensional Evidence
// 15-dimensional evidence scoring system
//

import Foundation
import CryptoKit

/// **Rule ID:** PR6_DIMENSIONAL_001
/// Dimensional evidence score set (15 dimensions)
/// Each dimension is clamped to [0, 1] using @ClampedEvidence
public struct DimensionalScoreSet: Codable, Sendable, Equatable {
    // Dimensions ①-⑮ (15 total)
    
    // ① View gain (from GateGainFunctions.viewGateGain)
    @ClampedEvidence public var dim1_viewGain: Double
    
    // ② Geometry gain (from GateGainFunctions.geomGateGain)
    @ClampedEvidence public var dim2_geometryGain: Double
    
    // ③ Depth quality (NEW: computed from depth data)
    @ClampedEvidence public var dim3_depthQuality: Double
    
    // ④ Semantic consistency (NEW: computed from semantic data)
    @ClampedEvidence public var dim4_semanticConsistency: Double
    
    // ⑤ Error type score (from ObservationErrorType)
    @ClampedEvidence public var dim5_errorTypeScore: Double
    
    // ⑥ Basic gain (from GateGainFunctions.basicGateGain)
    @ClampedEvidence public var dim6_basicGain: Double
    
    // ⑦ Provenance chain contribution (NEW: SHA-256 chain contribution)
    @ClampedEvidence public var dim7_provenanceContribution: Double
    
    // ⑧ Coverage tracker score (from GateCoverageTracker)
    @ClampedEvidence public var dim8_coverageTrackerScore: Double
    
    // ⑨ Resolution quality (NEW: computed from resolution data)
    @ClampedEvidence public var dim9_resolutionQuality: Double
    
    // ⑩ View diversity (from ViewDiversityTracker.diversityScore)
    @ClampedEvidence public var dim10_viewDiversity: Double
    
    // ⑪-⑮ Stubs (explicitly documented, not TODO)
    @ClampedEvidence public var dim11_stub: Double = 0.0
    @ClampedEvidence public var dim12_stub: Double = 0.0
    @ClampedEvidence public var dim13_stub: Double = 0.0
    @ClampedEvidence public var dim14_stub: Double = 0.0
    @ClampedEvidence public var dim15_stub: Double = 0.0
    
    public init(
        dim1_viewGain: Double = 0.0,
        dim2_geometryGain: Double = 0.0,
        dim3_depthQuality: Double = 0.0,
        dim4_semanticConsistency: Double = 0.0,
        dim5_errorTypeScore: Double = 0.0,
        dim6_basicGain: Double = 0.0,
        dim7_provenanceContribution: Double = 0.0,
        dim8_coverageTrackerScore: Double = 0.0,
        dim9_resolutionQuality: Double = 0.0,
        dim10_viewDiversity: Double = 0.0,
        dim11_stub: Double = 0.0,
        dim12_stub: Double = 0.0,
        dim13_stub: Double = 0.0,
        dim14_stub: Double = 0.0,
        dim15_stub: Double = 0.0
    ) {
        self.dim1_viewGain = dim1_viewGain
        self.dim2_geometryGain = dim2_geometryGain
        self.dim3_depthQuality = dim3_depthQuality
        self.dim4_semanticConsistency = dim4_semanticConsistency
        self.dim5_errorTypeScore = dim5_errorTypeScore
        self.dim6_basicGain = dim6_basicGain
        self.dim7_provenanceContribution = dim7_provenanceContribution
        self.dim8_coverageTrackerScore = dim8_coverageTrackerScore
        self.dim9_resolutionQuality = dim9_resolutionQuality
        self.dim10_viewDiversity = dim10_viewDiversity
        self.dim11_stub = dim11_stub
        self.dim12_stub = dim12_stub
        self.dim13_stub = dim13_stub
        self.dim14_stub = dim14_stub
        self.dim15_stub = dim15_stub
    }
    
    /// **Rule ID:** PR6_DIMENSIONAL_002
    /// Soft aggregate score (replaces softQuality placeholder)
    /// Weighted sum of active dimensions (①-⑩)
    public var softAggregate: Double {
        // Weighted sum of dimensions ①-⑩
        // Weights will be defined in DimensionalConstants (SSOT)
        // For now, use equal weights as placeholder
        let activeDimensions = [
            dim1_viewGain,
            dim2_geometryGain,
            dim3_depthQuality,
            dim4_semanticConsistency,
            dim5_errorTypeScore,
            dim6_basicGain,
            dim7_provenanceContribution,
            dim8_coverageTrackerScore,
            dim9_resolutionQuality,
            dim10_viewDiversity
        ]
        
        let sum = activeDimensions.reduce(0.0, +)
        return (sum / Double(activeDimensions.count)).clampedEvidence(to: 0...1)
    }
}

/// **Rule ID:** PR6_DIMENSIONAL_003
/// Dimensional computer: computes dimensional scores from raw metrics
public final class DimensionalComputer: @unchecked Sendable {
    
    public init() {}
    
    /// Compute dimensional scores from raw metrics
    ///
    /// - Parameters:
    ///   - gateGainFunctions: Gate gain functions output (for ①, ②, ⑥)
    ///   - gateCoverageTracker: Gate coverage tracker (for ⑧)
    ///   - viewDiversityTracker: View diversity tracker (for ⑩)
    ///   - observationErrorType: Observation error type (for ⑤)
    ///   - depthData: Depth data (for ③) - optional
    ///   - semanticData: Semantic data (for ④) - optional
    ///   - resolutionData: Resolution data (for ⑨) - optional
    ///   - provenanceHash: Provenance hash contribution (for ⑦) - optional
    /// - Returns: DimensionalScoreSet with all 15 dimensions computed
    public func compute(
        gateGainFunctions: GateGainFunctionsOutput? = nil,
        gateCoverageTracker: GateCoverageTrackerOutput? = nil,
        viewDiversityTracker: ViewDiversityTrackerOutput? = nil,
        observationErrorType: ObservationErrorType? = nil,
        depthData: DepthData? = nil,
        semanticData: SemanticData? = nil,
        resolutionData: ResolutionData? = nil,
        provenanceHash: String? = nil
    ) -> DimensionalScoreSet {
        
        // ① View gain (from GateGainFunctions.viewGateGain)
        let dim1 = gateGainFunctions?.viewGain ?? 0.0
        
        // ② Geometry gain (from GateGainFunctions.geomGateGain)
        let dim2 = gateGainFunctions?.geometryGain ?? 0.0
        
        // ③ Depth quality (NEW: computed from depth data)
        let dim3 = computeDepthQuality(depthData: depthData)
        
        // ④ Semantic consistency (NEW: computed from semantic data)
        let dim4 = computeSemanticConsistency(semanticData: semanticData)
        
        // ⑤ Error type score (from ObservationErrorType)
        let dim5 = computeErrorTypeScore(errorType: observationErrorType)
        
        // ⑥ Basic gain (from GateGainFunctions.basicGateGain)
        let dim6 = gateGainFunctions?.basicGain ?? 0.0
        
        // ⑦ Provenance chain contribution (NEW: SHA-256 chain contribution)
        let dim7 = computeProvenanceContribution(hash: provenanceHash)
        
        // ⑧ Coverage tracker score (from GateCoverageTracker)
        let dim8 = gateCoverageTracker?.coverageScore ?? 0.0
        
        // ⑨ Resolution quality (NEW: computed from resolution data)
        let dim9 = computeResolutionQuality(resolutionData: resolutionData)
        
        // ⑩ View diversity (from ViewDiversityTracker.diversityScore)
        let dim10 = viewDiversityTracker?.diversityScore ?? 0.0
        
        return DimensionalScoreSet(
            dim1_viewGain: dim1,
            dim2_geometryGain: dim2,
            dim3_depthQuality: dim3,
            dim4_semanticConsistency: dim4,
            dim5_errorTypeScore: dim5,
            dim6_basicGain: dim6,
            dim7_provenanceContribution: dim7,
            dim8_coverageTrackerScore: dim8,
            dim9_resolutionQuality: dim9,
            dim10_viewDiversity: dim10
        )
    }
    
    // MARK: - Helper Methods
    
    /// Compute depth quality (dimension ③)
    private func computeDepthQuality(depthData: DepthData?) -> Double {
        guard let depthData = depthData else {
            return 0.0
        }
        
        // Placeholder: compute depth quality from depth data
        // TODO: Implement actual depth quality computation
        // For now, return 0.0 as stub
        return 0.0
    }
    
    /// Compute semantic consistency (dimension ④)
    private func computeSemanticConsistency(semanticData: SemanticData?) -> Double {
        guard let semanticData = semanticData else {
            return 0.0
        }
        
        // Placeholder: compute semantic consistency from semantic data
        // TODO: Implement actual semantic consistency computation
        // For now, return 0.0 as stub
        return 0.0
    }
    
    /// Compute error type score (dimension ⑤)
    private func computeErrorTypeScore(errorType: ObservationErrorType?) -> Double {
        guard let errorType = errorType else {
            return 1.0  // No error = perfect score
        }
        
        // Map error types to scores
        switch errorType {
        case .dynamicObject:
            return 0.3  // Moderate penalty
        case .depthDistortion:
            return 0.2  // High penalty
        case .exposureDrift:
            return 0.5  // Low penalty
        case .whiteBalanceDrift:
            return 0.6  // Low penalty
        case .motionBlur:
            return 0.4  // Moderate penalty
        case .unknown:
            return 0.5  // Neutral (unknown)
        }
    }
    
    /// Compute provenance contribution (dimension ⑦)
    private func computeProvenanceContribution(hash: String?) -> Double {
        guard let hash = hash, !hash.isEmpty else {
            return 0.0
        }
        
        // Compute contribution based on hash stability
        // For now, return a simple score based on hash length
        // TODO: Implement actual provenance contribution computation
        return min(1.0, Double(hash.count) / 64.0)  // Normalize to [0, 1]
    }
    
    /// Compute resolution quality (dimension ⑨)
    private func computeResolutionQuality(resolutionData: ResolutionData?) -> Double {
        guard let resolutionData = resolutionData else {
            return 0.0
        }
        
        // Placeholder: compute resolution quality from resolution data
        // TODO: Implement actual resolution quality computation
        // For now, return 0.0 as stub
        return 0.0
    }
}

// MARK: - Supporting Types

/// Gate gain functions output
public struct GateGainFunctionsOutput: Sendable {
    public let viewGain: Double
    public let geometryGain: Double
    public let basicGain: Double
    
    public init(viewGain: Double, geometryGain: Double, basicGain: Double) {
        self.viewGain = viewGain
        self.geometryGain = geometryGain
        self.basicGain = basicGain
    }
}

/// Gate coverage tracker output
public struct GateCoverageTrackerOutput: Sendable {
    public let coverageScore: Double
    
    public init(coverageScore: Double) {
        self.coverageScore = coverageScore
    }
}

/// View diversity tracker output
public struct ViewDiversityTrackerOutput: Sendable {
    public let diversityScore: Double
    
    public init(diversityScore: Double) {
        self.diversityScore = diversityScore
    }
}

/// Depth data (placeholder for future implementation)
public struct DepthData: Sendable {
    // TODO: Define actual depth data structure
}

/// Semantic data (placeholder for future implementation)
public struct SemanticData: Sendable {
    // TODO: Define actual semantic data structure
}

/// Resolution data (placeholder for future implementation)
public struct ResolutionData: Sendable {
    // TODO: Define actual resolution data structure
}

// MARK: - Helper Extensions

extension Double {
    /// Clamp value to evidence range [0, 1]
    fileprivate func clampedEvidence(to range: ClosedRange<Double>) -> Double {
        return max(range.lowerBound, min(range.upperBound, self))
    }
}
