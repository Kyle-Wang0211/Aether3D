// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  DurableToken.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  DurableToken - commit-centric token for recovery validation (P17/P23)
//

import Foundation

/// DurableToken - commit-centric token for recovery validation
/// P17: Commit-centric (required: schemaVersion, sessionId, sessionSeq, commit_sha256, ts_monotonic_ms)
/// P23: sessionSeq renamed from sequenceNumber (session-local sequencing)
public struct DurableToken: Codable {
    /// Schema version (required)
    public let schemaVersion: Int
    
    /// Session ID (required)
    public let sessionId: String
    
    /// Session sequence number (required, P23: renamed from sequenceNumber)
    /// Session-local sequence: 1, 2, 3, ... per sessionId
    public let sessionSeq: Int
    
    /// Commit SHA256 hash (required)
    /// This is the primary validation field
    public let commit_sha256: String
    
    /// Monotonic timestamp in milliseconds (required, P20)
    public let ts_monotonic_ms: Int64
    
    /// Audit SHA256 hash (optional, debug only)
    public let audit_sha256: String?
    
    /// Coverage delta SHA256 hash (optional, debug only)
    public let coverage_delta_sha256: String?
    
    public init(
        schemaVersion: Int,
        sessionId: String,
        sessionSeq: Int,
        commit_sha256: String,
        ts_monotonic_ms: Int64,
        audit_sha256: String? = nil,
        coverage_delta_sha256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.sessionSeq = sessionSeq
        self.commit_sha256 = commit_sha256
        self.ts_monotonic_ms = ts_monotonic_ms
        self.audit_sha256 = audit_sha256
        self.coverage_delta_sha256 = coverage_delta_sha256
    }
}

