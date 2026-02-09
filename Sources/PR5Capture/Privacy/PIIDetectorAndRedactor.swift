// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIIDetectorAndRedactor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 7 + I: 隐私加固和双轨
// PII检测和编辑，敏感信息识别，数据脱敏
//

import Foundation

/// PII detector and redactor
///
/// Detects and redacts personally identifiable information.
/// Identifies sensitive information and applies redaction.
public actor PIIDetectorAndRedactor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - PII Types
    
    public enum PIIType: String, Sendable {
        case email
        case phone
        case ssn
        case creditCard
        case name
        case address
    }
    
    // MARK: - State
    
    /// Detection history
    private var detectionHistory: [(timestamp: Date, type: PIIType, count: Int)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - PII Detection
    
    /// Detect PII in data
    ///
    /// Identifies PII patterns in input data
    public func detectPII(_ data: String) -> PIIDetectionResult {
        var detected: [PIIType] = []
        
        // NOTE: Basic detection (in production, use proper regex/ML)
        if data.contains("@") {
            detected.append(.email)
        }
        if data.range(of: #"\d{3}-\d{2}-\d{4}"#, options: .regularExpression) != nil {
            detected.append(.ssn)
        }
        if data.range(of: #"\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}"#, options: .regularExpression) != nil {
            detected.append(.creditCard)
        }
        
        // Record detection
        for type in detected {
            detectionHistory.append((timestamp: Date(), type: type, count: 1))
        }
        
        // Keep only recent history (last 100)
        if detectionHistory.count > 100 {
            detectionHistory.removeFirst()
        }
        
        return PIIDetectionResult(
            detectedTypes: detected,
            count: detected.count
        )
    }
    
    /// Redact PII
    ///
    /// Applies redaction to detected PII
    public func redactPII(_ data: String, types: [PIIType]) -> String {
        var redacted = data
        
        for type in types {
            switch type {
            case .email:
                redacted = redacted.replacingOccurrences(of: #"[^\s]+@[^\s]+\.[^\s]+"#, with: "[REDACTED EMAIL]", options: .regularExpression)
            case .ssn:
                redacted = redacted.replacingOccurrences(of: #"\d{3}-\d{2}-\d{4}"#, with: "[REDACTED SSN]", options: .regularExpression)
            case .creditCard:
                redacted = redacted.replacingOccurrences(of: #"\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}"#, with: "[REDACTED CARD]", options: .regularExpression)
            default:
                break
            }
        }
        
        return redacted
    }
    
    // MARK: - Result Types
    
    /// PII detection result
    public struct PIIDetectionResult: Sendable {
        public let detectedTypes: [PIIType]
        public let count: Int
    }
}
