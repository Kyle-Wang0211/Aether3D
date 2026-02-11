// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DualAnchorManager.swift
// PR5Capture
//
// PR5 v1.8.1 - 五大核心方法论之一：双锚定（Dual Anchoring）
// Session Anchor + Segment Anchor 防止长期漂移
//

import Foundation

/// Dual anchoring system to prevent long-term drift
///
/// **Two Anchor Types**:
/// - **Session Anchor**: Long-term anchor updated at session start and periodically
/// - **Segment Anchor**: Short-term anchor updated on scene changes
///
/// **Evidence Velocity Comparison Safety**: Compares evidence accumulation rates
/// to detect anomalies before they cause drift.
public actor DualAnchorManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile.DualAnchorConfig
    
    // MARK: - Session Anchor
    
    /// Session anchor value
    /// Updated at session start and periodically based on config
    private var sessionAnchor: AnchorValue?
    
    /// Last session anchor update time
    private var lastSessionAnchorUpdate: Date?
    
    // MARK: - Segment Anchor
    
    /// Current segment anchor value
    /// Updated on scene changes
    private var segmentAnchor: AnchorValue?
    
    /// Last segment anchor update time
    private var lastSegmentAnchorUpdate: Date?
    
    // MARK: - Evidence Tracking
    
    /// Evidence accumulation rate for session anchor
    private var sessionEvidenceVelocity: Double = 0.0
    
    /// Evidence accumulation rate for segment anchor
    private var segmentEvidenceVelocity: Double = 0.0
    
    /// Evidence samples for velocity calculation
    private var evidenceSamples: [(value: Double, timestamp: Date)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile.DualAnchorConfig) {
        self.config = config
    }
    
    // MARK: - Session Anchor Management
    
    /// Initialize session anchor
    ///
    /// Called at session start
    public func initializeSessionAnchor(_ value: AnchorValue) {
        sessionAnchor = value
        lastSessionAnchorUpdate = Date()
        sessionEvidenceVelocity = 0.0
        evidenceSamples.removeAll()
    }
    
    /// Update session anchor if interval has elapsed
    ///
    /// Returns true if anchor was updated
    public func updateSessionAnchorIfNeeded(_ newValue: AnchorValue) -> Bool {
        guard let lastUpdate = lastSessionAnchorUpdate else {
            // First update
            initializeSessionAnchor(newValue)
            return true
        }
        
        let elapsed = Date().timeIntervalSince(lastUpdate)
        if elapsed >= config.sessionAnchorUpdateInterval {
            sessionAnchor = newValue
            lastSessionAnchorUpdate = Date()
            return true
        }
        
        return false
    }
    
    /// Get current session anchor
    public func getSessionAnchor() -> AnchorValue? {
        return sessionAnchor
    }
    
    // MARK: - Segment Anchor Management
    
    /// Update segment anchor
    ///
    /// Called on scene changes
    public func updateSegmentAnchor(_ value: AnchorValue) {
        segmentAnchor = value
        lastSegmentAnchorUpdate = Date()
    }
    
    /// Get current segment anchor
    public func getSegmentAnchor() -> AnchorValue? {
        return segmentAnchor
    }
    
    // MARK: - Drift Detection
    
    /// Check for anchor drift
    ///
    /// Compares current value against both anchors and checks drift thresholds
    public func checkDrift(_ currentValue: AnchorValue) -> DriftCheckResult {
        var sessionDrift: Double?
        var segmentDrift: Double?
        var hasDrift = false
        
        // Check session anchor drift
        if let session = sessionAnchor {
            let drift = abs(currentValue.value - session.value)
            sessionDrift = drift
            if drift > config.anchorDriftThreshold {
                hasDrift = true
            }
        }
        
        // Check segment anchor drift
        if let segment = segmentAnchor {
            let drift = abs(currentValue.value - segment.value)
            segmentDrift = drift
            if drift > config.anchorDriftThreshold {
                hasDrift = true
            }
        }
        
        return DriftCheckResult(
            hasDrift: hasDrift,
            sessionDrift: sessionDrift,
            segmentDrift: segmentDrift,
            sessionAnchor: sessionAnchor,
            segmentAnchor: segmentAnchor
        )
    }
    
    // MARK: - Evidence Velocity Comparison
    
    /// Record evidence sample for velocity calculation
    ///
    /// Used for evidence velocity comparison safety mechanism
    public func recordEvidenceSample(_ value: Double) {
        let now = Date()
        evidenceSamples.append((value: value, timestamp: now))
        
        // Keep only recent samples (last 10 seconds)
        let cutoff = now.addingTimeInterval(-10.0)
        evidenceSamples.removeAll { $0.timestamp < cutoff }
        
        // Calculate velocities if we have enough samples
        if evidenceSamples.count >= 2 {
            calculateEvidenceVelocities()
        }
    }
    
    /// Calculate evidence accumulation velocities
    private func calculateEvidenceVelocities() {
        guard evidenceSamples.count >= 2 else { return }
        
        // Calculate session anchor velocity
        if let session = sessionAnchor, let firstSample = evidenceSamples.first {
            let timeDelta = evidenceSamples.last!.timestamp.timeIntervalSince(firstSample.timestamp)
            if timeDelta > 0 {
                let valueDelta = abs(evidenceSamples.last!.value - session.value)
                sessionEvidenceVelocity = valueDelta / timeDelta
            }
        }
        
        // Calculate segment anchor velocity
        if let segment = segmentAnchor, let firstSample = evidenceSamples.first {
            let timeDelta = evidenceSamples.last!.timestamp.timeIntervalSince(firstSample.timestamp)
            if timeDelta > 0 {
                let valueDelta = abs(evidenceSamples.last!.value - segment.value)
                segmentEvidenceVelocity = valueDelta / timeDelta
            }
        }
        
        // Safety check: compare velocities
        if config.evidenceVelocityComparisonSafety {
            checkEvidenceVelocitySafety()
        }
    }
    
    /// Check evidence velocity safety
    ///
    /// Detects anomalies in evidence accumulation rates
    private func checkEvidenceVelocitySafety() {
        // If both velocities are available, compare them
        if sessionEvidenceVelocity > 0 && segmentEvidenceVelocity > 0 {
            let ratio = sessionEvidenceVelocity / segmentEvidenceVelocity
            
            // If ratio is too high or too low, it indicates an anomaly
            // Session anchor should accumulate evidence slower than segment anchor
            if ratio > 10.0 || ratio < 0.1 {
                // Log warning - this indicates potential drift or anomaly
                print("⚠️ Evidence velocity anomaly detected: session=\(sessionEvidenceVelocity), segment=\(segmentEvidenceVelocity), ratio=\(ratio)")
            }
        }
    }
    
    // MARK: - Anchor Value
    
    /// Anchor value structure
    public struct AnchorValue: Codable, Sendable {
        public let value: Double
        public let timestamp: Date
        public let frameId: UInt64?
        public let metadata: [String: String]
        
        public init(value: Double, timestamp: Date = Date(), frameId: UInt64? = nil, metadata: [String: String] = [:]) {
            self.value = value
            self.timestamp = timestamp
            self.frameId = frameId
            self.metadata = metadata
        }
    }
    
    // MARK: - Drift Check Result
    
    /// Result of drift check
    public struct DriftCheckResult: Sendable {
        public let hasDrift: Bool
        public let sessionDrift: Double?
        public let segmentDrift: Double?
        public let sessionAnchor: AnchorValue?
        public let segmentAnchor: AnchorValue?
        
        public init(
            hasDrift: Bool,
            sessionDrift: Double?,
            segmentDrift: Double?,
            sessionAnchor: AnchorValue?,
            segmentAnchor: AnchorValue?
        ) {
            self.hasDrift = hasDrift
            self.sessionDrift = sessionDrift
            self.segmentDrift = segmentDrift
            self.sessionAnchor = sessionAnchor
            self.segmentAnchor = segmentAnchor
        }
    }
}
