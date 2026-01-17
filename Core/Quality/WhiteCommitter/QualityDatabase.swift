//
//  QualityDatabase.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  SQLite database wrapper using system SQLite3 C API (PATCH E1, P23/H1/H2)
//

import Foundation
import SQLite3

/// QualityDatabase - SQLite database wrapper for quality commits
/// Uses system SQLite3 C API (not Swift wrappers) per PATCH E1
public class QualityDatabase {
    private var db: OpaquePointer?
    private let dbPath: String
    private let commitQueue = DispatchQueue(label: "com.aether3d.quality.commit")
    
    /// Current schema version
    public static let currentSchemaVersion: Int = 1
    
    public init(dbPath: String) {
        self.dbPath = dbPath
    }
    
    /// Open database connection
    /// PR5.1: Validates PRAGMA setup and ensures WAL mode is actually set
    public func open() throws {
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw mapSQLiteError(result, sqlOperation: "OPEN_DB")
        }
        
        // Configure WAL + synchronous=FULL
        // PR5.1: Verify PRAGMA commands succeed and verify journal_mode was set
        var errorMsg: UnsafeMutablePointer<CChar>?
        let walResult = sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, &errorMsg)
        guard walResult == SQLITE_OK else {
            sqlite3_free(errorMsg)
            throw mapSQLiteError(walResult, sqlOperation: "PRAGMA_WAL")
        }
        sqlite3_free(errorMsg)
        
        // Verify journal_mode was actually set to WAL (not just accepted)
        let verifyQuery = "PRAGMA journal_mode"
        var verifyStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, verifyQuery, -1, &verifyStmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "VERIFY_WAL")
        }
        defer { sqlite3_finalize(verifyStmt) }
        if sqlite3_step(verifyStmt) == SQLITE_ROW {
            if let journalMode = sqlite3_column_text(verifyStmt, 0) {
                let mode = String(cString: journalMode).uppercased()
                if mode != "WAL" {
                    throw CommitError.databaseUnknown(code: Int(SQLITE_ERROR), extendedCode: nil, sqlOperation: "VERIFY_WAL", errorMessage: "Journal mode is \(mode), expected WAL")
                }
            }
        }
        
        let syncResult = sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, &errorMsg)
        guard syncResult == SQLITE_OK else {
            sqlite3_free(errorMsg)
            throw mapSQLiteError(syncResult, sqlOperation: "PRAGMA_SYNC")
        }
        sqlite3_free(errorMsg)
        
        // PR5.1: Enable foreign keys for consistency
        let fkResult = sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, &errorMsg)
        guard fkResult == SQLITE_OK else {
            sqlite3_free(errorMsg)
            throw mapSQLiteError(fkResult, sqlOperation: "PRAGMA_FK")
        }
        sqlite3_free(errorMsg)
        
        // Initialize schema
        try initializeSchema()
    }
    
    /// Close database connection
    public func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    /// Initialize database schema
    private func initializeSchema() throws {
        // Check if commits table exists
        let tableExists = try checkTableExists("commits")
        
        if !tableExists {
            // Create new schema
            try createSchema()
        } else {
            // Check schema version and migrate if needed
            try checkAndMigrateSchema()
        }
    }
    
    /// Create new schema (version 1)
    private func createSchema() throws {
        let createCommitsTableSQL = """
        CREATE TABLE commits (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            sessionId TEXT NOT NULL,
            session_seq INTEGER NOT NULL,
            ts_monotonic_ms INTEGER NOT NULL,
            ts_wallclock_real REAL NOT NULL,
            audit_payload BLOB NOT NULL,
            coverage_delta_payload BLOB NOT NULL,
            audit_sha256 TEXT NOT NULL,
            coverage_delta_sha256 TEXT NOT NULL,
            prev_commit_sha256 TEXT NOT NULL,
            commit_sha256 TEXT NOT NULL,
            schemaVersion INTEGER NOT NULL,
            UNIQUE(sessionId, session_seq),
            CHECK(session_seq >= 1),
            CHECK(length(commit_sha256) = 64),
            CHECK(length(prev_commit_sha256) = 64),
            CHECK(length(audit_sha256) = 64),
            CHECK(length(coverage_delta_sha256) = 64),
            CHECK(ts_monotonic_ms >= 0),
            CHECK(length(sessionId) > 0 AND length(sessionId) <= 64)
        )
        """
        
        try execute(createCommitsTableSQL)
        
        // Create session_flags table (P0-6: corruptedEvidence sticky persistence)
        let createSessionFlagsSQL = """
        CREATE TABLE session_flags (
            sessionId TEXT PRIMARY KEY,
            corruptedEvidenceSticky BOOLEAN NOT NULL DEFAULT 0,
            firstCorruptCommitSha TEXT,
            ts_first_corrupt_ms INTEGER,
            CHECK(length(firstCorruptCommitSha) = 64 OR firstCorruptCommitSha IS NULL),
            CHECK(ts_first_corrupt_ms >= 0 OR ts_first_corrupt_ms IS NULL)
        )
        """
        
        try execute(createSessionFlagsSQL)
        
        // PR5.1: Create session_counters table for atomic session_seq allocation
        // Eliminates MAX(session_seq) race condition by using atomic counter updates
        // Schema: session_counters(sessionId TEXT PRIMARY KEY, next_seq INTEGER NOT NULL)
        let createSessionCountersSQL = """
        CREATE TABLE IF NOT EXISTS session_counters (
            sessionId TEXT PRIMARY KEY,
            next_seq INTEGER NOT NULL DEFAULT 1,
            CHECK(next_seq >= 1),
            CHECK(length(sessionId) > 0 AND length(sessionId) <= 64)
        )
        """
        
        try execute(createSessionCountersSQL)
        
        // Create indexes
        try execute("CREATE INDEX idx_commits_session_seq ON commits(sessionId, session_seq)")
        try execute("CREATE INDEX idx_commits_session_ts ON commits(sessionId, ts_monotonic_ms)")
    }
    
    /// Check if table exists
    private func checkTableExists(_ tableName: String) throws -> Bool {
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db))
        }
        
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_bind_text(stmt, 1, tableName, -1, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db))
        }
        
        let result = sqlite3_step(stmt)
        return result == SQLITE_ROW
    }
    
    /// Check schema version and migrate if needed
    private func checkAndMigrateSchema() throws {
        // H1: Migration lock - block all commits during migration
        // For now, simple check - full migration logic would go here
        // This is a placeholder for schema migration (P23/H1)
    }
    
    /// Execute SQL statement
    private func execute(_ sql: String) throws {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        
        if result != SQLITE_OK {
            // PR5.1: Enhanced error reporting with extended codes and SQL operation context
            let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
            sqlite3_free(errorMsg)
            // Extract SQL operation tag from statement (first word)
            let sqlOperation = sql.components(separatedBy: .whitespaces).first?.uppercased()
            throw mapSQLiteError(result, sqlOperation: sqlOperation)
        }
    }
    
    /// Map SQLite error code to CommitError
    /// H1: Explicit error code mapping
    /// PR5.1: Enhanced with extended error codes and SQL operation context
    public func mapSQLiteError(_ code: Int32, sqlOperation: String? = nil) -> CommitError {
        // Get extended error code if available
        let extendedCode = sqlite3_extended_errcode(db)
        
        switch code {
        case SQLITE_BUSY:
            return .databaseBusy(extendedCode: extendedCode, sqlOperation: sqlOperation)
        case SQLITE_LOCKED:
            return .databaseLocked(extendedCode: extendedCode, sqlOperation: sqlOperation)
        case SQLITE_IOERR:
            return .databaseIOError(extendedCode: extendedCode, sqlOperation: sqlOperation)
        case SQLITE_CORRUPT:
            return .databaseCorrupt(extendedCode: extendedCode, sqlOperation: sqlOperation)
        case SQLITE_FULL:
            return .databaseFull(extendedCode: extendedCode, sqlOperation: sqlOperation)
        default:
            // Get error message for unknown errors
            let errorMsg = sqlite3_errmsg(db)
            let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
            return .databaseUnknown(code: Int(code), extendedCode: extendedCode, sqlOperation: sqlOperation, errorMessage: errorMessage)
        }
    }
    
    /// Check if a table exists in the database
    /// PR5.1: Helper to detect schema version / backward compatibility
    private func hasTable(_ tableName: String) throws -> Bool {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "CHECK_TABLE_EXISTS")
        }
        defer { sqlite3_finalize(stmt) }
        
        let bindResult = tableName.withCString { cString -> Int32 in
            let byteCount = Int32(tableName.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "CHECK_TABLE_EXISTS")
        }
        
        let stepResult = sqlite3_step(stmt)
        return stepResult == SQLITE_ROW
    }
    
    /// Get next session_seq for a session (must be called within write transaction)
    /// PR5.1: Supports both atomic counter table allocation (preferred) and MAX() fallback (backward compat)
    /// Must be called within BEGIN IMMEDIATE transaction to ensure exclusive write lock
    func getNextSessionSeq(sessionId: String) throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // PR5.1: SessionId validation should have happened before calling this method
        // But double-check for safety
        guard !sessionId.isEmpty && sessionId.utf8.count <= 64 else {
            throw CommitError.corruptedEvidence
        }
        
        // PR5.1: Check if session_counters table exists (preferred path)
        let hasCounterTable = try hasTable("session_counters")
        
        if hasCounterTable {
            // Preferred path: Atomic allocation using counter table
            let allocatedSeq = try getNextSessionSeqFromCounter(sessionId: sessionId)
            
            #if DEBUG
            // DEBUG: Dump session_counters table state
            try dumpSessionCountersTable()
            #endif
            
            return allocatedSeq
        } else {
            // Fallback path: MAX(session_seq) + 1 (backward compatibility with older schema)
            // Must be scoped by WHERE sessionId = ? and executed inside the same transaction
            return try getNextSessionSeqFromMax(sessionId: sessionId)
        }
    }
    
    /// Preferred path: Atomic allocation using session_counters table
    /// PR5.1: Uses UPSERT pattern to atomically increment and return allocated value
    private func getNextSessionSeqFromCounter(sessionId: String) throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // PR5.1: Atomic allocation using SQLite UPSERT
        // INSERT INTO session_counters(sessionId, next_seq) VALUES(?, 2)
        // ON CONFLICT(sessionId) DO UPDATE SET next_seq = session_counters.next_seq + 1
        // RETURNING (next_seq - 1);
        // This ensures: new session returns 1; subsequent calls return 2,3,... per session
        let queryWithReturning = """
        INSERT INTO session_counters(sessionId, next_seq)
        VALUES(?, 2)
        ON CONFLICT(sessionId) DO UPDATE SET next_seq = session_counters.next_seq + 1
        RETURNING (next_seq - 1)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, queryWithReturning, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER")
        }
        defer { sqlite3_finalize(stmt) }
        
        // Bind sessionId with explicit UTF-8 byte length
        // Use SQLITE_TRANSIENT to ensure SQLite copies the string (withCString pointer is temporary)
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER")
        }
        
        // Execute INSERT/UPDATE and get returned session_seq
        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            // RETURNING clause supported - return the allocated value
            // Logic: INSERT ... VALUES(?, 2) sets next_seq=2, RETURNING (2-1)=1 (allocated seq=1)
            // UPDATE ... SET next_seq = next_seq + 1: if next_seq was 2, it becomes 3, RETURNING (3-1)=2 (allocated seq=2)
            // So RETURNING (next_seq - 1) returns the allocated session_seq directly
            let sessionSeq = sqlite3_column_int(stmt, 0)
            
            #if DEBUG
            print("[DEBUG] session_counters allocation: sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count)), allocated seq=\(sessionSeq)")
            #endif
            
            return Int(sessionSeq)
        } else if stepResult == SQLITE_DONE {
            // RETURNING not supported - fall back to read-after-write pattern
            return try getNextSessionSeqFromCounterFallback(sessionId: sessionId)
        } else {
            // Check if it's a constraint error (should not happen with valid sessionId)
            let errCode = sqlite3_errcode(db)
            if errCode == SQLITE_CONSTRAINT {
                let extendedCode = sqlite3_extended_errcode(db)
                let errorMsg = sqlite3_errmsg(db)
                let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
                throw CommitError.databaseUnknown(code: Int(errCode), extendedCode: extendedCode, sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER", errorMessage: errorMessage)
            }
            throw mapSQLiteError(errCode, sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER")
        }
    }
    
    /// Fallback for counter table allocation when RETURNING is not supported
    /// PR5.1: Reads the allocated value after INSERT/UPDATE
    private func getNextSessionSeqFromCounterFallback(sessionId: String) throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // First, ensure counter exists (INSERT if needed, UPDATE if exists)
        // Start with next_seq=2 for first commit (will return 2-1=1)
        let insertQuery = """
        INSERT INTO session_counters(sessionId, next_seq)
        VALUES(?, 2)
        ON CONFLICT(sessionId) DO UPDATE SET next_seq = session_counters.next_seq + 1
        """
        
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertQuery, -1, &insertStmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER_FALLBACK")
        }
        defer { sqlite3_finalize(insertStmt) }
        
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(insertStmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER_FALLBACK")
        }
        
        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "ALLOCATE_SESSION_SEQ_COUNTER_FALLBACK")
        }
        
        // Now read the allocated value (next_seq after increment, then subtract 1)
        let readQuery = "SELECT (next_seq - 1) FROM session_counters WHERE sessionId = ?"
        var readStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, readQuery, -1, &readStmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "READ_SESSION_SEQ_COUNTER_FALLBACK")
        }
        defer { sqlite3_finalize(readStmt) }
        
        let readBindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(readStmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard readBindResult == SQLITE_OK else {
            throw mapSQLiteError(readBindResult, sqlOperation: "READ_SESSION_SEQ_COUNTER_FALLBACK")
        }
        
        guard sqlite3_step(readStmt) == SQLITE_ROW else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "READ_SESSION_SEQ_COUNTER_FALLBACK")
        }
        
        // PR5.1: Return (next_seq - 1) as allocated session_seq
        // Logic: INSERT ... VALUES(?, 2) sets next_seq=2, allocated seq=2-1=1
        // UPDATE ... SET next_seq = next_seq + 1: if next_seq was 2, it becomes 3, allocated seq=3-1=2
        let allocatedSeq = sqlite3_column_int(readStmt, 0)
        
        #if DEBUG
        print("[DEBUG] session_counters allocation (fallback): sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count)), allocated seq=\(allocatedSeq)")
        #endif
        
        return Int(allocatedSeq)
    }
    
    /// Fallback path: MAX(session_seq) + 1 from commits table
    /// PR5.1: Backward compatibility for older schema without session_counters table
    private func getNextSessionSeqFromMax(sessionId: String) throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        let query = "SELECT COALESCE(MAX(session_seq), 0) + 1 FROM commits WHERE sessionId = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "ALLOCATE_SESSION_SEQ_MAX")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        // Bind sessionId with explicit UTF-8 byte length
        // Use SQLITE_TRANSIENT to ensure SQLite copies the string (withCString pointer is temporary)
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "ALLOCATE_SESSION_SEQ_MAX")
        }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "ALLOCATE_SESSION_SEQ_MAX")
        }
        
        let sessionSeq = sqlite3_column_int(stmt, 0)
        return Int(sessionSeq)
    }
    
    /// Get previous commit SHA256 for a session
    func getPrevCommitSHA256(sessionId: String, sessionSeq: Int) throws -> String {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        if sessionSeq == 1 {
            // Genesis: return 64-hex zeros (P15/P16/P23)
            return String(repeating: "0", count: 64)
        }
        
        // P23: Get prev commit (session_seq - 1) for this sessionId
        // Query prev_commit_sha256 from the previous commit, or commit_sha256 if we need the hash chain
        // Actually, we need commit_sha256 from the previous commit to use as prev_commit_sha256 for current
        let query = "SELECT commit_sha256 FROM commits WHERE sessionId = ? AND session_seq = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_PREV_COMMIT")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        // PR5.1: Bind sessionId with explicit UTF-8 byte length
        let bindResult1 = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult1 == SQLITE_OK else {
            throw mapSQLiteError(bindResult1, sqlOperation: "SELECT_PREV_COMMIT")
        }
        guard sqlite3_bind_int(stmt, 2, Int32(sessionSeq - 1)) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_PREV_COMMIT")
        }
        
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_ROW else {
            // PR5.1: If no row found, this means the previous commit doesn't exist
            // This should not happen if session_seq is correct, but handle gracefully
            // Return genesis zeros as fallback (should not happen in normal flow)
            if stepResult == SQLITE_DONE {
                return String(repeating: "0", count: 64)
            }
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_PREV_COMMIT")
        }
        
        guard let sha256 = sqlite3_column_text(stmt, 0) else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_PREV_COMMIT")
        }
        
        return String(cString: sha256)
    }
    
    /// Insert commit (must be called within transaction)
    /// PR5.1: Validates all SHA256 strings are exactly 64 hex characters before insertion
    func insertCommit(
        sessionId: String,
        sessionSeq: Int,
        tsMonotonicMs: Int64,
        tsWallclockReal: Double,
        auditPayload: Data,
        coverageDeltaPayload: Data,
        auditSHA256: String,
        coverageDeltaSHA256: String,
        prevCommitSHA256: String,
        commitSHA256: String
    ) throws {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // PR5.1: Validate all SHA256 strings are exactly 64 hex characters (UTF-8 bytes)
        // CHECK constraint: length(commit_sha256) = 64, length(audit_sha256) = 64, etc.
        // SQLite length() counts bytes, so validate UTF-8 byte length
        guard auditSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        guard coverageDeltaSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        guard prevCommitSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        guard commitSHA256.utf8.count == 64 else {
            throw CommitError.corruptedEvidence
        }
        
        // H1: Validate payload sizes
        guard auditPayload.count <= QualityPreCheckConstants.MAX_AUDIT_PAYLOAD_BYTES else {
            throw CommitError.payloadTooLarge
        }
        guard coverageDeltaPayload.count <= QualityPreCheckConstants.MAX_COVERAGE_DELTA_PAYLOAD_BYTES else {
            throw CommitError.payloadTooLarge
        }
        
        let insertSQL = """
        INSERT INTO commits (
            sessionId, session_seq, ts_monotonic_ms, ts_wallclock_real,
            audit_payload, coverage_delta_payload,
            audit_sha256, coverage_delta_sha256, prev_commit_sha256, commit_sha256,
            schemaVersion
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db))
        }
        
        defer { sqlite3_finalize(stmt) }
        
        // Bind parameters
        var bindIndex: Int32 = 1
        // PR5.1: Validate sessionId length before binding (CHECK constraint: length(sessionId) > 0 AND length(sessionId) <= 64)
        guard !sessionId.isEmpty && sessionId.utf8.count <= 64 else {
            throw CommitError.corruptedEvidence
        }
        let sessionIdBindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sessionIdBindResult == SQLITE_OK else {
            throw mapSQLiteError(sessionIdBindResult, sqlOperation: "INSERT_COMMIT_BIND_SESSIONID")
        }
        bindIndex += 1
        sqlite3_bind_int(stmt, bindIndex, Int32(sessionSeq)); bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, tsMonotonicMs); bindIndex += 1
        sqlite3_bind_double(stmt, bindIndex, tsWallclockReal); bindIndex += 1
        
        let auditBindResult = auditPayload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, bindIndex, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard auditBindResult == SQLITE_OK else {
            throw mapSQLiteError(auditBindResult)
        }
        bindIndex += 1
        
        let coverageBindResult = coverageDeltaPayload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, bindIndex, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard coverageBindResult == SQLITE_OK else {
            throw mapSQLiteError(coverageBindResult)
        }
        bindIndex += 1
        
        // PR5.1: Explicitly bind SHA256 strings with UTF-8 byte length
        // SQLite length() counts bytes, so we must ensure exact byte length
        // Use withCString to properly convert Swift String to C string
        auditSHA256.withCString { cString in
            let byteCount = Int32(auditSHA256.utf8.count)
            sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        bindIndex += 1
        coverageDeltaSHA256.withCString { cString in
            let byteCount = Int32(coverageDeltaSHA256.utf8.count)
            sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        bindIndex += 1
        prevCommitSHA256.withCString { cString in
            let byteCount = Int32(prevCommitSHA256.utf8.count)
            sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        bindIndex += 1
        commitSHA256.withCString { cString in
            let byteCount = Int32(commitSHA256.utf8.count)
            sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        bindIndex += 1
        sqlite3_bind_int(stmt, bindIndex, Int32(QualityDatabase.currentSchemaVersion)); bindIndex += 1
        
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            if result == SQLITE_CONSTRAINT {
                // PR5.1: Enhanced error reporting for constraint violations
                let extendedCode = sqlite3_extended_errcode(db)
                let errorMsg = sqlite3_errmsg(db)
                let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
                // PR5.1: With counter table allocation, UNIQUE constraint conflicts should not occur
                // If they do, it's a logic error, not a transient issue - do NOT retry
                throw CommitError.databaseUnknown(code: Int(SQLITE_CONSTRAINT), extendedCode: extendedCode, sqlOperation: "INSERT_COMMIT", errorMessage: errorMessage)
            }
            throw mapSQLiteError(result, sqlOperation: "INSERT_COMMIT")
        }
    }
    
    /// Begin immediate transaction
    /// P23/PR5.1: BEGIN IMMEDIATE acquires exclusive write lock to prevent concurrent writers
    /// Must be used for all commitWhite transactions to ensure atomic session_seq allocation
    func beginTransaction() throws {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: "BEGIN_TRANSACTION")
        }
        
        // PR5.1: Use BEGIN IMMEDIATE to acquire exclusive write lock immediately
        // This ensures no other transaction can read/write until this transaction commits
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, &errorMsg)
        
        if result != SQLITE_OK {
            let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
            sqlite3_free(errorMsg)
            
            // PR5.1: BUSY/LOCKED errors indicate another transaction is holding the lock
            // These are retryable errors (handled by retry logic in WhiteCommitter)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                throw CommitError.databaseBusy(extendedCode: sqlite3_extended_errcode(db), sqlOperation: "BEGIN_IMMEDIATE")
            }
            
            throw mapSQLiteError(result, sqlOperation: "BEGIN_IMMEDIATE")
        }
    }
    
    /// Commit transaction
    /// PR5.1: Validates transaction state before committing
    /// Ensures all prepared statements are finalized and transaction is properly committed
    func commitTransaction() throws {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: "COMMIT")
        }
        
        // PR5.1: Check if we're actually in a transaction
        // sqlite3_get_autocommit returns 0 if in transaction, 1 if not
        let inTransaction = sqlite3_get_autocommit(db) == 0
        guard inTransaction else {
            // Not in transaction - this is an error (should not commit when not in transaction)
            throw CommitError.databaseUnknown(code: Int(SQLITE_ERROR), extendedCode: nil, sqlOperation: "COMMIT", errorMessage: "Attempted to commit when not in transaction")
        }
        
        // PR5.1: Commit the transaction
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, "COMMIT", nil, nil, &errorMsg)
        
        if result != SQLITE_OK {
            let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
            sqlite3_free(errorMsg)
            throw mapSQLiteError(result, sqlOperation: "COMMIT")
        }
    }
    
    /// Rollback transaction
    /// PR5.1: Safe to call even if not in transaction (no-op)
    /// Only rolls back if actually in a transaction
    func rollbackTransaction() {
        guard let db = db else { return }
        
        // PR5.1: Check if we're actually in a transaction
        let inTransaction = sqlite3_get_autocommit(db) == 0
        guard inTransaction else {
            // Not in transaction - no-op (safe to call)
            return
        }
        
        // PR5.1: Rollback the transaction
        // Use try? to ignore errors (transaction might already be rolled back by SQLite)
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, "ROLLBACK", nil, nil, &errorMsg)
        sqlite3_free(errorMsg)
        // Ignore errors - rollback is best-effort cleanup
    }
    
    /// Set corruptedEvidence sticky flag for a session
    /// P0-6: Session-scoped sticky flag storage
    /// PR5.1: Validates commitSha length before insertion, ensures committed write
    /// This method MUST be called outside a transaction or within a committed transaction
    /// to ensure the flag persists and is readable by hasCorruptedEvidence()
    func setCorruptedEvidence(sessionId: String, commitSha: String, timestamp: Int64) throws {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // PR5.1: Validate sessionId length
        guard !sessionId.isEmpty && sessionId.utf8.count <= 64 else {
            throw CommitError.corruptedEvidence
        }
        
        // PR5.1: Validate commitSha is exactly 64 hex characters (UTF-8 bytes) or empty (will be NULL)
        // CHECK constraint: length(firstCorruptCommitSha) = 64 OR firstCorruptCommitSha IS NULL
        // SQLite length() counts bytes, so validate UTF-8 byte length
        if !commitSha.isEmpty && commitSha.utf8.count != 64 {
            throw CommitError.corruptedEvidence
        }
        
        // PR5.1: setCorruptedEvidence must be called outside a transaction
        // If called within a transaction, the write won't be visible until commit
        // For immediate visibility, ensure we're in autocommit mode
        // Note: This is a defensive check - callers should ensure no active transaction
        
        let sql = """
        INSERT INTO session_flags (sessionId, corruptedEvidenceSticky, firstCorruptCommitSha, ts_first_corrupt_ms)
        VALUES (?, 1, ?, ?)
        ON CONFLICT(sessionId) DO UPDATE SET
            corruptedEvidenceSticky = 1,
            firstCorruptCommitSha = COALESCE(firstCorruptCommitSha, excluded.firstCorruptCommitSha),
            ts_first_corrupt_ms = COALESCE(ts_first_corrupt_ms, excluded.ts_first_corrupt_ms)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "INSERT_SESSION_FLAGS")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        var bindIndex: Int32 = 1
        // Bind sessionId with explicit UTF-8 byte length
        let sessionIdBindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sessionIdBindResult == SQLITE_OK else {
            throw mapSQLiteError(sessionIdBindResult, sqlOperation: "INSERT_SESSION_FLAGS")
        }
        bindIndex += 1
        
        // Bind commitSha (NULL if empty, otherwise 64-byte string)
        let commitShaBindResult: Int32
        if commitSha.isEmpty {
            commitShaBindResult = sqlite3_bind_null(stmt, bindIndex)
        } else {
            commitShaBindResult = commitSha.withCString { cString -> Int32 in
                let byteCount = Int32(commitSha.utf8.count)
                return sqlite3_bind_text(stmt, bindIndex, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        guard commitShaBindResult == SQLITE_OK else {
            throw mapSQLiteError(commitShaBindResult, sqlOperation: "INSERT_SESSION_FLAGS")
        }
        bindIndex += 1
        
        guard sqlite3_bind_int64(stmt, bindIndex, timestamp) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "INSERT_SESSION_FLAGS")
        }
        bindIndex += 1
        
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            // PR5.1: Enhanced error reporting for constraint violations
            let extendedCode = sqlite3_extended_errcode(db)
            let errorMsg = sqlite3_errmsg(db)
            let errorMessage = errorMsg != nil ? String(cString: errorMsg!) : nil
            if result == SQLITE_CONSTRAINT {
                throw CommitError.databaseUnknown(code: Int(SQLITE_CONSTRAINT), extendedCode: extendedCode, sqlOperation: "INSERT_SESSION_FLAGS", errorMessage: errorMessage)
            }
            throw mapSQLiteError(result, sqlOperation: "INSERT_SESSION_FLAGS")
        }
        
        // PR5.1: Ensure the write is committed (autocommit mode commits immediately)
        // If we were in a transaction, we already committed above
    }
    
    /// Check if session has corruptedEvidence sticky flag
    /// P0-6: Returns true if corruptedEvidence is set (blocks new white forever)
    /// PR5.1: Validates sessionId length, uses explicit UTF-8 byte length binding,
    /// and correctly interprets SQLite INTEGER type (not BOOLEAN text affinity)
    func hasCorruptedEvidence(sessionId: String) throws -> Bool {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // PR5.1: Validate sessionId length
        guard !sessionId.isEmpty && sessionId.utf8.count <= 64 else {
            throw CommitError.corruptedEvidence
        }
        
        let sql = "SELECT corruptedEvidenceSticky FROM session_flags WHERE sessionId = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_CORRUPTED_EVIDENCE")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        // PR5.1: Explicitly bind sessionId with UTF-8 byte length
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "SELECT_CORRUPTED_EVIDENCE")
        }
        
        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            // PR5.1: Read as INTEGER (not BOOLEAN text affinity)
            // SQLite stores BOOLEAN as INTEGER 0/1, so use sqlite3_column_int
            let sticky = sqlite3_column_int(stmt, 0)
            return sticky != 0
        } else if stepResult == SQLITE_DONE {
            // No row found = no corrupted evidence
            return false
        } else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "SELECT_CORRUPTED_EVIDENCE")
        }
    }
    
    /// Get all commits for a session (for crash recovery)
    func getCommitsForSession(sessionId: String) throws -> [CommitRow] {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        // P23: Order by session_seq ASC only (no ambiguity)
        let query = "SELECT session_seq, ts_monotonic_ms, audit_payload, coverage_delta_payload, audit_sha256, coverage_delta_sha256, prev_commit_sha256, commit_sha256, schemaVersion FROM commits WHERE sessionId = ? ORDER BY session_seq ASC"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db))
        }
        
        defer { sqlite3_finalize(stmt) }
        
        // PR5.1: Bind sessionId with explicit UTF-8 byte length
        #if DEBUG
        print("[DEBUG] getCommitsForSession: binding sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count))")
        #endif
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "GET_COMMITS_FOR_SESSION")
        }
        
        var commits: [CommitRow] = []
        
        #if DEBUG
        var rowCount = 0
        #endif
        while sqlite3_step(stmt) == SQLITE_ROW {
            #if DEBUG
            rowCount += 1
            #endif
            let sessionSeq = Int(sqlite3_column_int(stmt, 0))
            let tsMonotonicMs = sqlite3_column_int64(stmt, 1)
            
            let auditPayloadLength = sqlite3_column_bytes(stmt, 2)
            let auditPayloadPtr = sqlite3_column_blob(stmt, 2)
            let auditPayload = Data(bytes: auditPayloadPtr!, count: Int(auditPayloadLength))
            
            let coverageDeltaPayloadLength = sqlite3_column_bytes(stmt, 3)
            let coverageDeltaPayloadPtr = sqlite3_column_blob(stmt, 3)
            let coverageDeltaPayload = Data(bytes: coverageDeltaPayloadPtr!, count: Int(coverageDeltaPayloadLength))
            
            let auditSHA256 = String(cString: sqlite3_column_text(stmt, 4))
            let coverageDeltaSHA256 = String(cString: sqlite3_column_text(stmt, 5))
            let prevCommitSHA256 = String(cString: sqlite3_column_text(stmt, 6))
            let commitSHA256 = String(cString: sqlite3_column_text(stmt, 7))
            let schemaVersion = Int(sqlite3_column_int(stmt, 8))
            
            commits.append(CommitRow(
                sessionSeq: sessionSeq,
                tsMonotonicMs: tsMonotonicMs,
                auditPayload: auditPayload,
                coverageDeltaPayload: coverageDeltaPayload,
                auditSHA256: auditSHA256,
                coverageDeltaSHA256: coverageDeltaSHA256,
                prevCommitSHA256: prevCommitSHA256,
                commitSHA256: commitSHA256,
                schemaVersion: schemaVersion
            ))
        }
        
        #if DEBUG
        print("[DEBUG] getCommitsForSession: retrieved \(rowCount) rows for sessionId='\(sessionId)'")
        #endif
        
        return commits
    }
    
    /// Get total commit count (DEBUG only)
    #if DEBUG
    func getTotalCommitCount() throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        let query = "SELECT COUNT(*) FROM commits"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "COUNT_TOTAL_COMMITS")
        }
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "COUNT_TOTAL_COMMITS")
        }
        
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    /// DEBUG: Dump all sessionIds in commits table
    func dumpAllSessionIds() throws {
        guard let db = db else { return }
        
        let query = "SELECT DISTINCT sessionId FROM commits ORDER BY sessionId"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        print("[DEBUG] All sessionIds in commits table:")
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionIdPtr = sqlite3_column_text(stmt, 0) else { continue }
            let sessionIdBytes = sqlite3_column_bytes(stmt, 0)
            let sessionId = String(cString: sessionIdPtr)
            let count = try? getCommitCountForSession(sessionId: sessionId)
            print("[DEBUG]   sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count), bytes=\(sessionIdBytes)), commit_count=\(count ?? -1)")
        }
    }
    
    /// Get commit count for a specific session (DEBUG only)
    func getCommitCountForSession(sessionId: String) throws -> Int {
        guard let db = db else {
            throw CommitError.databaseIOError(extendedCode: nil, sqlOperation: nil)
        }
        
        let query = "SELECT COUNT(*) FROM commits WHERE sessionId = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "COUNT_SESSION_COMMITS")
        }
        defer { sqlite3_finalize(stmt) }
        
        let bindResult = sessionId.withCString { cString -> Int32 in
            let byteCount = Int32(sessionId.utf8.count)
            return sqlite3_bind_text(stmt, 1, cString, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw mapSQLiteError(bindResult, sqlOperation: "COUNT_SESSION_COMMITS")
        }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw mapSQLiteError(sqlite3_errcode(db), sqlOperation: "COUNT_SESSION_COMMITS")
        }
        
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    /// DEBUG: Dump session_counters table state
    func dumpSessionCountersTable() throws {
        guard let db = db else { return }
        
        let query = "SELECT sessionId, next_seq FROM session_counters ORDER BY sessionId"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        print("[DEBUG] session_counters table dump:")
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionIdPtr = sqlite3_column_text(stmt, 0) else { continue }
            let sessionIdBytes = sqlite3_column_bytes(stmt, 0)
            let sessionId = String(cString: sessionIdPtr)
            let nextSeq = sqlite3_column_int(stmt, 1)
            print("[DEBUG]   sessionId='\(sessionId)' (utf8.count=\(sessionId.utf8.count), bytes=\(sessionIdBytes)), next_seq=\(nextSeq)")
        }
    }
    #endif
}

/// CommitRow - row structure for crash recovery
struct CommitRow {
    let sessionSeq: Int
    let tsMonotonicMs: Int64
    let auditPayload: Data
    let coverageDeltaPayload: Data
    let auditSHA256: String
    let coverageDeltaSHA256: String
    let prevCommitSHA256: String
    let commitSHA256: String
    let schemaVersion: Int
}

