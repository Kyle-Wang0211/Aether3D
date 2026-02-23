// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CrashRecovery.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  CrashRecovery - session-scoped recovery and validation (P16/P23/H2)
//

import Foundation

/// CrashRecoveryContract - protocol for crash recovery
public protocol CrashRecoveryContract {
    func recoverSession(sessionId: String) throws -> SessionRecoveryResult
}

/// SessionRecoveryResult - result of crash recovery
public struct SessionRecoveryResult {
    public let sessionId: String
    public let status: SessionCompletionStatus
    public let recoveredCommits: Int
    public let coverageGrid: CoverageGrid?
    
    public init(sessionId: String, status: SessionCompletionStatus, recoveredCommits: Int, coverageGrid: CoverageGrid?) {
        self.sessionId = sessionId
        self.status = status
        self.recoveredCommits = recoveredCommits
        self.coverageGrid = coverageGrid
    }
}

/// CrashRecovery - implementation of crash recovery
/// P16/P23: Session-scoped, ordered by session_seq ASC only
/// H2: Time order violation detection, corruptedEvidence sticky state
public class CrashRecovery: CrashRecoveryContract {
    private let database: QualityDatabase
    
    public init(database: QualityDatabase) {
        self.database = database
    }
    
    /// Recover session from database
    /// P23: Order by session_seq ASC only (no ambiguity)
    /// H2: Validate causality ordering, detect time order violations
    public func recoverSession(sessionId: String) throws -> SessionRecoveryResult {
        #if DEBUG
        // DEBUG diagnostics: Check total commits and session-specific commits
        do {
            let totalCommits = try database.getTotalCommitCount()
            let sessionCommits = try database.getCommitCountForSession(sessionId: sessionId)
            print("[DEBUG] CrashRecovery.recoverSession: sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count))")
            print("[DEBUG]   Total commits in DB: \(totalCommits)")
            print("[DEBUG]   Commits for this session: \(sessionCommits)")
            // DEBUG: Dump all sessionIds in commits table
            try database.dumpAllSessionIds()
        } catch {
            print("[DEBUG] CrashRecovery.recoverSession: failed to get commit counts: \(error)")
        }
        #endif
        
        // Get all commits for session (ordered by session_seq ASC)
        let commits = try database.getCommitsForSession(sessionId: sessionId)
        
        #if DEBUG
        print("[DEBUG]   Retrieved commits count: \(commits.count)")
        if commits.count > 0 {
            print("[DEBUG]   First 3 commits:")
            for (idx, commit) in commits.prefix(3).enumerated() {
                print("[DEBUG]     [\(idx)] session_seq=\(commit.sessionSeq), prev_sha256=\(commit.prevCommitSHA256.prefix(16))..., commit_sha256=\(commit.commitSHA256.prefix(16))...")
            }
        } else {
            print("[DEBUG]   WARNING: No commits retrieved for sessionId='\(sessionId)'")
        }
        #endif
        
        // H1: Check commit count limit
        if commits.count > QualityPreCheckConstants.MAX_COMMITS_PER_SESSION {
            return SessionRecoveryResult(
                sessionId: sessionId,
                status: .excessiveCommits,
                recoveredCommits: 0,
                coverageGrid: nil
            )
        }
        
        // Validate session_seq continuity (P23)
        var corruptionDetected = false
        var firstCorruptCommitSha: String? = nil
        
        if !validateSessionSeqContinuity(commits: commits) {
            corruptionDetected = true
            firstCorruptCommitSha = commits.first?.commitSHA256
        }
        
        // Validate hash chain (P15/P16/P23)
        if !corruptionDetected {
            do {
                if !(try validateHashChain(commits: commits)) {
                    corruptionDetected = true
                    firstCorruptCommitSha = commits.first?.commitSHA256
                }
            } catch {
                corruptionDetected = true
                firstCorruptCommitSha = commits.first?.commitSHA256
            }
        }
        
        // H2: Validate time order (no violations)
        if !corruptionDetected && !validateTimeOrder(commits: commits) {
            corruptionDetected = true
            firstCorruptCommitSha = commits.first?.commitSHA256
        }
        
        // P0-6: Set corruptedEvidence sticky flag if corruption detected
        if corruptionDetected {
            let corruptSha = firstCorruptCommitSha ?? String(repeating: "0", count: 64)
            try database.setCorruptedEvidence(
                sessionId: sessionId,
                commitSha: corruptSha,
                timestamp: MonotonicClock.nowMs()
            )
            
            return SessionRecoveryResult(
                sessionId: sessionId,
                status: .corruptedEvidence,
                recoveredCommits: 0,
                coverageGrid: nil
            )
        }
        
        // Replay coverage deltas to rebuild CoverageGrid
        var coverageGrid = CoverageGrid()
        for commit in commits {
            try replayCoverageDelta(commit.coverageDeltaPayload, into: &coverageGrid)
        }
        
        return SessionRecoveryResult(
            sessionId: sessionId,
            status: .completed,
            recoveredCommits: commits.count,
            coverageGrid: coverageGrid
        )
    }
    
