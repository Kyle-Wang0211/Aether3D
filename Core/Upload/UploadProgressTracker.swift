// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Progress Tracker
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload progress event.
public struct UploadProgressEvent: Equatable {
    public let sessionId: String
    public let progress: Double
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public let speedBps: Double
    public let estimatedRemainingSeconds: TimeInterval?
    public let timestamp: Date

    public init(
        sessionId: String,
        progress: Double,
        uploadedBytes: Int64,
        totalBytes: Int64,
        speedBps: Double,
        estimatedRemainingSeconds: TimeInterval?,
        timestamp: Date = Date()
    ) {
        self.sessionId = sessionId
        self.progress = progress
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.speedBps = speedBps
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.timestamp = timestamp
    }
}

/// Upload progress tracker delegate.
public protocol UploadProgressTrackerDelegate: AnyObject {
    func progressTracker(_ tracker: UploadProgressTracker, didUpdateProgress event: UploadProgressEvent)
}

/// Upload progress tracker for aggregating and reporting progress.
public final class UploadProgressTracker {

    public weak var delegate: UploadProgressTrackerDelegate?

    private let session: UploadSession
    private let speedMonitor: NetworkSpeedMonitor
    private let queue = DispatchQueue(label: "com.app.upload.progresstracker", qos: .userInitiated)
    private var lastReportedProgress: Double = 0.0
    private var lastReportTime: Date = .distantPast

    public init(session: UploadSession, speedMonitor: NetworkSpeedMonitor) {
        self.session = session
        self.speedMonitor = speedMonitor
    }

    /// Update and report progress if threshold is met.
    public func updateProgress() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let currentProgress = self.session.progress
            let now = Date()

            // Check throttle
            let timeSinceLastReport = now.timeIntervalSince(self.lastReportTime)
            if timeSinceLastReport < UploadConstants.PROGRESS_THROTTLE_INTERVAL {
                return
            }

            // Check minimum increment
            let progressDelta = abs(currentProgress - self.lastReportedProgress)
            if progressDelta < UploadConstants.MIN_PROGRESS_INCREMENT_PERCENT / 100.0 {
                return
            }

            self.lastReportedProgress = currentProgress
            self.lastReportTime = now

            let speedBps = self.speedMonitor.getSpeedBps()
            let remainingBytes = self.session.fileSize - self.session.uploadedBytes
            let estimatedRemaining: TimeInterval? = speedBps > 0
                ? Double(remainingBytes) / speedBps
                : nil

            let event = UploadProgressEvent(
                sessionId: self.session.sessionId,
                progress: currentProgress,
                uploadedBytes: self.session.uploadedBytes,
                totalBytes: self.session.fileSize,
                speedBps: speedBps,
                estimatedRemainingSeconds: estimatedRemaining
            )

            DispatchQueue.main.async {
                self.delegate?.progressTracker(self, didUpdateProgress: event)
            }
        }
    }

    /// Force report current progress (ignoring throttle).
    public func forceReportProgress() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.lastReportedProgress = self.session.progress
            self.lastReportTime = Date()

            let speedBps = self.speedMonitor.getSpeedBps()
            let remainingBytes = self.session.fileSize - self.session.uploadedBytes
            let estimatedRemaining: TimeInterval? = speedBps > 0
                ? Double(remainingBytes) / speedBps
                : nil

            let event = UploadProgressEvent(
                sessionId: self.session.sessionId,
                progress: self.session.progress,
                uploadedBytes: self.session.uploadedBytes,
                totalBytes: self.session.fileSize,
                speedBps: speedBps,
                estimatedRemainingSeconds: estimatedRemaining
            )

            DispatchQueue.main.async {
                self.delegate?.progressTracker(self, didUpdateProgress: event)
            }
        }
    }
}
