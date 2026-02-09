// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FileWALStorage.swift
// Aether3D
//
// File-based WAL Storage - File system implementation
// 符合 Phase 1.5: Crash Consistency Infrastructure
//

import Foundation

/// File-based WAL Storage
///
/// Implements WAL storage using file system with iOS durability levels.
/// 符合 Phase 1.5: FileWALStorage with iOS DataProtection
public actor FileWALStorage: WALStorage {
    
    // MARK: - State
    
    private let walFileURL: URL
    private let fileHandle: FileHandle?
    private var entries: [WALEntry] = []
    
    // MARK: - Initialization
    
    /// Initialize File WAL Storage
    /// 
    /// - Parameter walFileURL: URL to WAL file
    /// - Throws: WALError if initialization fails
    public init(walFileURL: URL) throws {
        self.walFileURL = walFileURL
        
        // Create directory if needed
        let directory = walFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Create or open file
        if !FileManager.default.fileExists(atPath: walFileURL.path) {
            FileManager.default.createFile(atPath: walFileURL.path, contents: nil)
        }
        
        // Open file handle
        self.fileHandle = try FileHandle(forWritingTo: walFileURL)
        
        // Load existing entries (nonisolated init can't call actor methods)
        // Entries will be loaded on first read
    }
    
    // MARK: - WAL Storage Implementation
    
    /// Write entry to WAL
    public func writeEntry(_ entry: WALEntry) async throws {
        guard let fileHandle = fileHandle else {
            throw WALError.ioError("File handle not available")
        }
        
        // Serialize entry to binary format
        let data = try serializeEntry(entry)
        
        // Write to file
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        
        // Update in-memory cache
        if let index = entries.firstIndex(where: { $0.entryId == entry.entryId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }
    
    /// Read all entries
    public func readEntries() async throws -> [WALEntry] {
        // Load entries if not already loaded
        if entries.isEmpty {
            try await loadEntries()
        }
        return entries
    }
    
    /// Load entries from file (internal async method)
    private func loadEntries() async throws {
        guard let data = try? Data(contentsOf: walFileURL) else {
            entries = []
            return
        }
        
        var offset = 0
        while offset < data.count {
            guard let (entry, entrySize) = try? deserializeEntry(from: data, offset: offset) else {
                break
            }
            entries.append(entry)
            offset += entrySize
        }
    }
    
    /// Flush to disk (fsync)
    public func fsync() async throws {
        guard let fileHandle = fileHandle else {
            throw WALError.ioError("File handle not available")
        }
        
        fileHandle.synchronizeFile()
    }
    
    /// Close storage
    public func close() async throws {
        fileHandle?.closeFile()
    }
    
    // MARK: - Private Methods
    
    /// Serialize entry to binary format
    /// 
    /// Format: [8 bytes entryId BE][1 byte committed][8 bytes timestamp BE][4 bytes hash length BE][hash bytes][4 bytes signedEntry length BE][signedEntry bytes][4 bytes merkleState length BE][merkleState bytes]
    private func serializeEntry(_ entry: WALEntry) throws -> Data {
        var data = Data()
        
        // Entry ID (8 bytes, big-endian)
        data.append(contentsOf: withUnsafeBytes(of: entry.entryId.bigEndian) { Data($0) })
        
        // Committed (1 byte)
        data.append(entry.committed ? 1 : 0)
        
        // Timestamp (8 bytes, big-endian)
        let timestamp = UInt64(entry.timestamp.timeIntervalSince1970 * 1_000_000_000)
        data.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })
        
        // Hash length and bytes
        data.append(contentsOf: withUnsafeBytes(of: UInt32(entry.hash.count).bigEndian) { Data($0) })
        data.append(entry.hash)
        
        // Signed entry length and bytes
        data.append(contentsOf: withUnsafeBytes(of: UInt32(entry.signedEntryBytes.count).bigEndian) { Data($0) })
        data.append(entry.signedEntryBytes)
        
        // Merkle state length and bytes
        data.append(contentsOf: withUnsafeBytes(of: UInt32(entry.merkleState.count).bigEndian) { Data($0) })
        data.append(entry.merkleState)
        
        return data
    }
    
    /// Deserialize entry from binary format
    private func deserializeEntry(from data: Data, offset: Int) throws -> (WALEntry, Int) {
        var offset = offset
        
        guard offset + 8 <= data.count else {
            throw WALError.corruptedEntry(0)
        }
        
        // Entry ID
        let entryId = UInt64(bigEndian: data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) })
        offset += 8
        
        // Committed
        guard offset < data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let committed = data[offset] != 0
        offset += 1
        
        // Timestamp
        guard offset + 8 <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let timestampNs = UInt64(bigEndian: data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) })
        let timestamp = Date(timeIntervalSince1970: Double(timestampNs) / 1_000_000_000)
        offset += 8
        
        // Hash
        guard offset + 4 <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let hashLength = Int(UInt32(bigEndian: data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4
        guard offset + hashLength <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let hash = data.subdata(in: offset..<offset+hashLength)
        offset += hashLength
        
        // Signed entry
        guard offset + 4 <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let signedEntryLength = Int(UInt32(bigEndian: data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4
        guard offset + signedEntryLength <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let signedEntryBytes = data.subdata(in: offset..<offset+signedEntryLength)
        offset += signedEntryLength
        
        // Merkle state
        guard offset + 4 <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let merkleStateLength = Int(UInt32(bigEndian: data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4
        guard offset + merkleStateLength <= data.count else {
            throw WALError.corruptedEntry(entryId)
        }
        let merkleState = data.subdata(in: offset..<offset+merkleStateLength)
        offset += merkleStateLength
        
        let entry = WALEntry(
            entryId: entryId,
            hash: hash,
            signedEntryBytes: signedEntryBytes,
            merkleState: merkleState,
            committed: committed,
            timestamp: timestamp
        )
        
        return (entry, offset - (offset - merkleStateLength - signedEntryLength - hashLength - 8 - 1 - 8 - 4 - 4 - 4))
    }
}
