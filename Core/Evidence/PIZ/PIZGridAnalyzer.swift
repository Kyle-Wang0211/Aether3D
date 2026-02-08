//
// PIZGridAnalyzer.swift
// Aether3D
//
// PR6 Evidence Grid System - Grid-based PIZ Analyzer
// Connected component analysis on EvidenceGrid cells with occlusion hardening
//

import Foundation

/// **Rule ID:** PR6_GRID_PIZ_001
/// Grid-based PIZ Analyzer
/// Analyzes EvidenceGrid cells for persistently insufficient zones
/// Note: This is NEW grid-based analysis logic, NOT replacing existing Core/PIZ/PIZDetector.swift
public final class PIZGridAnalyzer: @unchecked Sendable {
    
    /// Persistence window (30 seconds)
    private let persistenceWindowSec: Double = 30.0
    
    /// Improvement threshold (per second)
    private let improvementThreshold: Double = 0.01
    
    /// Minimum area in square meters
    private let minAreaSqM: Double = 0.001
    
    /// Minimum occlusion view directions
    private let minOcclusionViewDirections: Int = 3
    
    /// Last update timestamp (monotonic milliseconds)
    private var lastUpdateMonotonicMs: Int64 = 0
    
    /// Tracked regions (regionId -> region data)
    /// Note: Using existing PIZRegion from Core/PIZ/PIZRegion.swift
    /// For PR6, we create a simplified region representation
    private struct GridPIZRegion: Sendable {
        let regionId: UInt64
        let areaSqM: Double
        let boundingBox: (min: EvidenceVector3, max: EvidenceVector3)
        let occlusionLikelihood: Double
        let persistedSeconds: Double
        let lastImprovementPerSec: Double
    }
    
    private var trackedRegions: [UInt64: GridPIZRegion] = [:]
    
    public init() {
        self.lastUpdateMonotonicMs = MonotonicClock.nowMs()
    }
    
    /// **Rule ID:** PR6_GRID_PIZ_002
    /// Update PIZ analysis from EvidenceGrid cells
    ///
    /// - Parameter grid: EvidenceGrid instance
    /// - Returns: Array of PIZ regions (converted to existing PIZRegion format)
    public func update(grid: EvidenceGrid) async -> [PIZRegion] {
        let currentMonotonicMs = MonotonicClock.nowMs()
        let deltaTimeMs = currentMonotonicMs - lastUpdateMonotonicMs
        
        // Handle non-monotonic time
        let deltaTimeSeconds: Double
        if deltaTimeMs <= 0 {
            deltaTimeSeconds = 0.0
        } else {
            deltaTimeSeconds = Double(deltaTimeMs) / 1000.0
        }
        
        // Get low-level cells (L0/L1) - await actor call
        let allCells = await grid.allActiveCells()
        let cells = allCells.filter { cell in
            cell.level == .L0 || cell.level == .L1
        }
        
        // **Rule ID:** PR6_GRID_PIZ_003
        // Connected component analysis (deterministic)
        let regions = findConnectedComponents(cells: cells, grid: grid)
        
        // Filter by persistence and improvement rate
        var persistentRegions: [GridPIZRegion] = []
        for region in regions {
            if isPersistent(region: region, deltaTimeSeconds: deltaTimeSeconds) {
                persistentRegions.append(region)
            }
        }
        
        // Update tracked regions
        updateTrackedRegions(newRegions: persistentRegions, deltaTimeSeconds: deltaTimeSeconds)
        
        lastUpdateMonotonicMs = currentMonotonicMs
        
        // Convert to existing PIZRegion format
        return trackedRegions.values.map { gridRegion in
            // Convert 3D bounding box to 2D grid bbox (simplified)
            let bbox = BoundingBox(
                minRow: Int(gridRegion.boundingBox.min.y),
                maxRow: Int(gridRegion.boundingBox.max.y),
                minCol: Int(gridRegion.boundingBox.min.x),
                maxCol: Int(gridRegion.boundingBox.max.x)
            )
            
            let centroid = Point(
                row: (gridRegion.boundingBox.min.y + gridRegion.boundingBox.max.y) / 2.0,
                col: (gridRegion.boundingBox.min.x + gridRegion.boundingBox.max.x) / 2.0
            )
            
            let principalDirection = Vector(dx: 1.0, dy: 0.0)  // Simplified
            
            // Estimate pixel count from area (simplified)
            let pixelCount = max(8, Int(gridRegion.areaSqM * 10000))  // At least MIN_REGION_PIXELS
            
            return PIZRegion(
                id: String(gridRegion.regionId),
                pixelCount: pixelCount,
                areaRatio: gridRegion.areaSqM / 100.0,  // Simplified
                bbox: bbox,
                centroid: centroid,
                principalDirection: principalDirection,
                severityScore: gridRegion.occlusionLikelihood
            )
        }
    }
    
