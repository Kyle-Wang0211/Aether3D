//
// EndToEndEncryption.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 端到端加密，AES-GCM实现
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// End-to-end encryption
///
/// Implements end-to-end encryption with AES-GCM.
/// Provides secure data encryption.
public actor EndToEndEncryption {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Encryption keys
    private var encryptionKeys: [UUID: SymmetricKey] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Encryption
    
    /// Encrypt data
    public func encrypt(_ data: Data, keyId: UUID? = nil) -> EncryptionResult {
        let key: SymmetricKey
        let actualKeyId: UUID
        
        if let id = keyId, let existingKey = encryptionKeys[id] {
            key = existingKey
            actualKeyId = id
        } else {
            key = SymmetricKey(size: .bits256)
            actualKeyId = UUID()
            encryptionKeys[actualKeyId] = key
        }
        
        // Encrypt using AES-GCM
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            let encryptedData = sealedBox.combined ?? data
            
            return EncryptionResult(
                encryptedData: encryptedData,
                keyId: actualKeyId,
                nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
                success: true
            )
        } catch {
            return EncryptionResult(
                encryptedData: data,
                keyId: actualKeyId,
                nonce: Data(),
                success: false
            )
        }
    }
    
    /// Decrypt data
    public func decrypt(_ encryptedData: Data, keyId: UUID, nonce: Data) -> DecryptionResult {
        guard let key = encryptionKeys[keyId] else {
            return DecryptionResult(success: false, data: nil, reason: "Key not found")
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            
            return DecryptionResult(
                success: true,
                data: decryptedData,
                reason: "Decryption successful"
            )
        } catch {
            return DecryptionResult(
                success: false,
                data: nil,
                reason: error.localizedDescription
            )
        }
    }
    
    // MARK: - Result Types
    
    /// Encryption result
    public struct EncryptionResult: Sendable {
        public let encryptedData: Data
        public let keyId: UUID
        public let nonce: Data
        public let success: Bool
    }
    
    /// Decryption result
    public struct DecryptionResult: Sendable {
        public let success: Bool
        public let data: Data?
        public let reason: String
    }
}
