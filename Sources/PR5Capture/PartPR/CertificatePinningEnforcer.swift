// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CertificatePinningEnforcer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 证书固定强制，防中间人攻击
//

import Foundation

/// Certificate pinning enforcer
///
/// Enforces certificate pinning to prevent MITM attacks.
/// Validates server certificates against pinned certificates.
public actor CertificatePinningEnforcer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Pinned certificates
    private var pinnedCertificates: [String: Data] = [:]
    
    /// Validation history
    private var validationHistory: [(timestamp: Date, host: String, isValid: Bool)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Pinning
    
    /// Pin certificate
    public func pinCertificate(host: String, certificate: Data) {
        pinnedCertificates[host] = certificate
    }
    
    /// Validate pinned certificate
    public func validatePinnedCertificate(host: String, presentedCertificate: Data) -> ValidationResult {
        guard let pinnedCert = pinnedCertificates[host] else {
            return ValidationResult(
                isValid: false,
                reason: "No pinned certificate for host"
            )
        }
        
        let isValid = pinnedCert == presentedCertificate
        
        // Record validation
        validationHistory.append((timestamp: Date(), host: host, isValid: isValid))
        
        // Keep only recent history (last 1000)
        if validationHistory.count > 1000 {
            validationHistory.removeFirst()
        }
        
        return ValidationResult(
            isValid: isValid,
            reason: isValid ? "Certificate matches pinned certificate" : "Certificate mismatch"
        )
    }
    
    // MARK: - Result Types
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let reason: String
    }
}
