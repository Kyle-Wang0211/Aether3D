// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObservationModel.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Pure Validation Functions
//
// Pure functions, static, no side effects.
// All validation logic is deterministic and auditable.
//

import Foundation

/// Observation model validation (pure functions)
public struct ObservationModel {
    
    // MARK: - L1 Validation
    
    /// Validate L1 observational validity
    /// 
    /// L1 preconditions:
    /// 1. Camera ray geometrically intersects Patch's physical proxy
    /// 2. Projected overlap area exceeds minimum ε
    /// 3. Patch is not fully occluded at intersection point
    /// 4. All inputs are finite
    public static func validateL1(_ o: Observation) -> ObservationValidity {
        // Finite checks (U2)
        guard ObservationMath.isFinite(o.sensorPose.position) &&
              ObservationMath.isFinite(o.sensorPose.forward) &&
              ObservationMath.isFinite(o.ray.origin) &&
              ObservationMath.isFinite(o.ray.direction) &&
              ObservationMath.isFinite(o.ray.projectedOverlapArea) else {
            return .invalid(reason: .nonFiniteInput)
        }
        
        // 1. Camera ray geometrically intersects Patch's physical proxy
        if let intersection = o.ray.intersectionPoint {
            guard ObservationMath.isFinite(intersection) else {
                return .invalid(reason: .nonFiniteInput)
            }
        } else {
            return .invalid(reason: .noGeometricIntersection)
        }
        
        // 2. Projected overlap area exceeds minimum threshold
        guard o.ray.projectedOverlapArea >= ObservationConstants.minOverlapArea else {
            return .invalid(reason: .insufficientOverlapArea)
        }
        
        // 3. Patch is not fully occluded at intersection point
        guard o.occlusion != .fullyOccluded else {
            return .invalid(reason: .fullyOccluded)
        }
        
        return .l1
    }
    
    // MARK: - Distinct Viewpoints
    
    /// Check if two viewpoints are distinct (authoritative definition)
    /// 
    /// Two viewpoints are distinct if and only if:
    /// 1. baseline / depth >= r_min (avgDepth > 0 required)
    /// 2. angular separation >= θ_min (computed by forward dot + clamped acos)
    public static func areDistinctViewpoints(_ a: Observation, _ b: Observation) -> Bool {
        // Finite checks (U2)
        guard ObservationMath.isFinite(a.sensorPose.position) &&
              ObservationMath.isFinite(a.sensorPose.forward) &&
              ObservationMath.isFinite(b.sensorPose.position) &&
              ObservationMath.isFinite(b.sensorPose.forward) else {
            return false
        }
        
        // baseline / depth >= r_min (U4: avgDepth > 0 required)
        let baseline = ObservationMath.distance(a.sensorPose.position, b.sensorPose.position)
        guard let d1 = a.raw.depthMeters, let d2 = b.raw.depthMeters else {
            return false  // No depth measurement, cannot determine
        }
        
        // Depth must be finite and > 0 (U2)
        guard ObservationMath.isFinite(d1) && ObservationMath.isFinite(d2) &&
              d1 > 0 && d2 > 0 else {
            return false
        }
        
        let avgDepth = (d1 + d2) / 2.0
        guard avgDepth > ObservationConstants.finiteEpsilon else {
            return false
        }
        
        guard baseline / avgDepth >= ObservationConstants.minParallaxRatio else {
            return false
        }
        
        // Angular separation >= θ_min (using forward vectors, clamped acos)
        let angleSep = ObservationMath.angularSeparation(a.sensorPose, b.sensorPose)
        guard ObservationMath.isFinite(angleSep) &&
              angleSep >= ObservationConstants.minAngularSeparationRad else {
            return false
        }
        
        return true
    }
    
    // MARK: - L2 Validation
    
