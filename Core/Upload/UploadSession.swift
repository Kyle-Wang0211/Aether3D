// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Upload Session
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload session state enumeration.
public enum UploadSessionState: String, Codable, CaseIterable {
    case initialized = "initialized"
    case uploading = "uploading"
    case paused = "paused"
    case stalled = "stalled"
    case completing = "completing"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Chunk state enumeration.
public enum ChunkState: String, Codable {
    case pending = "pending"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
}

/// Chunk status tracking.
public struct ChunkStatus: Codable, Equatable {
    public let index: Int
    public let offset: Int64
    public let size: Int
    public var state: ChunkState
    public var retryCount: Int
    public var lastError: String?

    public init(index: Int, offset: Int64, size: Int) {
        self.index = index
        self.offset = offset
        self.size = size
        self.state = .pending
        self.retryCount = 0
        self.lastError = nil
    }
}

/// Upload session for managing a single file upload.
public final class UploadSession {

    public let sessionId: String
    public let fileSize: Int64
    public let fileName: String
    public private(set) var state: UploadSessionState
    public private(set) var chunks: [ChunkStatus]
    public private(set) var uploadedBytes: Int64
    public let createdAt: Date
    public private(set) var updatedAt: Date

    private let queue = DispatchQueue(label: "com.app.upload.session", qos: .userInitiated)

    public init(sessionId: String = UUID().uuidString, fileName: String, fileSize: Int64, chunkSize: Int) {
        self.sessionId = sessionId
        self.fileName = fileName
        self.fileSize = fileSize
        self.state = .initialized
        self.uploadedBytes = 0
        self.createdAt = Date()
        self.updatedAt = Date()

        // Calculate chunks
        var chunks: [ChunkStatus] = []
        var offset: Int64 = 0
        var index = 0
        while offset < fileSize {
            let remainingBytes = fileSize - offset
            let currentChunkSize = min(Int(remainingBytes), chunkSize)
            chunks.append(ChunkStatus(index: index, offset: offset, size: currentChunkSize))
            offset += Int64(currentChunkSize)
            index += 1
        }
        self.chunks = chunks
    }

    /// Get progress as a percentage (0.0 - 1.0).
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(uploadedBytes) / Double(fileSize)
    }

    /// Get number of completed chunks.
    public var completedChunkCount: Int {
        return queue.sync { chunks.filter { $0.state == .completed }.count }
    }

    /// Get total chunk count.
    public var totalChunkCount: Int {
        return chunks.count
    }

    /// Update session state.
    public func updateState(_ newState: UploadSessionState) {
        queue.sync {
            self.state = newState
            self.updatedAt = Date()
        }
    }

    /// Mark chunk as completed.
    public func markChunkCompleted(index: Int) {
        queue.sync {
            guard index < chunks.count else { return }
            chunks[index].state = .completed
            uploadedBytes = chunks.filter { $0.state == .completed }
                .reduce(0) { $0 + Int64($1.size) }
            updatedAt = Date()
        }
    }

    /// Mark chunk as failed.
    public func markChunkFailed(index: Int, error: String) {
        queue.sync {
            guard index < chunks.count else { return }
            chunks[index].state = .failed
            chunks[index].retryCount += 1
            chunks[index].lastError = error
            updatedAt = Date()
        }
    }

    /// Get next pending chunk.
    public func getNextPendingChunk() -> ChunkStatus? {
        return queue.sync {
            chunks.first { $0.state == .pending }
        }
    }

    /// Check if session has expired.
    public func isExpired(maxAge: TimeInterval = UploadConstants.SESSION_MAX_AGE_SECONDS) -> Bool {
        return Date().timeIntervalSince(createdAt) > maxAge
    }
}
