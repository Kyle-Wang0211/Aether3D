//
// QualityResult.swift
// PR4Quality
//
// PR4 V10 - Pillar 37: Quality result structure
//

import Foundation

/// Quality result
public struct QualityResult {
    public let value: Double
    public let uncertainty: Double
    
    public init(value: Double, uncertainty: Double) {
        self.value = value
        self.uncertainty = uncertainty
    }
}
