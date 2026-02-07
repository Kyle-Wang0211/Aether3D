//
// SQLiteWALStorage.swift
// Aether3D
//
// SQLite-based WAL Storage - SQLite WAL mode implementation
// 符合 Phase 1.5: Crash Consistency Infrastructure
//

import Foundation
import CSQLite

/// SQLite Handle Wrapper for WAL Storage
private final class SQLiteWALHandle: @unchecked Sendable {
    var db: OpaquePointer?
    
    init(db: OpaquePointer?) {
        self.db = db
    }
}

/// SQLite-based WAL Storage
///
/// Implements WAL storage using SQLite WAL mode for ACID guarantees.
/// 符合 Phase 1.5: SQLiteWALStorage with SQLite WAL mode
public actor SQLiteWALStorage: WALStorage {
    
    // MARK: - State
    
    private let handle: SQLiteWALHandle
    private let dbPath: String
    
    // MARK: - Initialization
    
    /// Initialize SQLite WAL Storage
    /// 
    /// - Parameter dbPath: Path to SQLite database
    /// - Throws: WALError if initialization fails
    public init(dbPath: String) throws {
        self.dbPath = dbPath
        
        // Open database
        var db: OpaquePointer?
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw WALError.ioError("Failed to open database: \(result)")
        }
        
        self.handle = SQLiteWALHandle(db: db)
        
        // Enable WAL mode
        try enableWALMode()
        
        // Create table if needed
        try createTable()
    }
    
    // MARK: - WAL Storage Implementation
    
    /// Write entry to WAL
    public func writeEntry(_ entry: WALEntry) async throws {
        guard let db = handle.db else {
            throw WALError.ioError("Database not available")
        }
        
        let sql = """
            INSERT OR REPLACE INTO wal_entries 
            (entry_id, hash, signed_entry_bytes, merkle_state, committed, timestamp)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WALError.ioError("Failed to prepare statement")
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_int64(statement, 1, Int64(entry.entryId))
        sqlite3_bind_blob(statement, 2, [UInt8](entry.hash), Int32(entry.hash.count), nil)
        sqlite3_bind_blob(statement, 3, [UInt8](entry.signedEntryBytes), Int32(entry.signedEntryBytes.count), nil)
        sqlite3_bind_blob(statement, 4, [UInt8](entry.merkleState), Int32(entry.merkleState.count), nil)
        sqlite3_bind_int(statement, 5, entry.committed ? 1 : 0)
        sqlite3_bind_int64(statement, 6, Int64(entry.timestamp.timeIntervalSince1970 * 1_000_000_000))
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WALError.ioError("Failed to execute statement")
        }
    }
    
    /// Read all entries
    public func readEntries() async throws -> [WALEntry] {
        guard let db = handle.db else {
            throw WALError.ioError("Database not available")
        }
        
        let sql = "SELECT entry_id, hash, signed_entry_bytes, merkle_state, committed, timestamp FROM wal_entries ORDER BY entry_id"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WALError.ioError("Failed to prepare statement")
        }
        
        defer { sqlite3_finalize(statement) }
        
        var entries: [WALEntry] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let entryId = UInt64(sqlite3_column_int64(statement, 0))
            
            let hashLength = sqlite3_column_bytes(statement, 1)
            let hashData = sqlite3_column_blob(statement, 1)
            let hash = Data(bytes: hashData!, count: Int(hashLength))
            
            let signedEntryLength = sqlite3_column_bytes(statement, 2)
            let signedEntryData = sqlite3_column_blob(statement, 2)
            let signedEntryBytes = Data(bytes: signedEntryData!, count: Int(signedEntryLength))
            
            let merkleStateLength = sqlite3_column_bytes(statement, 3)
            let merkleStateData = sqlite3_column_blob(statement, 3)
            let merkleState = Data(bytes: merkleStateData!, count: Int(merkleStateLength))
            
            let committed = sqlite3_column_int(statement, 4) != 0
            
            let timestampNs = UInt64(sqlite3_column_int64(statement, 5))
            let timestamp = Date(timeIntervalSince1970: Double(timestampNs) / 1_000_000_000)
            
            let entry = WALEntry(
                entryId: entryId,
                hash: hash,
                signedEntryBytes: signedEntryBytes,
                merkleState: merkleState,
                committed: committed,
                timestamp: timestamp
            )
            
            entries.append(entry)
        }
        
        return entries
    }
    
    /// Flush to disk (checkpoint)
    /// 
    /// 符合 Phase 1.5: SQLITE_CHECKPOINT_FULL
    public func fsync() async throws {
        guard let db = handle.db else {
            throw WALError.ioError("Database not available")
        }
        
        // Perform full checkpoint
        var checkpointed: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_FULL, &checkpointed, nil)
        
        guard result == SQLITE_OK else {
            throw WALError.ioError("Checkpoint failed: \(result)")
        }
    }
    
    /// Close storage
    public func close() async throws {
        guard let db = handle.db else {
            return
        }
        
        sqlite3_close(db)
        handle.db = nil
    }
    
    // MARK: - Private Methods
    
    /// Enable WAL mode
    private nonisolated func enableWALMode() throws {
        guard let db = handle.db else {
            throw WALError.ioError("Database not available")
        }
        
        let result = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        guard result == SQLITE_OK else {
            throw WALError.ioError("Failed to enable WAL mode: \(result)")
        }
    }
    
    /// Create WAL entries table
    private nonisolated func createTable() throws {
        guard let db = handle.db else {
            throw WALError.ioError("Database not available")
        }
        
        let sql = """
            CREATE TABLE IF NOT EXISTS wal_entries (
                entry_id INTEGER PRIMARY KEY,
                hash BLOB NOT NULL,
                signed_entry_bytes BLOB NOT NULL,
                merkle_state BLOB NOT NULL,
                committed INTEGER NOT NULL DEFAULT 0,
                timestamp INTEGER NOT NULL
            )
        """
        
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw WALError.ioError("Failed to create table: \(result)")
        }
    }
}
