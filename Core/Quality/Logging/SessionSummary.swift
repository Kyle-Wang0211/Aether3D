// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SessionSummary.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 8
//  SessionSummary - session-level statistics (PART 9.3)
//

import Foundation

/// SessionSummary - session-level statistics
public struct SessionSummary: Codable {
    public let sessionId: String
    public let completionStatus: SessionCompletionStatus
    public let totalDirections: Int
    public let totalHints: Int
    public let performanceStats: PerformanceStats?
    public let environmentInfo: EnvironmentInfo?
    
    public init(
        sessionId: String,
        completionStatus: SessionCompletionStatus,
        totalDirections: Int,
        totalHints: Int,
        performanceStats: PerformanceStats? = nil,
        environmentInfo: EnvironmentInfo? = nil
    ) {
        self.sessionId = sessionId
        self.completionStatus = completionStatus
        self.totalDirections = totalDirections
        self.totalHints = totalHints
        self.performanceStats = performanceStats
        self.environmentInfo = environmentInfo
    }
}

/// PerformanceStats - performance statistics
public struct PerformanceStats: Codable {
    public let avgFps: Double
    public let minFps: Double
    public let maxFps: Double
    
    public init(avgFps: Double, minFps: Double, maxFps: Double) {
        self.avgFps = avgFps
        self.minFps = minFps
        self.maxFps = maxFps
    }
}

/// EnvironmentInfo - environment information (privacy-safe buckets)
public struct EnvironmentInfo: Codable {
    public let deviceTier: String  // Bucketed, not exact model
    public let osVersion: String
    
    public init(deviceTier: String, osVersion: String) {
        self.deviceTier = deviceTier
        self.osVersion = osVersion
    }
}

