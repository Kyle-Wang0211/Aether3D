// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RelocalizationDiscardProtector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART D: 账本完整性增强
// 重定位丢弃保护
//

import Foundation

/// Relocalization discard protector
///
/// Protects against premature discarding during relocalization.
/// Ensures data integrity during tracking recovery.
public actor RelocalizationDiscardProtector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Protected frames during relocalization
    private var protectedFrames: Set<UInt64> = []
    
    /// Relocalization state
    private var isRelocalizing: Bool = false
    
    /// Protection history
    private var protectionHistory: [ProtectionEvent] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Protection Management
    
    /// Start relocalization protection
    ///
    /// Marks frames as protected during relocalization
    public func startRelocalization(frames: [UInt64]) {
        isRelocalizing = true
        protectedFrames = Set(frames)
        
        let event = ProtectionEvent(
            timestamp: Date(),
            action: .start,
            protectedFrames: frames.count
        )
        protectionHistory.append(event)
    }
    
    /// End relocalization protection
    public func endRelocalization() {
        isRelocalizing = false
        
        let event = ProtectionEvent(
            timestamp: Date(),
            action: .end,
            protectedFrames: protectedFrames.count
        )
        protectionHistory.append(event)
        
        // Clear protected frames after a delay
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            await clearProtectedFrames()
        }
    }
    
    /// Check if frame is protected
    public func isProtected(_ frameId: UInt64) -> Bool {
        return protectedFrames.contains(frameId)
    }
    
    /// Request discard
    ///
    /// Checks if discard is allowed (not protected)
    public func requestDiscard(_ frameId: UInt64) -> DiscardResult {
        if isProtected(frameId) {
            return .protected(
                frameId: frameId,
                reason: "Frame protected during relocalization"
            )
        } else {
            return .allowed(frameId: frameId)
        }
    }
    
    /// Clear protected frames
    private func clearProtectedFrames() {
        protectedFrames.removeAll()
    }
    
    /// Get protection status
    public func getProtectionStatus() -> ProtectionStatus {
        return ProtectionStatus(
            isRelocalizing: isRelocalizing,
            protectedFrameCount: protectedFrames.count,
            protectedFrames: Array(protectedFrames)
        )
    }
    
    // MARK: - Data Types
    
    /// Protection event
    public struct ProtectionEvent: Sendable {
        public let timestamp: Date
        public let action: ProtectionAction
        public let protectedFrames: Int
        
        public enum ProtectionAction: String, Sendable {
            case start
            case end
        }
    }
    
    /// Protection status
    public struct ProtectionStatus: Sendable {
        public let isRelocalizing: Bool
        public let protectedFrameCount: Int
        public let protectedFrames: [UInt64]
    }
    
    /// Discard result
    public enum DiscardResult: Sendable {
        case allowed(frameId: UInt64)
        case protected(frameId: UInt64, reason: String)
    }
}
