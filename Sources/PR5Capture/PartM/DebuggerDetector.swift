// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DebuggerDetector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 调试器检测，反调试保护
//

import Foundation
import SharedSecurity

/// Debugger detector
///
/// Detects debugger attachment and implements anti-debugging protection.
/// Prevents debugging attempts.
public actor DebuggerDetector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Detection history
    private var detectionHistory: [(timestamp: Date, detected: Bool)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Detection
    
    /// Detect debugger
    /// 
    /// 使用多层调试器检测，符合INV-SEC-058: 调试器检测必须使用3+独立技术。
    public func detect() -> DetectionResult {
        let detected = DebuggerGuard.isDebuggerPresent()
        
        // Record detection
        detectionHistory.append((timestamp: Date(), detected: detected))
        
        // Keep only recent history (last 100)
        if detectionHistory.count > 100 {
            detectionHistory.removeFirst()
        }
        
        return DetectionResult(
            detected: detected,
            timestamp: Date()
        )
    }
    
    // MARK: - Result Types
    
    /// Detection result
    public struct DetectionResult: Sendable {
        public let detected: Bool
        public let timestamp: Date
    }
}
