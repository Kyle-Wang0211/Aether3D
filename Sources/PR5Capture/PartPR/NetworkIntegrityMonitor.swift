//
// NetworkIntegrityMonitor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 网络完整性监控，异常检测
//

import Foundation

/// Network integrity monitor
///
/// Monitors network integrity with anomaly detection.
/// Detects network-based attacks and anomalies.
public actor NetworkIntegrityMonitor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Anomaly Types
    
    public enum AnomalyType: String, Sendable {
        case connectionReset
        case timeout
        case unexpectedResponse
        case rateLimitExceeded
        case none
    }
    
    // MARK: - State
    
    /// Monitoring history
    private var monitoringHistory: [(timestamp: Date, anomaly: AnomalyType)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Monitoring
    
    /// Monitor network activity
    public func monitorActivity(
        requestCount: Int,
        errorCount: Int,
        responseTime: TimeInterval
    ) -> MonitoringResult {
        var anomalies: [AnomalyType] = []
        
        // Detect anomalies
        if errorCount > requestCount / 2 {
            anomalies.append(.connectionReset)
        }
        
        if responseTime > 5.0 {
            anomalies.append(.timeout)
        }
        
        if requestCount > 1000 {
            anomalies.append(.rateLimitExceeded)
        }
        
        let primaryAnomaly = anomalies.first ?? .none
        
        // Record monitoring
        monitoringHistory.append((timestamp: Date(), anomaly: primaryAnomaly))
        
        // Keep only recent history (last 1000)
        if monitoringHistory.count > 1000 {
            monitoringHistory.removeFirst()
        }
        
        return MonitoringResult(
            anomalies: anomalies,
            primaryAnomaly: primaryAnomaly,
            requestCount: requestCount,
            errorCount: errorCount
        )
    }
    
    // MARK: - Result Types
    
    /// Monitoring result
    public struct MonitoringResult: Sendable {
        public let anomalies: [AnomalyType]
        public let primaryAnomaly: AnomalyType
        public let requestCount: Int
        public let errorCount: Int
    }
}
