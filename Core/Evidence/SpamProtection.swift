//
// SpamProtection.swift
// Aether3D
//
// PR2 Patch V4 - Spam Protection (Signal Provider)
// Provides quality scale factors, does NOT hard-block
//

import Foundation

/// Spam protection state per patch
private struct SpamState {
    var lastUpdateMs: Int64
    var recentUpdateCount: Int
    var lastResetMs: Int64
    
    init(lastUpdateMs: Int64 = 0, recentUpdateCount: Int = 0, lastResetMs: Int64 = 0) {
        self.lastUpdateMs = lastUpdateMs
        self.recentUpdateCount = recentUpdateCount
        self.lastResetMs = lastResetMs
    }
}

/// Spam protection signal provider
///
/// DESIGN:
/// - Provides quality scale factors (0.0 to 1.0)
/// - Does NOT hard-block (UnifiedAdmissionController handles hard blocks)
/// - Tracks per-patch update frequency
public final class SpamProtection {
    
    /// Per-patch spam state
    private var patchStates: [String: SpamState] = [:]
    
    /// Time window for frequency tracking (milliseconds)
    private let frequencyWindowMs: Int64 = 1000  // 1 second
    
    /// Maximum updates per window before penalty
    private let maxUpdatesPerWindow: Int = 10
    
    public init() {}
    
    /// Record an update for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - timestampMs: Current timestamp in milliseconds
    public func recordUpdate(patchId: String, timestampMs: Int64) {
        var state = patchStates[patchId] ?? SpamState(lastUpdateMs: timestampMs, lastResetMs: timestampMs)
        
        // Reset window if expired
        if timestampMs - state.lastResetMs >= frequencyWindowMs {
            state.recentUpdateCount = 0
            state.lastResetMs = timestampMs
        }
        
        state.recentUpdateCount += 1
        state.lastUpdateMs = timestampMs
        
        patchStates[patchId] = state
    }
    
    /// Get frequency cap scale factor
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - timestampMs: Current timestamp in milliseconds
    /// - Returns: Scale factor [0, 1] where 1.0 = no penalty, 0.0 = maximum penalty
    public func frequencyScale(patchId: String, timestampMs: Int64) -> Double {
        recordUpdate(patchId: patchId, timestampMs: timestampMs)
        
        guard let state = patchStates[patchId] else {
            return 1.0
        }
        
        // Compute scale: 1.0 if under limit, decreasing as over limit
        if state.recentUpdateCount <= maxUpdatesPerWindow {
            return 1.0
        }
        
        // Penalty: scale decreases as count exceeds limit
        let excess = state.recentUpdateCount - maxUpdatesPerWindow
        let penalty = min(1.0, Double(excess) / Double(maxUpdatesPerWindow))
        
        return max(0.0, 1.0 - penalty)
    }
    
    /// Convert raw novelty score to scale factor
    ///
    /// - Parameter rawNovelty: Raw novelty score [0, 1]
    /// - Returns: Scale factor [0, 1] where low novelty = lower scale
    public func noveltyScale(rawNovelty: Double) -> Double {
        // Low novelty threshold from SSOT
        let threshold = EvidenceConstants.lowNoveltyThreshold
        let penalty = EvidenceConstants.lowNoveltyPenalty
        
        if rawNovelty < threshold {
            return penalty
        }
        
        // Linear interpolation from threshold to 1.0
        let normalized = (rawNovelty - threshold) / (1.0 - threshold)
        return penalty + (1.0 - penalty) * normalized
    }
    
    /// Check if update should be allowed (time density check)
    /// NOTE: This is used by UnifiedAdmissionController for hard-blocking
    /// SpamProtection itself does NOT hard-block
    public func shouldAllowUpdate(patchId: String, timestamp: TimeInterval) -> Bool {
        let timestampMs = Int64(timestamp * 1000.0)
        guard let state = patchStates[patchId] else {
            return true  // No previous update = allow
        }
        
        // Minimum interval between updates (hard limit)
        let minIntervalMs: Int64 = 33  // ~30fps minimum
        
        let elapsedMs = timestampMs - state.lastUpdateMs
        
        return elapsedMs >= minIntervalMs
    }
    
    /// Reset all state
    public func reset() {
        patchStates.removeAll()
    }
}