    /// Validate session_seq continuity (P23)
    /// Must be exactly 1..N with no gaps/duplicates
    private func validateSessionSeqContinuity(commits: [CommitRow]) -> Bool {
        guard !commits.isEmpty else {
            #if DEBUG
            print("[DEBUG]   validateSessionSeqContinuity: empty commits array, returning true")
            #endif
            return true
        }
        
        var expectedSeq = 1
        for commit in commits {
            if commit.sessionSeq != expectedSeq {
                #if DEBUG
                print("[DEBUG]   validateSessionSeqContinuity: gap detected at expected seq=\(expectedSeq), actual seq=\(commit.sessionSeq)")
                #endif
                return false
            }
            expectedSeq += 1
        }
        
        #if DEBUG
        print("[DEBUG]   validateSessionSeqContinuity: passed, sequence is 1..\(commits.count)")
        #endif
        return true
    }
    
    /// Validate hash chain (P15/P16/P23)
    /// Verify prev_commit_sha256 matches previous commit's commit_sha256
    /// PR5.1: Do NOT silently return genesis zeros when query fails - that masks corruption
    /// Only use genesis zeros when seq==1 by definition
    private func validateHashChain(commits: [CommitRow]) throws -> Bool {
        guard !commits.isEmpty else {
            #if DEBUG
            print("[DEBUG]   validateHashChain: empty commits array, returning true")
            #endif
            return true
        }
        
        // First commit: prev_commit_sha256 must be 64-hex zeros (genesis)
        let firstCommit = commits[0]
        guard firstCommit.sessionSeq == 1 else {
            // PR5.1: If first commit is not seq=1, chain is invalid
            #if DEBUG
            print("[DEBUG]   validateHashChain: first commit session_seq=\(firstCommit.sessionSeq), expected 1")
            #endif
            return false
        }
        
        let genesisZeros = String(repeating: "0", count: 64)
        guard firstCommit.prevCommitSHA256 == genesisZeros else {
            // PR5.1: First commit must have genesis zeros as prev
            #if DEBUG
            print("[DEBUG]   validateHashChain: first commit prev_sha256='\(firstCommit.prevCommitSHA256.prefix(16))...', expected genesis zeros")
            #endif
            return false
        }
        
        // Verify each commit's prev_commit_sha256 matches previous commit's commit_sha256
        for i in 1..<commits.count {
            let prevCommit = commits[i - 1]
            let currentCommit = commits[i]
            
            // PR5.1: Verify session_seq continuity
            guard currentCommit.sessionSeq == prevCommit.sessionSeq + 1 else {
                #if DEBUG
                print("[DEBUG]   validateHashChain: seq continuity failed at index \(i): prev.seq=\(prevCommit.sessionSeq), current.seq=\(currentCommit.sessionSeq)")
                #endif
                return false
            }
            
            // PR5.1: Verify prev_commit_sha256 matches previous commit's commit_sha256
            guard currentCommit.prevCommitSHA256 == prevCommit.commitSHA256 else {
                #if DEBUG
                print("[DEBUG]   validateHashChain: hash chain broken at index \(i): current.prev='\(currentCommit.prevCommitSHA256.prefix(16))...', prev.commit='\(prevCommit.commitSHA256.prefix(16))...'")
                #endif
                return false
            }
            
            // Recompute and verify commit_sha256
            let prevBytes = Data(currentCommit.prevCommitSHA256.utf8)
            let auditBytes = Data(currentCommit.auditSHA256.utf8)
            let coverageBytes = Data(currentCommit.coverageDeltaSHA256.utf8)
            let computedSHA256 = SHA256Utility.sha256(concatenating: prevBytes, auditBytes, coverageBytes)
            
            guard computedSHA256 == currentCommit.commitSHA256 else {
                #if DEBUG
                print("[DEBUG]   validateHashChain: commit_sha256 mismatch at index \(i): computed='\(computedSHA256.prefix(16))...', stored='\(currentCommit.commitSHA256.prefix(16))...'")
                #endif
                return false
            }
        }
        
        #if DEBUG
        print("[DEBUG]   validateHashChain: passed for \(commits.count) commits")
        #endif
        return true
    }
    
