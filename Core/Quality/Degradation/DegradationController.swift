//
//  DegradationController.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 7
//  DegradationController - three-tier performance degradation (PART 8, H1)
//

import Foundation

/// DegradationController - manages FPS tier and quality level degradation
/// H1: Hysteresis control to prevent tier flapping
public class DegradationController {
    private var currentFpsTier: FpsTier = .full
    private var tierChangeTime: Int64 = 0
    private var lastFps: Double = 30.0
    
    public init() {}
    
    /// Update FPS tier based on current FPS
    /// H1: Hysteresis prevents flapping
    public func updateFpsTier(currentFps: Double) -> FpsTier {
        let now = MonotonicClock.nowMs()
        let timeSinceChange = now - tierChangeTime
        
        switch currentFpsTier {
        case .full:
            // Degrade if FPS < 30 for 500ms
            if currentFps < QualityPreCheckConstants.FPS_FULL_THRESHOLD {
                if timeSinceChange >= QualityPreCheckConstants.DEGRADATION_HYSTERESIS_MS {
                    currentFpsTier = .degraded
                    tierChangeTime = now
                }
            }
            
        case .degraded:
            // Upgrade to full if FPS >= 30 for 500ms
            if currentFps >= QualityPreCheckConstants.FPS_FULL_THRESHOLD {
                if timeSinceChange >= QualityPreCheckConstants.DEGRADATION_HYSTERESIS_MS {
                    currentFpsTier = .full
                    tierChangeTime = now
                }
            }
            // Degrade to emergency if FPS < 20 for 500ms
            else if currentFps < QualityPreCheckConstants.FPS_DEGRADED_THRESHOLD {
                if timeSinceChange >= QualityPreCheckConstants.DEGRADATION_HYSTERESIS_MS {
                    currentFpsTier = .emergency
                    tierChangeTime = now
                }
            }
            
        case .emergency:
            // Exit emergency if FPS >= 25 for 1.5s (stricter than entry)
            if currentFps >= QualityPreCheckConstants.FPS_EMERGENCY_EXIT_THRESHOLD {
                if timeSinceChange >= QualityPreCheckConstants.EMERGENCY_EXIT_HYSTERESIS_MS {
                    currentFpsTier = .degraded
                    tierChangeTime = now
                }
            }
        }
        
        lastFps = currentFps
        return currentFpsTier
    }
    
    /// Get current FPS tier
    public func getCurrentFpsTier() -> FpsTier {
        return currentFpsTier
    }
    
    /// Get current quality level (synonym for FPS tier)
    public func getCurrentQualityLevel() -> QualityLevel {
        return currentFpsTier
    }
}

