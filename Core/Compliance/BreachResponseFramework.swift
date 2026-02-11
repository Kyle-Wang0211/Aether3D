// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BreachResponseFramework.swift
// Aether3D
//
// Data breach incident response framework.
// GDPR Article 33: Notify supervisory authority within 72 hours.
// GDPR Article 34: Notify data subjects if high risk.
// PIPL Article 57: Notify authority AND individuals "immediately".
//

import Foundation

// MARK: - Breach Severity

/// Breach severity classification (ISO 27035 aligned)
public enum BreachSeverity: String, Sendable, Codable, CaseIterable, Comparable {
    /// Low: no personal data exposed, contained internally
    case low
    /// Medium: limited personal data, limited exposure
    case medium
    /// High: significant personal data, broad exposure
    case high
    /// Critical: sensitive personal data (biometric, health), mass exposure
    case critical

    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: BreachSeverity, rhs: BreachSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Whether supervisory authority notification is required
    public var requiresAuthorityNotification: Bool {
        self >= .medium
    }

    /// Whether individual data subject notification is required (GDPR Art 34)
    public var requiresSubjectNotification: Bool {
        self >= .high
    }
}

// MARK: - Breach Category

/// Type of data breach
public enum BreachCategory: String, Sendable, Codable {
    /// Unauthorized access to personal data
    case unauthorizedAccess
    /// Personal data sent to wrong recipient
    case wrongRecipient
    /// Loss of data (device lost/stolen)
    case dataLoss
    /// Ransomware or malware encryption
    case ransomware
    /// Accidental deletion of unbackuped data
    case accidentalDeletion
    /// Exploitation of vulnerability
    case vulnerabilityExploit
    /// Insider threat
    case insiderThreat
    /// Unknown / under investigation
    case unknown
}

// MARK: - Affected Data Types

/// Types of personal data affected in a breach
public enum AffectedDataType: String, Sendable, Codable {
    /// 3D capture data (faces, bodies)
    case captureData
    /// IMU sensor data
    case sensorData
    /// Consent records
    case consentRecords
    /// User identifiers
    case userIdentifiers
    /// Biometric data (face geometry)
    case biometricData
    /// Location data (derived from captures)
    case locationData
}

// MARK: - Breach Incident

/// A data breach incident record
public struct BreachIncident: Sendable, Codable {
    /// Unique incident identifier
    public let incidentId: String
    /// When the breach was discovered
    public let discoveredAt: Date
    /// Estimated time when the breach occurred (may differ from discovery)
    public let estimatedOccurredAt: Date?
    /// Breach category
    public let category: BreachCategory
    /// Severity classification
    public let severity: BreachSeverity
    /// Description of the breach
    public let description: String
    /// Types of personal data affected
    public let affectedDataTypes: [AffectedDataType]
    /// Estimated number of individuals affected (-1 = unknown)
    public let estimatedAffectedCount: Int
    /// Jurisdictions affected
    public let affectedJurisdictions: [String]
    /// Current status
    public var status: BreachStatus
    /// Timeline of actions taken
    public var timeline: [BreachTimelineEntry]

    /// GDPR 72-hour notification deadline
    public var notificationDeadline: Date {
        discoveredAt.addingTimeInterval(72 * 3600) // 72 hours
    }

    /// Hours remaining until notification deadline
    public var hoursUntilDeadline: Double {
        notificationDeadline.timeIntervalSince(Date()) / 3600
    }

    /// Whether the notification deadline has passed
    public var isOverdue: Bool {
        Date() > notificationDeadline
    }

    public init(
        incidentId: String = UUID().uuidString,
        discoveredAt: Date = Date(),
        estimatedOccurredAt: Date? = nil,
        category: BreachCategory,
        severity: BreachSeverity,
        description: String,
        affectedDataTypes: [AffectedDataType],
        estimatedAffectedCount: Int = -1,
        affectedJurisdictions: [String] = [],
        status: BreachStatus = .detected,
        timeline: [BreachTimelineEntry] = []
    ) {
        self.incidentId = incidentId
        self.discoveredAt = discoveredAt
        self.estimatedOccurredAt = estimatedOccurredAt
        self.category = category
        self.severity = severity
        self.description = description
        self.affectedDataTypes = affectedDataTypes
        self.estimatedAffectedCount = estimatedAffectedCount
        self.affectedJurisdictions = affectedJurisdictions
        self.status = status

        // Auto-add detection event to timeline
        var entries = timeline
        if entries.isEmpty {
            entries.append(BreachTimelineEntry(
                action: .detected,
                description: "Breach detected",
                performedBy: "system"
            ))
        }
        self.timeline = entries
    }
}

