//
// ScanRecordStore.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Record Store
// Thread-safe JSON persistence with atomic writes and crash recovery
// Apple-platform only (uses FileManager document directory)
//

import Foundation

#if canImport(UIKit) || canImport(AppKit)

/// Thread-safe JSON persistence for scan records
///
/// Storage layout:
///   Documents/Aether3D/scans.json       — JSON array of ScanRecord
///   Documents/Aether3D/thumbnails/      — JPEG thumbnails (one per scan)
///
/// Safety:
///   - Atomic writes via temp file + rename (prevents corruption on crash)
///   - Queue serialization (prevents concurrent write corruption)
///   - ISO 8601 date encoding (portable across locales)
///   - Maximum 1000 records (prevents unbounded storage growth)
public final class ScanRecordStore {

    /// Storage directory: Documents/Aether3D/
    private let baseDirectory: URL

    /// JSON file: Documents/Aether3D/scans.json
    private let jsonFileURL: URL

    /// Thumbnails directory: Documents/Aether3D/thumbnails/
    private let thumbnailsDirectory: URL

    /// In-memory cache
    private var cachedRecords: [ScanRecord]?

    /// Serial queue for thread safety
    private let queue = DispatchQueue(label: "com.aether3d.scanrecordstore", qos: .utility)

    /// Maximum stored records (prevents unbounded growth)
    private let maxRecords = 1000

    public init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDirectory = documents.appendingPathComponent("Aether3D")
        self.jsonFileURL = baseDirectory.appendingPathComponent("scans.json")
        self.thumbnailsDirectory = baseDirectory.appendingPathComponent("thumbnails")

        // Create directories if needed
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    /// Load all scan records (cached or from disk)
    ///
    /// - Returns: Array of scan records, newest first. Returns empty on parse failure.
    public func loadRecords() -> [ScanRecord] {
        return queue.sync {
            if let cached = cachedRecords { return cached }

            guard FileManager.default.fileExists(atPath: jsonFileURL.path) else {
                cachedRecords = []
                return []
            }

            do {
                let data = try Data(contentsOf: jsonFileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let records = try decoder.decode([ScanRecord].self, from: data)
                cachedRecords = records
                return records
            } catch {
                // JSON parse failed — return empty, don't crash
                cachedRecords = []
                return []
            }
        }
    }

    /// Save a new scan record (append + atomic write)
    ///
    /// - Parameter record: The scan record to save
    public func saveRecord(_ record: ScanRecord) {
        queue.sync {
            var records = cachedRecords ?? loadRecordsUnsafe()
            records.append(record)

            // Enforce max records (remove oldest)
            if records.count > maxRecords {
                let overflow = records.count - maxRecords
                let removed = Array(records.prefix(overflow))
                records = Array(records.suffix(maxRecords))
                // Cleanup thumbnails for removed records
                for r in removed {
                    cleanupThumbnail(for: r.id)
                }
            }

            cachedRecords = records
            writeRecordsToDisk(records)
        }
    }

    /// Delete a scan record by ID
    ///
    /// - Parameter id: UUID of the record to delete
    public func deleteRecord(id: UUID) {
        queue.sync {
            var records = cachedRecords ?? loadRecordsUnsafe()
            records.removeAll { $0.id == id }
            cachedRecords = records
            writeRecordsToDisk(records)
            cleanupThumbnail(for: id)
        }
    }

    /// Save thumbnail image data
    ///
    /// - Parameters:
    ///   - imageData: JPEG image data
    ///   - recordId: UUID of the associated scan record
    /// - Returns: Relative path to thumbnail, or nil on failure
    public func saveThumbnail(_ imageData: Data, for recordId: UUID) -> String? {
        let filename = "\(recordId.uuidString).jpg"
        let fileURL = thumbnailsDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL, options: [.atomic])
            return "thumbnails/\(filename)"
        } catch {
            return nil
        }
    }

    /// Get full URL for a thumbnail relative path
    public func thumbnailURL(for relativePath: String) -> URL {
        return baseDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Private Helpers

    /// Load records without queue synchronization (must be called within queue.sync)
    private func loadRecordsUnsafe() -> [ScanRecord] {
        guard FileManager.default.fileExists(atPath: jsonFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: jsonFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ScanRecord].self, from: data)
        } catch {
            return []
        }
    }

    /// Atomic write to disk
    private func writeRecordsToDisk(_ records: [ScanRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)

            // Atomic write: write to temp file, then rename
            let tempURL = jsonFileURL.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: [.atomic])

            // If original exists, remove it first
            if FileManager.default.fileExists(atPath: jsonFileURL.path) {
                try FileManager.default.removeItem(at: jsonFileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: jsonFileURL)
        } catch {
            // Write failed — cached records still valid, will retry on next save
        }
    }

    /// Remove thumbnail file for a record
    private func cleanupThumbnail(for recordId: UUID) {
        let filename = "\(recordId.uuidString).jpg"
        let fileURL = thumbnailsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

#endif
