// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AnonymizationPipeline.swift
// Aether3D
//
// 方案A anonymization pipeline:
//   1. Check user consent (ConsentStorage)
//   2. Detect sensitive regions in capture data
//   3. Apply irreversible anonymization (masking)
//   4. Store anonymized data permanently (for training)
//   5. Securely delete original data
//
// Anonymized data is no longer "personal data" under GDPR/PIPL,
// so it can be stored permanently and used for training.
//

import Foundation

// MARK: - Protocols

/// Detects sensitive regions (faces, license plates, text) in raw capture data.
///
/// Implement this protocol to bridge to your actual detection engine
/// (Vision framework, CoreML model, PrivacyMaskEnforcer, etc.)
public protocol SensitiveRegionDetector: Sendable {
    /// Detect sensitive regions in raw data
    /// - Parameter rawData: Raw capture data (image frame, point cloud, etc.)
    /// - Returns: Detected regions that need anonymization
    func detectSensitiveRegions(in rawData: Data) async throws -> [SensitiveRegion]
}

/// Applies irreversible anonymization to raw data given detected regions.
///
/// "Irreversible" means the original content in masked regions
/// cannot be recovered from the output.
public protocol DataAnonymizer: Sendable {
    /// Anonymize raw data by masking sensitive regions
    /// - Parameters:
    ///   - rawData: Original raw data
    ///   - regions: Regions to anonymize
    /// - Returns: Anonymized data (original content in regions is destroyed)
    func anonymize(rawData: Data, regions: [SensitiveRegion]) async throws -> Data
}

/// Stores anonymized data permanently.
public protocol AnonymizedDataStore: Sendable {
    /// Store anonymized data
    /// - Parameters:
    ///   - data: Anonymized data
    ///   - metadata: Associated metadata
    /// - Returns: Storage identifier
    func store(data: Data, metadata: AssetMetadata) async throws -> String
}

/// Securely deletes original (pre-anonymization) data.
public protocol SecureDataDeleter: Sendable {
    /// Securely delete data at the given path
    /// - Parameter path: File URL of data to delete
    /// - Returns: Whether deletion was successful
    func secureDelete(at path: URL) async throws -> Bool
}

// MARK: - Data Types

/// A sensitive region detected in capture data
public struct SensitiveRegion: Sendable {
    public let id: UUID
    public let type: RegionType
    public let bounds: RegionBounds
    public let confidence: Double

    public enum RegionType: String, Sendable, Codable {
        case face
        case licensePlate
        case text
        case custom
    }

