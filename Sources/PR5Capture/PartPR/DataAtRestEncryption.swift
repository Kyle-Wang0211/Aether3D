//
// DataAtRestEncryption.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 静态数据加密，本地存储保护
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Data at rest encryption
///
/// Encrypts data at rest for local storage protection.
/// Provides secure local data encryption.
public actor DataAtRestEncryption {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Encryption key
    private var encryptionKey: SymmetricKey?
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
        initializeKey()
    }
    
    /// Initialize encryption key
    private func initializeKey() {
        encryptionKey = SymmetricKey(size: .bits256)
    }
    
    // MARK: - Encryption
    
    /// Encrypt data at rest
    public func encrypt(_ data: Data) -> EncryptionResult {
        guard let key = encryptionKey else {
            return EncryptionResult(success: false, encryptedData: nil, reason: "No encryption key")
        }
        
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            let encryptedData = sealedBox.combined ?? data
            
            return EncryptionResult(
                success: true,
                encryptedData: encryptedData,
                reason: "Encryption successful"
            )
        } catch {
            return EncryptionResult(
                success: false,
                encryptedData: nil,
                reason: error.localizedDescription
            )
        }
    }
    
    /// Decrypt data at rest
    public func decrypt(_ encryptedData: Data) -> DecryptionResult {
        guard let key = encryptionKey else {
            return DecryptionResult(success: false, data: nil, reason: "No encryption key")
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
        public let success: Bool
        public let encryptedData: Data?
        public let reason: String
    }
    
    /// Decryption result
    public struct DecryptionResult: Sendable {
        public let success: Bool
        public let data: Data?
        public let reason: String
    }
}
