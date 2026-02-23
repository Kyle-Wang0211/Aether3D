// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SessionResumer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 会话恢复器，断点续传支持
//

import Foundation

/// Session resumer
///
/// Resumes sessions with checkpoint continuation support.
/// Enables seamless session recovery.
public actor SessionResumer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Resumed sessions
    private var resumedSessions: [ResumedSession] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Session Resumption
    
    /// Resume session from checkpoint
    public func resumeSession(from checkpoint: SessionCheckpoint) -> ResumptionResult {
        let session = ResumedSession(
            sessionId: checkpoint.sessionId,
            checkpointId: checkpoint.id,
            resumedAt: Date(),
            state: checkpoint.state
        )
        
        resumedSessions.append(session)
        
        // Keep only recent sessions (last 50)
        if resumedSessions.count > 50 {
            resumedSessions.removeFirst()
        }
        
        return ResumptionResult(
            success: true,
            sessionId: session.sessionId,
            checkpointId: checkpoint.id
        )
    }
    
    // MARK: - Data Types
    
    /// Session checkpoint
    public struct SessionCheckpoint: Sendable {
        public let id: UUID
        public let sessionId: UUID
        public let timestamp: Date
        public let state: [String: String]
    }
    
    /// Resumed session
    public struct ResumedSession: Sendable {
        public let sessionId: UUID
        public let checkpointId: UUID
        public let resumedAt: Date
        public let state: [String: String]
    }
    
    /// Resumption result
    public struct ResumptionResult: Sendable {
        public let success: Bool
        public let sessionId: UUID
        public let checkpointId: UUID
    }
}
