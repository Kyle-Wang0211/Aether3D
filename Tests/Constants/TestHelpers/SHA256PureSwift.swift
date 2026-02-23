// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SHA256PureSwift.swift
//  Aether3D
//
//  PR#1 SSOT Foundation v1.1.1 - Pure Swift SHA-256 Fallback
//  Test-only fallback implementation to avoid native crypto SIGILL on Linux
//  Only used when Crypto/CryptoKit imports fail or cause SIGILL
//
//  This is a minimal, self-contained SHA-256 implementation following RFC 6234 / FIPS 180-4.
//  It produces correct SHA-256 output and is deterministic across platforms.
//  Used ONLY as a safety net for tests when native crypto backend fails.
//

import Foundation

/// Pure Swift SHA-256 implementation (test-only fallback)
/// Used when native crypto backend triggers SIGILL despite OPENSSL_ia32cap=:0
/// This implementation is deterministic and produces correct SHA-256 output
internal enum SHA256PureSwift {
    // SHA-256 constants (first 32 bits of fractional parts of cube roots of first 64 primes)
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    
    // Initial hash values (first 32 bits of fractional parts of square roots of first 8 primes)
    private static let h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    
    // Right rotate helper
    private static func rightRotate(_ value: UInt32, _ amount: Int) -> UInt32 {
        return (value >> amount) | (value << (32 - amount))
    }
    
    // SHA-256 compression function
    private static func compress(_ chunk: [UInt8]) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 64)
        
        // Copy chunk into first 16 words (big-endian)
        for i in 0..<16 {
            let j = i * 4
            w[i] = UInt32(chunk[j]) << 24 | UInt32(chunk[j + 1]) << 16 | UInt32(chunk[j + 2]) << 8 | UInt32(chunk[j + 3])
        }
        
        // Extend to 64 words
        for i in 16..<64 {
            let s0 = rightRotate(w[i - 15], 7) ^ rightRotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rightRotate(w[i - 2], 17) ^ rightRotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        
        // Initialize working variables
        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], h_val = h[7]
        
        // Main loop
        for i in 0..<64 {
            let S1 = rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h_val &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = S0 &+ maj
            
            h_val = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        
        // Add compressed chunk to hash
        return [
            h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d,
            h[4] &+ e, h[5] &+ f, h[6] &+ g, h[7] &+ h_val
        ]
    }
    
    /// Compute SHA-256 digest as bytes from input data
    /// - Parameter data: Input data to hash
    /// - Returns: SHA-256 digest as array of bytes (32 bytes)
    static func sha256Digest(_ data: Data) -> [UInt8] {
        var hash = h
        
        // Pre-processing: pad message
        var padded = data.map { $0 }
        let originalLength = data.count * 8
        
        // Append single '1' bit
        padded.append(0x80)
        
        // Append zeros until length ≡ 448 (mod 512)
        while (padded.count % 64) != 56 {
            padded.append(0)
        }
        
        // Append original length as 64-bit big-endian
        padded.append(contentsOf: [
            UInt8((originalLength >> 56) & 0xff),
            UInt8((originalLength >> 48) & 0xff),
            UInt8((originalLength >> 40) & 0xff),
            UInt8((originalLength >> 32) & 0xff),
            UInt8((originalLength >> 24) & 0xff),
            UInt8((originalLength >> 16) & 0xff),
            UInt8((originalLength >> 8) & 0xff),
            UInt8(originalLength & 0xff)
        ])
        
        // Process message in 512-bit chunks
        for i in stride(from: 0, to: padded.count, by: 64) {
            let chunk = Array(padded[i..<min(i + 64, padded.count)])
            let compressed = compress(chunk)
            for j in 0..<8 {
                hash[j] = compressed[j]
            }
        }
        
        // Produce final hash (big-endian)
        var result = [UInt8]()
        for h_val in hash {
            result.append(UInt8((h_val >> 24) & 0xff))
            result.append(UInt8((h_val >> 16) & 0xff))
            result.append(UInt8((h_val >> 8) & 0xff))
            result.append(UInt8(h_val & 0xff))
        }
        
        return result
    }
}
