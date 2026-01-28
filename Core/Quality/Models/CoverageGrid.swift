//
//  CoverageGrid.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Coverage grid (128x128, PART 2.7)
//

import Foundation

/// CoverageGrid - 128x128 grid for tracking coverage
/// Row-major order: row 0..127, col 0..127
/// cellIndex = row * 128 + col
public struct CoverageGrid {
    private var grid: [CoverageState]
    private static let size = 128
    private static let totalCells = size * size
    
    public init() {
        self.grid = Array(repeating: .uncovered, count: CoverageGrid.totalCells)
    }
    
    /// Get cell index from row and column
    public static func cellIndex(row: Int, col: Int) -> Int {
        return row * size + col
    }
    
    /// Get row and column from cell index
    public static func rowCol(from cellIndex: Int) -> (row: Int, col: Int) {
        return (row: cellIndex / size, col: cellIndex % size)
    }
    
    /// Get state at cell index
    public func getState(at cellIndex: Int) -> CoverageState {
        guard cellIndex >= 0 && cellIndex < CoverageGrid.totalCells else {
            return .uncovered
        }
        return grid[cellIndex]
    }
    
    /// Set state at cell index
    public mutating func setState(_ state: CoverageState, at cellIndex: Int) {
        guard cellIndex >= 0 && cellIndex < CoverageGrid.totalCells else {
            return
        }
        grid[cellIndex] = state
    }
    
    /// Get state at row, col
    public func getState(row: Int, col: Int) -> CoverageState {
        return getState(at: CoverageGrid.cellIndex(row: row, col: col))
    }
    
    /// Set state at row, col
    public mutating func setState(_ state: CoverageState, row: Int, col: Int) {
        setState(state, at: CoverageGrid.cellIndex(row: row, col: col))
    }
    
    /// Get total number of cells
    public static var totalCellCount: Int {
        return totalCells
    }
    
    /// Get grid size
    public static var gridSize: Int {
        return size
    }
}

/// RequiredSamplesResult - time-to-frame conversion result (PART 2.3)
public struct RequiredSamplesResult: Codable {
    public let requiredSamples: Int
    public let timeWindowMs: Int64
    
    public init(requiredSamples: Int, timeWindowMs: Int64) {
        self.requiredSamples = requiredSamples
        self.timeWindowMs = timeWindowMs
    }
}

