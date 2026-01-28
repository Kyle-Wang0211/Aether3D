//
//  CoverageState.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Coverage state enumeration (uncovered/gray/white)
//

import Foundation

/// CoverageState - state of a coverage grid cell
/// Encoding: 00 = uncovered, 01 = gray, 10 = white, 11 = forbidden
public enum CoverageState: UInt8 {
    case uncovered = 0
    case gray = 1
    case white = 2
    
    /// Forbidden state (11 binary) - must never occur
    /// If detected → corruptedEvidence
    static let forbidden: UInt8 = 3
}

