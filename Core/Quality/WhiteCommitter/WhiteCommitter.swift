//
//  WhiteCommitter.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  WhiteCommitter - white commit atomicity (PART 0.1, P23/H1/H2)
//

import Foundation

/// WhiteCommitContract - protocol for white commit
public protocol WhiteCommitContract {
    func commitWhite(
        sessionId: String,
        auditRecord: AuditRecord,
        coverageDelta: CoverageDelta
    ) throws -> DurableToken
}

/// WhiteCommitter - implementation of white commit atomicity
/// P23/H1: Transactional session_seq computation, bounded retry, concurrent control
public class WhiteCommitter: WhiteCommitContract {
    private let database: QualityDatabase
    private let commitQueue = DispatchQueue(label: "com.aether3d.quality.commit")
    
    public init(database: QualityDatabase) {
        self.database = database
    }
    
    /// Commit white promise atomically
    /// P23: BEGIN IMMEDIATE, compute session_seq in transaction, handle UNIQUE conflicts
    /// H1: Bounded retry strategy, concurrent control
    public func commitWhite(
        sessionId: String,
        auditRecord: AuditRecord,
        coverageDelta: CoverageDelta
    ) throws -> DurableToken {
        // H1: Serialize commits using internal queue
        return try commitQueue.sync {
            try performCommit(sessionId: sessionId, auditRecord: auditRecord, coverageDelta: coverageDelta)
        }
    }
    
    private func performCommit(
        sessionId: String,
        auditRecord: AuditRecord,
        coverageDelta: CoverageDelta
    ) throws -> DurableToken {
        // PR5.1: Validate inputs BEFORE any database operations
        // SessionId must be 1..64 bytes UTF-8 (deterministic input validation)
        guard !sessionId.isEmpty && sessionId.utf8.count <= 64 else {
            throw CommitError.corruptedEvidence
        }
        
        // PR5.1: Validate audit record and coverage delta BEFORE database writes
        // If validation fails, throw immediately without touching database
        
        // P0-6: Check corruptedEvidence sticky flag before any commit attempt
        let hasCorrupted = try database.hasCorruptedEvidence(sessionId: sessionId)
        if hasCorrupted {
            throw CommitError.corruptedEvidence
        }
        
        // Compute hashes (may throw if invalid)
        let auditSHA256 = try auditRecord.computeSHA256()
        let coverageDeltaSHA256 = try coverageDelta.computeSHA256()
        
        // H1: Bounded retry strategy (retry ONLY on BUSY/LOCKED, NOT on constraint errors)
        // PR5.1: With counter table allocation, UNIQUE constraint conflicts should not occur
        // Retry only on transient BUSY/LOCKED errors (defense-in-depth)
        var lastError: Error?
        for attempt in 0..<QualityPreCheckConstants.MAX_COMMIT_RETRIES {
            do {
                return try attemptCommit(
                    sessionId: sessionId,
                    auditRecord: auditRecord,
                    coverageDelta: coverageDelta,
                    auditSHA256: auditSHA256,
                    coverageDeltaSHA256: coverageDeltaSHA256,
                    attempt: attempt
                )
            } catch let err as CommitError {
                // PR5.1: Retry ONLY on BUSY/LOCKED (transient concurrency issues)
                // Counter table allocation eliminates UNIQUE constraint races
                switch err {
                case .databaseBusy, .databaseLocked:
                    lastError = err
                    // H1: Exponential backoff (deterministic: 10ms, 20ms, 40ms)
                    if attempt < QualityPreCheckConstants.MAX_COMMIT_RETRIES - 1 {
                        let delayMs = min(
                            QualityPreCheckConstants.COMMIT_RETRY_INITIAL_DELAY_MS * Int64(1 << attempt),
                            QualityPreCheckConstants.COMMIT_RETRY_MAX_DELAY_MS
                        )
                        Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                    }
                    continue
                case .databaseUnknown(let code, let extCode, let sqlOp, let errMsg) where code == 19:
                    // PR5.1: SQLITE_CONSTRAINT (19) is NOT retryable - indicates logic error
                    // With counter table allocation, UNIQUE conflicts should not occur
                    // If they do, it's a bug, not a transient issue
                    throw CommitError.databaseUnknown(code: code, extendedCode: extCode, sqlOperation: sqlOp, errorMessage: errMsg)
                default:
                    // All other errors (including corruptedEvidence) throw immediately
                    throw err
                }
            } catch {
                // Non-CommitError exceptions throw immediately
                throw error
            }
        }
        
        // PR5.1: Include last error context in maxRetriesExceeded
        throw CommitError.maxRetriesExceeded(lastError: lastError as? CommitError)
    }
    
