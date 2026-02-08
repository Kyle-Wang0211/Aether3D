//
// CoverageEstimator.swift
// Aether3D
//
// PR6 Evidence Grid System - Coverage Estimator
// D-S based coverage calculation with EMA smoothing and anti-jitter limiter
//

import Foundation

/// **Rule ID:** PR6_GRID_COVERAGE_001
/// Coverage Estimator: computes coverage from EvidenceGrid cells
public final class CoverageEstimator: @unchecked Sendable {
    
    /// Level weights (SSOT constants)
    private let levelWeights: [Double] = [0.00, 0.20, 0.50, 0.80, 0.90, 0.95, 1.00]  // L0..L6
    
    /// EMA smoothing alpha
    private let emaAlpha: Double = 0.15
    
    /// Maximum coverage delta per second (anti-jitter limiter)
    private let maxCoverageDeltaPerSec: Double = 0.10
    
    /// Last coverage value (for EMA)
    private var lastCoverage: Double = 0.0
    
    /// Last update timestamp (monotonic milliseconds)
    private var lastUpdateMonotonicMs: Int64 = 0
    
    /// Non-monotonic time count (diagnostic)
    private var nonMonotonicTimeCount: Int = 0
    
    public init() {
        self.lastUpdateMonotonicMs = MonotonicClock.nowMs()
    }
    
    /// **Rule ID:** PR6_GRID_COVERAGE_002
    /// Update coverage from EvidenceGrid cells
    ///
    /// - Parameter grid: EvidenceGrid instance
    /// - Returns: CoverageResult with breakdown and explainability
    public func update(grid: EvidenceGrid) async -> CoverageResult {
        let cells = await grid.allActiveCells()
        
        // Compute coverage from cells
        var breakdownCounts = Array(repeating: 0, count: 7)  // L0..L6
        var weightedSumComponents = Array(repeating: 0.0, count: 7)
        var totalWeightedSum = 0.0
        var excludedAreaSqM = 0.0
        
        // Iterate cells in deterministic order (stable key list)
        for cell in cells {
            let levelIndex = Int(cell.level.rawValue)
            guard levelIndex >= 0 && levelIndex < 7 else {
                continue
            }
            
            // Count cells per level
            breakdownCounts[levelIndex] += 1
            
            // Compute weighted contribution
            let weight = levelWeights[levelIndex]
            let dsBelief = cell.dsMass.occupied  // Use occupied mass as belief
            let contribution = weight * dsBelief
            
            weightedSumComponents[levelIndex] += contribution
            totalWeightedSum += contribution
            
            // TODO: Compute excluded area from PIZ occlusion exclusion
            // For now, excludedAreaSqM = 0.0
        }
        
        // Compute raw coverage percentage
        let totalCells = cells.count
        let rawCoverage = totalCells > 0 ? totalWeightedSum / Double(totalCells) : 0.0
        
        // Apply EMA smoothing (MUST-FIX S)
        let currentMonotonicMs = MonotonicClock.nowMs()
        let deltaTimeMs = currentMonotonicMs - lastUpdateMonotonicMs
        
        // **Rule ID:** PR6_GRID_COVERAGE_003
        // Handle non-monotonic time
        let deltaTimeSeconds: Double
        if deltaTimeMs <= 0 {
            deltaTimeSeconds = 0.0
            nonMonotonicTimeCount += 1
        } else {
            deltaTimeSeconds = Double(deltaTimeMs) / 1000.0
        }
        
        // EMA smoothing: newValue = alpha * rawValue + (1 - alpha) * oldValue
        let smoothedCoverage = emaAlpha * rawCoverage + (1.0 - emaAlpha) * lastCoverage
        
        // **Rule ID:** PR6_GRID_COVERAGE_004
        // Anti-jitter limiter (MUST-FIX R + S)
        let coverageDelta = smoothedCoverage - lastCoverage
        let deltaRate = deltaTimeSeconds > 0 ? abs(coverageDelta) / deltaTimeSeconds : 0.0
        
        let finalCoverage: Double
        if deltaRate > maxCoverageDeltaPerSec {
            // Limit change rate
            let maxDelta = maxCoverageDeltaPerSec * deltaTimeSeconds
            finalCoverage = lastCoverage + (coverageDelta > 0 ? maxDelta : -maxDelta)
        } else {
            finalCoverage = smoothedCoverage
        }
        
        // Clamp to [0, 1]
        let clampedCoverage = max(0.0, min(1.0, finalCoverage))
        
        // Update state
        lastCoverage = clampedCoverage
        lastUpdateMonotonicMs = currentMonotonicMs
        
        return CoverageResult(
            coveragePercentage: clampedCoverage,
            breakdownCounts: breakdownCounts,
            weightedSumComponents: weightedSumComponents,
            excludedAreaSqM: excludedAreaSqM
        )
    }
    
    /// Get last coverage value
    public func getLastCoverage() -> Double {
        return lastCoverage
    }
    
    /// Reset estimator
    public func reset() {
        lastCoverage = 0.0
        lastUpdateMonotonicMs = MonotonicClock.nowMs()
        nonMonotonicTimeCount = 0
    }
}
