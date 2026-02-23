// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AnonymizedFileStore.swift
// Aether3D
//
// File-based storage for anonymized data.
// Anonymized data is stored permanently (legal — no longer personal data).
//

import Foundation

/// File-based storage for anonymized assets
///
/// Stores anonymized data as files in a designated directory.
/// Each asset gets a UUID-based filename with its metadata stored as a sidecar JSON.
///
/// Since anonymized data is no longer "personal data" under GDPR/PIPL,
/// it can be stored permanently and used for model training.
public actor AnonymizedFileStore: AnonymizedDataStore {

    private let storageDirectory: URL

    /// Initialize file store
    ///
    /// - Parameter storageDirectory: Directory for anonymized assets
    public init(storageDirectory: URL) throws {
        self.storageDirectory = storageDirectory
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Store anonymized data and its metadata
    ///
    /// - Parameters:
    ///   - data: Anonymized data (image, point cloud, etc.)
    ///   - metadata: Associated metadata (original file ID, regions masked, consent ID)
    /// - Returns: Storage identifier (UUID string)
    public func store(data: Data, metadata: AssetMetadata) async throws -> String {
        let assetId = UUID().uuidString

        // Write anonymized data
        let dataURL = storageDirectory.appendingPathComponent("\(assetId).dat")
        try data.write(to: dataURL)

        // Write metadata sidecar
        let metadataURL = storageDirectory.appendingPathComponent("\(assetId).meta.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL)

        return assetId
    }

    /// Read anonymized data by storage ID
    public func read(assetId: String) throws -> (data: Data, metadata: AssetMetadata) {
        let dataURL = storageDirectory.appendingPathComponent("\(assetId).dat")
        let metadataURL = storageDirectory.appendingPathComponent("\(assetId).meta.json")

        let data = try Data(contentsOf: dataURL)
        let metadataData = try Data(contentsOf: metadataURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let metadata = try decoder.decode(AssetMetadata.self, from: metadataData)

        return (data, metadata)
    }

    /// List all stored asset IDs
    public func listAssets() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "dat" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Count of stored assets
    public func assetCount() throws -> Int {
        return try listAssets().count
    }
}
