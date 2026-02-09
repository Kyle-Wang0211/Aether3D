// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TwoPhaseQualityGate.swift
// PR5Capture
//
// PR5 v1.8.1 - 五大核心方法论之一：两阶段质量门（Two-Phase Quality Gates）
// Frame Gate + Patch Gate 双重验证
//

import Foundation

/// Two-phase quality gate system
///
/// **Two Phases**:
/// - **Frame Gate**: Per-frame disposition decision
/// - **Patch Gate**: Per-region ledger commit decision
///
/// **Two-Phase Commit Logic**: Ensures consistency between frame-level and patch-level decisions
public actor TwoPhaseQualityGate {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile.TwoPhaseGateConfig
    
    // MARK: - Frame Gate State
    
    /// Pending frame gate decisions awaiting patch gate confirmation
    private var pendingFrameDecisions: [PendingFrameDecision] = []
    
    /// Confirmed frame decisions (passed both gates)
    private var confirmedDecisions: [ConfirmedDecision] = []
    
    // MARK: - Patch Gate State
    
    /// Pending patch gate decisions
    private var pendingPatchDecisions: [PendingPatchDecision] = []
    
    // MARK: - Timeout Management
    
    /// Timeout timers for pending decisions
    private var timeoutTimers: [UUID: Date] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile.TwoPhaseGateConfig) {
        self.config = config
    }
    
    // MARK: - Frame Gate (Phase 1)
    
    /// Evaluate frame gate
    ///
    /// First phase: determines if frame passes quality threshold
    /// Returns a pending decision that must be confirmed by patch gate
    public func evaluateFrameGate(quality: Double, frameId: UInt64) -> FrameGateResult {
        let passes = quality >= config.frameGateThreshold
        
        if passes {
            // Create pending decision
            let decisionId = UUID()
            let pending = PendingFrameDecision(
                id: decisionId,
                frameId: frameId,
                quality: quality,
                timestamp: Date()
            )
            pendingFrameDecisions.append(pending)
            
            // Set timeout
            timeoutTimers[decisionId] = Date().addingTimeInterval(config.twoPhaseCommitTimeout)
            
            return .pending(decisionId: decisionId, quality: quality)
        } else {
            return .rejected(reason: "Quality \(quality) below threshold \(config.frameGateThreshold)")
        }
    }
    
    // MARK: - Patch Gate (Phase 2)
    
    /// Evaluate patch gate
    ///
    /// Second phase: determines if patch/region passes quality threshold
    /// Confirms or rejects pending frame decisions
    public func evaluatePatchGate(
        quality: Double,
        frameDecisionId: UUID?,
        patchId: UUID
    ) -> PatchGateResult {
        let passes = quality >= config.patchGateThreshold
        
        if passes {
            // If frame decision ID provided, confirm it
            if let frameId = frameDecisionId {
                if let index = pendingFrameDecisions.firstIndex(where: { $0.id == frameId }) {
                    let frameDecision = pendingFrameDecisions.remove(at: index)
                    timeoutTimers.removeValue(forKey: frameId)
                    
                    // Create confirmed decision
                    let confirmed = ConfirmedDecision(
                        frameId: frameDecision.frameId,
                        frameQuality: frameDecision.quality,
                        patchId: patchId,
                        patchQuality: quality,
                        confirmedAt: Date()
                    )
                    confirmedDecisions.append(confirmed)
                    
                    return .confirmed(frameDecisionId: frameId, patchId: patchId)
                }
            }
            
            // Standalone patch gate pass (no frame decision to confirm)
            return .standalonePass(patchId: patchId, quality: quality)
        } else {
            // Patch gate failed - reject pending frame decision if exists
            if let frameId = frameDecisionId {
                if let index = pendingFrameDecisions.firstIndex(where: { $0.id == frameId }) {
                    pendingFrameDecisions.remove(at: index)
                    timeoutTimers.removeValue(forKey: frameId)
                }
            }
            
            return .rejected(reason: "Patch quality \(quality) below threshold \(config.patchGateThreshold)")
        }
    }
    
    // MARK: - Timeout Handling
    
    /// Check for timed-out pending decisions
    ///
    /// Should be called periodically to clean up timed-out decisions
    public func checkTimeouts() -> [TimedOutDecision] {
        let now = Date()
        var timedOut: [TimedOutDecision] = []
        
        // Check frame decision timeouts
        var indicesToRemove: [Int] = []
        for (index, decision) in pendingFrameDecisions.enumerated() {
            if let timeout = timeoutTimers[decision.id], now >= timeout {
                timedOut.append(TimedOutDecision(
                    decisionId: decision.id,
                    frameId: decision.frameId,
                    phase: .frameGate,
                    timedOutAt: timeout
                ))
                indicesToRemove.append(index)
                timeoutTimers.removeValue(forKey: decision.id)
            }
        }
        
        // Remove timed-out decisions (in reverse order to maintain indices)
        for index in indicesToRemove.reversed() {
            pendingFrameDecisions.remove(at: index)
        }
        
        return timedOut
    }
    
    // MARK: - Confirmation Requirements
    
    /// Check if frame decision requires patch gate confirmation
    ///
    /// Returns number of confirmation frames required
    public func getConfirmationRequirement() -> Int {
        return config.patchGateConfirmationFrames
    }
    
    // MARK: - State Queries
    
    /// Get pending frame decisions count
    public func getPendingFrameDecisionsCount() -> Int {
        return pendingFrameDecisions.count
    }
    
    /// Get confirmed decisions count
    public func getConfirmedDecisionsCount() -> Int {
        return confirmedDecisions.count
    }
    
    // MARK: - Data Structures
    
    /// Pending frame decision (awaiting patch gate confirmation)
    public struct PendingFrameDecision: Sendable {
        public let id: UUID
        public let frameId: UInt64
        public let quality: Double
        public let timestamp: Date
    }
    
    /// Pending patch decision
    public struct PendingPatchDecision: Sendable {
        public let id: UUID
        public let patchId: UUID
        public let quality: Double
        public let timestamp: Date
    }
    
    /// Confirmed decision (passed both gates)
    public struct ConfirmedDecision: Sendable {
        public let frameId: UInt64
        public let frameQuality: Double
        public let patchId: UUID
        public let patchQuality: Double
        public let confirmedAt: Date
    }
    
    /// Timed-out decision
    public struct TimedOutDecision: Sendable {
        public let decisionId: UUID
        public let frameId: UInt64
        public let phase: GatePhase
        public let timedOutAt: Date
        
        public enum GatePhase: String, Sendable {
            case frameGate
            case patchGate
        }
    }
    
    // MARK: - Result Types
    
    /// Frame gate result
    public enum FrameGateResult: Sendable {
        case pending(decisionId: UUID, quality: Double)
        case rejected(reason: String)
    }
    
    /// Patch gate result
    public enum PatchGateResult: Sendable {
        case confirmed(frameDecisionId: UUID, patchId: UUID)
        case standalonePass(patchId: UUID, quality: Double)
        case rejected(reason: String)
    }
}
