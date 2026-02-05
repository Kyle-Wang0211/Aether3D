//
// PR5CaptureRiskRegister.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 可执行风险注册表，发布门控检查
//

import Foundation

/// Risk severity levels
public enum RiskSeverity: String, Codable, Sendable, CaseIterable {
    case p0  // Critical - blocks release
    case p1  // High - blocks release
    case p2  // Medium - warns
    case p3  // Low - informational
}

/// Risk status
public enum RiskStatus: String, Codable, Sendable, CaseIterable {
    case open
    case verified
    case mitigated
    case accepted
}

/// Risk entry in the register
public struct RiskEntry: Codable, Sendable {
    public let riskId: String
    public let severity: RiskSeverity
    public let description: String
    public let status: RiskStatus
    public let verifiedAt: Date?
    public let verifiedBy: String?
    public let mitigationPlan: String?
    
    public init(
        riskId: String,
        severity: RiskSeverity,
        description: String,
        status: RiskStatus = .open,
        verifiedAt: Date? = nil,
        verifiedBy: String? = nil,
        mitigationPlan: String? = nil
    ) {
        self.riskId = riskId
        self.severity = severity
        self.description = description
        self.status = status
        self.verifiedAt = verifiedAt
        self.verifiedBy = verifiedBy
        self.mitigationPlan = mitigationPlan
    }
}

/// PR5Capture risk register
///
/// Executable risk register for release gating.
/// P0/P1 risks must be verified before release.
public actor PR5CaptureRiskRegister {
    
    // MARK: - State
    
    private var risks: [String: RiskEntry] = [:]
    
    // MARK: - Initialization
    
    public init() {
        // Initialize with default risks (inline to avoid actor isolation issue)
        let defaultRisks = [
            RiskEntry(
                riskId: "P0-001",
                severity: .p0,
                description: "Domain boundary violations detected",
                status: .open
            ),
            RiskEntry(
                riskId: "P0-002",
                severity: .p0,
                description: "Anchor drift exceeds threshold",
                status: .open
            ),
            RiskEntry(
                riskId: "P0-003",
                severity: .p0,
                description: "Quality gate failure rate exceeds threshold",
                status: .open
            ),
            RiskEntry(
                riskId: "P1-001",
                severity: .p1,
                description: "Performance degradation detected",
                status: .open
            ),
            RiskEntry(
                riskId: "P1-002",
                severity: .p1,
                description: "Memory usage exceeds budget",
                status: .open
            )
        ]
        
        // Store risks directly (safe in init)
        for risk in defaultRisks {
            risks[risk.riskId] = risk
        }
    }
    
    // MARK: - Risk Management
    
    /// Register a new risk
    public func registerRisk(_ risk: RiskEntry) {
        risks[risk.riskId] = risk
    }
    
    /// Get risk by ID
    public func getRisk(_ riskId: String) -> RiskEntry? {
        return risks[riskId]
    }
    
    /// Verify a risk
    public func verifyRisk(_ riskId: String, verifiedBy: String) throws {
        guard var risk = risks[riskId] else {
            throw RiskRegisterError.riskNotFound(riskId)
        }
        
        risk = RiskEntry(
            riskId: risk.riskId,
            severity: risk.severity,
            description: risk.description,
            status: .verified,
            verifiedAt: Date(),
            verifiedBy: verifiedBy,
            mitigationPlan: risk.mitigationPlan
        )
        
        risks[riskId] = risk
    }
    
    // MARK: - Release Gating
    
    /// Check if release is allowed
    ///
    /// Returns true if all P0/P1 risks are verified
    public func canRelease() -> Bool {
        let p0p1Risks = risks.values.filter { $0.severity == .p0 || $0.severity == .p1 }
        let unverified = p0p1Risks.filter { $0.status != .verified }
        return unverified.isEmpty
    }
    
    /// Get unverified P0/P1 risks
    public func getUnverifiedCriticalRisks() -> [RiskEntry] {
        return risks.values.filter { risk in
            (risk.severity == .p0 || risk.severity == .p1) && risk.status != .verified
        }
    }
    
    
    // MARK: - Error Types
    
    public enum RiskRegisterError: Error, Sendable {
        case riskNotFound(String)
        case invalidRiskStatus(String)
    }
}
