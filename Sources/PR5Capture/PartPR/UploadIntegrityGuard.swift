// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// UploadIntegrityGuard.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 上传完整性守卫，传输校验
//

import Foundation
import SharedSecurity

/// Upload integrity guard
///
/// Guards upload integrity with transmission verification.
/// Ensures data integrity during upload.
public actor UploadIntegrityGuard {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Upload history
    private var uploadHistory: [UploadRecord] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Integrity Guarding
    
    /// Guard upload
    public func guardUpload(_ data: Data, destination: String) -> GuardResult {
        // Compute checksum
        let checksum = computeChecksum(data)
        
        let record = UploadRecord(
            id: UUID(),
            timestamp: Date(),
            dataSize: data.count,
            checksum: checksum,
            destination: destination
        )
        
        uploadHistory.append(record)
        
        // Keep only recent history (last 1000)
        if uploadHistory.count > 1000 {
            uploadHistory.removeFirst()
        }
        
        return GuardResult(
            uploadId: record.id,
            checksum: checksum,
            verified: true
        )
    }
    
    /// Verify upload integrity
    public func verifyIntegrity(uploadId: UUID, receivedChecksum: String) -> VerificationResult {
        guard let record = uploadHistory.first(where: { $0.id == uploadId }) else {
            return VerificationResult(verified: false, reason: "Upload not found")
        }
        
        let verified = record.checksum == receivedChecksum
        
        return VerificationResult(
            verified: verified,
            reason: verified ? "Checksum match" : "Checksum mismatch"
        )
    }
    
    /// Compute checksum
    /// 
    /// 使用密码学安全的SHA256哈希，符合INV-SEC-065: 传输校验必须使用SHA256而非hashValue。
    private func computeChecksum(_ data: Data) -> String {
        return CryptoHasher.sha256(data)
    }
    
    // MARK: - Data Types
    
    /// Upload record
    public struct UploadRecord: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let dataSize: Int
        public let checksum: String
        public let destination: String
    }
    
    /// Guard result
    public struct GuardResult: Sendable {
        public let uploadId: UUID
        public let checksum: String
        public let verified: Bool
    }
    
    /// Verification result
    public struct VerificationResult: Sendable {
        public let verified: Bool
        public let reason: String
    }
}
