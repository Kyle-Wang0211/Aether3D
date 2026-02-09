// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CrashReportGenerator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 崩溃报告生成，诊断信息收集
//

import Foundation

/// Crash report generator
///
/// Generates crash reports with diagnostic information collection.
/// Provides detailed crash analysis.
public actor CrashReportGenerator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Crash reports
    private var reports: [CrashReport] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Report Generation
    
    /// Generate crash report
    public func generateReport(
        error: Error,
        context: [String: String],
        stackTrace: [String]? = nil
    ) -> ReportResult {
        let report = CrashReport(
            id: UUID(),
            timestamp: Date(),
            error: error.localizedDescription,
            context: context,
            stackTrace: stackTrace ?? [],
            platform: PlatformAbstractionLayer.currentPlatform.rawValue
        )
        
        reports.append(report)
        
        // Keep only recent reports (last 50)
        if reports.count > 50 {
            reports.removeFirst()
        }
        
        return ReportResult(
            reportId: report.id,
            timestamp: report.timestamp,
            success: true
        )
    }
    
    // MARK: - Data Types
    
    /// Crash report
    public struct CrashReport: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let error: String
        public let context: [String: String]
        public let stackTrace: [String]
        public let platform: String
    }
    
    /// Report result
    public struct ReportResult: Sendable {
        public let reportId: UUID
        public let timestamp: Date
        public let success: Bool
    }
}
