//
// EvidenceGridPIZBridge.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence Grid to PIZ Bridge
// Converts EvidenceGrid to PIZ [[Double]] heatmap format
//

import Foundation

/// **Rule ID:** PR6_GRID_PIZ_BRIDGE_001
/// Evidence Grid to PIZ Bridge
/// Converts EvidenceGrid cells to PIZ [[Double]] heatmap format
public struct EvidenceGridPIZBridge {
    
    /// Generate heatmap from EvidenceGrid
    ///
    /// - Parameter grid: EvidenceGrid instance
    /// - Returns: Heatmap as [[Double]] (2D array)
    public static func generateHeatmap(from grid: EvidenceGrid) async -> [[Double]] {
        let cells = await grid.allActiveCells()
        
        // Simplified: create a 2D heatmap from grid cells
        // Full implementation would properly map 3D grid to 2D heatmap
        var heatmap: [[Double]] = []
        
        // Group cells by quantized position
        var cellMap: [String: [GridCell]] = [:]
        for cell in cells {
            let key = "\(cell.quantizedPosition.x),\(cell.quantizedPosition.y)"
            if cellMap[key] == nil {
                cellMap[key] = []
            }
            cellMap[key]?.append(cell)
        }
        
        // Convert to 2D array
        let sortedKeys = cellMap.keys.sorted()
        for key in sortedKeys {
            if let cellGroup = cellMap[key] {
                let row = cellGroup.map { $0.dsMass.occupied }
                heatmap.append(row)
            }
        }
        
        return heatmap
    }
}
