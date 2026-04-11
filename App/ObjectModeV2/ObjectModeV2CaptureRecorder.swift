import Foundation

#if canImport(UIKit) && canImport(AVFoundation)
import CoreImage
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
    private let captureQueue = DispatchQueue(label: "com.aether3d.objectmodev2.capture")
    private let previewCaptureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let thumbnailContext = CIContext(options: nil)
    private let visualSignatureWidth = 32
    private let visualSignatureHeight = 32

    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var didStartPreview = false

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var recordingOutputURL: URL?
    private var recordingStartedAt: Date?
    private var recordingStartSampleTimestamp: TimeInterval?
    private var finishErrorMessage: String?
    private var stopContinuation: CheckedContinuation<ObjectModeV2RecordedClip, Error>?
    private var isFinishing = false
    private var latestThumbnailImage: UIImage?
    private var lastThumbnailCaptureAt: CFAbsoluteTime = 0
    private var lastVisualSampleAt: CFAbsoluteTime = 0
    private var hasDeliveredPreviewFrame = false

    private(set) var isPrepared = false
    private(set) var isRecording = false
    var onVisualFrameSample: ((ObjectModeV2VisualFrameSample) -> Void)?
    var onPreviewFirstFrame: (() -> Void)?

    var previewSession: AVCaptureSession {
        previewCaptureSession
    }

    func captureSnapshotImage() -> UIImage? {
        captureQueue.sync {
            latestThumbnailImage
        }
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

                if !self.previewCaptureSession.isRunning {
                    self.previewCaptureSession.startRunning()
                }
                self.didStartPreview = true
                continuation.resume(returning: ())
            }
        }
    }

    func startRecording() throws {
        let readiness = captureQueue.sync { () -> (prepared: Bool, recording: Bool, running: Bool, previewStarted: Bool) in
            (
                prepared: isPrepared,
                recording: isRecording,
                running: previewCaptureSession.isRunning,
                previewStarted: didStartPreview
            )
        }
        guard readiness.prepared else {
            throw ObjectModeV2CaptureRecorderError.notPrepared
        }
        guard !readiness.recording else {
            throw ObjectModeV2CaptureRecorderError.alreadyRecording
        }
        guard readiness.previewStarted, readiness.running else {
            throw ObjectModeV2CaptureRecorderError.recordingFailed("相机仍在启动，请稍候再试。")
        }

        let outputURL = try makeOutputURL()
        captureQueue.sync {
            recordingOutputURL = outputURL
            recordingStartedAt = Date()
            recordingStartSampleTimestamp = nil
            finishErrorMessage = nil
            writer = nil
            writerInput = nil
            stopContinuation = nil
            isFinishing = false
            isRecording = true
        }
    }

    func stopRecording() async throws -> ObjectModeV2RecordedClip {
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
                self.finishWritingIfNeeded()
            }
        }
    }

    func shutdown() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.isPrepared = false
            self.isRecording = false
            self.isFinishing = false
            self.writerInput?.markAsFinished()
            self.writer?.cancelWriting()
            self.writer = nil
            self.writerInput = nil
            self.recordingOutputURL = nil
            self.recordingStartedAt = nil
            self.recordingStartSampleTimestamp = nil
            self.finishErrorMessage = nil
            if let continuation = self.stopContinuation {
                self.stopContinuation = nil
                continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed("录制已取消。"))
            }
            self.latestThumbnailImage = nil
            self.lastThumbnailCaptureAt = 0
            self.lastVisualSampleAt = 0
            self.hasDeliveredPreviewFrame = false
            self.didStartPreview = false
            if self.previewCaptureSession.isRunning {
                self.previewCaptureSession.stopRunning()
            }
        }
    }

    func suspendPreview() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.didStartPreview = false
            self.hasDeliveredPreviewFrame = false
            if self.previewCaptureSession.isRunning {
                self.previewCaptureSession.stopRunning()
            }
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
                    try self.configureGraphIfNeeded()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureGraphIfNeeded() throws {
        guard !isConfigured else { return }

        previewCaptureSession.beginConfiguration()
        defer { previewCaptureSession.commitConfiguration() }

        previewCaptureSession.sessionPreset = .high

        for input in previewCaptureSession.inputs {
            previewCaptureSession.removeInput(input)
        }
        for output in previewCaptureSession.outputs {
            previewCaptureSession.removeOutput(output)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw ObjectModeV2CaptureRecorderError.recordingFailed("找不到可用的后置相机。")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard previewCaptureSession.canAddInput(input) else {
            throw ObjectModeV2CaptureRecorderError.recordingFailed("无法添加相机输入。")
        }
        previewCaptureSession.addInput(input)
        videoInput = input

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard previewCaptureSession.canAddOutput(videoDataOutput) else {
            throw ObjectModeV2CaptureRecorderError.recordingFailed("无法添加视频输出。")
        }
        previewCaptureSession.addOutput(videoDataOutput)
        Self.applyPortraitRotation(to: videoDataOutput.connection(with: .video))

        isConfigured = true
    }

    private func configureWriterIfNeeded(from sampleBuffer: CMSampleBuffer) {
        guard writer == nil else { return }
        guard let outputURL = recordingOutputURL else {
            finishErrorMessage = "录制输出路径不存在。"
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            finishErrorMessage = "无法读取视频格式。"
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height)
        ]

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                finishErrorMessage = "无法添加视频写入输入。"
                return
            }

            writer.add(input)
            self.writer = writer
            self.writerInput = input
        } catch {
            finishErrorMessage = error.localizedDescription
        }
    }

    private func finishWritingIfNeeded() {
        guard !isFinishing else { return }
        isFinishing = true

        guard let continuation = stopContinuation else {
            resetWriterState()
            return
        }

        guard let writer = writer, let writerInput = writerInput else {
            stopContinuation = nil
            let message = finishErrorMessage ?? "没有采集到可用画面。"
            resetWriterState()
            continuation.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed(message))
            return
        }

        writerInput.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.captureQueue.async {
                let continuation = self.stopContinuation
                self.stopContinuation = nil
                let writerStatus = self.writer?.status
                let writerErrorDescription = self.writer?.error?.localizedDescription

                if writerStatus == .completed, let outputURL = self.recordingOutputURL {
                    let end = Date()
                    let duration = self.recordingStartedAt.map { end.timeIntervalSince($0) } ?? 0
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    self.resetWriterState()
                    continuation?.resume(returning: ObjectModeV2RecordedClip(
                        fileURL: outputURL,
                        duration: duration,
                        fileSize: fileSize
                    ))
                } else {
                    let message = writerErrorDescription ?? self.finishErrorMessage ?? "录制写入失败。"
                    self.resetWriterState()
                    continuation?.resume(throwing: ObjectModeV2CaptureRecorderError.recordingFailed(message))
                }
            }
        }
    }

    private func resetWriterState() {
        writer = nil
        writerInput = nil
        recordingOutputURL = nil
        recordingStartedAt = nil
        recordingStartSampleTimestamp = nil
        finishErrorMessage = nil
        isFinishing = false
    }

    private static func applyPortraitRotation(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let portraitRotationAngle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(portraitRotationAngle) {
            connection.videoRotationAngle = portraitRotationAngle
        }
    }

    private func refreshLatestThumbnail(from sampleBuffer: CMSampleBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastThumbnailCaptureAt >= 0.22 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = thumbnailContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            latestThumbnailImage = UIImage(cgImage: cgImage)
            lastThumbnailCaptureAt = now
        }
    }

    private func emitVisualFrameSample(from sampleBuffer: CMSampleBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVisualSampleAt >= 0.16 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let relativeTimestamp: TimeInterval
        if recordingStartedAt != nil {
            if let startTimestamp = recordingStartSampleTimestamp {
                relativeTimestamp = max(0, presentationTimestamp - startTimestamp)
            } else {
                recordingStartSampleTimestamp = presentationTimestamp
                relativeTimestamp = 0
            }
        } else {
            relativeTimestamp = presentationTimestamp
        }
        guard let sample = makeVisualFrameSample(from: pixelBuffer, timestamp: relativeTimestamp) else { return }
        lastVisualSampleAt = now

        guard let onVisualFrameSample else { return }
        DispatchQueue.main.async {
            onVisualFrameSample(sample)
        }
    }

    private func makeVisualFrameSample(
        from pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) -> ObjectModeV2VisualFrameSample? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let signatureWidth = visualSignatureWidth
        let signatureHeight = visualSignatureHeight
        var signature = [UInt8](repeating: 0, count: signatureWidth * signatureHeight)
        var luminanceSum = 0.0

        for row in 0..<signatureHeight {
            let sourceY = min((row * height) / signatureHeight, max(height - 1, 0))
            for column in 0..<signatureWidth {
                let sourceX = min((column * width) / signatureWidth, max(width - 1, 0))
                let pixelOffset = sourceY * bytesPerRow + sourceX * 4
                let blue = Double(buffer[pixelOffset])
                let green = Double(buffer[pixelOffset + 1])
                let red = Double(buffer[pixelOffset + 2])
                let luminance = min(max(Int(round(red * 0.299 + green * 0.587 + blue * 0.114)), 0), 255)
                signature[row * signatureWidth + column] = UInt8(luminance)
                luminanceSum += Double(luminance)
            }
        }

        let pixelCount = Double(signature.count)
        guard pixelCount > 0 else { return nil }
        let meanBrightness = luminanceSum / pixelCount

        var varianceAccumulator = 0.0
        for value in signature {
            let delta = Double(value) - meanBrightness
            varianceAccumulator += delta * delta
        }
        let globalVariance = varianceAccumulator / pixelCount

        var laplacianMean = 0.0
        var laplacianSquaredMean = 0.0
        var laplacianCount = 0.0
        if signatureWidth > 2, signatureHeight > 2 {
            for row in 1..<(signatureHeight - 1) {
                for column in 1..<(signatureWidth - 1) {
                    let center = Double(signature[row * signatureWidth + column])
                    let left = Double(signature[row * signatureWidth + (column - 1)])
                    let right = Double(signature[row * signatureWidth + (column + 1)])
                    let up = Double(signature[(row - 1) * signatureWidth + column])
                    let down = Double(signature[(row + 1) * signatureWidth + column])
                    let laplacian = left + right + up + down - 4.0 * center
                    laplacianMean += laplacian
                    laplacianSquaredMean += laplacian * laplacian
                    laplacianCount += 1
                }
            }
        }

        let laplacianVariance: Double
        if laplacianCount > 0 {
            let mean = laplacianMean / laplacianCount
            laplacianVariance = max(0, laplacianSquaredMean / laplacianCount - mean * mean)
        } else {
            laplacianVariance = 0
        }

        return ObjectModeV2VisualFrameSample(
            timestamp: timestamp,
            signatureWidth: signatureWidth,
            signatureHeight: signatureHeight,
            signature: Data(signature),
            laplacianVariance: laplacianVariance,
            meanBrightness: meanBrightness,
            globalVariance: globalVariance
        )
    }
}

