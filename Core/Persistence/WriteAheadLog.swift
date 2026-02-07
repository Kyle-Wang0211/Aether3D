//
// WriteAheadLog.swift
// Aether3D
//
// Write-Ahead Log (WAL) for Crash Consistency
// 符合 Phase 1.5: Crash Consistency Infrastructure
//

import Foundation

/// Write-Ahead Log Entry
///
/// Represents a single WAL entry for atomic dual-write.
public struct WALEntry: Sendable, Codable {
    /// Unique entry ID
    public let entryId: UInt64
    
    /// Entry hash (SHA-256)
    public let hash: Data
    
    /// Signed audit entry bytes
    public let signedEntryBytes: Data
    
    /// Merkle tree state bytes
    public let merkleState: Data
    
    /// Whether entry is committed
    public var committed: Bool
    
    /// Timestamp
    public let timestamp: Date
    
    public init(entryId: UInt64, hash: Data, signedEntryBytes: Data, merkleState: Data, committed: Bool, timestamp: Date) {
        self.entryId = entryId
        self.hash = hash
        self.signedEntryBytes = signedEntryBytes
        self.merkleState = merkleState
        self.committed = committed
        self.timestamp = timestamp
    }
}

/// WAL Storage Protocol
///
/// Protocol for WAL storage backends (file-based or SQLite).
public protocol WALStorage: Sendable {
    /// Write entry to WAL
    func writeEntry(_ entry: WALEntry) async throws
    
    /// Read all entries
    func readEntries() async throws -> [WALEntry]
    
    /// Flush to disk (fsync)
    func fsync() async throws
    
    /// Close storage
    func close() async throws
}

/// Write-Ahead Log
///
/// Implements WAL for atomic dual-write to SignedAuditLog and MerkleTree.
/// 符合 Phase 1.5: Crash Consistency Infrastructure
public actor WriteAheadLog {
    
    // MARK: - State
    
    private let storage: WALStorage
    private var uncommittedEntries: [WALEntry] = []
    private var nextEntryId: UInt64 = 1
    
    // MARK: - Initialization
    
    /// Initialize Write-Ahead Log
    /// 
    /// - Parameters:
    ///   - storage: WAL storage backend
    public init(storage: WALStorage) {
        self.storage = storage
    }
    
    // MARK: - WAL Operations
    
    /// Append entry to WAL
    /// 
    /// 符合 Phase 1.5: Atomic dual-write
    /// - Parameters:
    ///   - hash: Entry hash (SHA-256)
    ///   - signedEntryBytes: Signed audit entry bytes
    ///   - merkleState: Merkle tree state bytes
    /// - Returns: WAL entry
    /// - Throws: WALError if append fails
    public func appendEntry(hash: Data, signedEntryBytes: Data, merkleState: Data) async throws -> WALEntry {
        guard hash.count == 32 else {
            throw WALError.invalidHashLength(expected: 32, actual: hash.count)
        }
        
        let entry = WALEntry(
            entryId: nextEntryId,
            hash: hash,
            signedEntryBytes: signedEntryBytes,
            merkleState: merkleState,
            committed: false,
            timestamp: Date()
        )
        
        try await storage.writeEntry(entry)
        try await storage.fsync() // Flush to disk
        
        uncommittedEntries.append(entry)
        nextEntryId += 1
        
        return entry
    }
    
    /// Commit entry
    ///
    /// - Parameter entry: WAL entry to commit
    /// - Throws: WALError if commit fails
    public func commitEntry(_ entry: WALEntry) async throws {
        // Check entry exists before async operations
        guard uncommittedEntries.contains(where: { $0.entryId == entry.entryId }) else {
            throw WALError.entryNotFound(entry.entryId)
        }

        var committedEntry = entry
        committedEntry.committed = true

        // Update entry in storage
        try await storage.writeEntry(committedEntry)
        try await storage.fsync()

        // Remove from uncommitted by entryId (not index) to handle concurrent mutations
        // After await, array state may have changed, so we need to find the index again
        uncommittedEntries.removeAll { $0.entryId == entry.entryId }
    }
    
    /// Get uncommitted entries
    /// 
    /// - Returns: Array of uncommitted entries
    public func getUncommittedEntries() async throws -> [WALEntry] {
        return uncommittedEntries
    }
    
    /// Recover from WAL
    /// 
    /// 符合 Phase 1.5: Crash recovery
    /// - Returns: Array of WAL entries
    /// - Throws: WALError if recovery fails
    public func recover() async throws -> [WALEntry] {
        let entries = try await storage.readEntries()
        
        // Separate committed and uncommitted
        let committed = entries.filter { $0.committed }
        uncommittedEntries = entries.filter { !$0.committed }
        
        // Update next entry ID
        if let maxId = entries.map({ $0.entryId }).max() {
            nextEntryId = maxId + 1
        }
        
        return committed
    }
    
    /// Close WAL
    /// 
    /// - Throws: WALError if close fails
    public func close() async throws {
        try await storage.close()
    }
}

/// WAL Errors
public enum WALError: Error, Sendable {
    case ioError(String)
    case corruptedEntry(UInt64)
    case recoveryFailed(String)
    case durabilityLevelNotSupported
    case entryNotFound(UInt64)
    case invalidHashLength(expected: Int, actual: Int)
    
    public var localizedDescription: String {
        switch self {
        case .ioError(let reason):
            return "WAL I/O error: \(reason)"
        case .corruptedEntry(let entryId):
            return "Corrupted WAL entry: \(entryId)"
        case .recoveryFailed(let reason):
            return "WAL recovery failed: \(reason)"
        case .durabilityLevelNotSupported:
            return "Durability level not supported"
        case .entryNotFound(let entryId):
            return "WAL entry not found: \(entryId)"
        case .invalidHashLength(let expected, let actual):
            return "Invalid hash length: expected \(expected), got \(actual)"
        }
    }
}