/// Breach incident status (ordered by progression)
public enum BreachStatus: String, Sendable, Codable, Comparable {
    /// Just detected, investigation not started
    case detected
    /// Under investigation
    case investigating
    /// Breach contained (no further exposure)
    case contained
    /// Supervisory authority notified
    case authorityNotified
    /// Affected individuals notified
    case subjectsNotified
    /// Remediation in progress
    case remediating
    /// Incident resolved and closed
    case resolved

    private var sortOrder: Int {
        switch self {
        case .detected: return 0
        case .investigating: return 1
        case .contained: return 2
        case .authorityNotified: return 3
        case .subjectsNotified: return 4
        case .remediating: return 5
        case .resolved: return 6
        }
    }

    public static func < (lhs: BreachStatus, rhs: BreachStatus) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Timeline entry for breach response actions
public struct BreachTimelineEntry: Sendable, Codable {
    public let timestamp: Date
    public let action: BreachAction
    public let description: String
    public let performedBy: String

    public init(
        timestamp: Date = Date(),
        action: BreachAction,
        description: String,
        performedBy: String
    ) {
        self.timestamp = timestamp
        self.action = action
        self.description = description
        self.performedBy = performedBy
    }
}

/// Breach response actions
public enum BreachAction: String, Sendable, Codable {
    case detected
    case investigationStarted
    case containmentApplied
    case impactAssessed
    case authorityNotified
    case subjectsNotified
    case remediationStarted
    case remediationCompleted
    case resolved
    case noteAdded
}

// MARK: - Notification Templates

/// Pre-built notification content for regulatory compliance
public struct BreachNotification: Sendable, Codable {
    /// Target audience
    public let audience: NotificationAudience
    /// Jurisdiction this notification targets
    public let jurisdiction: String
    /// Regulatory basis
    public let regulatoryBasis: String
    /// Required deadline (hours from discovery)
    public let deadlineHours: Int
    /// Notification content sections
    public let sections: [NotificationSection]

    public enum NotificationAudience: String, Sendable, Codable {
        case supervisoryAuthority
        case dataSubjects
    }

