//
// DynamicWeights.swift
// Aether3D
//
// PR2 Patch V4 - Dynamic Weight Scheduler
// Deterministic blending of Gate vs Soft evidence based on progress
//

import Foundation

/// Dynamic weight scheduler for Gate/Soft evidence blending
///
/// DESIGN:
/// - Early stage: Gate evidence dominates (geometry foundation)
/// - Late stage: Soft evidence dominates (quality refinement)
/// - Smooth transition using smoothstep interpolation
///
/// INVARIANTS:
/// - Pure function: no side effects, deterministic
/// - gate + soft ≈ 1.0 (within epsilon)
/// - gate is non-increasing, soft is non-decreasing
/// - Cross-platform stable (no floating-point drift)
public enum DynamicWeights {
    
    /// Compute gate and soft weights based on progress
    ///
    /// - Parameters:
    ///   - progress: Normalized progress [0, 1] where 0 = early stage, 1 = late stage
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Tuple (gate, soft) where both are in [0, 1] and sum ≈ 1.0
    public static func weights(
        progress: Double,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> (gate: Double, soft: Double) {
        // Clamp progress to [0, 1]
        let clampedProgress = max(0.0, min(1.0, progress))
        
        // Early and late weights from SSOT
        let gateEarly = constants.dynamicWeightsGateEarly
        let gateLate = constants.dynamicWeightsGateLate
        let transitionStart = constants.dynamicWeightsTransitionStart
        let transitionEnd = constants.dynamicWeightsTransitionEnd
        
        // Compute smoothstep interpolation factor
        let t: Double
        if clampedProgress <= transitionStart {
            t = 0.0  // Early stage: use early weights
        } else if clampedProgress >= transitionEnd {
            t = 1.0  // Late stage: use late weights
        } else {
            // Smooth transition: smoothstep(t) = t*t*(3 - 2*t)
            let normalized = (clampedProgress - transitionStart) / (transitionEnd - transitionStart)
            t = normalized * normalized * (3.0 - 2.0 * normalized)
        }
        
        // Interpolate gate weight (decreasing from early to late)
        let gate = gateEarly + (gateLate - gateEarly) * t
        
        // Soft weight is complement (ensures sum ≈ 1.0)
        let soft = 1.0 - gate
        
        // Clamp both to [0, 1] for safety
        let clampedGate = max(0.0, min(1.0, gate))
        let clampedSoft = max(0.0, min(1.0, soft))
        
        return (gate: clampedGate, soft: clampedSoft)
    }
    
    /// Convenience: compute weights from current total evidence
    /// Uses total evidence as progress indicator
    public static func weights(currentTotal: Double) -> (gate: Double, soft: Double) {
        // Normalize total evidence to [0, 1] progress
        // Assuming S5 threshold (1.0) represents "late stage"
        let progress = max(0.0, min(1.0, currentTotal))
        return weights(progress: progress)
    }
    
    /// **Rule ID:** PR6_GRID_WEIGHTS_001
    /// Compute 4-way weights (Gate, Soft, Provenance, Advanced)
    ///
    /// - Parameter progress: Normalized progress [0, 1]
    /// - Returns: Tuple (gate, soft, provenance, advanced) where sum ≈ 1.0
    public static func weights4(progress: Double) -> (gate: Double, soft: Double, provenance: Double, advanced: Double) {
        // Clamp progress to [0, 1]
        let clampedProgress = max(0.0, min(1.0, progress))
        
        // Get 2-way weights first
        let (gate, soft) = weights(progress: clampedProgress)
        
        // Split gate weight between gate and provenance
        // Split soft weight between soft and advanced
        // Early stage: gate dominates, late stage: soft dominates
        let gateWeight = gate * 0.7  // 70% gate, 30% provenance
        let provenanceWeight = gate * 0.3
        let softWeight = soft * 0.7  // 70% soft, 30% advanced
        let advancedWeight = soft * 0.3
        
        // Normalize to ensure sum ≈ 1.0
        let sum = gateWeight + provenanceWeight + softWeight + advancedWeight
        guard sum > 1e-9 else {
            return (0.25, 0.25, 0.25, 0.25)  // Equal weights if sum is too small
        }
        
        return (
            gate: gateWeight / sum,
            soft: softWeight / sum,
            provenance: provenanceWeight / sum,
            advanced: advancedWeight / sum
        )
    }
}