    /// Validate time order (H2)
    /// H2: Detect time order violations (ts_monotonic_ms must be non-decreasing)
    private func validateTimeOrder(commits: [CommitRow]) -> Bool {
        guard commits.count > 1 else { return true }
        
        for i in 1..<commits.count {
            let prevTs = commits[i - 1].tsMonotonicMs
            let currentTs = commits[i].tsMonotonicMs
            
            // H2: Time order violation - ts_monotonic_ms must be non-decreasing
            if currentTs < prevTs {
                return false
            }
        }
        
        return true
    }
    
    /// Replay coverage delta into coverage grid
    /// P21: Validate newState values (must be 0, 1, or 2)
    private func replayCoverageDelta(_ payload: Data, into grid: inout CoverageGrid) throws {
        guard payload.count >= 4 else {
            throw CommitError.corruptedEvidence
        }
        
        // Read changedCount (u32 LE)
        // Ensure we read exactly 4 bytes from the start of payload
        guard payload.count >= 4 else {
            throw CommitError.corruptedEvidence
        }
        
        #if DEBUG
        let first4Bytes = payload.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[DEBUG] replayCoverageDelta: payload.count=\(payload.count), first 4 bytes (hex)=\(first4Bytes)")
        #endif
        
        let changedCount = payload.prefix(4).withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.load(as: UInt32.self))
        }
        
        #if DEBUG
        print("[DEBUG] replayCoverageDelta: changedCount=\(changedCount), MAX_DELTA_CHANGED_COUNT=\(QualityPreCheckConstants.MAX_DELTA_CHANGED_COUNT)")
        #endif
        
        guard Int(changedCount) <= QualityPreCheckConstants.MAX_DELTA_CHANGED_COUNT else {
            #if DEBUG
            print("[DEBUG] replayCoverageDelta: deltaTooLarge - changedCount=\(changedCount) > MAX=\(QualityPreCheckConstants.MAX_DELTA_CHANGED_COUNT)")
            #endif
            throw CommitError.deltaTooLarge
        }
        
        var offset = 4
        for _ in 0..<changedCount {
            guard offset + 5 <= payload.count else {
                throw CommitError.corruptedEvidence
            }
            
            // Read cellIndex (u32 LE)
            let cellIndex = payload.subdata(in: offset..<offset+4).withUnsafeBytes { bytes in
                bytes.load(as: UInt32.self).littleEndian
            }
            offset += 4
            
            // Read newState (u8)
            let newState = payload[offset]
            offset += 1
            
            // P21: Validate newState (must be 0, 1, or 2)
            guard newState <= 2 else {
                throw CommitError.corruptedEvidence
            }
            
            // Update grid
            let state = CoverageState(rawValue: newState) ?? .uncovered
            grid.setState(state, at: Int(cellIndex))
        }
    }
}

