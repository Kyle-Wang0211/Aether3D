// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Chunk Manager
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Chunk upload error enumeration.
public enum ChunkUploadError: Error, Equatable {
    case networkError(String)
    case serverError(Int)
    case timeout
    case cancelled
    case maxRetriesExceeded
}

/// Chunk manager delegate protocol.
public protocol ChunkManagerDelegate: AnyObject {
    func chunkManager(_ manager: ChunkManager, didStartChunk index: Int)
    func chunkManager(_ manager: ChunkManager, didCompleteChunk index: Int)
    func chunkManager(_ manager: ChunkManager, didFailChunk index: Int, error: ChunkUploadError)
    func chunkManager(_ manager: ChunkManager, didUpdateProgress progress: Double)
}

/// Chunk manager for coordinating parallel chunk uploads.
public final class ChunkManager {

    public weak var delegate: ChunkManagerDelegate?

    private let session: UploadSession
    private let speedMonitor: NetworkSpeedMonitor
    private let chunkSizer: AdaptiveChunkSizer
    private let queue = DispatchQueue(label: "com.app.upload.chunkmanager", qos: .userInitiated)
    private var activeUploads: Set<Int> = []
    private var isCancelled: Bool = false

    public init(session: UploadSession, speedMonitor: NetworkSpeedMonitor, chunkSizer: AdaptiveChunkSizer) {
        self.session = session
        self.speedMonitor = speedMonitor
        self.chunkSizer = chunkSizer
    }

    /// Get current number of active uploads.
    public var activeUploadCount: Int {
        return queue.sync { activeUploads.count }
    }

    /// Get recommended parallel count based on network conditions.
    public var recommendedParallelCount: Int {
        return chunkSizer.getRecommendedParallelCount()
    }

    /// Check if upload should continue.
    public var shouldContinue: Bool {
        return queue.sync { !isCancelled && !session.state.isTerminal }
    }

    /// Cancel all uploads.
    public func cancel() {
        queue.sync {
            isCancelled = true
            activeUploads.removeAll()
        }
        session.updateState(.cancelled)
    }

    /// Mark chunk upload as started.
    public func markChunkStarted(index: Int) {
        queue.sync { [self] in
            _ = activeUploads.insert(index)
        }
        delegate?.chunkManager(self, didStartChunk: index)
    }

    /// Mark chunk upload as completed.
    public func markChunkCompleted(index: Int, bytesTransferred: Int64, duration: TimeInterval) {
        queue.sync {
            _ = activeUploads.remove(index)
        }
        session.markChunkCompleted(index: index)
        speedMonitor.recordSample(bytesTransferred: bytesTransferred, durationSeconds: duration)
        delegate?.chunkManager(self, didCompleteChunk: index)
        delegate?.chunkManager(self, didUpdateProgress: session.progress)
    }

    /// Mark chunk upload as failed.
    public func markChunkFailed(index: Int, error: ChunkUploadError) {
        queue.sync {
            _ = activeUploads.remove(index)
        }
        session.markChunkFailed(index: index, error: "\(error)")
        delegate?.chunkManager(self, didFailChunk: index, error: error)
    }

    /// Calculate retry delay with decorrelated jitter.
    public func calculateRetryDelay(attempt: Int) -> TimeInterval {
        let baseDelay = UploadConstants.RETRY_BASE_DELAY_SECONDS
        let maxDelay = UploadConstants.RETRY_MAX_DELAY_SECONDS
        let jitter = UploadConstants.RETRY_JITTER_FACTOR

        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, maxDelay)
        let jitterRange = cappedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)

        return max(baseDelay, cappedDelay + randomJitter)
    }
}
