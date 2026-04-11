import Foundation

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
@preconcurrency import AVFoundation

enum ObjectModeV2CaptureRecorderError: LocalizedError {
    case permissionDenied
    case notPrepared
    case alreadyRecording
    case notRecording
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "请先允许相机权限，再使用对象模式。"
        case .notPrepared:
            return "相机尚未准备好。"
        case .alreadyRecording:
            return "已经在录制中。"
        case .notRecording:
            return "当前没有正在录制的内容。"
        case .recordingFailed(let message):
            return message
        }
    }
}

struct ObjectModeV2RecordedClip: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let fileSize: Int64
}

final class ObjectModeV2CaptureRecorder: NSObject, @unchecked Sendable {
    private let previewReadyMinimumDuration: CFTimeInterval = 0.45
    private let captureQueue = DispatchQueue(label: "com.aether3d.objectmodev2.capture")
    private let cameraSession: CameraSessionProtocol = CameraSession()

    private var didStartPreview = false
    private var recordingOutputURL: URL?
    private var recordingStartedAt: Date?
    private var stopContinuation: CheckedContinuation<ObjectModeV2RecordedClip, Error>?
    private var pendingFinishResult: Result<ObjectModeV2RecordedClip, Error>?
    private var hasDeliveredPreviewFrame = false
    private var hasSignaledPreviewReady = false
    private var previewReadyWorkItem: DispatchWorkItem?
    private var didStartRunningObserver: NSObjectProtocol?

    private(set) var isPrepared = false
    private(set) var isRecording = false
    var onPreviewFirstFrame: (() -> Void)?
    var onPreviewReadyForCapture: (() -> Void)?
    var onRecordingFirstFrame: (() -> Void)?

