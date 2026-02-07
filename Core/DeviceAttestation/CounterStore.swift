//
// CounterStore.swift
// Aether3D
//
// Counter Store Implementations - In-memory and SQLite counter stores
// 符合 Phase 3: Device Attestation (Persistent Counter Store)
//

import Foundation
import CSQLite

/// In-Memory Counter Store
///
/// In-memory implementation of counter store (for testing).
public actor InMemoryCounterStore: CounterStore {
    
    private var counters: [String: UInt64] = [:]
    private var registeredKeys: [String: (deviceBinding: Data?, firstSeen: Date)] = [:]
    
    /// Get counter for key
    public func getCounter(keyId: String) async throws -> UInt64? {
        return counters[keyId]
    }
    
    /// Set counter for key
    public func setCounter(keyId: String, counter: UInt64) async throws {
        counters[keyId] = counter
    }
    
    /// Register key
    public func registerKey(keyId: String, deviceBinding: Data?, firstSeen: Date) async throws {
        registeredKeys[keyId] = (deviceBinding: deviceBinding, firstSeen: firstSeen)
    }
}

/// SQLite Handle Wrapper
///
/// Wrapper for OpaquePointer to make it Sendable.
private final class SQLiteHandle: @unchecked Sendable {
    var db: OpaquePointer?
    
    init(db: OpaquePointer?) {
        self.db = db
    }
}

/// SQLite Counter Store
///
/// SQLite-based implementation of counter store (for production).
public actor SQLiteCounterStore: CounterStore {
    
    private let handle: SQLiteHandle
    private let dbPath: String
    
    /// Initialize SQLite Counter Store
    /// 
    /// - Parameter dbPath: Path to SQLite database
    /// - Throws: AttestationVerifierError if initialization fails
    public init(dbPath: String) throws {
        self.dbPath = dbPath
        
        // Open database
        var db: OpaquePointer?
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw AttestationVerifierError.invalidCBOR("Failed to open database: \(result)")
        }
        
        self.handle = SQLiteHandle(db: db)
        
        // Create table if needed
        try createTable()
    }
    
    /// Get counter for key
    public func getCounter(keyId: String) async throws -> UInt64? {
        guard let db = handle.db else {
            throw AttestationVerifierError.invalidCBOR("Database not available")
        }
        
        let sql = "SELECT counter FROM attestation_counters WHERE key_id = ?"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AttestationVerifierError.invalidCBOR("Failed to prepare statement")
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, keyId, -1, nil)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            return UInt64(sqlite3_column_int64(statement, 0))
        }
        
        return nil
    }
    
    /// Set counter for key
    public func setCounter(keyId: String, counter: UInt64) async throws {
        guard let db = handle.db else {
            throw AttestationVerifierError.invalidCBOR("Database not available")
        }
        
        let sql = "INSERT OR REPLACE INTO attestation_counters (key_id, counter, updated_at) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AttestationVerifierError.invalidCBOR("Failed to prepare statement")
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, keyId, -1, nil)
        sqlite3_bind_int64(statement, 2, Int64(counter))
        sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AttestationVerifierError.invalidCBOR("Failed to execute statement")
        }
    }
    
    /// Register key
    public func registerKey(keyId: String, deviceBinding: Data?, firstSeen: Date) async throws {
        guard let db = handle.db else {
            throw AttestationVerifierError.invalidCBOR("Database not available")
        }
        
        let sql = "INSERT INTO registered_keys (key_id, device_binding, first_seen) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AttestationVerifierError.invalidCBOR("Failed to prepare statement")
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, keyId, -1, nil)
        if let deviceBinding = deviceBinding {
            sqlite3_bind_blob(statement, 2, [UInt8](deviceBinding), Int32(deviceBinding.count), nil)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int64(statement, 3, Int64(firstSeen.timeIntervalSince1970 * 1_000_000_000))
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AttestationVerifierError.invalidCBOR("Failed to execute statement")
        }
    }
    
    /// Create tables
    private func createTable() throws {
        guard let db = handle.db else {
            throw AttestationVerifierError.invalidCBOR("Database not available")
        }
        
        let sql1 = """
            CREATE TABLE IF NOT EXISTS attestation_counters (
                key_id TEXT PRIMARY KEY,
                counter INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
        """
        
        let sql2 = """
            CREATE TABLE IF NOT EXISTS registered_keys (
                key_id TEXT PRIMARY KEY,
                device_binding BLOB,
                first_seen INTEGER NOT NULL
            )
        """
        
        guard sqlite3_exec(db, sql1, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, sql2, nil, nil, nil) == SQLITE_OK else {
            throw AttestationVerifierError.invalidCBOR("Failed to create tables")
        }
    }
}
