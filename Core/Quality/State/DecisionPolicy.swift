//
//  DecisionPolicy.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  DecisionPolicy - single source of truth for Gray→White decisions (P10/P19/H2)
//

import Foundation

/// DecisionPolicy - single source of truth for state transition decisions
/// P19: Only component that can decide Gray→White
/// H2: Failure semantics (Safety > Consistency > UX, uncertainty blocks White)
public struct DecisionPolicy {
    /// Private helper for Gray→White confidence check
    /// Compile-time sealed: cannot be called outside this file
    /// Only Full tier can reach White, so threshold is always 0.80
    private static func checkGrayToWhiteConfidence(
        criticalMetrics: CriticalMetricBundle,
        fpsTier: FpsTier
    ) -> Bool {
        // P10: Only Full tier allows Gray→White, so threshold is always 0.80
        let threshold = QualityPreCheckConstants.CONFIDENCE_THRESHOLD_FULL  // 0.80
        
        // Check both brightness and laplacian confidence
        let brightnessPass = criticalMetrics.brightness.confidence >= threshold
        let laplacianPass = criticalMetrics.laplacian.confidence >= threshold
        
        return brightnessPass && laplacianPass
    }
    
    /// Check if transition is allowed
    /// P10: FPS White Policy locked - ONLY Full tier allows Gray→White
    /// Degraded and Emergency tiers BLOCK Gray→White
    /// H2: Uncertainty blocks White
    public static func canTransition(
        from: VisualState,
        to: VisualState,
        fpsTier: FpsTier,
        criticalMetrics: CriticalMetricBundle?,
        stability: Double?
    ) -> (allowed: Bool, reason: String?) {
        // Gray→White transition - ONLY allowed in Full tier
        if from == .gray && to == .white {
            // P10: Only Full tier allows Gray→White
            if fpsTier != .full {
                return (false, "Only Full tier allows Gray→White; \(fpsTier) tier blocks Gray→White")
            }
            
            // H2: Uncertainty blocks White
            guard let criticalMetrics = criticalMetrics else {
                return (false, "Missing critical metrics")
            }
            
            guard let stability = stability else {
                return (false, "Missing stability value")
            }
            
            // P19: Use private helper (compile-time sealed)
            // Full tier: 0.80 confidence threshold
            let confidencePass = checkGrayToWhiteConfidence(
                criticalMetrics: criticalMetrics,
                fpsTier: .full  // Always use Full tier threshold since only Full allows White
            )
            
            if !confidencePass {
                return (false, "Confidence threshold not met")
            }
            
            // P18: Check stability threshold (Full tier: ≤0.15)
            if stability > QualityPreCheckConstants.FULL_WHITE_STABILITY_MAX {
                return (false, "Stability threshold exceeded")
            }
            
            return (true, nil)
        }
        
        // Other transitions (always allow forward progression)
        if to > from {
            return (true, nil)
        }
        
        return (false, "Cannot retreat visual state")
    }
}

