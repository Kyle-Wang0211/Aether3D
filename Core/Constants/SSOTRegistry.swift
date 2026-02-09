// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTRegistry.swift
// Aether3D
//
// Central registry for all SSOT constants and error codes.
//

import Foundation

/// Central registry for SSOT system
public enum SSOTRegistry {
    /// All constant specifications
    public static var allConstantSpecs: [AnyConstantSpec] {
        var all: [AnyConstantSpec] = []
        all.append(contentsOf: SystemConstants.allSpecs)
        all.append(contentsOf: ConversionConstants.allSpecs)
        all.append(contentsOf: QualityThresholds.allSpecs)
        all.append(contentsOf: RetryConstants.allSpecs)
        all.append(contentsOf: SamplingConstants.allSpecs)
        all.append(contentsOf: FrameQualityConstants.allSpecs)
        all.append(contentsOf: ContinuityConstants.allSpecs)
        all.append(contentsOf: CoverageVisualizationConstants.allSpecs)
        all.append(contentsOf: StorageConstants.allSpecs)
        all.append(contentsOf: ScanGuidanceConstants.allSpecs)
        // Note: Ultra-Granular Capture policies (CaptureProfile, GridResolutionPolicy, etc.)
        // are not registered as AnyConstantSpec because they use LengthQ and custom types.
        // They are validated through their own digest and validation methods.
        return all
    }
    
    /// All error codes
    public static var allErrorCodes: [SSOTErrorCode] {
        return ErrorCodes.all
    }
    
    /// Find constant spec by SSOT ID
    public static func findConstantSpec(ssotId: String) -> AnyConstantSpec? {
        return allConstantSpecs.first { $0.ssotId == ssotId }
    }
    
    /// Find error code by stable name
    public static func findErrorCode(stableName: String) -> SSOTErrorCode? {
        return allErrorCodes.first { $0.stableName == stableName }
    }
    
    /// Find error code by domain and code
    public static func findErrorCode(domain: String, code: Int) -> SSOTErrorCode? {
        return allErrorCodes.first { $0.domain.id == domain && $0.code == code }
    }
    
    /// Comprehensive self-check for registry integrity.
    /// Validates uniqueness, format, and relationships.
    public static func selfCheck() -> [String] {
        var errors: [String] = []
        
        // Check constant spec uniqueness
        var specIds: Set<String> = []
        for spec in allConstantSpecs {
            if specIds.contains(spec.ssotId) {
                errors.append("Duplicate constant spec ID: \(spec.ssotId)")
            }
            specIds.insert(spec.ssotId)
            
            // Validate spec format
            switch spec {
            case .threshold(let s):
                errors.append(contentsOf: SSOTValidation.validate(s))
            case .systemConstant(let s):
                errors.append(contentsOf: SSOTValidation.validate(s))
            case .minLimit(let s):
                errors.append(contentsOf: SSOTValidation.validate(s))
            case .fixedConstant(let s):
                errors.append(contentsOf: SSOTValidation.validate(s))
            }
        }
        
        // Check error code uniqueness (by stable name)
        var stableNames: Set<String> = []
        var codeKeys: Set<String> = []
        for code in allErrorCodes {
            if stableNames.contains(code.stableName) {
                errors.append("Duplicate error code stable name: \(code.stableName)")
            }
            stableNames.insert(code.stableName)
            
            let codeKey = "\(code.domain.id):\(code.code)"
            if codeKeys.contains(codeKey) {
                errors.append("Duplicate error code: \(codeKey)")
            }
            codeKeys.insert(codeKey)
            
            // Validate error code format
            errors.append(contentsOf: SSOTValidation.validateErrorCode(code))
        }
        
        // Validate cross-constant relationships
        errors.append(contentsOf: SystemConstants.validateRelationships())
        errors.append(contentsOf: QualityThresholds.validateRelationships())
        errors.append(contentsOf: ScanGuidanceConstants.validateRelationships())
        
        return errors
    }
}

