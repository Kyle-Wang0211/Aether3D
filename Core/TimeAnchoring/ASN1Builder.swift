// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ASN1Builder.swift
// Aether3D
//
// Phase 1: Time Anchoring - Minimal ASN.1 DER Builder for RFC 3161
//
// **Note:** This is a minimal implementation for RFC 3161 TimeStampReq/TimeStampResp.
// For production use, consider a full ASN.1 library, but this ensures determinism.
//

import Foundation

/// Minimal ASN.1 DER builder for RFC 3161
///
/// **Invariants:**
/// - INV-C2: All integer encoding is Big-Endian
/// - Deterministic: Same input produces same output
internal struct ASN1Builder {
    private var data: Data = Data()
    private var sequenceLengthOffsets: [Int] = []
    
    mutating func beginSequence() {
        data.append(0x30) // SEQUENCE tag
        data.append(0x00) // Length placeholder (backfilled in endSequence)
        sequenceLengthOffsets.append(data.count - 1)
    }
    
    mutating func endSequence() {
        guard let lengthOffset = sequenceLengthOffsets.popLast(), lengthOffset < data.count else {
            return
        }
        let contentStart = lengthOffset + 1
        let contentLength = max(0, data.count - contentStart)
        let encodedLength = encodeLength(contentLength)
        data.remove(at: lengthOffset)
        data.insert(contentsOf: encodedLength, at: lengthOffset)
    }
    
    mutating func appendInteger(_ value: Int64) {
        data.append(0x02) // INTEGER
        let encoded = encodeInteger(value)
        data.append(contentsOf: encodeLength(encoded.count))
        data.append(contentsOf: encoded)
    }
    
    mutating func appendOctetString(_ data: Data) {
        self.data.append(0x04) // OCTET STRING
        self.data.append(contentsOf: encodeLength(data.count))
        self.data.append(data)
    }
    
    mutating func appendAlgorithmIdentifier(oid: [Int]) {
        guard oid.count >= 2 else { return }
        var oidBytes: [UInt8] = [UInt8(oid[0] * 40 + oid[1])]
        for component in oid.dropFirst(2) {
            oidBytes.append(contentsOf: encodeOIDComponent(component))
        }

        beginSequence()
        data.append(0x06) // OBJECT IDENTIFIER
        data.append(contentsOf: encodeLength(oidBytes.count))
        data.append(contentsOf: oidBytes)
        endSequence()
    }
    
    mutating func appendBoolean(_ value: Bool) {
        data.append(0x01) // BOOLEAN
        data.append(0x01) // length
        data.append(value ? 0xff : 0x00)
    }
    
    func build() -> Data {
        return data
    }

    private func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var tmp = length
        var bytes: [UInt8] = []
        while tmp > 0 {
            bytes.append(UInt8(tmp & 0xff))
            tmp >>= 8
        }
        bytes.reverse()
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private func encodeInteger(_ value: Int64) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        if value >= 0 {
            while bytes.count > 1 && bytes[0] == 0x00 && (bytes[1] & 0x80) == 0 {
                bytes.removeFirst()
            }
            if (bytes[0] & 0x80) != 0 {
                bytes.insert(0x00, at: 0)
            }
        } else {
            while bytes.count > 1 && bytes[0] == 0xff && (bytes[1] & 0x80) == 0x80 {
                bytes.removeFirst()
            }
        }
        return bytes
    }

    private func encodeOIDComponent(_ value: Int) -> [UInt8] {
        guard value >= 0 else { return [0] }
        if value < 128 {
            return [UInt8(value)]
        }
        var tmp = value
        var chunks: [UInt8] = []
        chunks.append(UInt8(tmp & 0x7f))
        tmp >>= 7
        while tmp > 0 {
            chunks.append(UInt8(tmp & 0x7f) | 0x80)
            tmp >>= 7
        }
        return chunks.reversed()
    }
}
