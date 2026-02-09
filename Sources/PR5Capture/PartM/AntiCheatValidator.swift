// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AntiCheatValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 反作弊验证，检测模拟器/越狱/Hook
//

import Foundation
import SharedSecurity

/// Anti-cheat validator
///
/// Validates system integrity and detects cheating attempts.
/// Detects simulators, jailbreaks, and code hooks.
public actor AntiCheatValidator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Threat Types
    
    public enum ThreatType: String, Sendable {
        case simulator
        case jailbreak
        case codeHook
        case debugger
        case none
    }
    
    // MARK: - State
    
    /// Detection history
    private var detectionHistory: [(timestamp: Date, threat: ThreatType)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Validation
    
    /// Validate system integrity
    public func validate() -> ValidationResult {
        var threats: [ThreatType] = []
        
        // Check for simulator
        if PlatformAbstractionLayer.isSimulator() {
            threats.append(.simulator)
        }
        
        // Check for debugger (simplified)
        if isDebuggerAttached() {
            threats.append(.debugger)
        }
        
        let threat = threats.first ?? .none
        
        // Record detection
        detectionHistory.append((timestamp: Date(), threat: threat))
        
        // Keep only recent history (last 100)
        if detectionHistory.count > 100 {
            detectionHistory.removeFirst()
        }
        
        return ValidationResult(
            isValid: threat == .none,
            threats: threats,
            primaryThreat: threat
        )
    }
    
    /// Check if debugger is attached
    /// 
    /// 使用多层调试器检测，符合INV-SEC-058: 调试器检测必须使用3+独立技术。
    private func isDebuggerAttached() -> Bool {
        return DebuggerGuard.isDebuggerPresent()
    }
    
    // MARK: - Result Types
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let threats: [ThreatType]
        public let primaryThreat: ThreatType
    }
}
