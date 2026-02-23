// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// UUIDRFC4122.swift
// Aether3D
//
// PR1 v2.4 Addendum - UUID RFC4122 Canonical Bytes Encoding
//
// Explicit field-level RFC4122 network order encoding (no memory layout assumptions)
//

import Foundation

/// UUID RFC4122 canonical bytes encoding
/// 
/// **P0 Contract:**
/// - Encodes UUID as exactly 16 bytes in RFC4122 network order
/// - Uses explicit field extraction and reordering (no memory layout assumptions)
/// - Cross-platform deterministic (macOS + Linux produce identical bytes)
public enum UUIDRFC4122 {
    /// Encode UUID as RFC4122 network order bytes (16 bytes)
    /// 
    /// **RFC4122 Field Order:**
    /// - time_low (4 bytes, BE)
    /// - time_mid (2 bytes, BE)
    /// - time_hi_and_version (2 bytes, BE)
    /// - clock_seq_hi_and_reserved (1 byte)
    /// - clock_seq_low (1 byte)
    /// - node (6 bytes)
    /// 
    /// **Fail-closed:** Throws FailClosedError on encoding failure
    public static func uuidRFC4122Bytes(_ uuid: UUID) throws -> [UInt8] {
        // Extract UUID fields using uuid_t (uuid_t is a tuple of 16 UInt8)
        let uuidBytes = uuid.uuid
        
        // RFC4122 network order: time_low(4) + time_mid(2) + time_hi_and_version(2) + 
        //                        clock_seq_hi_and_reserved(1) + clock_seq_low(1) + node(6)
        // UUID memory layout on Apple platforms matches RFC4122 byte order
        // But we extract explicitly to ensure cross-platform consistency
        
        // time_low: bytes 0-3 (already in BE order in uuid_t)
        // time_mid: bytes 4-5 (already in BE order in uuid_t)
        // time_hi_and_version: bytes 6-7 (already in BE order in uuid_t)
        // clock_seq_hi_and_reserved: byte 8
        // clock_seq_low: byte 9
        // node: bytes 10-15
        
        // On Apple platforms, uuid.uuid already provides RFC4122 network order
        // We return it directly, but document the explicit field mapping
        var result: [UInt8] = []
        result.reserveCapacity(16)
        
        // Explicitly copy bytes in RFC4122 order (which matches uuid_t order on Apple platforms)
        result.append(contentsOf: [
            uuidBytes.0,  // time_low[0]
            uuidBytes.1,  // time_low[1]
            uuidBytes.2,  // time_low[2]
            uuidBytes.3,  // time_low[3]
            uuidBytes.4,  // time_mid[0]
            uuidBytes.5,  // time_mid[1]
            uuidBytes.6,  // time_hi_and_version[0]
            uuidBytes.7,  // time_hi_and_version[1]
            uuidBytes.8,  // clock_seq_hi_and_reserved
            uuidBytes.9,  // clock_seq_low
            uuidBytes.10, // node[0]
            uuidBytes.11, // node[1]
            uuidBytes.12, // node[2]
            uuidBytes.13, // node[3]
            uuidBytes.14, // node[4]
            uuidBytes.15  // node[5]
        ])
        
        guard result.count == 16 else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.uuidCanonicalizationError.rawValue,
                context: "UUID RFC4122 encoding must produce exactly 16 bytes"
            )
        }
        
        return result
    }
}
