//
// GridPatchMap.swift
// Aether3D
//
// PR6 Evidence Grid System - Grid Patch Map
// UInt64-keyed parallel PatchEvidenceMap for grid cells
//

import Foundation

/// **Rule ID:** PR6_GRID_PATCHMAP_001
/// Grid Patch Map: UInt64-keyed parallel PatchEvidenceMap
/// Maintains evidence for grid cells keyed by SpatialKey (Morton code)
public final class GridPatchMap: @unchecked Sendable {
    
    /// Evidence map: SpatialKey -> evidence value
    private var evidenceMap: [SpatialKey: Double] = [:]
    
    public init() {}
    
    /// Update evidence for a spatial key
    public func update(key: SpatialKey, evidence: Double) {
        evidenceMap[key] = evidence
    }
    
    /// Get evidence for a spatial key
    public func evidence(for key: SpatialKey) -> Double {
        return evidenceMap[key] ?? 0.0
    }
    
    /// Get all keys
    public func allKeys() -> [SpatialKey] {
        return Array(evidenceMap.keys)
    }
    
    /// Reset map
    public func reset() {
        evidenceMap.removeAll()
    }
}
