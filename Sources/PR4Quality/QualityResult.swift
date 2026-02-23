// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityResult.swift
// PR4Quality
//
// PR4 V10 - Pillar 37: Quality result structure
//

import Foundation
import PR4Protocols

/// Quality result
public struct QualityResult: HasDoubleValue {
    public let value: Double
    public let uncertainty: Double

    public init(value: Double, uncertainty: Double) {
        self.value = value
        self.uncertainty = uncertainty
    }

    // MARK: - HasDoubleValue conformance

    public var doubleValue: Double { value }
}