    public struct NotificationSection: Sendable, Codable {
        public let heading: String
        public let content: String
    }
}

// MARK: - Breach Response Manager

/// Data breach incident response manager
///
/// Manages breach incidents, tracks response timelines,
/// generates notifications, and enforces regulatory deadlines.
///
/// GDPR Art 33: Notify authority within 72 hours of awareness.
/// GDPR Art 34: Notify individuals if "high risk to rights and freedoms".
/// PIPL Art 57: Notify authority AND individuals "immediately".
///
/// Usage:
/// ```swift
/// let manager = BreachResponseManager(storageDirectory: breachDir)
///
/// // Report a breach
/// let incident = try await manager.reportBreach(
///     category: .unauthorizedAccess,
///     severity: .high,
///     description: "Unauthorized API access detected",
///     affectedDataTypes: [.captureData, .sensorData],
///     affectedJurisdictions: ["EU", "CN"]
/// )
///
/// // Check deadline
/// print("Hours remaining: \(incident.hoursUntilDeadline)")
///
/// // Generate authority notification
/// let notification = manager.generateAuthorityNotification(for: incident)
/// ```
public actor BreachResponseManager {

    private let storageDirectory: URL
    private var incidents: [BreachIncident] = []

    // MARK: - Initialization

    /// Initialize breach response manager
    ///
    /// - Parameter storageDirectory: Directory for breach incident records
    public init(storageDirectory: URL) throws {
        self.storageDirectory = storageDirectory
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        // Load existing incidents
        self.incidents = (try? Self.loadIncidents(from: storageDirectory)) ?? []
    }

    // MARK: - Report Breach

    /// Report a new data breach incident
    ///
    /// Creates an incident record, starts the 72-hour clock,
    /// and persists the incident to disk.
    ///
    /// - Returns: The created breach incident with 72-hour deadline set
    @discardableResult
    public func reportBreach(
        category: BreachCategory,
        severity: BreachSeverity,
        description: String,
        affectedDataTypes: [AffectedDataType],
        estimatedAffectedCount: Int = -1,
        affectedJurisdictions: [String] = []
    ) throws -> BreachIncident {
        let incident = BreachIncident(
            category: category,
            severity: severity,
            description: description,
            affectedDataTypes: affectedDataTypes,
            estimatedAffectedCount: estimatedAffectedCount,
            affectedJurisdictions: affectedJurisdictions
        )

        incidents.append(incident)
        try persistIncident(incident)

        return incident
    }

    // MARK: - Update Incident

    /// Add a timeline entry to an existing incident
    public func addTimelineEntry(
        incidentId: String,
        action: BreachAction,
        description: String,
        performedBy: String
    ) throws {
        guard let index = incidents.firstIndex(where: { $0.incidentId == incidentId }) else {
            return
        }

        let entry = BreachTimelineEntry(
            action: action,
            description: description,
            performedBy: performedBy
        )

        incidents[index].timeline.append(entry)

        // Auto-update status based on action
        switch action {
        case .investigationStarted:
            incidents[index].status = .investigating
        case .containmentApplied:
            incidents[index].status = .contained
        case .authorityNotified:
            incidents[index].status = .authorityNotified
        case .subjectsNotified:
            incidents[index].status = .subjectsNotified
        case .remediationStarted:
            incidents[index].status = .remediating
        case .resolved:
            incidents[index].status = .resolved
        default:
            break
        }

        try persistIncident(incidents[index])
    }

    // MARK: - Query

    /// Get all active (non-resolved) incidents
    public func activeIncidents() -> [BreachIncident] {
        incidents.filter { $0.status != .resolved }
    }

    /// Get incidents that are overdue for notification
    public func overdueIncidents() -> [BreachIncident] {
        incidents.filter { $0.isOverdue && $0.status < .authorityNotified }
    }

    /// Get incident by ID
    public func incident(id: String) -> BreachIncident? {
        incidents.first { $0.incidentId == id }
    }

    /// Get all incidents
    public func allIncidents() -> [BreachIncident] {
        incidents
    }

    // MARK: - Notification Generation

    /// Generate supervisory authority notification for a breach
    ///
    /// Produces notification content compliant with GDPR Art 33(3):
    /// (a) nature of the breach
    /// (b) DPO contact
    /// (c) likely consequences
    /// (d) measures taken/proposed
    public nonisolated func generateAuthorityNotification(
        for incident: BreachIncident
    ) -> BreachNotification {
        let dataTypesStr = incident.affectedDataTypes
            .map(\.rawValue)
            .joined(separator: ", ")

        let sections: [BreachNotification.NotificationSection] = [
            .init(
                heading: "1. Nature of the Breach",
                content: """
                    Incident ID: \(incident.incidentId)
                    Category: \(incident.category.rawValue)
                    Discovered: \(ISO8601DateFormatter().string(from: incident.discoveredAt))
                    Description: \(incident.description)
                    """
            ),
            .init(
                heading: "2. Data Protection Officer Contact",
                content: "[INSERT DPO CONTACT INFORMATION]"
            ),
            .init(
                heading: "3. Likely Consequences",
                content: """
                    Severity: \(incident.severity.rawValue)
                    Affected data types: \(dataTypesStr)
                    Estimated individuals affected: \(incident.estimatedAffectedCount == -1 ? "Under investigation" : "\(incident.estimatedAffectedCount)")
                    Affected jurisdictions: \(incident.affectedJurisdictions.joined(separator: ", "))
                    """
            ),
            .init(
                heading: "4. Measures Taken",
                content: incident.timeline.map { entry in
                    "[\(ISO8601DateFormatter().string(from: entry.timestamp))] \(entry.action.rawValue): \(entry.description)"
                }.joined(separator: "\n")
            )
        ]

        // Determine jurisdiction-specific requirements
        let isEU = incident.affectedJurisdictions.contains("EU")
        let isCN = incident.affectedJurisdictions.contains("CN")

        let jurisdiction: String
        let regulatoryBasis: String
        let deadlineHours: Int

        if isCN {
            jurisdiction = "CN"
            regulatoryBasis = "PIPL Article 57 — Immediate notification"
            deadlineHours = 0 // PIPL: "immediately"
        } else if isEU {
            jurisdiction = "EU"
            regulatoryBasis = "GDPR Article 33 — 72-hour notification"
            deadlineHours = 72
        } else {
            jurisdiction = "US"
            regulatoryBasis = "State breach notification laws (varies)"
            deadlineHours = 72 // Conservative default
        }

        return BreachNotification(
            audience: .supervisoryAuthority,
            jurisdiction: jurisdiction,
            regulatoryBasis: regulatoryBasis,
            deadlineHours: deadlineHours,
            sections: sections
        )
    }

    /// Generate data subject notification for a high-risk breach
    ///
    /// GDPR Art 34: Required when breach "is likely to result in
    /// a high risk to the rights and freedoms of natural persons"
    public nonisolated func generateSubjectNotification(
        for incident: BreachIncident
    ) -> BreachNotification? {
        guard incident.severity.requiresSubjectNotification else {
            return nil
        }

        let sections: [BreachNotification.NotificationSection] = [
            .init(
                heading: "What Happened",
                content: incident.description
            ),
            .init(
                heading: "What Data Was Affected",
                content: incident.affectedDataTypes
                    .map(\.rawValue)
                    .joined(separator: ", ")
            ),
            .init(
                heading: "What We Are Doing",
                content: incident.timeline
                    .filter { $0.action != .detected && $0.action != .noteAdded }
                    .map(\.description)
                    .joined(separator: ". ")
            ),
            .init(
                heading: "What You Can Do",
                content: "If you have concerns about your data, please contact our data protection officer at [INSERT DPO CONTACT]."
            )
        ]

        return BreachNotification(
            audience: .dataSubjects,
            jurisdiction: "ALL",
            regulatoryBasis: "GDPR Article 34 — High risk to individuals",
            deadlineHours: 0, // "Without undue delay"
            sections: sections
        )
    }

    // MARK: - Impact Assessment

    /// Assess the impact scope of a breach
    ///
    /// Returns a structured assessment useful for regulatory reporting.
    public nonisolated func assessImpact(
        for incident: BreachIncident
    ) -> BreachImpactAssessment {
        let containsBiometric = incident.affectedDataTypes.contains(.biometricData)
        let containsLocation = incident.affectedDataTypes.contains(.locationData)
        let containsSensor = incident.affectedDataTypes.contains(.sensorData)

        let riskLevel: BreachSeverity
        if containsBiometric {
            riskLevel = .critical // Biometric data = GDPR special category
        } else if containsLocation || containsSensor {
            riskLevel = max(incident.severity, .high)
        } else {
            riskLevel = incident.severity
        }

        let requiresDPIA = containsBiometric || containsLocation
        let crossBorder = incident.affectedJurisdictions.count > 1

        return BreachImpactAssessment(
            incidentId: incident.incidentId,
            assessedRiskLevel: riskLevel,
            containsSensitiveData: containsBiometric,
            crossBorderTransfer: crossBorder,
            requiresDPIA: requiresDPIA,
            requiresAuthorityNotification: riskLevel.requiresAuthorityNotification,
            requiresSubjectNotification: riskLevel.requiresSubjectNotification,
            recommendedActions: generateRecommendations(
                severity: riskLevel,
                crossBorder: crossBorder,
                containsBiometric: containsBiometric
            )
        )
    }

    // MARK: - Private

    private nonisolated func generateRecommendations(
        severity: BreachSeverity,
        crossBorder: Bool,
        containsBiometric: Bool
    ) -> [String] {
        var actions: [String] = []

        actions.append("Contain the breach immediately — isolate affected systems")
        actions.append("Preserve evidence for forensic analysis")

        if severity.requiresAuthorityNotification {
            actions.append("Notify supervisory authority within 72 hours (GDPR) or immediately (PIPL)")
        }
        if severity.requiresSubjectNotification {
            actions.append("Notify affected individuals without undue delay")
        }
        if crossBorder {
            actions.append("Coordinate with lead supervisory authority for cross-border notification")
        }
        if containsBiometric {
            actions.append("CRITICAL: Biometric data exposed — consider mandatory DPIA update")
            actions.append("Verify if biometric templates can be revoked/rotated")
        }

        actions.append("Document all response actions for accountability (GDPR Art 5(2))")
        actions.append("Conduct post-incident review within 30 days")

        return actions
    }

    private func persistIncident(_ incident: BreachIncident) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(incident)
        let fileURL = storageDirectory.appendingPathComponent("\(incident.incidentId).json")
        try data.write(to: fileURL)
    }

    private static func loadIncidents(from directory: URL) throws -> [BreachIncident] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(BreachIncident.self, from: data)
        }
    }
}

// MARK: - Impact Assessment

/// Result of a breach impact assessment
public struct BreachImpactAssessment: Sendable, Codable {
    public let incidentId: String
    public let assessedRiskLevel: BreachSeverity
    public let containsSensitiveData: Bool
    public let crossBorderTransfer: Bool
    public let requiresDPIA: Bool
    public let requiresAuthorityNotification: Bool
    public let requiresSubjectNotification: Bool
    public let recommendedActions: [String]
}