    private func attemptCommit(
        sessionId: String,
        auditRecord: AuditRecord,
        coverageDelta: CoverageDelta,
        auditSHA256: String,
        coverageDeltaSHA256: String,
        attempt: Int
    ) throws -> DurableToken {
        // P23: BEGIN IMMEDIATE TRANSACTION
        try database.beginTransaction()
        
        // PR5.1: Track transaction state to prevent rollback after successful commit
        var transactionCommitted = false
        
        defer {
            // PR5.1: Only rollback if transaction was not committed
            if !transactionCommitted {
                database.rollbackTransaction()
            }
        }
        
        // P23: Compute next session_seq in transaction
        let sessionSeq = try database.getNextSessionSeq(sessionId: sessionId)
        
        // P23: Get prev_commit_sha256 (or genesis zeros)
        let prevCommitSHA256 = try database.getPrevCommitSHA256(sessionId: sessionId, sessionSeq: sessionSeq)
        
        // Compute commit_sha256 (chain: prev || audit || coverageDelta)
        // PR5.1: Validate input SHA256 strings are exactly 64 hex characters (UTF-8 bytes)
        // SQLite length() counts bytes, so we must validate UTF-8 byte length
        guard prevCommitSHA256.utf8.count == 64, auditSHA256.utf8.count == 64, coverageDeltaSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        let prevBytes = Data(prevCommitSHA256.utf8)
        let auditBytes = Data(auditSHA256.utf8)
        let coverageBytes = Data(coverageDeltaSHA256.utf8)
        let commitSHA256 = SHA256Utility.sha256(concatenating: prevBytes, auditBytes, coverageBytes)
        // PR5.1: Validate output SHA256 is exactly 64 hex characters (UTF-8 bytes) before insertion
        // SQLite length() counts bytes, so validate UTF-8 byte length
        guard commitSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        
        // Get timestamps
        let tsMonotonicMs = MonotonicClock.nowMs()
        let tsWallclockReal = Date().timeIntervalSince1970
        
        // Serialize payloads
        let auditPayload = try auditRecord.toCanonicalJSONBytes()
        let coverageDeltaPayload = try coverageDelta.encode()
        
        #if DEBUG
        if coverageDeltaPayload.count >= 4 {
            let first4Bytes = coverageDeltaPayload.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[DEBUG] WhiteCommitter.attemptCommit: coverageDeltaPayload.count=\(coverageDeltaPayload.count), first 4 bytes (hex)=\(first4Bytes)")
        }
        #endif
        
        // Insert commit
        do {
            try database.insertCommit(
                sessionId: sessionId,
                sessionSeq: sessionSeq,
                tsMonotonicMs: tsMonotonicMs,
                tsWallclockReal: tsWallclockReal,
                auditPayload: auditPayload,
                coverageDeltaPayload: coverageDeltaPayload,
                auditSHA256: auditSHA256,
                coverageDeltaSHA256: coverageDeltaSHA256,
                prevCommitSHA256: prevCommitSHA256,
                commitSHA256: commitSHA256
            )
            
            // Commit transaction
            try database.commitTransaction()
            transactionCommitted = true // PR5.1: Mark transaction as committed to prevent rollback
            
            // Return DurableToken
            return DurableToken(
                schemaVersion: 1, // Current schema version
                sessionId: sessionId,
                sessionSeq: sessionSeq,
                commit_sha256: commitSHA256,
                ts_monotonic_ms: tsMonotonicMs,
                audit_sha256: auditSHA256,
                coverage_delta_sha256: coverageDeltaSHA256
            )
            } catch CommitError.databaseUnknown(let code, let extCode, let sqlOp, let errMsg) where code == 19 {
                // PR5.1: SQLITE_CONSTRAINT (19) is NOT retryable - indicates logic error
                // With counter table allocation, UNIQUE conflicts should not occur
                // If they do, it's a bug, not a transient issue
                throw CommitError.databaseUnknown(code: code, extendedCode: extCode, sqlOperation: sqlOp, errorMessage: errMsg)
            } catch {
                // All other errors (including corruptedEvidence) throw immediately
                throw error
            }
    }
}

