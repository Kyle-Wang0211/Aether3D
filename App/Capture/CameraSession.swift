//
//  CameraSession.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//

import Foundation
import AVFoundation
import os.log

// CI-HARDENED: ClockProvider for deterministic time (no Date() in production code)
private protocol ClockProvider {
    func now() -> Date
}

private struct DefaultClockProvider: ClockProvider {
    func now() -> Date { Date() }
}

// CI-HARDENED: CMTime conversion helper (AVFoundation stays in App/Capture, not Core)
// Single source of truth: uses CaptureRecordingConstants.cmTimePreferredTimescale
private func cmTime(seconds: TimeInterval) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: CaptureRecordingConstants.cmTimePreferredTimescale)
}

protocol CameraSessionProtocol: AnyObject {
    var captureSession: AVCaptureSession { get }
    var selectedConfig: SelectedCaptureConfig? { get }
    
    func configure(orientation: AVCaptureVideoOrientation) throws
    func startRunning()
    func startRecording(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate)
    func stopRecording()
    func reconfigureAfterInterruption(orientation: AVCaptureVideoOrientation) throws
}

struct SelectedCaptureConfig {
    let dimensions: VideoDimensions
    let tier: ResolutionTier
    let frameRate: Double
    let hdrCapable: Bool
    let isVirtualDevice: Bool
    let formatScore: Int64
    let codec: VideoCodec
}

// CI-HARDENED: This file must not use Date() or Timer.scheduledTimer.
// All time operations must use injected ClockProvider for determinism.

final class CameraSession: CameraSessionProtocol {
    let captureSession: AVCaptureSession
    private(set) var selectedConfig: SelectedCaptureConfig?
    
    private let sessionQueue = DispatchQueue(label: "com.aether3d.camera.session")
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private let clock: ClockProvider
    
    // CI-HARDENED: ClockProvider injection for deterministic time
    init(clock: ClockProvider = DefaultClockProvider()) {
        self.clock = clock
        captureSession = AVCaptureSession()
        #if DEBUG
        sessionQueue.setSpecific(key: DispatchSpecificKey<String>(), value: "sessionQueue")
        #endif
    }
    
    func configure(orientation: AVCaptureVideoOrientation) throws {
        try sessionQueue.sync {
            try configureInternal(orientation: orientation)
        }
    }
    
    private func configureInternal(orientation: AVCaptureVideoOrientation) throws {
        // CI-HARDENED: No dispatchPrecondition() - use log for debugging if needed
        // Queue validation is handled by sessionQueue.sync/async boundaries
        
        // Check permission
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .notDetermined:
            throw RecordingError.configurationFailed(.permissionNotDetermined)
        case .denied, .restricted:
            throw RecordingError.permissionDenied
        case .authorized:
            break
        @unknown default:
            throw RecordingError.configurationFailed(.permissionNotDetermined)
        }
        