    /// Find connected components (simplified implementation)
    private func findConnectedComponents(cells: [GridCell], grid: EvidenceGrid) -> [GridPIZRegion] {
        // Simplified: group cells by spatial proximity
        // Full implementation would use BFS/DFS on grid neighbors
        var regions: [GridPIZRegion] = []
        var processed: Set<String> = []  // Use patchId as key
        
        for cell in cells {
            if processed.contains(cell.patchId) {
                continue
            }
            
            // Find connected cells (simplified: single cell region)
            let region = createRegion(from: cell, grid: grid)
            if region.areaSqM >= minAreaSqM {
                regions.append(region)
            }
            
            processed.insert(cell.patchId)
        }
        
        return regions
    }
    
    /// Create PIZ region from cell
    private func createRegion(from cell: GridCell, grid: EvidenceGrid) -> GridPIZRegion {
        // **Rule ID:** PR6_GRID_PIZ_004
        // Deterministic region ID: use quantized position (simplified)
        let regionId = cell.dsMass.occupied > 0 ? UInt64(cell.quantizedPosition.x) : 0
        
        // Compute area (simplified: assume cell size)
        let areaSqM = 0.01  // Placeholder
        
        // Bounding box (simplified)
        let pos = EvidenceVector3(
            x: Double(cell.quantizedPosition.x),
            y: Double(cell.quantizedPosition.y),
            z: Double(cell.quantizedPosition.z)
        )
        let boundingBox = (min: pos, max: pos)
        
        // Occlusion likelihood (from directional mask)
        let occlusionLikelihood = computeOcclusionLikelihood(cell: cell)
        
        return GridPIZRegion(
            regionId: regionId,
            areaSqM: areaSqM,
            boundingBox: boundingBox,
            occlusionLikelihood: occlusionLikelihood,
            persistedSeconds: 0.0,
            lastImprovementPerSec: 0.0
        )
    }
    
    /// Compute occlusion likelihood from cell
    private func computeOcclusionLikelihood(cell: GridCell) -> Double {
        // Check minimum view directions
        let directionCount = DirectionalBitmask.popcount(cell.directionalMask)
        if directionCount < minOcclusionViewDirections {
            return 0.0  // Not enough views to determine occlusion
        }
        
        // Simplified: use low evidence as occlusion indicator
        return 1.0 - cell.dsMass.occupied
    }
    
    /// Check if region is persistent
    private func isPersistent(region: GridPIZRegion, deltaTimeSeconds: Double) -> Bool {
        // Check if region has persisted for at least persistenceWindowSec
        if region.persistedSeconds < persistenceWindowSec {
            return false
        }
        
        // Check improvement rate
        if region.lastImprovementPerSec > improvementThreshold {
            return false  // Improving, not persistent
        }
        
        return true
    }
    
    /// Update tracked regions
    private func updateTrackedRegions(newRegions: [GridPIZRegion], deltaTimeSeconds: Double) {
        // Update existing regions or add new ones
        for region in newRegions {
            if let existing = trackedRegions[region.regionId] {
                // Update existing region
                trackedRegions[region.regionId] = region
            } else {
                // Add new region
                trackedRegions[region.regionId] = region
            }
        }
        
        // Remove regions that are no longer present
        let newRegionIds = Set(newRegions.map { $0.regionId })
        trackedRegions = trackedRegions.filter { newRegionIds.contains($0.key) }
    }
}
