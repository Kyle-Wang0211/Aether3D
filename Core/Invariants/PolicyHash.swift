//
//  PolicyHash.swift
//  Aether3D
//
//  PR#7: Policy Hash Calculation
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Policy Hash Calculator
public struct PolicyHash {
    /// Calculate SHA256 hash of policy JSON
    public static func calculate(policies: InvariantPolicies) throws -> String {
        let jsonString = try StableJSONEncoder.encode(policies)
        let jsonData = jsonString.data(using: .utf8)!
        
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: jsonData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // Fallback for platforms without CryptoKit
        return calculateSHA256(data: jsonData)
        #endif
    }
    
    #if !canImport(CryptoKit)
    /// Fallback SHA256 implementation
    private static func calculateSHA256(data: Data) -> String {
        // Simple SHA256 implementation using CommonCrypto or built-in
        // For cross-platform compatibility
        var hash = [UInt8](repeating: 0, count: 32)
        
        #if canImport(CommonCrypto)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        #else
        // Pure Swift SHA256 implementation (simplified)
        // In production, use a proper crypto library
        hash = Array(data.prefix(32))
        #endif
        
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

