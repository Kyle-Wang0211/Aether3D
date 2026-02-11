// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AsymmetricDeltaTracker.swift
// Aether3D
//
// PR2 Patch V4 - Asymmetric Delta Tracker
// Fast response to increases, slow decay for decreases
//

import Foundation

/// Delta tracker with asymmetric smoothing
public struct AsymmetricDeltaTracker {
    
    /// Raw delta (accurate, for diagnostics)
    public private(set) var raw: Double = 0.0
    
    /// EMA-smoothed delta (for UI animation speed)
    public private(set) var smoothed: Double = 0.0
    
    /// Alpha for increasing delta (fast response to gains)
    public let alphaRise: Double
    
    /// Alpha for decreasing delta (slow decay for losses)
    public let alphaFall: Double
    
    /// Initialize with default asymmetric alphas
    /// - Parameters:
    ///   - alphaRise: Response to increases (default 0.3 = fast)
    ///   - alphaFall: Response to decreases (default 0.1 = slow)
    public init(alphaRise: Double = 0.3, alphaFall: Double = 0.1) {
        self.alphaRise = alphaRise
        self.alphaFall = alphaFall
    }
    
    /// Update with new delta
    public mutating func update(newDelta: Double) {
        raw = newDelta
        
        // Choose alpha based on direction
        let alpha: Double
        if newDelta > smoothed {
            // Rising: use fast alpha
            alpha = alphaRise
        } else {
            // Falling: use slow alpha
            alpha = alphaFall
        }
        
        smoothed = alpha * newDelta + (1 - alpha) * smoothed
    }
    
    /// Reset
    public mutating func reset() {
        raw = 0.0
        smoothed = 0.0
    }
}
