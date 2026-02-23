// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FusionResult.swift
// PR4Fusion
//
// PR4 V10 - Fusion result structure
//

import Foundation

/// Fusion result
public struct FusionResult {
    public let fusedDepth: Double
    public let fusedConfidence: Double
    
    public init(fusedDepth: Double, fusedConfidence: Double) {
        self.fusedDepth = fusedDepth
        self.fusedConfidence = fusedConfidence
    }
}
