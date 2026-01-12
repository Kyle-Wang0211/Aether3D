//
// SSOTValidation.swift
// Aether3D
//
// Validation utilities for SSOT specifications.
//

import Foundation

/// Static validation methods for SSOT integrity.
public enum SSOTValidation {
    /// Validates a threshold spec for internal consistency.
    public static func validate(_ spec: ThresholdSpec) -> [String] {
        var errors: [String] = []
        
        if spec.min > spec.max {
            errors.append("\(spec.ssotId): min (\(spec.min)) > max (\(spec.max))")
        }
        
        if spec.defaultValue < spec.min || spec.defaultValue > spec.max {
            errors.append("\(spec.ssotId): defaultValue (\(spec.defaultValue)) outside [min, max]")
        }
        
        if spec.ssotId.isEmpty {
            errors.append("\(spec.ssotId): ssotId is empty")
        }
        
        if !spec.ssotId.contains(".") {
            errors.append("\(spec.ssotId): ssotId must contain '.' separator")
        }
        
        return errors
    }
    
    /// Validates a system constant spec.
    public static func validate(_ spec: SystemConstantSpec) -> [String] {
        var errors: [String] = []
        
        if spec.value <= 0 {
            errors.append("\(spec.ssotId): value must be positive")
        }
        
        if spec.ssotId.isEmpty {
            errors.append("\(spec.ssotId): ssotId is empty")
        }
        
        if !spec.ssotId.contains(".") {
            errors.append("\(spec.ssotId): ssotId must contain '.' separator")
        }
        
        return errors
    }
    
    /// Validates a minimum limit spec.
    public static func validate(_ spec: MinLimitSpec) -> [String] {
        var errors: [String] = []
        
        if spec.minValue <= 0 {
            errors.append("\(spec.ssotId): minValue must be positive")
        }
        
        if spec.ssotId.isEmpty {
            errors.append("\(spec.ssotId): ssotId is empty")
        }
        
        if !spec.ssotId.contains(".") {
            errors.append("\(spec.ssotId): ssotId must contain '.' separator")
        }
        
        return errors
    }
    
    /// Validates a fixed constant spec.
    public static func validate(_ spec: FixedConstantSpec) -> [String] {
        var errors: [String] = []
        
        if spec.value <= 0 {
            errors.append("\(spec.ssotId): value must be positive")
        }
        
        if spec.ssotId.isEmpty {
            errors.append("\(spec.ssotId): ssotId is empty")
        }
        
        if !spec.ssotId.contains(".") {
            errors.append("\(spec.ssotId): ssotId must contain '.' separator")
        }
        
        return errors
    }
    
    /// Validates an error code for format and consistency.
    public static func validateErrorCode(_ code: SSOTErrorCode) -> [String] {
        var errors: [String] = []
        
        if code.stableName.isEmpty {
            errors.append("Error code stableName is empty")
        }
        
        if code.stableName.count > 64 {
            errors.append("Error code stableName exceeds 64 characters: \(code.stableName)")
        }
        
        if !code.stableName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            errors.append("Error code stableName contains invalid characters: \(code.stableName)")
        }
        
        if !code.domain.codeRange.contains(code.code) {
            errors.append("Error code \(code.code) not in domain range \(code.domain.codeRange)")
        }
        
        if code.defaultUserMessage.isEmpty {
            errors.append("Error code defaultUserMessage is empty")
        }
        
        return errors
    }
}

