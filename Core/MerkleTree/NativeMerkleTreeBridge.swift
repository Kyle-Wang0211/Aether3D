// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for RFC 9162 Merkle tree operations.
enum NativeMerkleTreeBridge {
    static func create() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var tree: OpaquePointer?
        let rc = aether_merkle_tree_create(&tree)
        return rc == 0 ? tree : nil
        #else
        return nil
        #endif
    }
    static func destroy(_ tree: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_merkle_tree_destroy(tree)
        #endif
    }
    static func reset(_ tree: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_merkle_tree_reset(tree)
        #endif
    }
    static func size(_ tree: OpaquePointer) -> UInt64 {
        #if canImport(CAetherNativeBridge)
        var sz: UInt64 = 0
        _ = aether_merkle_tree_size(tree, &sz)
        return sz
        #else
        return 0
        #endif
    }
    static func rootHash(_ tree: OpaquePointer) -> Data? {
        #if canImport(CAetherNativeBridge)
        var hash = [UInt8](repeating: 0, count: 32)
        let rc = aether_merkle_tree_root_hash(tree, &hash)
        return rc == 0 ? Data(hash) : nil
        #else
        return nil
        #endif
    }
    static func append(_ tree: OpaquePointer, data: Data) -> Bool {
        #if canImport(CAetherNativeBridge)
        return data.withUnsafeBytes { buf in
            let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let rc = aether_merkle_tree_append(tree, ptr, Int32(data.count))
            return rc == 0
        }
        #else
        return false
        #endif
    }
}