extension ObjectModeV2CaptureRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !hasDeliveredPreviewFrame {
            hasDeliveredPreviewFrame = true
            if let onPreviewFirstFrame {
                DispatchQueue.main.async {
                    onPreviewFirstFrame()
                }
            }
        }
        refreshLatestThumbnail(from: sampleBuffer)
        emitVisualFrameSample(from: sampleBuffer)
        guard isRecording || stopContinuation != nil else { return }

        if isRecording {
            configureWriterIfNeeded(from: sampleBuffer)
            guard finishErrorMessage == nil else {
                isRecording = false
                finishWritingIfNeeded()
                return
            }

            guard let writer = writer, let writerInput = writerInput else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if writer.status == .unknown {
                guard writer.startWriting() else {
                    finishErrorMessage = writer.error?.localizedDescription ?? "无法开始写入视频。"
                    isRecording = false
                    finishWritingIfNeeded()
                    return
                }
                writer.startSession(atSourceTime: presentationTime)
            }

            guard writer.status == .writing else {
                if writer.status == .failed {
                    finishErrorMessage = writer.error?.localizedDescription ?? "视频写入失败。"
                    isRecording = false
                    finishWritingIfNeeded()
                }
                return
            }

            guard writerInput.isReadyForMoreMediaData else { return }
            if !writerInput.append(sampleBuffer) {
                finishErrorMessage = writer.error?.localizedDescription ?? "视频帧写入失败。"
                isRecording = false
                finishWritingIfNeeded()
            }
            return
        }

        if stopContinuation != nil {
            finishWritingIfNeeded()
        }
    }
}

#endif
