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
    
    // MARK: - Profile-Aware Thresholds (PR5-QUALITY-2.0)
    
    /// Get effective Laplacian threshold for given capture profile
    /// Different profiles have different sharpness requirements
    public static func getEffectiveLaplacianThreshold(
        for profile: CaptureProfile
    ) -> Double {
        let base = FrameQualityConstants.blurThresholdLaplacian
        
        switch profile {
        case .standard:
            return base  // 200
        case .smallObjectMacro:
            return base * FrameQualityConstants.LAPLACIAN_MULTIPLIER_PRO_MACRO  // 250
        case .largeScene:
            return base * FrameQualityConstants.LAPLACIAN_MULTIPLIER_LARGE_SCENE  // 180
        case .proMacro:
            return base * FrameQualityConstants.LAPLACIAN_MULTIPLIER_PRO_MACRO  // 250
        case .cinematicScene:
            return base * FrameQualityConstants.LAPLACIAN_MULTIPLIER_CINEMATIC  // 180
        }
    }
    
    /// Get effective minimum ORB feature count for given capture profile
    public static func getEffectiveMinFeatureCount(
        for profile: CaptureProfile
    ) -> Int {
        let base = FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM
        
        switch profile {
        case .standard, .largeScene:
            return base  // 500
        case .smallObjectMacro, .proMacro:
            return Int(Double(base) * FrameQualityConstants.FEATURE_MULTIPLIER_PRO_MACRO)  // 600
        case .cinematicScene:
            return Int(Double(base) * FrameQualityConstants.FEATURE_MULTIPLIER_CINEMATIC)  // 350
        }
    }
    
    /// Get effective Tenengrad threshold for given capture profile
    public static func getEffectiveTenengradThreshold(
        for profile: CaptureProfile
    ) -> Double {
        let base = FrameQualityConstants.TENENGRAD_THRESHOLD
        
        switch profile {
        case .standard, .largeScene, .cinematicScene:
            return base  // 50
        case .smallObjectMacro, .proMacro:
            return base * 1.2  // 60 (sharper required for macro)
        }
    }
}

