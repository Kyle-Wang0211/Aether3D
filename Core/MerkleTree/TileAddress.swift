//
// TileAddress.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Tile Address
//
// **Reference:** Sigstore Rekor v2 tile-based architecture
//

import Foundation

/// Tile address in tile-based Merkle tree
///
/// **Reference:** Sigstore Rekor v2
/// **Tile Size:** 256 entries (industry standard)
public struct TileAddress: Codable, Sendable, Hashable {
    /// Tile level (0 = leaf tiles)
    public let level: UInt8
    
    /// Tile index within level
    public let index: UInt64
    
    public init(level: UInt8, index: UInt64) {
        self.level = level
        self.index = index
    }
}
