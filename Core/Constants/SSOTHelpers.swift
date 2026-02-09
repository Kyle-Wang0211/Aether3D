// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTHelpers.swift
// Aether3D
//
// Helper functions for clamping and validation.
// CRITICAL: No fatalError() - returns .rejected() with S_ASSERTION_FAILED instead.
//

import Foundation

/// Result type for validation/clamping operations
public enum SSOTValidationResult<T> {
    case accepted(T)
    case rejected(SSOTError)
    case clamped(T, original: T)
}

/// Helper functions for SSOT operations
public enum SSOTHelpers {
    /// Convert Double to T (handles both Int and Double)
    private static func convertToT<T: Numeric>(_ value: Double) -> T {
        if let intVal = Int(exactly: value), let result = T(exactly: intVal) {
            return result
        } else if T.self == Double.self {
            return value as! T
        } else {
            return T.zero
        }
    }
    
    /// Clamp a value to a threshold spec range.
    /// Returns .clamped if value was adjusted, .accepted if within range, .rejected if spec is invalid.
    public static func clamp<T: Comparable & Numeric>(
        _ value: T,
        to spec: ThresholdSpec
    ) -> SSOTValidationResult<T> {
        // Validate spec first
        let specErrors = SSOTValidation.validate(spec)
        if !specErrors.isEmpty {
            return .rejected(SSOTError(
                code: ErrorCodes.S_INVALID_SPEC,
                context: [
                    "ssotId": spec.ssotId,
                    "spec": specErrors.joined(separator: "; ")
                ]
            ))
        }
        
        let minVal: T = convertToT(spec.min)
        let maxVal: T = convertToT(spec.max)
        
        if value < minVal {
            switch spec.onUnderflow {
            case .clamp:
                return .clamped(minVal, original: value)
            case .reject:
                return .rejected(SSOTError(
                    code: ErrorCodes.S_UNDERFLOWED_MIN,
                    context: [
                        "ssotId": spec.ssotId,
                        "value": "\(value)",
                        "min": "\(spec.min)"
                    ]
                ))
            case .warn:
                return .accepted(value)
            }
        } else if value > maxVal {
            switch spec.onExceed {
            case .clamp:
                return .clamped(maxVal, original: value)
            case .reject:
                return .rejected(SSOTError(
                    code: ErrorCodes.S_EXCEEDED_MAX,
                    context: [
                        "ssotId": spec.ssotId,
                        "value": "\(value)",
                        "max": "\(spec.max)"
                    ]
                ))
            case .warn:
                return .accepted(value)
            }
        }
        
        return .accepted(value)
    }
    
    /// Validate a value against a threshold spec (no clamping).
    public static func validate<T: Comparable & Numeric>(
        _ value: T,
        against spec: ThresholdSpec
    ) -> SSOTValidationResult<T> {
        let specErrors = SSOTValidation.validate(spec)
        if !specErrors.isEmpty {
            return .rejected(SSOTError(
                code: ErrorCodes.S_INVALID_SPEC,
                context: [
                    "ssotId": spec.ssotId,
                    "spec": specErrors.joined(separator: "; ")
                ]
            ))
        }
        
        let minVal: T = convertToT(spec.min)
        let maxVal: T = convertToT(spec.max)
        
        if value < minVal {
            return .rejected(SSOTError(
                code: ErrorCodes.S_UNDERFLOWED_MIN,
                context: [
                    "ssotId": spec.ssotId,
                    "value": "\(value)",
                    "min": "\(spec.min)"
                ]
            ))
        } else if value > maxVal {
            return .rejected(SSOTError(
                code: ErrorCodes.S_EXCEEDED_MAX,
                context: [
                    "ssotId": spec.ssotId,
                    "value": "\(value)",
                    "max": "\(spec.max)"
                ]
            ))
        }
        
        return .accepted(value)
    }
    
    /// Validate a value against a minimum limit spec.
    public static func validate<T: Comparable & Numeric>(
        _ value: T,
        against spec: MinLimitSpec
    ) -> SSOTValidationResult<T> {
        let specErrors = SSOTValidation.validate(spec)
        if !specErrors.isEmpty {
            return .rejected(SSOTError(
                code: ErrorCodes.S_INVALID_SPEC,
                context: [
                    "ssotId": spec.ssotId,
                    "spec": specErrors.joined(separator: "; ")
                ]
            ))
        }
        
        let minVal = T(exactly: spec.minValue) ?? T.zero
        
        if value < minVal {
            switch spec.onUnderflow {
            case .clamp:
                return .clamped(minVal, original: value)
            case .reject:
                return .rejected(SSOTError(
                    code: ErrorCodes.S_UNDERFLOWED_MIN,
                    context: [
                        "ssotId": spec.ssotId,
                        "value": "\(value)",
                        "min": "\(spec.minValue)"
                    ]
                ))
            case .warn:
                return .accepted(value)
            }
        }
        
        return .accepted(value)
    }
}

