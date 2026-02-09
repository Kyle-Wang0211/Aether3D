// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ErrorPropagationBudget.swift
// PR4Math
//
// PR4 V10 - Pillar 32: Error propagation budget tracking
//

import Foundation

/// Error propagation budget
///
/// V8 RULE: Track cumulative error from rounding/quantization.
/// If budget exceeds threshold, flag for review.
public enum ErrorPropagationBudget {
    
    /// Maximum allowed cumulative error (in Q16 units)
    public static let maxBudget: Int64 = 1000  // ~0.015 in normalized units
    
    /// Error budget tracker
    public struct BudgetTracker {
        private var cumulativeError: Int64 = 0
        private let maxBudget: Int64
        
        public init(maxBudget: Int64 = ErrorPropagationBudget.maxBudget) {
            self.maxBudget = maxBudget
        }
        
        /// Add error to budget
        @inline(__always)
        public mutating func addError(_ error: Int64) {
            cumulativeError += abs(error)
        }
        
        /// Check if budget is exceeded
        public var isExceeded: Bool {
            return cumulativeError > maxBudget
        }
        
        /// Get current error
        public var currentError: Int64 {
            return cumulativeError
        }
        
        /// Reset budget
        public mutating func reset() {
            cumulativeError = 0
        }
    }
    
    /// Track rounding error
    @inline(__always)
    public static func trackRoundingError(
        exact: Double,
        rounded: Int64,
        tracker: inout BudgetTracker
    ) {
        let exactQ16 = Q16.fromDouble(exact)
        let error = exactQ16 - rounded
        tracker.addError(error)
    }
    
    /// Track quantization error
    @inline(__always)
    public static func trackQuantizationError(
        before: Int64,
        after: Int64,
        tracker: inout BudgetTracker
    ) {
        let error = before - after
        tracker.addError(error)
    }
}
