// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VideoWriterObserver.swift
// Aether3D
//
// Writes an ARKit-sourced .mov file. Replaces the writer code that used
// to live inside `ObjectModeV2ARCaptureCoordinator.handle(_:)` — that
// method mixed pose extraction + video writing + analyzer stubs in the
// same function, which made both lifecycle bugs and dependency sprawl
// easy. Now the writer is a self-contained observer.
//
// LIFECYCLE
// ─────────
// `startRecording()` is called externally (typically by the ViewModel
// when the user taps the red button). It configures the AVAssetWriter
// and flips an internal `isActive` flag. After that, every frame
// delivered via `receive(_:session:)` is appended to the writer on
// `writerQueue` — the actor hop releases immediately so we don't block
// the session broadcast.
//
// `stopRecording()` finalizes the file and returns the
// `ObjectModeV2RecordedClip` value the rest of the app expects.

import Foundation

#if canImport(AVFoundation) && canImport(ARKit)
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

public struct CapturedClip: Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let fileSize: Int64
    public let frameCount: Int
}

public enum VideoWriterObserverError: Error, LocalizedError {
    case notStarted
    case alreadyStarted
    case writerSetupFailed(String)
    case finalizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "当前未在录制。"
        case .alreadyStarted: return "已经在录制中。"
        case .writerSetupFailed(let m): return "视频写入初始化失败: \(m)"
        case .finalizationFailed(let m): return "视频收尾失败: \(m)"
        }
    }
}

public final class VideoWriterObserver: CaptureFrameObserver, @unchecked Sendable {

    public let observerID: String = "VideoWriter"

    /// Every frame. Dropping any frame during a recording is visible to
    /// the user as a stutter and compromises downstream reconstruction.
    public let preferredInterval: TimeInterval = 0

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let codec: AVVideoCodecType
        public let width: Int
        public let height: Int
        public let preferredPixelFormat: OSType
        public let outputDirectory: URL

        public init(
            codec: AVVideoCodecType = .h264,
            width: Int = 1920,
            height: Int = 1440,
            preferredPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            outputDirectory: URL
        ) {
            self.codec = codec
            self.width = width
            self.height = height
            self.preferredPixelFormat = preferredPixelFormat
            self.outputDirectory = outputDirectory
        }

        public static func defaultObjectModeV2() -> Configuration {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return Configuration(outputDirectory: docs.appendingPathComponent("ObjectModeV2Captures", isDirectory: true))
        }
    }

    // MARK: - State (all guarded by writerQueue)

    private let writerQueue = DispatchQueue(label: "com.aether3d.capture.videowriter", qos: .userInitiated)
    private let configuration: Configuration

    /// All the mutable fields live on `writerQueue`. We use
    /// `nonisolated(unsafe)` to express that the compiler should NOT
    /// enforce actor isolation here — the queue does the work.
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var writerInput: AVAssetWriterInput?
    nonisolated(unsafe) private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var startPTS: CMTime?
    nonisolated(unsafe) private var frameCount: Int = 0
    nonisolated(unsafe) private var outputURL: URL?
    nonisolated(unsafe) private var _isActive: Bool = false
    nonisolated(unsafe) private var _recordingStartTimestamp: TimeInterval = 0

    public init(configuration: Configuration = .defaultObjectModeV2()) {
        self.configuration = configuration
    }

    // MARK: - External control

    /// Call when the user taps record. Returns the URL the writer will
    /// produce on successful stop (so the caller can pre-emptively
    /// attach it to a record id).
    public func startRecording() throws -> URL {
        var thrown: Error?
        var resultURL: URL?
        writerQueue.sync {
            guard !_isActive else {
                thrown = VideoWriterObserverError.alreadyStarted
                return
            }
            do {
                try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
            } catch {
                thrown = VideoWriterObserverError.writerSetupFailed(error.localizedDescription)
                return
            }
            let url = configuration.outputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).mov")
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: configuration.codec,
                    AVVideoWidthKey: configuration.width,
                    AVVideoHeightKey: configuration.height
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                input.expectsMediaDataInRealTime = true
                w.add(input)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: configuration.preferredPixelFormat,
                        kCVPixelBufferWidthKey as String: configuration.width,
                        kCVPixelBufferHeightKey as String: configuration.height
                    ]
                )
                guard w.startWriting() else {
                    let reason = w.error?.localizedDescription ?? "未知"
                    thrown = VideoWriterObserverError.writerSetupFailed(reason)
                    return
                }
                w.startSession(atSourceTime: .zero)
                writer = w
                writerInput = input
                writerAdaptor = adaptor
                startPTS = nil
                frameCount = 0
                outputURL = url
                _isActive = true
                _recordingStartTimestamp = CACurrentMediaTime()
                resultURL = url
            } catch {
                thrown = VideoWriterObserverError.writerSetupFailed(error.localizedDescription)
            }
        }
        if let error = thrown { throw error }
        guard let url = resultURL else {
            throw VideoWriterObserverError.writerSetupFailed("未知路径错误")
        }
        return url
    }

    /// Finalize the file. Returns the clip descriptor on success.
    public func stopRecording() async throws -> CapturedClip {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedClip, Error>) in
            writerQueue.async { [self] in
                guard _isActive, let w = writer, let input = writerInput, let url = outputURL else {
                    cont.resume(throwing: VideoWriterObserverError.notStarted)
                    return
                }
                _isActive = false
                input.markAsFinished()
                w.finishWriting { [self] in
                    writerQueue.async { [self] in
                        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        let frames = frameCount
                        let duration = Double(frames) / 30.0
                        // Clear state before returning so a subsequent
                        // startRecording() lands on a clean slate.
                        writer = nil
                        writerInput = nil
                        writerAdaptor = nil
                        startPTS = nil
                        frameCount = 0
                        outputURL = nil
                        cont.resume(returning: CapturedClip(
                            fileURL: url,
                            duration: duration,
                            fileSize: size,
                            frameCount: frames
                        ))
                    }
                }
            }
        }
    }

    public var isActive: Bool {
        writerQueue.sync { _isActive }
    }

    public var currentRecordingDuration: TimeInterval {
        writerQueue.sync {
            guard _isActive else { return 0 }
            return CACurrentMediaTime() - _recordingStartTimestamp
        }
    }

    // MARK: - CaptureFrameObserver

    public func receive(_ frame: CaptureFrame, session: CaptureSession) async {
        // Hop off the actor fast. The pixel buffer is refcounted; it stays
        // valid for the duration of the closure because we capture `frame`
        // which retains it.
        guard let pixelBuffer = frame.pixelBuffer else { return }
        let timestamp = frame.timestamp
        writerQueue.async { [self] in
            guard _isActive,
                  let adaptor = writerAdaptor,
                  adaptor.assetWriterInput.isReadyForMoreMediaData else {
                return
            }
            let now = CMTime(seconds: timestamp, preferredTimescale: 600)
            if startPTS == nil {
                startPTS = now
            }
            let pts = CMTimeSubtract(now, startPTS ?? now)
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                frameCount += 1
            }
        }
    }

    public func sessionWillStop(_ session: CaptureSession) async {
        // If the outer session stops while we're still recording (e.g.
        // user backgrounded the app mid-capture), finalize silently so
        // the partial .mov is at least playable.
        if isActive {
            _ = try? await stopRecording()
        }
    }
}

#endif