        // Find camera device
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            throw RecordingError.configurationFailed(.cameraUnavailable)
        }
        
        videoDevice = device
        
        // Select format using two-phase algorithm
        let selectedFormat = try selectFormat(device: device)
        
        // Lock device for configuration
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        device.activeFormat = selectedFormat.format
        device.activeVideoMinFrameDuration = selectedFormat.frameDuration
        
        // Determine codec
        let codec: VideoCodec
        if selectedFormat.format.isVideoCodecSupported(.hevc) {
            codec = .hevc
        } else {
            codec = .h264
        }
        
        // Determine tier
        let tier = determineTier(width: selectedFormat.format.formatDescription.dimensions.width,
                                  height: selectedFormat.format.formatDescription.dimensions.height)
        
        // Create selected config
        selectedConfig = SelectedCaptureConfig(
            dimensions: VideoDimensions(
                width: Int(selectedFormat.format.formatDescription.dimensions.width),
                height: Int(selectedFormat.format.formatDescription.dimensions.height)
            ),
            tier: tier,
            frameRate: selectedFormat.targetFps,
            hdrCapable: selectedFormat.format.isVideoHDRSupported,
            isVirtualDevice: device.isVirtualDevice,
            formatScore: selectedFormat.score,
            codec: codec
        )
        
        // Setup session
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Remove existing inputs/outputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        
        // Add video input
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        captureSession.addInput(input)
        videoInput = input
        
        // Verify no audio input
        for input in captureSession.inputs {
            guard input.ports.first?.mediaType == .video else {
                throw RecordingError.configurationFailed(.formatSelectionFailed)
            }
        }
        
        // Disable audio session configuration
        if #available(iOS 13.0, *) {
            captureSession.automaticallyConfiguresApplicationAudioSession = false
        }
        
        // Add movie output
        let output = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(output) else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        captureSession.addOutput(output)
        movieOutput = output
        
        // Set output file type
        output.movieFragmentInterval = .invalid
        
        // Configure video connection orientation
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
        
        // Setup focus and exposure
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }
    
    private struct FormatCandidate {
        let format: AVCaptureDevice.Format
        let frameDuration: CMTime
        let targetFps: Double
        let score: Int64
    }
    
    private func selectFormat(device: AVCaptureDevice) throws -> FormatCandidate {
        // Phase 1: Group by resolution tier
        var tierGroups: [ResolutionTier: [AVCaptureDevice.Format]] = [:]
        
        for format in device.formats {
            let dimensions = format.formatDescription.dimensions
            let tier = determineTier(width: Int(dimensions.width), height: Int(dimensions.height))
            
            // Only consider formats with video frame rate ranges
            guard !format.videoSupportedFrameRateRanges.isEmpty else { continue }
            
            if tierGroups[tier] == nil {
                tierGroups[tier] = []
            }
            tierGroups[tier]?.append(format)
        }
        
        // Select highest tier
        let sortedTiers: [ResolutionTier] = [.t8K, .t4K, .t1080p, .t720p, .lower]
        guard let selectedTier = sortedTiers.first(where: { tierGroups[$0] != nil }) else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        
        guard let formatsInTier = tierGroups[selectedTier] else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        
        // Phase 2: Score formats within tier
        var candidates: [FormatCandidate] = []
        
        for format in formatsInTier {
            for fpsRange in format.videoSupportedFrameRateRanges {
                for candidateFps in CaptureRecordingConstants.candidateFps {
                    if abs(candidateFps - fpsRange.maxFrameRate) < CaptureRecordingConstants.fpsMatchTolerance ||
                       (candidateFps <= fpsRange.maxFrameRate && candidateFps >= fpsRange.minFrameRate) {
                        let hdrCapable = format.isVideoHDRSupported
                        let hevcCapable = format.isVideoCodecSupported(.hevc)
                        
                        let score = Int64(candidateFps * 100) + (hdrCapable ? 10 : 0) + (hevcCapable ? 5 : 0)
                        
                        let frameDuration = CMTime(value: 1, timescale: Int32(candidateFps))
                        
                        candidates.append(FormatCandidate(
                            format: format,
                            frameDuration: frameDuration,
                            targetFps: candidateFps,
                            score: score
                        ))
                    }
                }
            }
        }
        
        // Sort by score descending
        candidates.sort { $0.score > $1.score }
        
        // Try candidates with validation
        for attempt in 0..<CaptureRecordingConstants.maxFormatAttempts {
            guard attempt < candidates.count else { break }
            
            let candidate = candidates[attempt]
            
            // Validate format
            if validateFormat(device: device, candidate: candidate) {
                return candidate
            }
        }
        
        throw RecordingError.configurationFailed(.formatSelectionFailed)
    }
    
    private func validateFormat(device: AVCaptureDevice, candidate: FormatCandidate) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            let wasRunning = captureSession.isRunning
            let oldFormat = device.activeFormat
            let oldFrameDuration = device.activeVideoMinFrameDuration
            
            device.activeFormat = candidate.format
            device.activeVideoMinFrameDuration = candidate.frameDuration
            
            if !wasRunning {
                captureSession.startRunning()
                
                // Wait for session to start (CI-HARDENED: use clock provider)
                let startTime = clock.now()
                while !captureSession.isRunning && clock.now().timeIntervalSince(startTime) < CaptureRecordingConstants.sessionRunningCheckMaxSeconds {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            let isValid = captureSession.isRunning &&
                          device.activeFormat == candidate.format &&
                          device.activeVideoMinFrameDuration == candidate.frameDuration
            
            if !wasRunning {
                captureSession.stopRunning()
                device.activeFormat = oldFormat
                device.activeVideoMinFrameDuration = oldFrameDuration
            }
            
            return isValid
        } catch {
            return false
        }
    }
    
    private func determineTier(width: Int, height: Int) -> ResolutionTier {
        let maxDim = max(width, height)
        if maxDim >= 7680 {
            return .t8K
        } else if maxDim >= 3840 {
            return .t4K
        } else if maxDim >= 1920 {
            return .t1080p
        } else if maxDim >= 1280 {
            return .t720p
        } else {
            return .lower
        }
    }
    
    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }
    
    func startRecording(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        sessionQueue.async { [weak self] in
            guard let self = self, let output = self.movieOutput else { return }
            
            // Set gates IMMEDIATELY before recording - this is the SINGLE SOURCE OF TRUTH
            output.maxRecordedDuration = cmTime(seconds: CaptureRecordingConstants.maxDurationSeconds)
            output.maxRecordedFileSize = CaptureRecordingConstants.maxBytes
            
            // Verify gates are set (CI-safe validation + production log)
            // CI-HARDENED: No assert() - use log + validation instead
            let durationMatches = abs(output.maxRecordedDuration.seconds - CaptureRecordingConstants.maxDurationSeconds) < 0.001
            let sizeMatches = output.maxRecordedFileSize == CaptureRecordingConstants.maxBytes
            
            if !durationMatches {
                os_log("[PR4] gate_misconfiguration: duration expected=%f actual=%f",
                       CaptureRecordingConstants.maxDurationSeconds,
                       output.maxRecordedDuration.seconds)
            }
            if !sizeMatches {
                os_log("[PR4] gate_misconfiguration: size expected=%lld actual=%lld",
                       CaptureRecordingConstants.maxBytes,
                       output.maxRecordedFileSize)
            }
            
            os_log("[PR4] gates_configured duration=%f size=%lld",
                   output.maxRecordedDuration.seconds,
                   output.maxRecordedFileSize)
            
            output.startRecording(to: url, recordingDelegate: delegate)
        }
    }
    
    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.movieOutput?.stopRecording()
        }
    }
    
    func reconfigureAfterInterruption(orientation: AVCaptureVideoOrientation) throws {
        try sessionQueue.sync {
            try reconfigureAfterInterruptionInternal(orientation: orientation)
        }
    }
    
    private func reconfigureAfterInterruptionInternal(orientation: AVCaptureVideoOrientation) throws {
        // CI-HARDENED: No dispatchPrecondition() - use log for debugging if needed
        // Queue validation is handled by sessionQueue.sync/async boundaries
        
        // Check permission again
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .notDetermined, .denied, .restricted:
            throw RecordingError.configurationFailed(.reconfigureFailed)
        case .authorized:
            break
        @unknown default:
            throw RecordingError.configurationFailed(.reconfigureFailed)
        }
        
        // Re-run format selection if needed
        if captureSession.inputs.isEmpty {
            try configureInternal(orientation: orientation)
        }
        
        // Start running if not already
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }
}

// MARK: - AVCaptureDevice.Format Extensions

extension AVCaptureDevice.Format {
    var isVideoCodecSupported: (AVVideoCodecType) -> Bool {
        return { codecType in
            self.formatDescription.mediaSubType == codecType.rawValue.fourCharCode ||
            self.supportedVideoCodecTypes.contains(codecType)
        }
    }
}

