//
// PatchDisplayMap.swift
// Aether3D
//
// PR2 Patch V4 - Patch Display Map
// Monotonic display evidence per patch with EMA smoothing
//

import Foundation

/// Display entry for a patch
public struct DisplayEntry: Codable, Sendable {
    /// Patch identifier
    public let patchId: String
    
    /// Current display evidence [0, 1] (monotonic, never decreases)
    @ClampedEvidence public var display: Double
    
    /// EMA state [0, 1]
    @ClampedEvidence public var ema: Double
    
    /// Observation count
    public var observationCount: Int
    
    /// Last update timestamp (milliseconds)
    public var lastUpdateMs: Int64
    
    public init(
        patchId: String,
        display: Double = 0.0,
        ema: Double = 0.0,
        observationCount: Int = 0,
        lastUpdateMs: Int64 = 0
    ) {
        self.patchId = patchId
        self._display = ClampedEvidence(wrappedValue: display)
        self._ema = ClampedEvidence(wrappedValue: ema)
        self.observationCount = observationCount
        self.lastUpdateMs = lastUpdateMs
    }
}

/// Patch display evidence storage
/// 
/// INVARIANTS:
/// - Display evidence NEVER decreases per patch
/// - Uses EMA smoothing for gradual updates
/// - Locked patches accelerate display growth (but remain monotonic)
public final class PatchDisplayMap {
    
    /// Patch ID → Display Entry storage
    private var displays: [String: DisplayEntry] = [:]
    
    public init() {}
    
    /// Update display evidence for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - target: Target evidence value [0, 1]
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - isLocked: Whether patch is locked (affects acceleration)
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Updated display entry
    @discardableResult
    public func update(
        patchId: String,
        target: Double,
        timestampMs: Int64,
        isLocked: Bool,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> DisplayEntry {
        var entry = displays[patchId] ?? DisplayEntry(
            patchId: patchId,
            lastUpdateMs: timestampMs
        )
        
        let prevDisplay = entry.display
        let prevEma = entry.ema
        
        // Clamp target to [0, 1]
        let clampedTarget = max(0.0, min(1.0, target))
        
        // EMA update: ema = alpha * target + (1 - alpha) * prevEma
        let alpha = constants.patchDisplayAlpha
        let newEma = alpha * clampedTarget + (1.0 - alpha) * prevEma
        
        // Compute base next display (from EMA)
        let baseNext = newEma
        
        // Apply locked acceleration if applicable
        let nextDisplay: Double
        if isLocked {
            // Locked acceleration: multiply growth delta by acceleration factor
            let growthDelta = baseNext - prevDisplay
            let acceleratedDelta = growthDelta * constants.patchDisplayLockedAcceleration
            let acceleratedNext = prevDisplay + acceleratedDelta
            
            // Clamp to [0, 1] and ensure monotonic
            nextDisplay = max(prevDisplay, min(1.0, acceleratedNext))
        } else {
            // Normal: just ensure monotonic
            nextDisplay = max(prevDisplay, min(1.0, baseNext))
        }
        
        // Update entry
        entry.display = nextDisplay
        entry.ema = newEma
        entry.observationCount += 1
        entry.lastUpdateMs = timestampMs
        
        displays[patchId] = entry
        
        return entry
    }
    
    /// Get display evidence for a patch
    public func display(for patchId: String) -> Double {
        return displays[patchId]?.display ?? 0.0
    }
    
    /// Compute color evidence using hybrid formula (Rule F)
    ///
    /// Formula: colorEvidence = local * 0.7 + global * 0.3
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - globalDisplay: Global display evidence [0, 1]
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Color evidence [0, 1]
    public func colorEvidence(
        for patchId: String,
        globalDisplay: Double,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        let local = display(for: patchId)
        let clampedGlobal = max(0.0, min(1.0, globalDisplay))
        
        // Hybrid formula: local * localWeight + global * globalWeight
        let color = local * constants.colorEvidenceLocalWeight + clampedGlobal * constants.colorEvidenceGlobalWeight
        
        // Clamp to [0, 1]
        return max(0.0, min(1.0, color))
    }
    
    /// Get all entries sorted by patch ID (deterministic)
    public func snapshotSorted() -> [DisplayEntry] {
        return displays.sorted { $0.key < $1.key }.map { $0.value }
    }
    
    /// Reset all displays
    public func reset() {
        displays.removeAll()
    }
}
