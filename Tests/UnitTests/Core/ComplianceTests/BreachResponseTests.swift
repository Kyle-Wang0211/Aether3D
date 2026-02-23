// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BreachResponseTests.swift
// Aether3D
//
// Tests for BreachResponseFramework.
//

import XCTest
@testable import Aether3DCore

final class BreachResponseTests: XCTestCase {

    var tempDir: URL!
    var manager: BreachResponseManager!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("breach_test_\(UUID().uuidString)")
        manager = try BreachResponseManager(storageDirectory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Report Breach

    func testReportBreach_CreatesIncident() async throws {
        let incident = try await manager.reportBreach(
            category: .unauthorizedAccess,
            severity: .high,
            description: "Test breach",
            affectedDataTypes: [.captureData],
            affectedJurisdictions: ["EU"]
        )

        XCTAssertFalse(incident.incidentId.isEmpty)
        XCTAssertEqual(incident.category, .unauthorizedAccess)
        XCTAssertEqual(incident.severity, .high)
        XCTAssertEqual(incident.status, .detected)
        XCTAssertEqual(incident.timeline.count, 1) // Auto-added detection event
        XCTAssertEqual(incident.timeline[0].action, .detected)
    }

    func testReportBreach_72HourDeadline() async throws {
        let incident = try await manager.reportBreach(
            category: .dataLoss,
            severity: .medium,
            description: "Lost device",
            affectedDataTypes: [.sensorData]
        )

        // Deadline should be ~72 hours from now
        let expectedDeadline = incident.discoveredAt.addingTimeInterval(72 * 3600)
        XCTAssertEqual(
            incident.notificationDeadline.timeIntervalSince1970,
            expectedDeadline.timeIntervalSince1970,
            accuracy: 1.0
        )

        // Should not be overdue yet
        XCTAssertFalse(incident.isOverdue)
        XCTAssertTrue(incident.hoursUntilDeadline > 71.0)
    }

    func testReportBreach_PersistsToDisk() async throws {
        let incident = try await manager.reportBreach(
            category: .vulnerabilityExploit,
            severity: .critical,
            description: "Persistence test",
            affectedDataTypes: [.biometricData]
        )

        let fileURL = tempDir.appendingPathComponent("\(incident.incidentId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Timeline Updates

    func testAddTimelineEntry_UpdatesStatus() async throws {
        let incident = try await manager.reportBreach(
            category: .unauthorizedAccess,
            severity: .high,
            description: "Timeline test",
            affectedDataTypes: [.captureData]
        )

        try await manager.addTimelineEntry(
            incidentId: incident.incidentId,
            action: .investigationStarted,
            description: "Forensic analysis started",
            performedBy: "security_team"
        )

        let updated = await manager.incident(id: incident.incidentId)
        XCTAssertEqual(updated?.status, .investigating)
        XCTAssertEqual(updated?.timeline.count, 2)
    }

    func testAddTimelineEntry_ContainmentUpdatesStatus() async throws {
        let incident = try await manager.reportBreach(
            category: .ransomware,
            severity: .critical,
            description: "Containment test",
            affectedDataTypes: [.captureData, .sensorData]
        )

        try await manager.addTimelineEntry(
            incidentId: incident.incidentId,
            action: .containmentApplied,
            description: "Isolated affected systems",
            performedBy: "ops_team"
        )

        let updated = await manager.incident(id: incident.incidentId)
        XCTAssertEqual(updated?.status, .contained)
    }

    // MARK: - Queries

    func testActiveIncidents_ExcludesResolved() async throws {
        let i1 = try await manager.reportBreach(
            category: .dataLoss, severity: .low,
            description: "Active breach", affectedDataTypes: [.sensorData]
        )
        let i2 = try await manager.reportBreach(
            category: .wrongRecipient, severity: .medium,
            description: "Resolved breach", affectedDataTypes: [.consentRecords]
        )

        // Resolve i2
        try await manager.addTimelineEntry(
            incidentId: i2.incidentId, action: .resolved,
            description: "Resolved", performedBy: "admin"
        )

        let active = await manager.activeIncidents()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].incidentId, i1.incidentId)
    }

    // MARK: - Severity Classification

    func testSeverity_AuthorityNotificationRequired() {
        XCTAssertFalse(BreachSeverity.low.requiresAuthorityNotification)
        XCTAssertTrue(BreachSeverity.medium.requiresAuthorityNotification)
        XCTAssertTrue(BreachSeverity.high.requiresAuthorityNotification)
        XCTAssertTrue(BreachSeverity.critical.requiresAuthorityNotification)
    }

    func testSeverity_SubjectNotificationRequired() {
        XCTAssertFalse(BreachSeverity.low.requiresSubjectNotification)
        XCTAssertFalse(BreachSeverity.medium.requiresSubjectNotification)
        XCTAssertTrue(BreachSeverity.high.requiresSubjectNotification)
        XCTAssertTrue(BreachSeverity.critical.requiresSubjectNotification)
    }

    func testSeverity_Comparable() {
        XCTAssertTrue(BreachSeverity.low < BreachSeverity.medium)
        XCTAssertTrue(BreachSeverity.medium < BreachSeverity.high)
        XCTAssertTrue(BreachSeverity.high < BreachSeverity.critical)
    }

    // MARK: - Notification Generation

    func testGenerateAuthorityNotification_GDPR() async throws {
        let incident = try await manager.reportBreach(
            category: .unauthorizedAccess,
            severity: .high,
            description: "EU breach",
            affectedDataTypes: [.captureData],
            affectedJurisdictions: ["EU"]
        )

        let notification = await manager.generateAuthorityNotification(for: incident)

        XCTAssertEqual(notification.audience, .supervisoryAuthority)
        XCTAssertEqual(notification.jurisdiction, "EU")
        XCTAssertEqual(notification.deadlineHours, 72)
        XCTAssertTrue(notification.regulatoryBasis.contains("GDPR"))
        XCTAssertEqual(notification.sections.count, 4)
    }

    func testGenerateAuthorityNotification_PIPL() async throws {
        let incident = try await manager.reportBreach(
            category: .dataLoss,
            severity: .critical,
            description: "China breach",
            affectedDataTypes: [.biometricData],
            affectedJurisdictions: ["CN"]
        )

        let notification = await manager.generateAuthorityNotification(for: incident)

        XCTAssertEqual(notification.jurisdiction, "CN")
        XCTAssertEqual(notification.deadlineHours, 0) // PIPL: immediately
        XCTAssertTrue(notification.regulatoryBasis.contains("PIPL"))
    }

    func testGenerateSubjectNotification_HighSeverity() async throws {
        let incident = try await manager.reportBreach(
            category: .unauthorizedAccess,
            severity: .high,
            description: "Subject notification test",
            affectedDataTypes: [.captureData, .sensorData]
        )

        let notification = await manager.generateSubjectNotification(for: incident)
        XCTAssertNotNil(notification)
        XCTAssertEqual(notification?.audience, .dataSubjects)
    }

    func testGenerateSubjectNotification_LowSeverity_ReturnsNil() async throws {
        let incident = try await manager.reportBreach(
            category: .accidentalDeletion,
            severity: .low,
            description: "Low severity",
            affectedDataTypes: [.sensorData]
        )

        let notification = await manager.generateSubjectNotification(for: incident)
        XCTAssertNil(notification, "Low severity should not require subject notification")
    }

    // MARK: - Impact Assessment

    func testAssessImpact_BiometricData_Critical() async throws {
        let incident = try await manager.reportBreach(
            category: .unauthorizedAccess,
            severity: .medium,
            description: "Biometric breach",
            affectedDataTypes: [.biometricData, .captureData],
            affectedJurisdictions: ["EU", "CN"]
        )

        let assessment = await manager.assessImpact(for: incident)

        XCTAssertEqual(assessment.assessedRiskLevel, .critical) // Biometric → critical
        XCTAssertTrue(assessment.containsSensitiveData)
        XCTAssertTrue(assessment.crossBorderTransfer)
        XCTAssertTrue(assessment.requiresDPIA)
        XCTAssertTrue(assessment.requiresAuthorityNotification)
        XCTAssertTrue(assessment.requiresSubjectNotification)
        XCTAssertTrue(assessment.recommendedActions.count > 0)
    }

    func testAssessImpact_SensorData_ElevatedRisk() async throws {
        let incident = try await manager.reportBreach(
            category: .dataLoss,
            severity: .medium,
            description: "Sensor breach",
            affectedDataTypes: [.sensorData]
        )

        let assessment = await manager.assessImpact(for: incident)

        XCTAssertEqual(assessment.assessedRiskLevel, .high) // Sensor data → elevated
        XCTAssertFalse(assessment.containsSensitiveData)
    }

    // MARK: - BreachStatus Comparable

    func testBreachStatus_Ordering() {
        XCTAssertTrue(BreachStatus.detected < BreachStatus.investigating)
        XCTAssertTrue(BreachStatus.investigating < BreachStatus.contained)
        XCTAssertTrue(BreachStatus.contained < BreachStatus.authorityNotified)
        XCTAssertTrue(BreachStatus.authorityNotified < BreachStatus.resolved)
    }
}
