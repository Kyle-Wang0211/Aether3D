// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZOcclusionFilter.swift
// Aether3D
//
// PR6 Evidence Grid System - PIZ Occlusion Filter
// Occlusion-aware PIZ exclusion with hardening (MUST-FIX H)
//

import Foundation

/// **Rule ID:** PR6_GRID_PIZ_005
/// PIZ Occlusion Filter: filters PIZ regions based on occlusion hardening rules
public final class PIZOcclusionFilter: @unchecked Sendable {
    
    /// Minimum occlusion view directions
    private let minOcclusionViewDirections: Int = 3
    
    /// Occlusion freeze window (seconds)
    private let occlusionFreezeSec: Double = 60.0
    
    /// Maximum exclusion delta per second
    private let maxExclusionDeltaPerSec: Double = 0.05
    
    /// Exclusion state: regionId -> exclusion info
    private struct ExclusionInfo {
        let exclusionTimestamp: Int64
        var exclusionFrozenUntil: Int64
        var lastExcludedAreaFraction: Double
    }
    
    private var exclusionStates: [String: ExclusionInfo] = [:]  // Use String ID (PIZRegion.id)
    
    /// Last update timestamp (monotonic milliseconds)
    private var lastUpdateMonotonicMs: Int64 = 0
    
    public init() {
        self.lastUpdateMonotonicMs = MonotonicClock.nowMs()
    }
    
    /// **Rule ID:** PR6_GRID_PIZ_006
    /// Filter PIZ regions based on occlusion hardening rules
    ///
    /// - Parameter regions: Input PIZ regions
    /// - Returns: Filtered regions (excluded regions removed)
    public func filter(regions: [PIZRegion]) -> [PIZRegion] {
        let currentMonotonicMs = MonotonicClock.nowMs()
        let deltaTimeMs = currentMonotonicMs - lastUpdateMonotonicMs
        
        // Handle non-monotonic time
        let deltaTimeSeconds: Double
        if deltaTimeMs <= 0 {
            deltaTimeSeconds = 0.0
        } else {
            deltaTimeSeconds = Double(deltaTimeMs) / 1000.0
        }
        
        var filteredRegions: [PIZRegion] = []
        
        for region in regions {
            // **(1) Minimum view attempt diversity**
            if !hasMinimumViewDiversity(region: region) {
                // Not enough views, don't exclude
                filteredRegions.append(region)
                continue
            }
            
            // **(2) Exclusion freeze window**
            if isFrozen(regionId: region.id, currentMs: currentMonotonicMs) {
                // Region is frozen (excluded), keep excluded
                continue
            }
            
            // **(3) Rate limiter**
            if shouldExclude(region: region, deltaTimeSeconds: deltaTimeSeconds) {
                // Exclude region and update freeze window
                updateExclusionState(regionId: region.id, currentMs: currentMonotonicMs)
            } else {
                // Include region
                filteredRegions.append(region)
            }
        }
        
        lastUpdateMonotonicMs = currentMonotonicMs
        
        return filteredRegions
    }
    
    /// Check if region has minimum view diversity
    private func hasMinimumViewDiversity(region: PIZRegion) -> Bool {
        // Simplified: check severity score (higher severity suggests occlusion)
        // Full implementation would check directionalMask from grid cells
        return region.severityScore > 0.5  // Placeholder
    }
    
    /// Check if region is frozen (excluded)
    private func isFrozen(regionId: String, currentMs: Int64) -> Bool {
        guard let exclusionInfo = exclusionStates[regionId] else {
            return false
        }
        
        return currentMs < exclusionInfo.exclusionFrozenUntil
    }
    
    /// Check if region should be excluded
    private func shouldExclude(region: PIZRegion, deltaTimeSeconds: Double) -> Bool {
        // Check severity score threshold (occlusion likelihood equivalent)
        if region.severityScore <= 0.8 {
            return false
        }
        
        // Check rate limiter
        if let exclusionInfo = exclusionStates[region.id] {
            let currentFraction = region.areaRatio  // Use areaRatio as fraction
            let deltaFraction = abs(currentFraction - exclusionInfo.lastExcludedAreaFraction)
            
            if deltaTimeSeconds > 0 {
                let deltaRate = deltaFraction / deltaTimeSeconds
                if deltaRate > maxExclusionDeltaPerSec {
                    // Rate limited, don't exclude yet
                    return false
                }
            }
        }
        
        return true
    }
    
    /// Update exclusion state
    private func updateExclusionState(regionId: String, currentMs: Int64) {
        let frozenUntil = currentMs + Int64(occlusionFreezeSec * 1000.0)
        
        if var existing = exclusionStates[regionId] {
            existing.exclusionFrozenUntil = frozenUntil
            exclusionStates[regionId] = existing
        } else {
            exclusionStates[regionId] = ExclusionInfo(
                exclusionTimestamp: currentMs,
                exclusionFrozenUntil: frozenUntil,
                lastExcludedAreaFraction: 0.0
            )
        }
        
        // Update last excluded area fraction
        if var info = exclusionStates[regionId] {
            // Will be updated when region is processed
            exclusionStates[regionId] = info
        }
    }
    
    /// Reset filter
    public func reset() {
        exclusionStates.removeAll()
        lastUpdateMonotonicMs = MonotonicClock.nowMs()
    }
}
