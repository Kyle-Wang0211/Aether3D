//
//  CompactSnapshot.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 8
//  CompactSnapshot - compact log snapshot (PART 9.2)
//

import Foundation

/// CompactSnapshot - compact log snapshot (only on state changes)
public struct CompactSnapshot: Codable {
    public let schemaVersion: Int
    public let thresholdVersion: String
    public let buildGitSha: String
    public let fps: Double?
    public let qualityLevel: QualityLevel?
    public let fpsTier: FpsTier?
    public let directionId: DirectionId?
    public let visualChange: VisualState?
    public let decisionChange: DecisionState?
    public let metricSnapshot: MetricSnapshotMinimal?
    public let ruleIds: [RuleId]
    
    public init(
        schemaVersion: Int,
        thresholdVersion: String,
        buildGitSha: String,
        fps: Double? = nil,
        qualityLevel: QualityLevel? = nil,
        fpsTier: FpsTier? = nil,
        directionId: DirectionId? = nil,
        visualChange: VisualState? = nil,
        decisionChange: DecisionState? = nil,
        metricSnapshot: MetricSnapshotMinimal? = nil,
        ruleIds: [RuleId]
    ) {
        self.schemaVersion = schemaVersion
        self.thresholdVersion = thresholdVersion
        self.buildGitSha = buildGitSha
        self.fps = fps
        self.qualityLevel = qualityLevel
        self.fpsTier = fpsTier
        self.directionId = directionId
        self.visualChange = visualChange
        self.decisionChange = decisionChange
        self.metricSnapshot = metricSnapshot
        self.ruleIds = ruleIds
    }
}

