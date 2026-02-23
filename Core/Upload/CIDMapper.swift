// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-CONTENT-1.0
// Module: Upload Infrastructure - CID Mapper
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

/// ACI ↔ CID v1 bidirectional mapping, Multicodec compatibility.
///
/// **Purpose**: Map between ACI (Aether Content Identifier) and CID v1 (Content Identifier).
///
/// **ACI Format**: `aci:1:sha256:ba7816bf...`
/// **CID v1 Format**: `multibase("b") + multicodec(0x12) + multihash(0x12, 32, sha256_bytes)`
///
/// **Multicodec Codes**:
/// - 0x12 = sha2-256 (32 bytes)
/// - Future: 0x1e = blake3, 0x1f = verkle (reserved)
public enum CIDMapper {
    
    // MARK: - ACI → CID v1
    
    /// Convert ACI to CID v1.
    ///
    /// - Parameter aci: ACI string
    /// - Returns: CID v1 string (base32 multibase), or nil if conversion fails
    public static func aciToCID(_ aci: String) -> String? {
        // Parse ACI
        guard let parsed = try? ACI.parse(aci) else {
            return nil
        }
        
        // Only support sha256 for now
        guard parsed.algorithm == "sha256" else {
            return nil
        }
        
        // Convert hex digest to bytes
        guard let digestBytes = hexStringToBytes(parsed.digest) else {
            return nil
        }
        
        // Build CID v1: multibase("b") + multicodec(0x12) + multihash(0x12, 32, sha256_bytes)
        var cidBytes = Data()
        
        // Multibase prefix: "b" (base32)
        cidBytes.append(0x62)  // 'b' in ASCII
        
        // Multicodec: 0x12 (sha2-256)
        cidBytes.append(0x12)
        
        // Multihash: 0x12 (sha2-256), 0x20 (32 bytes), digest
        cidBytes.append(0x12)  // hash algorithm
        cidBytes.append(0x20)   // length (32 bytes)
        cidBytes.append(digestBytes)
        
        // Encode as base32
        return base32Encode(cidBytes)
    }
    
    // MARK: - CID v1 → ACI
    
    /// Convert CID v1 to ACI.
    ///
    /// - Parameter cid: CID v1 string (base32 multibase)
    /// - Returns: ACI string, or nil if conversion fails
    public static func cidToACI(_ cid: String) -> String? {
        // Decode base32
        guard let cidBytes = base32Decode(cid) else {
            return nil
        }
        
        // Check multibase prefix
        guard cidBytes.count > 0, cidBytes[0] == 0x62 else {
            return nil  // Not base32 multibase
        }
        
        // Extract multicodec and multihash
        guard cidBytes.count >= 35 else {  // 1 (multibase) + 1 (multicodec) + 1 (hash alg) + 1 (length) + 32 (digest)
            return nil
        }
        
        let multicodec = cidBytes[1]
        guard multicodec == 0x12 else {  // sha2-256
            return nil
        }
        
        let hashAlgorithm = cidBytes[2]
        let hashLength = cidBytes[3]
        guard hashAlgorithm == 0x12, hashLength == 0x20 else {
            return nil
        }
        
        // Extract digest
        let digestBytes = cidBytes[4..<36]
        let digestHex = bytesToHexString(Array(digestBytes))
        
        // Build ACI
        return "aci:1:sha256:\(digestHex)"
    }
    
    // MARK: - Helper Functions
    
    /// Convert hex string to bytes.
    private static func hexStringToBytes(_ hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        var data = Data()
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        return data
    }
    
    /// Convert bytes to hex string.
    private static func bytesToHexString(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Base32 encode (RFC 4648).
    private static func base32Encode(_ data: Data) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        var result = ""
        var buffer: UInt64 = 0
        var bits = 0
        
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            
            while bits >= 5 {
                let index = Int((buffer >> (bits - 5)) & 0x1F)
                result.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)])
                bits -= 5
            }
        }
        
        if bits > 0 {
            let index = Int((buffer << (5 - bits)) & 0x1F)
            result.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)])
        }
        
        return result
    }
    
    /// Base32 decode (RFC 4648).
    private static func base32Decode(_ encoded: String) -> Data? {
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        var result = Data()
        var buffer: UInt64 = 0
        var bits = 0
        
        for char in encoded.lowercased() {
            guard let index = alphabet.firstIndex(of: char) else {
                return nil
            }
            
            let value = alphabet.distance(from: alphabet.startIndex, to: index)
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            
            while bits >= 8 {
                let byte = UInt8((buffer >> (bits - 8)) & 0xFF)
                result.append(byte)
                bits -= 8
            }
        }
        
        return result
    }
}
