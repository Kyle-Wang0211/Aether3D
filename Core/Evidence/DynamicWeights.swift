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
}