    override init() {
        super.init()
        didStartRunningObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: cameraSession.captureSession,
            queue: nil
        ) { [weak self] _ in
            self?.handleSessionDidStartRunning()
        }
    }

    deinit {
        if let didStartRunningObserver {
            NotificationCenter.default.removeObserver(didStartRunningObserver)
        }
    }

    var previewSession: AVCaptureSession {
        cameraSession.captureSession
    }

    func prepare() async throws {
        if isPrepared {
            return
        }

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw ObjectModeV2CaptureRecorderError.permissionDenied
            }
        case .denied, .restricted:
            throw ObjectModeV2CaptureRecorderError.permissionDenied
        @unknown default:
            throw ObjectModeV2CaptureRecorderError.permissionDenied
        }

        try await configureIfNeeded()
        isPrepared = true
    }

    func startPreviewIfNeeded() async throws {
        guard isPrepared else {
            throw ObjectModeV2CaptureRecorderError.notPrepared
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed("录制器已释放。"))
                    return
                }

                self.previewReadyWorkItem?.cancel()
                self.previewReadyWorkItem = nil
                self.hasDeliveredPreviewFrame = false
                self.hasSignaledPreviewReady = false
                self.cameraSession.startRunning()
                self.didStartPreview = true
                continuation.resume(returning: ())
            }
        }
    }

    func startRecording() throws {
        let readiness = captureQueue.sync { () -> (prepared: Bool, recording: Bool, previewStarted: Bool, previewReady: Bool) in
            (
                prepared: isPrepared,
                recording: isRecording,
                previewStarted: didStartPreview,
                previewReady: hasSignaledPreviewReady
            )
        }
        guard readiness.prepared else {
            throw ObjectModeV2CaptureRecorderError.notPrepared
        }
        guard !readiness.recording else {
            throw ObjectModeV2CaptureRecorderError.alreadyRecording
        }
        guard readiness.previewStarted, readiness.previewReady else {
            throw ObjectModeV2CaptureRecorderError.recordingFailed("相机仍在启动，请稍候再试。")
        }

        let outputURL = try makeOutputURL()
        captureQueue.sync {
            recordingOutputURL = outputURL
            recordingStartedAt = Date()
            stopContinuation = nil
            pendingFinishResult = nil
            isRecording = true
        }

        cameraSession.startRecording(to: outputURL, delegate: self)
    }

    func stopRecording() async throws -> ObjectModeV2RecordedClip {
        let pendingResult = captureQueue.sync { () -> Result<ObjectModeV2RecordedClip, Error>? in
            guard isRecording || pendingFinishResult != nil else {
                return nil
            }
            if let pendingFinishResult {
                self.pendingFinishResult = nil
                self.isRecording = false
                return pendingFinishResult
            }
            return nil
        }

        if let pendingResult {
            return try pendingResult.get()
        }

        guard isRecording else {
            throw ObjectModeV2CaptureRecorderError.notRecording
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ObjectModeV2RecordedClip, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed("录制器已释放。"))
                    return
                }
                self.stopContinuation = continuation
                self.isRecording = false
                self.cameraSession.stopRecording()
            }
        }
    }

    func shutdown() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.isPrepared = false
            self.isRecording = false
            self.didStartPreview = false
            self.recordingOutputURL = nil
            self.recordingStartedAt = nil
            self.pendingFinishResult = nil
            self.previewReadyWorkItem?.cancel()
            self.previewReadyWorkItem = nil
            if let continuation = self.stopContinuation {
                self.stopContinuation = nil
                continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed("录制已取消。"))
            }
            self.hasDeliveredPreviewFrame = false
            self.hasSignaledPreviewReady = false
            self.cameraSession.stopRunning()
        }
    }

    func suspendPreview() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.didStartPreview = false
            self.previewReadyWorkItem?.cancel()
            self.previewReadyWorkItem = nil
            self.hasDeliveredPreviewFrame = false
            self.hasSignaledPreviewReady = false
            self.cameraSession.stopRunning()
        }
    }

    private func makeOutputURL() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectModeV2Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(UUID().uuidString.lowercased()).mov")
    }

    private func configureIfNeeded() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed("录制器已释放。"))
                    return
                }

                do {
                    try self.cameraSession.configure(orientation: .portrait)
                    continuation.resume(returning: ())
                } catch let error as ObjectModeV2CaptureRecorderError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed(error.localizedDescription))
                }
            }
        }
    }

    private func makeRecordedClip(from outputFileURL: URL) -> Result<ObjectModeV2RecordedClip, Error> {
        let end = Date()
        let duration = recordingStartedAt.map { end.timeIntervalSince($0) } ?? 0
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        guard FileManager.default.fileExists(atPath: outputFileURL.path), fileSize > 0 else {
            return .failure(ObjectModeV2CaptureRecorderError.recordingFailed("录制文件未成功写出。"))
        }

        return .success(
            ObjectModeV2RecordedClip(
                fileURL: outputFileURL,
                duration: duration,
                fileSize: fileSize
            )
        )
    }

    private func handleSessionDidStartRunning() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.didStartPreview else { return }
            guard !self.hasDeliveredPreviewFrame else { return }

            self.hasDeliveredPreviewFrame = true
            if let onPreviewFirstFrame {
                DispatchQueue.main.async {
                    onPreviewFirstFrame()
                }
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.captureQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.didStartPreview, self.hasDeliveredPreviewFrame, !self.hasSignaledPreviewReady else { return }
                    self.hasSignaledPreviewReady = true
                    if let onPreviewReadyForCapture {
                        DispatchQueue.main.async {
                            onPreviewReadyForCapture()
                        }
                    }
                }
            }
            self.previewReadyWorkItem?.cancel()
            self.previewReadyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.previewReadyMinimumDuration, execute: workItem)
        }
    }
}

extension ObjectModeV2CaptureRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.recordingStartedAt == nil {
                self.recordingStartedAt = Date()
            }
            if let onRecordingFirstFrame {
                DispatchQueue.main.async {
                    onRecordingFirstFrame()
                }
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        captureQueue.async { [weak self] in
            guard let self else { return }

            let result: Result<ObjectModeV2RecordedClip, Error>
            if let error {
                result = .failure(
                    ObjectModeV2CaptureRecorderError.recordingFailed(error.localizedDescription)
                )
            } else {
                result = self.makeRecordedClip(from: outputFileURL)
            }

            self.recordingOutputURL = nil
            self.recordingStartedAt = nil

            if let continuation = self.stopContinuation {
                self.stopContinuation = nil
                switch result {
                case .success(let clip):
                    continuation.resume(returning: clip)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            } else {
                self.pendingFinishResult = result
            }
        }
    }
}

#endif
