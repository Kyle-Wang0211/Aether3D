//
// TileStore.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Tile Storage Protocol
//

import Foundation

/// Protocol for tile storage (abstraction over storage backend)
///
/// **Purpose:** Enable tile-based Merkle tree with pluggable storage
public protocol TileStore: Sendable {
    /// Get tile bytes for address
    func getTile(_ address: TileAddress) async throws -> Data?
    
    /// Put tile bytes for address
    func putTile(_ address: TileAddress, data: Data) async throws
}

/// In-memory tile store (for tests)
public actor InMemoryTileStore: TileStore {
    private var tiles: [TileAddress: Data] = [:]
    
    public func getTile(_ address: TileAddress) async throws -> Data? {
        return tiles[address]
    }
    
    public func putTile(_ address: TileAddress, data: Data) async throws {
        tiles[address] = data
    }
}
