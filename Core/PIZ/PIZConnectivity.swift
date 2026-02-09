// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZConnectivity.swift
// Aether3D
//
// PR1 PIZ Detection - Connectivity Mode (Frozen)
//
// Defines the connectivity mode used for continuous region detection.
// This is frozen to 4-neighborhood and must be used consistently everywhere.

import Foundation

/// Connectivity mode for PIZ region detection.
/// 
/// **Frozen Decision:** FOUR-neighborhood is chosen and must be used everywhere.
/// This prevents ambiguity and ensures deterministic behavior.
public enum ConnectivityMode: String, Codable {
    case four = "FOUR"
    case eight = "EIGHT"
    
    /// The frozen connectivity mode used throughout the system.
    /// This value must never change without a schema version bump.
    public static let frozen: ConnectivityMode = .four
}

/// Connectivity utilities for 4-neighborhood operations.
public struct Connectivity {
    /// Get 4-neighborhood neighbors of a cell (up, down, left, right).
    /// 
    /// - Parameters:
    ///   - row: Row index (0-based)
    ///   - col: Column index (0-based)
    ///   - gridSize: Size of the grid (32 for PIZ detection)
    /// - Returns: Array of (row, col) tuples for valid neighbors
    public static func fourNeighbors(row: Int, col: Int, gridSize: Int) -> [(row: Int, col: Int)] {
        var neighbors: [(row: Int, col: Int)] = []
        
        // Up
        if row > 0 {
            neighbors.append((row: row - 1, col: col))
        }
        
        // Down
        if row < gridSize - 1 {
            neighbors.append((row: row + 1, col: col))
        }
        
        // Left
        if col > 0 {
            neighbors.append((row: row, col: col - 1))
        }
        
        // Right
        if col < gridSize - 1 {
            neighbors.append((row: row, col: col + 1))
        }
        
        return neighbors
    }
    
    /// Check if two cells are 4-neighbors.
    public static func areFourNeighbors(row1: Int, col1: Int, row2: Int, col2: Int) -> Bool {
        let rowDiff = abs(row1 - row2)
        let colDiff = abs(col1 - col2)
        return (rowDiff == 1 && colDiff == 0) || (rowDiff == 0 && colDiff == 1)
    }
}
