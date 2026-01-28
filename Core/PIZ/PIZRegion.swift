//
// PIZRegion.swift
// Aether3D
//
// PR1 PIZ Detection - Region Structure
//
// Defines the structure for a detected PIZ region.

import Foundation

/// Bounding box for a region (grid coordinates).
public struct BoundingBox: Codable, Equatable {
    public let minRow: Int
    public let maxRow: Int
    public let minCol: Int
    public let maxCol: Int
    
    public init(minRow: Int, maxRow: Int, minCol: Int, maxCol: Int) {
        self.minRow = minRow
        self.maxRow = maxRow
        self.minCol = minCol
        self.maxCol = maxCol
    }
    
    /// Width of the bounding box (columns).
    public var width: Int {
        return maxCol - minCol + 1
    }
    
    /// Height of the bounding box (rows).
    public var height: Int {
        return maxRow - minRow + 1
    }
}

/// Point in grid coordinates.
public struct Point: Codable, Equatable {
    public let row: Double
    public let col: Double
    
    public init(row: Double, col: Double) {
        self.row = row
        self.col = col
    }
}

/// Vector in grid coordinates.
public struct Vector: Codable, Equatable {
    public let dx: Double
    public let dy: Double
    
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
    
    /// Normalize the vector to unit length.
    public func normalized() -> Vector {
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.0 else {
            return Vector(dx: 0.0, dy: 0.0)
        }
        return Vector(dx: dx / length, dy: dy / length)
    }
}

/// Detected PIZ region.
public struct PIZRegion: Codable, Equatable {
    /// Unique identifier for the region (deterministic, based on bbox hash).
    public let id: String
    
    /// Number of pixels in the region.
    public let pixelCount: Int
    
    /// Area ratio: region pixels / total grid pixels.
    public let areaRatio: Double
    
    /// Bounding box of the region.
    public let bbox: BoundingBox
    
    /// Centroid of the region.
    public let centroid: Point
    
    /// Principal direction vector (from centroid to farthest point in bbox).
    public let principalDirection: Vector
    
    /// Severity score (0.0-1.0, computed from coverage_local).
    /// Higher gap = higher severity.
    public let severityScore: Double
    
    public init(
        id: String,
        pixelCount: Int,
        areaRatio: Double,
        bbox: BoundingBox,
        centroid: Point,
        principalDirection: Vector,
        severityScore: Double
    ) {
        self.id = id
        self.pixelCount = pixelCount
        self.areaRatio = areaRatio
        self.bbox = bbox
        self.centroid = centroid
        self.principalDirection = principalDirection
        self.severityScore = severityScore
    }
}

/// Recapture suggestion priority.
public enum RecapturePriority: String, Codable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

/// Structured recapture suggestion.
public struct RecaptureSuggestion: Codable, Equatable {
    /// Region IDs requiring recapture.
    public let suggestedRegions: [String]
    
    /// Priority level.
    public let priority: RecapturePriority
    
    /// Explanation for UI.
    public let reason: String
    
    public init(
        suggestedRegions: [String],
        priority: RecapturePriority,
        reason: String
    ) {
        self.suggestedRegions = suggestedRegions
        self.priority = priority
        self.reason = reason
    }
}