    /// Validate L2 observational validity
    /// 
    /// L2 preconditions (U3):
    /// 1. >= 2 valid L1 observations
    /// 2. At least one pair satisfies areDistinctViewpoints
    /// 3. At least one distinct pair has pairMetrics that pass thresholds
    /// 
    /// Note: Missing pairMetrics do not invalidate; they only cannot support escalation.
    public static func validateL2(_ obs: [Observation], pairMetrics: [ObservationPairMetrics]) -> ObservationValidity {
        // 1. At least two valid L1 observations
        let validL1 = obs.compactMap { o -> Observation? in
            if case .l1 = validateL1(o) { return o }
            return nil
        }
        guard validL1.count >= 2 else {
            return .invalid(reason: .insufficientMultiViewSupport)
        }
        
        // 2. Build pairMetrics lookup dictionary
        var metricsLookup: [ObservationPairKey: ObservationPairMetrics] = [:]
        for pm in pairMetrics {
            metricsLookup[pm.key] = pm
        }
        
        // 3. Find at least one distinct pair whose pairMetrics exist and pass thresholds
        var foundValidPair = false
        
        for i in 0..<validL1.count {
            for j in (i+1)..<validL1.count {
                let o1 = validL1[i]
                let o2 = validL1[j]
                
                // Check if distinct viewpoints
                guard areDistinctViewpoints(o1, o2) else {
                    continue
                }
                
                // Build pair key
                let pairKey = ObservationPairKey(o1.id, o2.id)
                
                // Check if pairMetrics exists
                guard let metrics = metricsLookup[pairKey] else {
                    continue  // Missing metrics don't invalidate, just can't support escalation
                }
                
                // Check thresholds
                guard metrics.reprojectionErrorPx <= ObservationConstants.maxReprojectionErrorPx else {
                    return .invalid(reason: .reprojectionErrorExceeded)
                }
                
                guard metrics.triangulatedVariance <= ObservationConstants.maxGeometricVariance else {
                    return .invalid(reason: .geometricVarianceExceeded)
                }
                
                foundValidPair = true
                break  // One valid pair is sufficient
            }
            if foundValidPair { break }
        }
        
        guard foundValidPair else {
            return .invalid(reason: .missingPairMetrics)
        }
        
        return .l2
    }
    
    // MARK: - L3 Validation
    
    /// Validate L3 observational validity
    /// 
    /// L3 preconditions:
    /// 1. >= 3 valid L1 observations
    /// 2. Deterministically select >= 3 distinct viewpoints
    /// 3. Depth variance <= ε_depth
    /// 4. Luminance variance <= ε_L
    /// 5. If >= 3 Lab samples exist: Lab variance <= ε_Lab => l3_strict, else l3_core
    /// 
    /// Note: pairMetrics parameter is accepted for API consistency with L2 but is NOT used.
    /// L3 focuses on photometric consistency (depth/luminance/Lab variance), not geometric consistency.
    public static func validateL3(_ obs: [Observation], pairMetrics: [ObservationPairMetrics]) -> ObservationValidity {
        // 1. At least 3 valid L1 observations
        let validL1 = obs.compactMap { o -> Observation? in
            if case .l1 = validateL1(o) { return o }
            return nil
        }
        guard validL1.count >= 3 else {
            return .invalid(reason: .insufficientDistinctViewpoints)
        }
        
        // 2. Deterministic selection: sort by timestamp -> patchId -> id
        let sorted = validL1.sorted { o1, o2 in
            if o1.timestamp.unixMs != o2.timestamp.unixMs {
                return o1.timestamp.unixMs < o2.timestamp.unixMs
            }
            if o1.patchId.value != o2.patchId.value {
                return o1.patchId.value < o2.patchId.value
            }
            return o1.id.value < o2.id.value
        }
        
        // Greedily select distinct viewpoints
        var selected: [Observation] = []
        for candidate in sorted {
            let isDistinct = selected.allSatisfy { existing in
                areDistinctViewpoints(candidate, existing)
            }
            if isDistinct {
                selected.append(candidate)
            }
        }
        
        guard selected.count >= 3 else {
            return .invalid(reason: .insufficientDistinctViewpoints)
        }
        
        // 3. Depth variance <= ε_depth
        let depths = selected.compactMap { $0.raw.depthMeters }
        guard depths.count >= 3 else {
            return .invalid(reason: .missingDepthMeasurement)
        }
        let depthVariance = ObservationMath.variance(depths)
        guard depthVariance <= ObservationConstants.maxDepthVariance else {
            return .invalid(reason: .depthVarianceExceeded)
        }
        
        // 4. Luminance variance <= ε_L
        let luminances = selected.compactMap { $0.raw.luminanceLStar }
        guard luminances.count >= 3 else {
            return .invalid(reason: .luminanceVarianceExceeded)
        }
        let luminanceVariance = ObservationMath.variance(luminances)
        guard luminanceVariance <= ObservationConstants.maxLuminanceVariance else {
            return .invalid(reason: .luminanceVarianceExceeded)
        }
        
        // 5. Lab variance <= ε_Lab (if available) => l3_strict, else l3_core
        let labColors = selected.compactMap { $0.raw.lab }
        guard labColors.count >= 3 else {
            return .l3_core  // Only luminance, return L3_core
        }
        let labVariance = ObservationMath.labVariance(labColors)
        guard labVariance <= ObservationConstants.maxLabVariance else {
            return .invalid(reason: .labVarianceExceeded)
        }
        
        return .l3_strict
    }
}
