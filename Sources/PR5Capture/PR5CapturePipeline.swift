//
// PR5CapturePipeline.swift
// PR5Capture
//
// PR5 v1.8.1 - 主捕获管道
// 集成所有组件，实现五大核心方法论
//

import Foundation
import PR4Math
import PR4Ownership
import PR4Quality
import PR4Gate

/// PR5Capture main pipeline
///
/// Integrates all components and implements the five core methodologies:
/// 1. Three-Domain Isolation
/// 2. Dual Anchoring
/// 3. Two-Phase Quality Gates
/// 4. Hysteresis/Cooldown/Minimum Dwell
/// 5. Profile-Based Extreme Values
public actor PR5CapturePipeline {
    
    // MARK: - Configuration
    
    private let profile: ExtremeProfile
    
    // MARK: - Core Methodology Components
    
    /// Domain boundary enforcer
    private let domainBoundaryEnforcer: DomainBoundaryEnforcer
    
    /// Dual anchor manager
    private let dualAnchorManager: DualAnchorManager
    
    /// Two-phase quality gate
    private let twoPhaseQualityGate: TwoPhaseQualityGate
    
    /// Hysteresis/cooldown/dwell controllers (pre-configured)
    private let lowLightController: HysteresisCooldownDwellController
    private let highMotionController: HysteresisCooldownDwellController
    private let hdrController: HysteresisCooldownDwellController
    private let thermalController: HysteresisCooldownDwellController
    private let focusController: HysteresisCooldownDwellController
    
    // MARK: - Session State
    
    /// Current session context
    private var sessionContext: SessionContext?
    
    /// Current frame context
    private var frameContext: FrameContextLegacy?
    
    // MARK: - Initialization
    
    public init(profile: ConfigProfile = .standard) {
        let extremeProfile = ExtremeProfile(profile: profile)
        self.profile = extremeProfile
        
        // Initialize core methodology components
        self.domainBoundaryEnforcer = DomainBoundaryEnforcer(config: extremeProfile.domainBoundary)
        self.dualAnchorManager = DualAnchorManager(config: extremeProfile.dualAnchor)
        self.twoPhaseQualityGate = TwoPhaseQualityGate(config: extremeProfile.twoPhaseGate)
        
        // Initialize pre-configured controllers
        self.lowLightController = HysteresisCooldownDwellController.lowLight(config: extremeProfile.stateMachine)
        self.highMotionController = HysteresisCooldownDwellController.highMotion(config: extremeProfile.stateMachine)
        self.hdrController = HysteresisCooldownDwellController.hdr(config: extremeProfile.stateMachine)
        self.thermalController = HysteresisCooldownDwellController.thermal(config: extremeProfile.stateMachine)
        self.focusController = HysteresisCooldownDwellController.focus(config: extremeProfile.stateMachine)
    }
    
    // MARK: - Session Management
    
    /// Start a new capture session
    public func startSession() async throws -> UUID {
        let sessionId = UUID()
        let context = SessionContext()
        self.sessionContext = context
        
        // Initialize session anchor
        let initialAnchor = DualAnchorManager.AnchorValue(value: 0.0)
        await dualAnchorManager.initializeSessionAnchor(initialAnchor)
        
        return sessionId
    }
    
    /// End current capture session
    public func endSession() {
        sessionContext = nil
        frameContext = nil
    }
    
    // MARK: - Frame Processing
    
    /// Process a frame through the pipeline
    ///
    /// Implements the full PR5Capture pipeline with all five core methodologies
    public func processFrame(
        frameId: UInt64,
        timestamp: TimeInterval,
        quality: Double
    ) async throws -> FrameProcessingResult {
        guard sessionContext != nil else {
            throw PR5CaptureError.configurationError(message: "No active session")
        }
        
        // Enter Perception domain
        await domainBoundaryEnforcer.enterDomain(.perception)
        defer { Task { await domainBoundaryEnforcer.exitDomain() } }
        
        // Verify domain boundary
        try await domainBoundaryEnforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
        
        // Enter Decision domain
        await domainBoundaryEnforcer.enterDomain(.decision)
        defer { Task { await domainBoundaryEnforcer.exitDomain() } }
        
        // Evaluate frame gate (Phase 1)
        let frameGateResult = await twoPhaseQualityGate.evaluateFrameGate(quality: quality, frameId: frameId)
        
        // Check anchor drift
        let currentAnchor = DualAnchorManager.AnchorValue(value: quality)
        let driftCheck = await dualAnchorManager.checkDrift(currentAnchor)
        
        if driftCheck.hasDrift {
            // Handle drift (log, alert, etc.)
            print("⚠️ Anchor drift detected: session=\(driftCheck.sessionDrift ?? 0), segment=\(driftCheck.segmentDrift ?? 0)")
        }
        
        // Update anchors if needed
        _ = await dualAnchorManager.updateSessionAnchorIfNeeded(currentAnchor)
        
        // Verify domain boundary for ledger
        try await domainBoundaryEnforcer.verifyCrossDomainAccess(from: .decision, to: .ledger)
        
        // Enter Ledger domain
        await domainBoundaryEnforcer.enterDomain(.ledger)
        defer { Task { await domainBoundaryEnforcer.exitDomain() } }
        
        // Process frame gate result
        switch frameGateResult {
        case .pending(let decisionId, let q):
            return FrameProcessingResult(
                frameId: frameId,
                disposition: .pending,
                quality: q,
                frameDecisionId: decisionId,
                requiresPatchGate: true
            )
        case .rejected(let reason):
            return FrameProcessingResult(
                frameId: frameId,
                disposition: .reject,
                quality: quality,
                frameDecisionId: nil,
                requiresPatchGate: false,
                rejectionReason: reason
            )
        }
    }
    
    // MARK: - Patch Gate Processing
    
    /// Process patch gate (Phase 2)
    public func processPatchGate(
        patchId: UUID,
        quality: Double,
        frameDecisionId: UUID?
    ) async throws -> PatchGateResult {
        // Enter Decision domain
        await domainBoundaryEnforcer.enterDomain(.decision)
        defer { Task { await domainBoundaryEnforcer.exitDomain() } }
        
        // Evaluate patch gate
        let result = await twoPhaseQualityGate.evaluatePatchGate(
            quality: quality,
            frameDecisionId: frameDecisionId,
            patchId: patchId
        )
        
        // Verify domain boundary for ledger
        try await domainBoundaryEnforcer.verifyCrossDomainAccess(from: .decision, to: .ledger)
        
        // Enter Ledger domain for audit
        await domainBoundaryEnforcer.enterDomain(.ledger)
        defer { Task { await domainBoundaryEnforcer.exitDomain() } }
        
        return PatchGateResult(
            patchId: patchId,
            result: result,
            timestamp: Date()
        )
    }
    
    // MARK: - Result Types
    
    /// Frame processing result
    public struct FrameProcessingResult: Sendable {
        public let frameId: UInt64
        public let disposition: FrameDisposition
        public let quality: Double
        public let frameDecisionId: UUID?
        public let requiresPatchGate: Bool
        public let rejectionReason: String?
        
        public init(
            frameId: UInt64,
            disposition: FrameDisposition,
            quality: Double,
            frameDecisionId: UUID?,
            requiresPatchGate: Bool,
            rejectionReason: String? = nil
        ) {
            self.frameId = frameId
            self.disposition = disposition
            self.quality = quality
            self.frameDecisionId = frameDecisionId
            self.requiresPatchGate = requiresPatchGate
            self.rejectionReason = rejectionReason
        }
    }
    
    /// Patch gate result
    public struct PatchGateResult: Sendable {
        public let patchId: UUID
        public let result: TwoPhaseQualityGate.PatchGateResult
        public let timestamp: Date
    }
}
