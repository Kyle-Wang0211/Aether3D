// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Resume Manager
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload resume manager for persisting and recovering upload sessions.
public final class UploadResumeManager {

    private let userDefaults: UserDefaults
    private let keyPrefix: String
    private let queue = DispatchQueue(label: "com.app.upload.resumemanager", qos: .utility)

    public init(userDefaults: UserDefaults = .standard, keyPrefix: String = UploadConstants.SESSION_PERSISTENCE_KEY_PREFIX) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    /// Save session state for later resume.
    public func saveSession(_ session: UploadSession) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let key = self.keyPrefix + session.sessionId
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            if let data = try? encoder.encode(SessionSnapshot(session: session)) {
                self.userDefaults.set(data, forKey: key)
            }
        }
    }

    /// Load session state for resume.
    public func loadSession(sessionId: String) -> SessionSnapshot? {
        return queue.sync { [weak self] in
            guard let self = self else { return nil }
            let key = self.keyPrefix + sessionId
            guard let data = self.userDefaults.data(forKey: key) else { return nil }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SessionSnapshot.self, from: data)
        }
    }

    /// Delete session state.
    public func deleteSession(sessionId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let key = self.keyPrefix + sessionId
            self.userDefaults.removeObject(forKey: key)
        }
    }

    /// Get all saved session IDs.
    public func getAllSessionIds() -> [String] {
        return queue.sync { [weak self] in
            guard let self = self else { return [] }
            return self.userDefaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(self.keyPrefix) }
                .map { String($0.dropFirst(self.keyPrefix.count)) }
        }
    }

    /// Clean up expired sessions.
    public func cleanupExpiredSessions(maxAge: TimeInterval = UploadConstants.SESSION_MAX_AGE_SECONDS) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let sessionIds = self.getAllSessionIds()
            let cutoff = Date().addingTimeInterval(-maxAge)

            for sessionId in sessionIds {
                if let snapshot = self.loadSession(sessionId: sessionId),
                   snapshot.createdAt < cutoff {
                    self.deleteSession(sessionId: sessionId)
                }
            }
        }
    }
}

/// Session snapshot for persistence.
public struct SessionSnapshot: Codable {
    public let sessionId: String
    public let fileName: String
    public let fileSize: Int64
    public let chunks: [ChunkStatus]
    public let uploadedBytes: Int64
    public let createdAt: Date
    public let state: UploadSessionState

    public init(session: UploadSession) {
        self.sessionId = session.sessionId
        self.fileName = session.fileName
        self.fileSize = session.fileSize
        self.chunks = session.chunks
        self.uploadedBytes = session.uploadedBytes
        self.createdAt = session.createdAt
        self.state = session.state
    }
}