    public struct RegionBounds: Sendable, Codable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(
        id: UUID = UUID(),
        type: RegionType,
        bounds: RegionBounds,
        confidence: Double = 1.0
    ) {
        self.id = id
        self.type = type
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// Metadata for an anonymized asset
public struct AssetMetadata: Sendable, Codable {
    public let originalFileId: String
    public let anonymizedAt: Date
    public let regionsAnonymized: Int
    public let regionTypes: [String]
    public let consentId: String

    public init(
        originalFileId: String,
        anonymizedAt: Date = Date(),
        regionsAnonymized: Int,
        regionTypes: [String],
        consentId: String
    ) {
        self.originalFileId = originalFileId
        self.anonymizedAt = anonymizedAt
        self.regionsAnonymized = regionsAnonymized
        self.regionTypes = regionTypes
        self.consentId = consentId
    }
}

/// Result of processing one item through the pipeline
public struct AnonymizationResult: Sendable {
    public let fileId: String
    public let storageId: String
    public let regionsDetected: Int
    public let regionsAnonymized: Int
    public let originalDeleted: Bool
    public let timestamp: Date
    public let consentId: String

    /// Whether the data had sensitive content that was anonymized
    public var hadSensitiveContent: Bool {
        regionsDetected > 0
    }
}

/// Pipeline errors
public enum AnonymizationPipelineError: Error, Sendable {
    case consentNotGranted(operation: String)
    case detectionFailed(String)
    case anonymizationFailed(String)
    case storageFailed(String)
    case deletionFailed(String)

    public var localizedDescription: String {
        switch self {
        case .consentNotGranted(let op):
            return "Consent not granted for operation: \(op)"
        case .detectionFailed(let r):
            return "Sensitive region detection failed: \(r)"
        case .anonymizationFailed(let r):
            return "Anonymization failed: \(r)"
        case .storageFailed(let r):
            return "Anonymized data storage failed: \(r)"
        case .deletionFailed(let r):
            return "Original data deletion failed: \(r)"
        }
    }
}

// MARK: - Pipeline

/// Anonymization pipeline — the core of 方案A
///
/// Orchestrates the full flow:
/// 1. **Consent check** → refuse to process if user hasn't granted consent
/// 2. **Detection** → find faces, license plates, text in raw data
/// 3. **Anonymization** → irreversibly mask detected regions
/// 4. **Storage** → save anonymized data permanently (legal for training)
/// 5. **Deletion** → securely delete original raw data
///
/// Usage:
/// ```swift
/// let pipeline = AnonymizationPipeline(
///     consentStorage: consentStorage,
///     detector: myDetector,
///     anonymizer: myAnonymizer,
///     store: myStore,
///     deleter: myDeleter,
///     consentOperation: "3d_capture"
/// )
///
/// let result = try await pipeline.process(
///     fileId: "capture_001",
///     rawData: frameData,
///     originalPath: frameURL
/// )
/// ```
public actor AnonymizationPipeline {

    private let consentStorage: ConsentStorage
    private let detector: SensitiveRegionDetector
    private let anonymizer: DataAnonymizer
    private let store: AnonymizedDataStore
    private let deleter: SecureDataDeleter
    private let consentOperation: String

    /// Processing history (bounded)
    private var history: [AnonymizationResult] = []

    // MARK: - Initialization

    /// Initialize the anonymization pipeline
    ///
    /// - Parameters:
    ///   - consentStorage: Persistent consent storage for consent checks
    ///   - detector: Detects sensitive regions in raw data
    ///   - anonymizer: Applies irreversible masking
    ///   - store: Stores anonymized data permanently
    ///   - deleter: Securely deletes original data
    ///   - consentOperation: The consent operation key to check (e.g., "3d_capture")
    public init(
        consentStorage: ConsentStorage,
        detector: SensitiveRegionDetector,
        anonymizer: DataAnonymizer,
        store: AnonymizedDataStore,
        deleter: SecureDataDeleter,
        consentOperation: String = "data_collection"
    ) {
        self.consentStorage = consentStorage
        self.detector = detector
        self.anonymizer = anonymizer
        self.store = store
        self.deleter = deleter
        self.consentOperation = consentOperation
    }

    // MARK: - Process

    /// Process a single capture through the full anonymization pipeline
    ///
    /// - Parameters:
    ///   - fileId: Identifier for the original file
    ///   - rawData: Raw capture data (image frame, point cloud, etc.)
    ///   - originalPath: File path of the original data (will be securely deleted)
    /// - Returns: Result describing what was detected, anonymized, and stored
    /// - Throws: `AnonymizationPipelineError` if any step fails
    public func process(
        fileId: String,
        rawData: Data,
        originalPath: URL
    ) async throws -> AnonymizationResult {

        // Step 1: Check consent
        let consentValid = try await consentStorage.isConsentValid(operation: consentOperation)
        guard consentValid else {
            throw AnonymizationPipelineError.consentNotGranted(operation: consentOperation)
        }

        // Get consent record for audit trail
        let consentRecord = try await consentStorage.queryConsent(operation: consentOperation)
        let consentId = consentRecord?.id ?? "unknown"

        // Step 2: Detect sensitive regions
        let regions: [SensitiveRegion]
        do {
            regions = try await detector.detectSensitiveRegions(in: rawData)
        } catch {
            throw AnonymizationPipelineError.detectionFailed("\(error)")
        }

        // Step 3: Anonymize (even if no regions detected, still run anonymizer
        // to ensure consistent output format)
        let anonymizedData: Data
        do {
            anonymizedData = try await anonymizer.anonymize(rawData: rawData, regions: regions)
        } catch {
            throw AnonymizationPipelineError.anonymizationFailed("\(error)")
        }

        // Step 4: Store anonymized data permanently
        let metadata = AssetMetadata(
            originalFileId: fileId,
            regionsAnonymized: regions.count,
            regionTypes: regions.map { $0.type.rawValue },
            consentId: consentId
        )

        let storageId: String
        do {
            storageId = try await store.store(data: anonymizedData, metadata: metadata)
        } catch {
            throw AnonymizationPipelineError.storageFailed("\(error)")
        }

        // Step 5: Securely delete original data
        let deleted: Bool
        do {
            deleted = try await deleter.secureDelete(at: originalPath)
        } catch {
            throw AnonymizationPipelineError.deletionFailed("\(error)")
        }

        let result = AnonymizationResult(
            fileId: fileId,
            storageId: storageId,
            regionsDetected: regions.count,
            regionsAnonymized: regions.count,
            originalDeleted: deleted,
            timestamp: Date(),
            consentId: consentId
        )

        // Record in bounded history
        history.append(result)
        if history.count > 1000 {
            history.removeFirst()
        }

        return result
    }

    // MARK: - Batch Processing

    /// Process multiple captures through the pipeline
    ///
    /// Processes sequentially to avoid overwhelming the system.
    /// Stops on first consent failure, continues through other errors.
    public func processBatch(
        items: [(fileId: String, rawData: Data, originalPath: URL)]
    ) async throws -> [Result<AnonymizationResult, Error>] {

        // Single consent check for the batch
        let consentValid = try await consentStorage.isConsentValid(operation: consentOperation)
        guard consentValid else {
            throw AnonymizationPipelineError.consentNotGranted(operation: consentOperation)
        }

        var results: [Result<AnonymizationResult, Error>] = []

        for item in items {
            do {
                let result = try await process(
                    fileId: item.fileId,
                    rawData: item.rawData,
                    originalPath: item.originalPath
                )
                results.append(.success(result))
            } catch {
                results.append(.failure(error))
            }
        }

        return results
    }

    // MARK: - Query

    /// Get processing history
    public func getHistory() -> [AnonymizationResult] {
        return history
    }

    /// Get count of items processed
    public func processedCount() -> Int {
        return history.count
    }
}
