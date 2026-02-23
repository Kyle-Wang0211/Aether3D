// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DataAtRestEncryption.swift
// Aether3D
//
// Data at Rest Encryption - AES-256-GCM encryption for files and databases
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// Data at Rest Encryption Manager
///
/// Provides AES-256-GCM encryption for files and databases.
public actor DataAtRestEncryption {
    
    // MARK: - Configuration
    
    private let masterKey: SymmetricKey
    
    // MARK: - Initialization
    
    /// Initialize Data at Rest Encryption
    /// 
    /// - Parameter masterKey: Master encryption key (derived from Secure Enclave)
    public init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
    }
    
    // MARK: - File Encryption
    
    /// Encrypt file data
    /// 
    /// Algorithm: AES-256-GCM
    /// Format: [IV (12 bytes) || ciphertext || auth_tag (16 bytes)]
    /// - Parameters:
    ///   - data: Plaintext data
    ///   - fileId: Unique file identifier
    ///   - metadata: File metadata (AAD)
    /// - Returns: Encrypted data with IV and auth tag
    /// - Throws: EncryptionError if encryption fails
    public func encryptFile(data: Data, fileId: String, metadata: [String: String]) throws -> Data {
        // Derive file-specific key
        let fileKey = deriveFileKey(fileId: fileId)
        
        // Generate random IV (96 bits = 12 bytes for GCM)
        let iv = AES.GCM.Nonce()
        
        // Prepare AAD (Additional Authenticated Data)
        let aad = prepareAAD(metadata: metadata)
        
        // Encrypt with AES-GCM
        let sealedBox = try AES.GCM.seal(data, using: fileKey, nonce: iv, authenticating: aad)
        
        // Combine IV, ciphertext, and auth tag
        var encryptedData = Data()
        encryptedData.append(contentsOf: iv)
        encryptedData.append(sealedBox.ciphertext)
        encryptedData.append(sealedBox.tag)
        
        return encryptedData
    }
    
    /// Decrypt file data
    /// 
    /// - Parameters:
    ///   - encryptedData: Encrypted data with IV and auth tag
    ///   - fileId: Unique file identifier
    ///   - metadata: File metadata (AAD)
    /// - Returns: Decrypted plaintext data
    /// - Throws: EncryptionError if decryption fails
    public func decryptFile(encryptedData: Data, fileId: String, metadata: [String: String]) throws -> Data {
        // Extract IV, ciphertext, and auth tag
        guard encryptedData.count >= 28 else { // 12 (IV) + 16 (tag) minimum
            throw EncryptionError.invalidEncryptedData
        }
        
        let ivData = encryptedData.prefix(12)
        let tagData = encryptedData.suffix(16)
        let ciphertext = encryptedData.dropFirst(12).dropLast(16)
        
        // Create nonce from IV
        let iv = try AES.GCM.Nonce(data: ivData)
        
        // Derive file-specific key
        let fileKey = deriveFileKey(fileId: fileId)
        
        // Prepare AAD
        let aad = prepareAAD(metadata: metadata)
        
        // Create sealed box
        let sealedBox = try AES.GCM.SealedBox(nonce: iv, ciphertext: ciphertext, tag: tagData)
        
        // Decrypt
        return try AES.GCM.open(sealedBox, using: fileKey, authenticating: aad)
    }
    
    // MARK: - Key Derivation
    
    /// Derive file-specific key from master key
    /// 
    /// - Parameter fileId: File identifier
    /// - Returns: Derived symmetric key
    private func deriveFileKey(fileId: String) -> SymmetricKey {
        // Use HKDF to derive file key
        let fileIdData = fileId.data(using: .utf8) ?? Data()
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey, info: fileIdData, outputByteCount: 32)
    }
    
    /// Prepare AAD (Additional Authenticated Data)
    /// 
    /// - Parameter metadata: File metadata
    /// - Returns: AAD data
    private func prepareAAD(metadata: [String: String]) -> Data {
        // Convert metadata to canonical JSON for AAD
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        return jsonData ?? Data()
    }
}

// MARK: - Errors

/// Encryption errors
public enum EncryptionError: Error, Sendable {
    case invalidEncryptedData
    case decryptionFailed
    case keyDerivationFailed
    
    public var localizedDescription: String {
        switch self {
        case .invalidEncryptedData:
            return "Invalid encrypted data format"
        case .decryptionFailed:
            return "Decryption failed - data may be corrupted or tampered"
        case .keyDerivationFailed:
            return "Key derivation failed"
        }
    }
}
