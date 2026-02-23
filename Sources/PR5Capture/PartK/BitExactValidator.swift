// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BitExactValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 位精确验证，确保跨平台结果一致
//

import Foundation

/// Bit-exact validator
///
/// Validates bit-exact consistency across platforms.
/// Ensures identical results regardless of platform.
public actor BitExactValidator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Validation history
    private var validationHistory: [(timestamp: Date, passed: Bool, platform: String)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Validation
    
    /// Validate bit-exact match
    ///
    /// Compares data bit-by-bit for exact match
    public func validateBitExact(_ data1: Data, _ data2: Data) -> ValidationResult {
        guard data1.count == data2.count else {
            return ValidationResult(
                isExact: false,
                reason: "Length mismatch: \(data1.count) vs \(data2.count)"
            )
        }
        
        for i in 0..<data1.count {
            if data1[i] != data2[i] {
                return ValidationResult(
                    isExact: false,
                    reason: "Byte mismatch at index \(i): \(data1[i]) vs \(data2[i])"
                )
            }
        }
        
        let result = ValidationResult(isExact: true, reason: "Bit-exact match")
        
        // Record validation
        validationHistory.append((
            timestamp: Date(),
            passed: true,
            platform: PlatformAbstractionLayer.currentPlatform.rawValue
        ))
        
        return result
    }
    
    /// Validate floating-point bit-exact match
    public func validateBitExact(_ value1: Double, _ value2: Double) -> ValidationResult {
        let data1 = withUnsafeBytes(of: value1) { Data($0) }
        let data2 = withUnsafeBytes(of: value2) { Data($0) }
        return validateBitExact(data1, data2)
    }
    
    // MARK: - Result Types
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isExact: Bool
        public let reason: String
    }
}
