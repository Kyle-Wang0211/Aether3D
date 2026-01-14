//
//  RecordingController.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//
//  CI-HARDENED: This file is CI-hardened for GitHub Actions / xcodebuild / swift test.
//  Do not add:
//    - Date() (use ClockProvider)
//    - Timer.scheduledTimer (use TimerScheduler)
//    - Magic number literals (use CaptureRecordingConstants)
//    - Force unwraps in file operations (provide fallbacks)
//

import Foundation
import AVFoundation
import UIKit
import os.log

// MARK: - Dependency Protocols

private protocol ThermalStateProvider {
    var currentState: ProcessInfo.ThermalState { get }
    var isCurrentStateUnknown: Bool { get }
}

private protocol FileManagerProvider {
    func fileExists(at url: URL) -> Bool
    func fileSize(at url: URL) -> UInt64?
    func moveItem(from: URL, to: URL) throws
    func copyItem(from: URL, to: URL) throws
    func removeItem(at url: URL) throws
    func freeDiskBytes(for url: URL) -> UInt64?
}

private protocol ClockProvider {
    func now() -> Date
}

private protocol TimerScheduler {
    @discardableResult
    func schedule(after: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
}

private protocol Cancellable {
    func cancel()
}

private protocol BundleInfoProvider {
    var appVersion: String { get }
    var buildVersion: String { get }
}

// MARK: - Default Implementations

private struct DefaultThermalStateProvider: ThermalStateProvider {
    var currentState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    var isCurrentStateUnknown: Bool { false }
}

private struct DefaultFileManagerProvider: FileManagerProvider {
    private let fm = FileManager.default
    
    func fileExists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }
    
    func fileSize(at url: URL) -> UInt64? {
        try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64
    }
    
    func moveItem(from: URL, to: URL) throws {
        try fm.moveItem(at: from, to: to)
    }
    
    func copyItem(from: URL, to: URL) throws {
        try fm.copyItem(at: from, to: to)
    }
    
    func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }
    
    func freeDiskBytes(for url: URL) -> UInt64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

private struct DefaultClockProvider: ClockProvider {
    func now() -> Date { Date() }
}

private struct DefaultTimerScheduler: TimerScheduler {
    @discardableResult
    func schedule(after: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let timer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { _ in block() }
        return TimerCancellable(timer: timer)
    }
}

private struct TimerCancellable: Cancellable {
    let timer: Timer
    func cancel() { timer.invalidate() }
}

private struct DefaultBundleInfoProvider: BundleInfoProvider {
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }
    var buildVersion: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown" }
}

// MARK: - RecordingController

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed(RecordingError)
}

final class RecordingController: NSObject {
    private let cameraSession: CameraSessionProtocol
    private let interruptionHandler: InterruptionHandler
    private let thermalProvider: ThermalStateProvider
    private let fileManager: FileManagerProvider
    private let clock: ClockProvider
    private let timerScheduler: TimerScheduler
    private let bundleInfo: BundleInfoProvider
    
    private var state: RecordingState = .idle
    private var epoch: Int = 0
    private var pendingStop: Bool = false
    private var hasDeliveredFinish: Bool = false
    private var lockedStopReason: StopReason?
    private var lockedStopTriggerSource: StopTriggerSource?
    private var metadata: CaptureMetadata
    private var currentTmpFileURL: URL?
    private var currentOrientation: AVCaptureVideoOrientation = .portrait
    private var sizePollToken: Cancellable?
    private var processingFinishEpoch: Int?
    
    var onFinish: ((Result<CaptureMetadata, RecordingError>) -> Void)?
    var onStateChange: ((String) -> Void)?
    
