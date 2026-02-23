// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ProgressTracker.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 4
//  ProgressTracker - tracks white coverage increments
//

import Foundation

/// ProgressTracker - tracks white coverage progress
public class ProgressTracker {
    private var lastWhiteCoverage: Int = 0
    private var lastProgressTime: Int64?
    private var lastVisibleProgressTime: Int64?
    private var lastIncrement: Int = 0
    
    public init() {}
    
    /// Update white coverage
    public func updateWhiteCoverage(_ coverage: Int) {
        let increment = max(0, coverage - lastWhiteCoverage)
        lastIncrement = increment
        let now = MonotonicClock.nowMs()
        
        if increment >= QualityPreCheckConstants.MIN_PROGRESS_INCREMENT {
            lastProgressTime = now
        }

        if increment >= QualityPreCheckConstants.MIN_VISIBLE_PROGRESS_INCREMENT {
            lastVisibleProgressTime = now
        }
        
        lastWhiteCoverage = coverage
    }
    
    /// Check if has progress
    /// ≥ minProgressIncrement (10 cells)
    public func hasProgress() -> Bool {
        // Simplified - would track actual increments
        return lastProgressTime != nil
    }
    
    /// Check if has visible progress
    /// ≥ minVisibleIncrement (30 cells)
    public func hasVisibleProgress() -> Bool {
        return lastVisibleProgressTime != nil ||
            lastIncrement >= QualityPreCheckConstants.MIN_VISIBLE_PROGRESS_INCREMENT
    }
    
    /// Get no progress duration
    public func getNoProgressDuration() -> Int64 {
        guard let lastProgress = lastProgressTime else {
            return Int64.max
        }
        
        let now = MonotonicClock.nowMs()
        return now - lastProgress
    }
}
