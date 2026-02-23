// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ComplianceManager.swift
// Aether3D
//
// High-level facade for compliance operations.
// Single entry point for consent management and data retention enforcement.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Compliance manager — single entry point for all compliance operations
///
/// Ties together:
/// - `ConsentStorage`: encrypted persistent consent records
/// - `RetentionPurgeEngine`: data retention enforcement with audit trail
///
/// Usage:
/// ```swift
/// let manager = try ComplianceManager(
///     databaseDirectory: appSupportDir.appendingPathComponent("compliance"),
///     encryptionKey: masterKey
/// )
///
/// // On app startup
/// let purgeResult = try await manager.onAppStartup(walStorage: walStorage)
///
/// // Record consent
/// try await manager.recordConsent(operation: "3d_capture", state: .granted)
///
/// // Check consent before data collection
/// if try await manager.isConsentValid(operation: "3d_capture") {
///     // proceed with capture
/// }
/// ```
public actor ComplianceManager {

    private let consentStorage: ConsentStorage
    private let purgeEngine: RetentionPurgeEngine

    // MARK: - Initialization

    /// Initialize compliance manager
    ///
    /// - Parameters:
    ///   - databaseDirectory: Directory for compliance databases and audit logs
    ///   - encryptionKey: Master encryption key for consent storage (256-bit)
    ///   - policies: Optional custom retention policies (defaults to PIPL + GDPR)
    public init(
        databaseDirectory: URL,
        encryptionKey: SymmetricKey,
        policies: [RetentionPolicy]? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )

        let dbPath = databaseDirectory
            .appendingPathComponent("consent.db").path

        let auditLogDir = databaseDirectory
            .appendingPathComponent("purge_audit")

        self.consentStorage = try ConsentStorage(
            dbPath: dbPath,
            encryptionKey: encryptionKey
        )

        self.purgeEngine = try RetentionPurgeEngine(
            policies: policies,
            auditLogDirectory: auditLogDir
        )
    }

    // MARK: - Consent Operations

    /// Record a consent decision
    @discardableResult
    public func recordConsent(
        operation: String,
        state: PersistentConsentState,
        expirationDays: Int = ComplianceConstants.gdprDataRetentionDays,
        metadata: [String: String]? = nil
    ) async throws -> PersistentConsentRecord {
        return try await consentStorage.recordConsent(
            operation: operation,
            state: state,
            expirationDays: expirationDays,
            metadata: metadata
        )
    }

    /// Query the most recent consent for an operation
    public func queryConsent(operation: String) async throws -> PersistentConsentRecord? {
        return try await consentStorage.queryConsent(operation: operation)
    }

    /// Withdraw consent for an operation
    @discardableResult
    public func withdrawConsent(operation: String) async throws -> PersistentConsentRecord {
        return try await consentStorage.withdrawConsent(operation: operation)
    }

    /// Check if consent is currently valid for an operation
    public func isConsentValid(operation: String) async throws -> Bool {
        return try await consentStorage.isConsentValid(operation: operation)
    }

    // MARK: - Retention Operations

    /// Run full retention purge
    public func runRetentionPurge(
        walStorage: SQLiteWALStorage? = nil,
        fileDirectories: [URL] = []
    ) async throws -> PurgeResult {
        return try await purgeEngine.runFullPurge(
            walStorage: walStorage,
            consentStorage: consentStorage,
            fileDirectories: fileDirectories
        )
    }

    // MARK: - App Lifecycle

    /// Run on app startup to enforce retention and clean expired data
    ///
    /// This should be called early in the app lifecycle.
    /// It purges expired consent records and enforces data retention policies.
    public func onAppStartup(
        walStorage: SQLiteWALStorage? = nil,
        fileDirectories: [URL] = []
    ) async throws -> PurgeResult {
        return try await runRetentionPurge(
            walStorage: walStorage,
            fileDirectories: fileDirectories
        )
    }

    // MARK: - Close

    /// Close all resources
    public func close() async throws {
        try await consentStorage.close()
    }
}