    init(cameraSession: CameraSessionProtocol,
         interruptionHandler: InterruptionHandler,
         thermalProvider: ThermalStateProvider = DefaultThermalStateProvider(),
         fileManager: FileManagerProvider = DefaultFileManagerProvider(),
         clock: ClockProvider = DefaultClockProvider(),
         timerScheduler: TimerScheduler = DefaultTimerScheduler(),
         bundleInfo: BundleInfoProvider = DefaultBundleInfoProvider()) {
        self.cameraSession = cameraSession
        self.interruptionHandler = interruptionHandler
        self.thermalProvider = thermalProvider
        self.fileManager = fileManager
        self.clock = clock
        self.timerScheduler = timerScheduler
        self.bundleInfo = bundleInfo
        
        let deviceModel = UIDevice.current.model
        let osVersion = UIDevice.current.systemVersion
        self.metadata = CaptureMetadata(
            recordingId: UUID(),
            epoch: 0,
            requestedAt: clock.now(),
            deviceModel: deviceModel,
            osVersion: osVersion,
            appVersion: bundleInfo.appVersion,
            thermalPreflightWeight: thermalProvider.currentState.weight,
            thermalMaxWeight: thermalProvider.currentState.weight,
            thermalPlatform: CaptureRecordingConstants.thermalPlatform,
            maxBytesConfigured: CaptureRecordingConstants.maxBytes,
            maxDurationConfigured: CaptureRecordingConstants.maxDurationSeconds,
            audioPolicy: .ignored,
            buildVersion: bundleInfo.buildVersion
        )
    }
    
    func startRecording(orientation: AVCaptureVideoOrientation = .portrait) -> RecordingError? {
        guard case .idle = state else {
            return .alreadyRecording
        }
        
        // Increment epoch
        epoch += 1
        
        // Reset per-epoch flags
        pendingStop = false
        hasDeliveredFinish = false
        lockedStopReason = nil
        lockedStopTriggerSource = nil
        
        // Update orientation
        currentOrientation = orientation
        
        // Generate new recording ID and update metadata
        let newRecordingId = UUID()
        metadata.recordingId = newRecordingId
        metadata.epoch = epoch
        metadata.requestedAt = clock.now()
        
        // Add diagnostic
        addDiag(.startRequested, note: nil)
        
        // Configure session
        do {
            try cameraSession.configure(orientation: orientation)
            addDiag(.sessionConfigured, note: nil)
            
            // Add format selected diagnostic
            if let config = cameraSession.selectedConfig {
                addDiag(.formatSelected, note: .tierFpsCodec(
                    tier: config.tier,
                    fps: Int(round(config.frameRate)),
                    codec: config.codec
                ))
            }
        } catch {
            if let recError = error as? RecordingError {
                state = .failed(recError)
                return recError
            }
            state = .failed(.configurationFailed(.formatSelectionFailed))
            return .configurationFailed(.formatSelectionFailed)
        }
        
        // Start session running
        cameraSession.startRunning()
        
        // Generate tmp file URL
        let tmpDir = FileManager.default.temporaryDirectory
        let recordingIdStr = newRecordingId.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        currentTmpFileURL = tmpDir.appendingPathComponent("\(recordingIdStr).mov")
        
        guard let tmpURL = currentTmpFileURL else {
            state = .failed(.configurationFailed(.outputDirectoryFailed))
            return .configurationFailed(.outputDirectoryFailed)
        }
        
        // Transition to starting
        state = .starting
        
        // Start recording
        cameraSession.startRecording(to: tmpURL, delegate: self)
        
        return nil
    }
    
    func requestStop(reason: StopReason) {
        lockStopReasonIfNil(reason)
        
        switch state {
        case .idle:
            return
        case .starting:
            pendingStop = true
        case .recording:
            state = .stopping
            invalidateTimers()
            cameraSession.stopRecording()
        case .stopping, .failed:
            return
        }
    }
    
    private func invalidateTimers() {
        sizePollToken?.cancel()
        sizePollToken = nil
    }
    
    // MARK: - Stop Locking
    
    private func lockStopReasonIfNil(_ reason: StopReason) {
        guard lockedStopReason == nil else { return }
        lockedStopReason = reason
        metadata.stopReason = reason
        
        // Map to stopTriggerSource
        let triggerSource: StopTriggerSource
        switch reason {
        case .userStopped: triggerSource = .user
        case .maxDurationReached: triggerSource = .durationLimit
        case .maxSizeReached: triggerSource = .sizeLimit
        case .thermalLimitReached: triggerSource = .thermal
        case .interrupted: triggerSource = .interruption
        }
        lockStopTriggerSourceIfNil(triggerSource)
        
        // First lock: set stopRequestedAt and add diagnostic
        if metadata.stopRequestedAt == nil {
            metadata.stopRequestedAt = clock.now()
            addDiag(.stopRequested, note: nil)
        }
        
        os_log("[PR4] stop_reason_locked: %{public}@", String(describing: reason))
    }
    
