// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-RESUME-1.0
// Module: Upload Infrastructure - Enhanced Resume Manager
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Security)
import Security
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File fingerprint for resume validation.
public struct FileFingerprint: Sendable, Codable {
    public let fileSize: Int64
    public let sha256Hex: String
    public let createdAt: Date
    public let modifiedAt: Date
}

/// Resume state snapshot.
public struct ResumeState: Sendable, Codable {
    public let sessionId: String
    public let fileFingerprint: FileFingerprint
    public let ackedChunks: [Int]
    public let merkleRoot: String?
    public let commitmentTip: String?
    public let uploadPosition: Int64
    public let version: UInt8  // v1=plaintext, v2=AES-GCM
}

/// Resume level.
public enum ResumeLevel: Int, Sendable {
    case level1 = 1  // Local state only
    case level2 = 2  // Server state verification
    case level3 = 3  // Full integrity check
}

/// 3-level resume strategy with FileFingerprint, AES-GCM encrypted snapshots.
///
/// **Purpose**: 3-level resume strategy with FileFingerprint, AES-GCM encrypted snapshots,
/// server state verification, atomic persistence (write+fsync+rename).
///
/// **3-Level Resume**:
/// - Level 1: Local encrypted snapshot only
/// - Level 2: Verify with server (GetChunksResponse)
/// - Level 3: Full integrity check (Merkle + Commitment Chain)
///
/// **Atomic Persistence**: write+fsync+rename pattern — survives crashes and power loss.
/// Checkpoint frequency: every 10 ACKed chunks.
public actor EnhancedResumeManager {
    
    // MARK: - State
    
    private let resumeDirectory: URL
    private var sessionKey: SymmetricKey?
    private let masterKey: SymmetricKey
    
    // MARK: - Initialization
    
    /// Initialize enhanced resume manager.
    ///
    /// - Parameters:
    ///   - resumeDirectory: Directory for resume state files
    ///   - masterKey: Master encryption key (from Keychain)
    public init(resumeDirectory: URL, masterKey: SymmetricKey) {
        self.resumeDirectory = resumeDirectory
        self.masterKey = masterKey
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - File Fingerprint
    
    /// Compute file fingerprint.
    ///
    /// - Parameter fileURL: File URL
    /// - Returns: File fingerprint
    /// - Throws: IOError on read failure
    public func computeFingerprint(fileURL: URL) async throws -> FileFingerprint { // LINT:ALLOW
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let createdAt = attributes[.creationDate] as? Date ?? Date()
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        
        // Compute SHA-256 hash
        let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
        
        return FileFingerprint( // LINT:ALLOW
            fileSize: fileSize,
            sha256Hex: hashResult.sha256Hex,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
    
    // MARK: - Resume State Persistence
    
    /// Persist resume state atomically (write+fsync+rename).
    ///
    /// **Atomic Pattern**: Write to temp file → fsync → rename
    /// This guarantees: either old state or new state is on disk. NEVER a half-written state.
    ///
    /// - Parameter state: Resume state to persist
    /// - Throws: ResumeError on persistence failure
    public func persistResumeState(_ state: ResumeState) async throws {
        // Derive session key
        let sessionKey = deriveSessionKey(sessionId: state.sessionId)
        
        // Encode state
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(state)
        
        // Encrypt with AES-GCM
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: sessionKey, nonce: nonce)
        
        guard let encryptedData = sealedBox.combined else {
            throw ResumeError.encryptionFailed
        }
        
        // Atomic write: temp file → fsync → rename
        let targetPath = resumeStatePath(sessionId: state.sessionId)
        let tempPath = targetPath.appendingPathExtension("tmp.\(UUID().uuidString)")
        
        // Write to temp file
        try encryptedData.write(to: tempPath)
        
        // fsync to ensure data on disk
        let fd = open(tempPath.path, O_RDWR)
        guard fd >= 0 else {
            throw ResumeError.persistenceFailed
        }
        defer { close(fd) }
        
        fsync(fd)
        
        // Atomic rename (replaceItemAt overwrites existing)
        if FileManager.default.fileExists(atPath: targetPath.path) {
            _ = try FileManager.default.replaceItemAt(targetPath, withItemAt: tempPath)
        } else {
            try FileManager.default.moveItem(at: tempPath, to: targetPath)
        }
    }
    
    /// Load resume state.
    ///
    /// - Parameter sessionId: Session ID
    /// - Returns: Resume state, or nil if not found
    /// - Throws: ResumeError on load failure
    public func loadResumeState(sessionId: String) async throws -> ResumeState? {
        let filePath = resumeStatePath(sessionId: sessionId)

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return nil
        }

        // Read encrypted data
        let encryptedData = try Data(contentsOf: filePath)

        // Decrypt — wrap CryptoKit/decoding errors into ResumeError
        do {
            let sessionKey = deriveSessionKey(sessionId: sessionId)
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(sealedBox, using: sessionKey)

            // Decode
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ResumeState.self, from: plaintext)
        } catch is ResumeError {
            throw ResumeError.decryptionFailed
        } catch {
            throw ResumeError.decryptionFailed
        }
    }
    
    // MARK: - Resume Levels
    
    /// Resume at level 1 (local state only).
    ///
    /// - Parameters:
    ///   - sessionId: Session ID
    ///   - fileURL: File URL
    /// - Returns: Resume state if valid, nil otherwise
    public func resumeLevel1(sessionId: String, fileURL: URL) async throws -> ResumeState? {
        guard let state = try await loadResumeState(sessionId: sessionId) else {
            return nil
        }
        
        // Verify file fingerprint matches
        let currentFingerprint = try await computeFingerprint(fileURL: fileURL) // LINT:ALLOW
        guard currentFingerprint.sha256Hex == state.fileFingerprint.sha256Hex else {
            return nil  // File changed
        }
        
        return state
    }
    
    /// Resume at level 2 (server state verification).
    ///
    /// - Parameters:
    ///   - sessionId: Session ID
    ///   - fileURL: File URL
    ///   - serverChunks: Server-reported received chunks
    /// - Returns: Resume state if valid, nil otherwise
    public func resumeLevel2(
        sessionId: String,
        fileURL: URL,
        serverChunks: [Int]
    ) async throws -> ResumeState? {
        guard let state = try await resumeLevel1(sessionId: sessionId, fileURL: fileURL) else {
            return nil
        }
        
        // Verify server chunks match local state
        let localChunks = Set(state.ackedChunks)
        let serverChunksSet = Set(serverChunks)
        
        guard localChunks.isSubset(of: serverChunksSet) else {
            return nil  // Server has fewer chunks than local state
        }
        
        return state
    }
    
    /// Resume at level 3 (full integrity check).
    ///
    /// - Parameters:
    ///   - sessionId: Session ID
    ///   - fileURL: File URL
    ///   - serverChunks: Server-reported received chunks
    ///   - merkleRoot: Expected Merkle root
    ///   - commitmentTip: Expected commitment chain tip
    /// - Returns: Resume state if valid, nil otherwise
    public func resumeLevel3(
        sessionId: String,
        fileURL: URL,
        serverChunks: [Int],
        merkleRoot: String?,
        commitmentTip: String?
    ) async throws -> ResumeState? {
        guard let state = try await resumeLevel2(
            sessionId: sessionId,
            fileURL: fileURL,
            serverChunks: serverChunks
        ) else {
            return nil
        }
        
        // Verify Merkle root
        if let expectedRoot = merkleRoot, let actualRoot = state.merkleRoot {
            guard expectedRoot == actualRoot else {
                return nil  // Merkle root mismatch
            }
        }
        
        // Verify commitment chain tip
        if let expectedTip = commitmentTip, let actualTip = state.commitmentTip {
            guard expectedTip == actualTip else {
                return nil  // Commitment chain mismatch
            }
        }
        
        return state
    }
    
    // MARK: - Helper Functions
    
    /// Derive session-specific key from master key.
    private func deriveSessionKey(sessionId: String) -> SymmetricKey {
        let info = Data("PR9-resume-\(sessionId)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: info,
            outputByteCount: 32
        )
    }
    
    /// Get resume state file path.
    /// Long session IDs are hashed to prevent exceeding filesystem filename limits.
    private func resumeStatePath(sessionId: String) -> URL {
        let filename: String
        if sessionId.count > 200 {
            // Hash long session IDs to stay within filesystem limits
            let hash = SHA256.hash(data: Data(sessionId.utf8))
            filename = hash.compactMap { String(format: "%02x", $0) }.joined()
        } else {
            filename = sessionId
        }
        return resumeDirectory.appendingPathComponent("\(filename).resume")
    }
}

/// Resume error.
public enum ResumeError: Error, Sendable {
    case encryptionFailed
    case decryptionFailed
    case persistenceFailed
    case fingerprintMismatch
    case invalidState
}
