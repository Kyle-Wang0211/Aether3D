// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConversionConstants.swift
// Aether3D
//
// Immutable mathematical conversion factors.
//

import Foundation

/// Conversion constants (immutable mathematical factors).
public enum ConversionConstants {
    /// Bytes per kilobyte (bytes)
    /// literal by contract: avoid expression normalization
    public static let bytesPerKB = 1024
    
    /// Bytes per megabyte (bytes)
    /// literal by contract: avoid expression normalization
    public static let bytesPerMB = 1048576
    
    // MARK: - Specifications
    
    /// Specification for bytesPerKB
    public static let bytesPerKBSpec = FixedConstantSpec(
        ssotId: "ConversionConstants.bytesPerKB",
        name: "Bytes per Kilobyte",
        unit: .bytes,
        value: bytesPerKB,
        documentation: "Mathematical conversion factor: 1 KB = 1024 bytes"
    )
    
    /// Specification for bytesPerMB
    public static let bytesPerMBSpec = FixedConstantSpec(
        ssotId: "ConversionConstants.bytesPerMB",
        name: "Bytes per Megabyte",
        unit: .bytes,
        value: bytesPerMB,
        documentation: "Mathematical conversion factor: 1 MB = 1048576 bytes"
    )
    
    /// All conversion constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .fixedConstant(bytesPerKBSpec),
        .fixedConstant(bytesPerMBSpec)
    ]
    
    // MARK: - Convenience Functions
    
    /// Convert kilobytes to bytes
    public static func kilobytesToBytes(_ kb: Int) -> Int {
        return kb * bytesPerKB
    }
    
    /// Convert megabytes to bytes
    public static func megabytesToBytes(_ mb: Int) -> Int {
        return mb * bytesPerMB
    }
    
    /// Convert bytes to kilobytes
    public static func bytesToKilobytes(_ bytes: Int) -> Double {
        return Double(bytes) / Double(bytesPerKB)
    }
    
    /// Convert bytes to megabytes
    public static func bytesToMegabytes(_ bytes: Int) -> Double {
        return Double(bytes) / Double(bytesPerMB)
    }
}