    private func lockStopTriggerSourceIfNil(_ src: StopTriggerSource) {
        guard lockedStopTriggerSource == nil else { return }
        lockedStopTriggerSource = src
        metadata.stopTriggerSource = src
    }
    
    // MARK: - Diagnostics
    
    private func addDiag(_ code: DiagnosticEventCode, note: DiagnosticNote?) {
        let now = clock.now()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.metadata.addDiagnostic(code: code, at: now, note: note)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension RecordingController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Verify epoch matches
            guard fileURL == self.currentTmpFileURL else {
                os_log("[PR4] didStart epoch_mismatch: url_mismatch")
                return
            }
            
            // Verify state
            guard case .starting = self.state else {
                self.addWarning(.startCallbackAfterFinish)
                return
            }
            
            // If pending stop, stop immediately
            if self.pendingStop {
                self.requestStop(reason: .userStopped)
                return
            }
            
            // Add diagnostic
            self.addDiag(.recordingDidStart, note: nil)
            
            // Write capability snapshot
            if let config = self.cameraSession.selectedConfig {
                self.metadata.capabilitySnapshot = CaptureCapabilitySnapshot(
                    resolutionTier: config.tier,
                    width: config.dimensions.width,
                    height: config.dimensions.height,
                    fps: config.frameRate,
                    isHDR: config.hdrCapable,
                    codec: config.codec
                )
            }
            
            // Set start time
            self.metadata.startedAt = self.clock.now()
            
            // Transition to recording
            self.state = .recording
            
            // Start file size polling
            if let tmpURL = self.currentTmpFileURL {
                self.startFileSizePolling(fileURL: tmpURL)
            }
        }
    }
    
    // MARK: - File Size Polling
    
    private func startFileSizePolling(fileURL: URL) {
        // Initial delay before first poll
        sizePollToken = timerScheduler.schedule(after: CaptureRecordingConstants.fileSizePollStartDelaySeconds) { [weak self] in
            DispatchQueue.main.async {
                self?.pollFileSize(fileURL: fileURL)
            }
        }
    }
    
    private func pollFileSize(fileURL: URL) {
        guard case .recording = state else {
            invalidateTimers()
            return
        }
        
        // Check if file exists
        guard fileManager.fileExists(at: fileURL) else {
            // File not yet created, schedule next poll
            scheduleNextPoll(fileURL: fileURL, currentSize: 0)
            return
        }
        
        // Read file size
        guard let size = fileManager.fileSize(at: fileURL) else {
            // Failed to read size, continue polling
            scheduleNextPoll(fileURL: fileURL, currentSize: 0)
            return
        }
        
        // Update metadata
        metadata.fileSizeBytes = Int64(size)
        
        // Check against max size
        if Int64(size) >= CaptureRecordingConstants.maxBytes {
            requestStop(reason: .maxSizeReached)
            return
        }
        
        // Schedule next poll with dynamic interval
        scheduleNextPoll(fileURL: fileURL, currentSize: Int64(size))
    }
    
    private func scheduleNextPoll(fileURL: URL, currentSize: Int64) {
        let interval: TimeInterval
        if currentSize >= CaptureRecordingConstants.fileSizeLargeThresholdBytes {
            interval = CaptureRecordingConstants.fileSizePollIntervalLargeFile
        } else {
            interval = CaptureRecordingConstants.fileSizePollIntervalSmallFile
        }
        
        sizePollToken = timerScheduler.schedule(after: interval) { [weak self] in
            DispatchQueue.main.async {
                self?.pollFileSize(fileURL: fileURL)
            }
        }
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // === PHASE 0: Main thread snapshot (CRITICAL - must be first) ===
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Snapshot main-thread state as constants for validation
            let snapshotEpoch = self.epoch
            let snapshotTmpURL = self.currentTmpFileURL
            let snapshotDelivered = self.hasDeliveredFinish
            
            // Early exit if already delivered
            if snapshotDelivered {
                let winnerNote = self.metadata.finishDeliveredBy.map { DiagnosticNote.winner($0) }
                os_log("[PR4] duplicate_finish_ignored: epoch=%d", snapshotEpoch)
                self.addDiag(.duplicateFinishIgnored, note: winnerNote)
                return
            }
            
            // Add diagnostic
            self.addDiag(.didFinishArrived, note: nil)
            
            // Verify URL matches expected for this epoch
            guard outputFileURL == snapshotTmpURL else {
                os_log("[PR4] stale_finish_callback: url_mismatch")
                self.addDiag(.staleFinishDiscardedURL, note: nil)
                return
            }
            
            // Verify epoch matches
            guard outputFileURL == self.currentTmpFileURL && snapshotEpoch == self.epoch else {
                os_log("[PR4] stale_finish_callback: epoch_mismatch snapshot=%d current=%d", snapshotEpoch, self.epoch)
                self.addDiag(.staleFinishDiscardedEpoch, note: nil)
                return
            }
            
            // Mark processing epoch
            self.processingFinishEpoch = snapshotEpoch
            
            // === PHASE 1: Background - gather file info ===
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                let budgetStart = self.clock.now()
                let fileExists = self.fileManager.fileExists(at: outputFileURL)
                
                // If file missing, record diagnostic on main thread and skip AVAsset checks
                if !fileExists {
                    DispatchQueue.main.async {
                        self.addDiag(.fileMissingAtFinish, note: nil)
                    }
                    let evidence = FinishEvidence(
                        fileMissing: true,
                        tmpSize: nil,
                        assetDuration: nil,
                        wallclockDuration: self.metadata.startedAt.map { self.clock.now().timeIntervalSince($0) } ?? 0,
                        audioTracks: nil,
                        isPlayable: nil,
                        budgetSkipped: false,
                        error: error
                    )
                    self.proceedToPhase2(evidence: evidence, snapshotEpoch: snapshotEpoch, snapshotTmpURL: snapshotTmpURL, outputFileURL: outputFileURL)
                    return
                }
                
                // File exists, gather evidence
                let tmpSize = Int64(self.fileManager.fileSize(at: outputFileURL) ?? 0)
                let wallclockDuration = self.metadata.startedAt.map { self.clock.now().timeIntervalSince($0) } ?? 0
                
                var assetDuration: Double?
                var audioTracks: Int?
                var isPlayable: Bool?
                var budgetSkipped = false
                
                // AVAsset checks with budget
                let asset = AVAsset(url: outputFileURL)
                let d = asset.duration.seconds
                if d.isFinite && d > 0 {
                    assetDuration = d
                }
                
                // Check budget
                let elapsed = self.clock.now().timeIntervalSince(budgetStart)
                if elapsed < CaptureRecordingConstants.assetCheckTimeoutSeconds {
                    // Within budget, check tracks and playable
                    audioTracks = asset.tracks(withMediaType: .audio).count
                    isPlayable = asset.isPlayable
                } else {
                    // Budget exceeded
                    budgetSkipped = true
                    DispatchQueue.main.async {
                        self.addDiag(.assetChecksSkippedBudget, note: .elapsedSeconds(Int(elapsed.rounded())))
                    }
                }
                
                let evidence = FinishEvidence(
                    fileMissing: false,
                    tmpSize: tmpSize,
                    assetDuration: assetDuration,
                    wallclockDuration: wallclockDuration,
                    audioTracks: audioTracks,
                    isPlayable: isPlayable,
                    budgetSkipped: budgetSkipped,
                    error: error
                )
                
                self.proceedToPhase2(evidence: evidence, snapshotEpoch: snapshotEpoch, snapshotTmpURL: snapshotTmpURL, outputFileURL: outputFileURL)
            }
        }
    }
    
    private func proceedToPhase2(evidence: FinishEvidence, snapshotEpoch: Int, snapshotTmpURL: URL?, outputFileURL: URL) {
        // === PHASE 2: Main thread - validate and determine outcome ===
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Double-factor validation using snapshots
            guard snapshotEpoch == self.epoch && outputFileURL == snapshotTmpURL else {
                return
            }
            
            // Determine outcome
            if evidence.fileMissing {
                let finalResult: Result<CaptureMetadata, RecordingError> = .failure(.finalizeFailed(.fileMissing))
                self.deliverFinish(result: finalResult)
                return
            }
            
            // Calculate effective duration
            let effectiveDuration: Double?
            if let asset = evidence.assetDuration, let wallclock = evidence.wallclockDuration as Double? {
                effectiveDuration = max(asset, wallclock)
                self.metadata.durationSource = (asset >= wallclock) ? .asset : .wallclock
            } else if let asset = evidence.assetDuration {
                effectiveDuration = asset
                self.metadata.durationSource = .asset
            } else if let wallclock = evidence.wallclockDuration as Double? {
                effectiveDuration = wallclock
                self.metadata.durationSource = .wallclock
                self.addWarning(.durationSourceWallclock)
            } else {
                effectiveDuration = nil
            }
            
            self.metadata.assetDurationSeconds = evidence.assetDuration
            self.metadata.wallclockDurationSeconds = evidence.wallclockDuration
            self.metadata.rawDurationSeconds = effectiveDuration
            self.metadata.durationSeconds = effectiveDuration.map { min($0, CaptureRecordingConstants.maxDurationSeconds) }
            
            // Check for audio tracks and playable (warnings only)
            if let tracks = evidence.audioTracks, tracks > 0 {
                self.addWarning(.audioTrackDetected)
            }
            if let playable = evidence.isPlayable, !playable {
                self.addWarning(.playableCheckFalse)
            }
            
            // Check tooShort
            if let duration = effectiveDuration,
               duration < (CaptureRecordingConstants.minDurationSeconds - CaptureRecordingConstants.durationTolerance) {
                // tooShort: delete tmp file
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    do {
                        try self.fileManager.removeItem(at: outputFileURL)
                        DispatchQueue.main.async {
                            let result: Result<CaptureMetadata, RecordingError> = .failure(.tooShort(
                                min: CaptureRecordingConstants.minDurationSeconds,
                                actual: duration
                            ))
                            self.metadata.fileURL = nil
                            self.deliverFinish(result: result)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            let result: Result<CaptureMetadata, RecordingError> = .failure(.finalizeFailed(.unknown))
                            self.metadata.fileURL = outputFileURL
                            self.deliverFinish(result: result)
                        }
                    }
                }
                return
            }
            
            // Determine destination directory and generate URL
            let isSuccess = self.lockedStopReason == .maxDurationReached || (self.lockedStopReason == nil && evidence.error == nil)
            let destDir = isSuccess ? self.recordingsDirectory : self.failuresDirectory
            
            guard let finalURL = self.generateFinalURL(in: destDir) else {
                // Destination unavailable
                self.addDiag(.finalizeDelivered, note: .destUnavailable)
                let result: Result<CaptureMetadata, RecordingError> = .failure(.finalizeFailed(.destinationUnavailable))
                self.deliverFinish(result: result)
                return
            }
            
            // Route to Phase 3
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.executePhase3(
                    tmpURL: outputFileURL,
                    finalURL: finalURL,
                    isSuccess: isSuccess,
                    evidence: evidence,
                    snapshotEpoch: snapshotEpoch
                )
            }
        }
    }
    
    private struct FinishEvidence {
        let fileMissing: Bool
        let tmpSize: Int64?
        let assetDuration: Double?
        let wallclockDuration: Double
        let audioTracks: Int?
        let isPlayable: Bool?
        let budgetSkipped: Bool
        let error: Error?
    }
    
    private func deliverFinish(result: Result<CaptureMetadata, RecordingError>) {
        hasDeliveredFinish = true
        lockFinishDeliveredByIfNil(.didFinish)
        addDiag(.finalizeDelivered, note: .winner(.didFinish))
        onFinish?(result)
    }
    
    private func lockFinishDeliveredByIfNil(_ winner: FinishDeliveryWinner) {
        guard metadata.finishDeliveredBy == nil else { return }
        metadata.finishDeliveredBy = winner
    }
    
    private func addWarning(_ warning: WarningCode) {
        guard !metadata.warnings.contains(warning) else { return }
        metadata.warnings.append(warning)
    }
    
    private var recordingsDirectory: URL {
        // CI-HARDENED: Remove force unwrap, provide fallback
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to temporary directory if applicationSupportDirectory unavailable (should never happen in practice)
            return FileManager.default.temporaryDirectory.appendingPathComponent("Recordings")
        }
        return base.appendingPathComponent("Recordings")
    }
    
    private var failuresDirectory: URL {
        recordingsDirectory.appendingPathComponent("Failures")
    }
    
    private func generateFinalURL(in directory: URL) -> URL? {
        // Ensure directory exists
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        
        let uuid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let formatter = DateFormatter()
        formatter.dateFormat = CaptureRecordingConstants.timestampFormat
        formatter.locale = Locale(identifier: CaptureRecordingConstants.timestampLocale)
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: clock.now())
        let baseName = "\(uuid)_\(timestamp)"
        var candidate = directory.appendingPathComponent("\(baseName).mov")
        
        for i in 0..<CaptureRecordingConstants.maxFilenameCollisionRetries {
            if !fileManager.fileExists(at: candidate) {
                if i > 0 {
                    addWarning(.filenameCollision)
                }
                return candidate
            }
            candidate = directory.appendingPathComponent("\(baseName)_\(i + 1).mov")
        }
        
        return nil
    }
    
    private func executePhase3(tmpURL: URL, finalURL: URL, isSuccess: Bool, evidence: FinishEvidence, snapshotEpoch: Int) {
        // Add diagnostic on main thread
        DispatchQueue.main.async { [weak self] in
            self?.addDiag(.moveAttempted, note: nil)
        }
        
        var finalSize: Int64?
        var moveSucceeded = false
        
        // Attempt move
        do {
            try fileManager.moveItem(from: tmpURL, to: finalURL)
            moveSucceeded = true
            DispatchQueue.main.async { [weak self] in
                self?.addDiag(.moveSucceeded, note: nil)
            }
        } catch {
            // Try copy fallback
            do {
                try fileManager.copyItem(from: tmpURL, to: finalURL)
                try? fileManager.removeItem(at: tmpURL)
                moveSucceeded = true
                DispatchQueue.main.async { [weak self] in
                    self?.addDiag(.copyFallbackUsed, note: nil)
                }
            } catch {
                // Move/copy failed
                DispatchQueue.main.async { [weak self] in
                    self?.addWarning(.moveFailed)
                }
            }
        }
        
        // Read final size if move succeeded
        if moveSucceeded {
            finalSize = Int64(fileManager.fileSize(at: finalURL) ?? 0)
        }
        
        // === PHASE 4: Main thread - finalize and deliver ===
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Final epoch check
            guard snapshotEpoch == self.epoch else { return }
            
            // Update metadata
            self.metadata.fileURL = moveSucceeded ? finalURL : tmpURL
            self.metadata.fileName = moveSucceeded ? finalURL.lastPathComponent : tmpURL.lastPathComponent
            self.metadata.fileSizeBytes = finalSize ?? evidence.tmpSize
            self.metadata.endedAt = self.clock.now()
            
            // Determine result
            let finalResult: Result<CaptureMetadata, RecordingError>
            if isSuccess && moveSucceeded {
                finalResult = .success(self.metadata)
            } else if !moveSucceeded {
                finalResult = .failure(.finalizeFailed(.moveFailed))
            } else {
                finalResult = .failure(self.mapSystemError(evidence.error))
            }
            
            self.deliverFinish(result: finalResult)
        }
    }
    
    private func mapSystemError(_ error: Error?) -> RecordingError {
        guard let error = error else {
            return .unknownFailure(.systemError)
        }
        
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
            return .unknownFailure(.diskFull)
        }
        
        return .unknownFailure(.systemError)
    }
}

// MARK: - ProcessInfo.ThermalState Extension

extension ProcessInfo.ThermalState {
    var weight: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 2
        }
    }
}

