// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ClampedEvidence.swift
// Aether3D
//
// PR2 Patch V4 - Clamped Evidence Value Property Wrapper
// Ensures evidence values always stay in [0, 1] range
//

import Foundation

/// Clamped evidence value (always in [0, 1])
@propertyWrapper
public struct ClampedEvidence: Codable, Equatable, Hashable, @unchecked Sendable {
    private var _value: Double
    
    public var wrappedValue: Double {
        get { _value }
        set { _value = newValue.clampedEvidence(to: 0...1) }
    }
    
    public init(wrappedValue: Double) {
        self._value = wrappedValue.clampedEvidence(to: 0...1)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Double.self)
        self._value = raw.clampedEvidence(to: 0...1)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(_value)
    }
}

extension Double {
    /// Clamp value to range (Evidence-specific)
    /// NOTE: This is a file-private helper, not a public API
    fileprivate func clampedEvidence(to range: ClosedRange<Double>) -> Double {
        return max(range.lowerBound, min(range.upperBound, self))
    }
}
