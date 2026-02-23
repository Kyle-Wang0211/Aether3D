//
// ScanRecord.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Record Data Model
// Cross-platform data model (Foundation-only, no platform imports)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI  // For Identifiable in older iOS
#endif

/// Scan record for gallery display and JSON persistence
///
/// Each completed scan produces one ScanRecord containing metadata:
/// coverage quality, triangle count, duration, and paths to artifacts.
/// Records are persisted as JSON in Documents/Aether3D/scans.json.
public struct ScanRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var thumbnailPath: String?       // Relative path: "thumbnails/{id}.jpg"
    public var artifactPath: String?        // .splat file path (future NFT mint)
    public var coveragePercentage: Double   // Final coverage [0, 1]
    public var triangleCount: Int           // Total mesh triangles
    public var durationSeconds: TimeInterval // Scan duration

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        createdAt: Date = Date(),
        thumbnailPath: String? = nil,
        artifactPath: String? = nil,
        coveragePercentage: Double = 0.0,
        triangleCount: Int = 0,
        durationSeconds: TimeInterval = 0.0
    ) {
        self.id = id
        self.name = name ?? Self.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.thumbnailPath = thumbnailPath
        self.artifactPath = artifactPath
        self.coveragePercentage = max(0.0, min(1.0, coveragePercentage))
        self.triangleCount = max(0, triangleCount)
        self.durationSeconds = max(0, durationSeconds)
    }

    /// Default name: "扫描 YYYY-MM-DD HH:mm"
    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "扫描 \(formatter.string(from: date))"
    }
}
