// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CameraSession.swift
//  progect2
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation
@preconcurrency import AVFoundation
import UIKit
import os.log
import Aether3DCore

// CI-HARDENED: CMTime conversion helper (AVFoundation stays in App/Capture, not Core)
// Single source of truth: uses CaptureRecordingConstants.cmTimePreferredTimescale
private func cmTime(seconds: TimeInterval) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: CaptureRecordingConstants.cmTimePreferredTimescale)
}

protocol CameraSessionProtocol: AnyObject {
    var captureSession: AVCaptureSession { get }
    var selectedConfig: SelectedCaptureConfig? { get }
    
    func configure(orientation: UIInterfaceOrientation) throws
    func configureObjectMode(orientation: UIInterfaceOrientation) throws
    func startRunning()
    func stopRunning()
    func startRecording(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate)
    func startRecordingWithoutGates(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate)
    func stopRecording()
    func reconfigureAfterInterruption(orientation: UIInterfaceOrientation) throws
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

final class CameraSession: CameraSessionProtocol, @unchecked Sendable {
    private enum CaptureProfile {
        case defaultRecording
        case objectModeRecording
    }

    private enum RecordingStartMode {
        case gated
        case ungated
    }

    private struct CachedFormatSelection {
        let width: Int32
        let height: Int32
        let targetFps: Double
        let hdrCapable: Bool
    }

    private static let formatCacheQueue = DispatchQueue(label: "com.aether3d.camera.format-cache")
    nonisolated(unsafe) private static var cachedFormatSelectionByDeviceID: [String: CachedFormatSelection] = [:]
    private let recordingStartRetryDelay: TimeInterval = 0.08
    private let recordingStartRetryAttempts = 18

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
    
    func configure(orientation: UIInterfaceOrientation) throws {
        try sessionQueue.sync {
            try configureInternal(orientation: orientation, profile: .defaultRecording)
        }
    }

    func configureObjectMode(orientation: UIInterfaceOrientation) throws {
        try sessionQueue.sync {
            try configureInternal(orientation: orientation, profile: .objectModeRecording)
        }
    }
    
    private func configureInternal(orientation: UIInterfaceOrientation, profile: CaptureProfile) throws {
        try ensureAuthorizedVideoAccess()
        try configureGraph(orientation: orientation, profile: profile)
    }

    private func ensureAuthorizedVideoAccess() throws {
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
    }

    private func configureGraph(orientation: UIInterfaceOrientation, profile: CaptureProfile) throws {
        
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
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if !isSessionGraphReusable(for: device) {
            try rebuildSessionGraph(for: device)
        }

        switch profile {
        case .defaultRecording:
            if captureSession.canSetSessionPreset(.inputPriority) {
                captureSession.sessionPreset = .inputPriority
            }
            try applyFullQualityFormatSelection(to: device)
        case .objectModeRecording:
            try applyObjectModeRecordingStablePreset(to: device)
        }

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

        // Configure video connection orientation
        if let connection = movieOutput?.connection(with: .video) {
            applyVideoOrientation(connection: connection, orientation: orientation)
        }
        
        try applyFocusAndExposureConfiguration(to: device)
    }

    private func applyFullQualityFormatSelection(to device: AVCaptureDevice) throws {
        let selectedFormat = try selectFormat(device: device)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = selectedFormat.format
        device.activeVideoMinFrameDuration = selectedFormat.frameDuration

        let codec: VideoCodec = selectedFormat.format.isVideoCodecSupported(.hevc) ? .hevc : .h264
        let dimensions = selectedFormat.format.formatDescription.dimensions
        let tier = determineTier(width: Int(dimensions.width), height: Int(dimensions.height))

        selectedConfig = SelectedCaptureConfig(
            dimensions: VideoDimensions(width: Int(dimensions.width), height: Int(dimensions.height)),
            tier: tier,
            frameRate: selectedFormat.targetFps,
            hdrCapable: selectedFormat.format.isVideoHDRSupported,
            isVirtualDevice: device.isVirtualDevice,
            formatScore: selectedFormat.score,
            codec: codec
        )
    }

    private func applyObjectModeRecordingStablePreset(to device: AVCaptureDevice) throws {
        let preset: AVCaptureSession.Preset
        let dimensions: CMVideoDimensions
        let tier: ResolutionTier

        if captureSession.canSetSessionPreset(.hd1920x1080) {
            preset = .hd1920x1080
            dimensions = CMVideoDimensions(width: 1920, height: 1080)
            tier = .t1080p
        } else if captureSession.canSetSessionPreset(.high) {
            preset = .high
            let fallbackDims = device.activeFormat.formatDescription.dimensions
            dimensions = fallbackDims.width > 0 && fallbackDims.height > 0
                ? fallbackDims
                : CMVideoDimensions(width: 1280, height: 720)
            tier = determineTier(width: Int(dimensions.width), height: Int(dimensions.height))
        } else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }

        captureSession.sessionPreset = preset

        let codec: VideoCodec = device.activeFormat.isVideoCodecSupported(.hevc) ? .hevc : .h264
        selectedConfig = SelectedCaptureConfig(
            dimensions: VideoDimensions(width: Int(dimensions.width), height: Int(dimensions.height)),
            tier: tier,
            frameRate: 30.0,
            hdrCapable: false,
            isVirtualDevice: device.isVirtualDevice,
            formatScore: Int64(max(dimensions.width, dimensions.height)),
            codec: codec
        )

        os_log(
            "[ObjectModeV2] recording_safe_preset preset=%{public}@ width=%d height=%d fps=30.00 hdr=false",
            preset.rawValue,
            dimensions.width,
            dimensions.height
        )
    }

    private func applyFocusAndExposureConfiguration(to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    private func isSessionGraphReusable(for device: AVCaptureDevice) -> Bool {
        guard let videoInput else {
            return false
        }

        guard let movieOutput else {
            return false
        }

        let hasInstalledOutput = captureSession.outputs.contains { output in
            output === movieOutput
        }
        guard hasInstalledOutput else {
            return false
        }

        guard videoInput.device.uniqueID == device.uniqueID else {
            return false
        }

        let hasInstalledInput = captureSession.inputs.contains { input in
            (input as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID
        }
        return hasInstalledInput
    }

    private func rebuildSessionGraph(for device: AVCaptureDevice) throws {
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        movieOutput = nil

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        captureSession.addInput(input)
        videoInput = input

        let output = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(output) else {
            throw RecordingError.configurationFailed(.formatSelectionFailed)
        }
        captureSession.addOutput(output)
        output.movieFragmentInterval = .invalid
        movieOutput = output
    }
    
    private struct FormatCandidate {
        let format: AVCaptureDevice.Format
        let frameDuration: CMTime
        let targetFps: Double
        let score: Int64
    }
    
    private func selectFormat(device: AVCaptureDevice) throws -> FormatCandidate {
        if let cachedCandidate = cachedFormatCandidate(for: device) {
            return cachedCandidate
        }

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
        let sortedTiers: [ResolutionTier] = [.t8K, .t4K, .t1080p, .t720p, .lower, .t2K, .t480p]
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
                        let score = calculateFormatScore(format: format, fps: candidateFps)
                        
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
                cacheFormatCandidate(candidate, for: device)
                return candidate
            }
        }
        
        throw RecordingError.configurationFailed(.formatSelectionFailed)
    }

    
    private func validateFormat(device: AVCaptureDevice, candidate: FormatCandidate) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let oldFormat = device.activeFormat
            let oldFrameDuration = device.activeVideoMinFrameDuration

            device.activeFormat = candidate.format
            device.activeVideoMinFrameDuration = candidate.frameDuration

            let isValid =
                device.activeFormat == candidate.format &&
                device.activeVideoMinFrameDuration == candidate.frameDuration

            device.activeFormat = oldFormat
            device.activeVideoMinFrameDuration = oldFrameDuration

            return isValid
        } catch {
            return false
        }
    }

    private func cachedFormatCandidate(for device: AVCaptureDevice) -> FormatCandidate? {
        let cachedSelection = Self.formatCacheQueue.sync {
            Self.cachedFormatSelectionByDeviceID[device.uniqueID]
        }
        guard let cachedSelection else { return nil }

        for format in device.formats {
            let dimensions = format.formatDescription.dimensions
            guard dimensions.width == cachedSelection.width,
                  dimensions.height == cachedSelection.height,
                  format.isVideoHDRSupported == cachedSelection.hdrCapable else {
                continue
            }

            for fpsRange in format.videoSupportedFrameRateRanges {
                if cachedSelection.targetFps >= fpsRange.minFrameRate &&
                    cachedSelection.targetFps <= fpsRange.maxFrameRate {
                    let frameDuration = CMTime(value: 1, timescale: Int32(cachedSelection.targetFps))
                    return FormatCandidate(
                        format: format,
                        frameDuration: frameDuration,
                        targetFps: cachedSelection.targetFps,
                        score: calculateFormatScore(format: format, fps: cachedSelection.targetFps)
                    )
                }
            }
        }

        return nil
    }

    private func cacheFormatCandidate(_ candidate: FormatCandidate, for device: AVCaptureDevice) {
        let dimensions = candidate.format.formatDescription.dimensions
        let cachedSelection = CachedFormatSelection(
            width: dimensions.width,
            height: dimensions.height,
            targetFps: candidate.targetFps,
            hdrCapable: candidate.format.isVideoHDRSupported
        )
        Self.formatCacheQueue.sync {
            Self.cachedFormatSelectionByDeviceID[device.uniqueID] = cachedSelection
        }
    }
    
    private func calculateFormatScore(format: AVCaptureDevice.Format, fps: Double) -> Int64 {
        var score: Int64 = 0
        
        // FPS contribution
        score += Int64(fps) * CaptureRecordingConstants.scoreWeightFps
        
        // Resolution contribution
        let dimensions = format.formatDescription.dimensions
        let maxDimension = max(dimensions.width, dimensions.height)
        score += Int64(maxDimension) / 100 * CaptureRecordingConstants.scoreWeightResolution
        
        // HDR contribution (safe check)
        if format.isVideoHDRSupported {
            score += CaptureRecordingConstants.scoreWeightHDR
        }
        
        // HEVC contribution
        if format.isVideoCodecSupported(.hevc) {
            score += CaptureRecordingConstants.scoreWeightHEVC
        }
        
        // ProRes contribution (iOS 15+ only, safe check)
        // ProRes support is detected via device capability constants
        // (CaptureRecordingConstants.proResCapableModels), not format-level API
        
        // Apple Log contribution (iOS 17.2+ only)
        if #available(iOS 17.2, *) {
            // Apple Log support detection would go here
            // This is a placeholder for future implementation
        }
        
        // Dolby Vision and HDR10+ detection would require additional AVFoundation APIs
        // These are format-specific and may not be directly queryable
        
        return score
    }
    
    private func determineTier(width: Int, height: Int) -> ResolutionTier {
        let maxDim = max(width, height)
        if maxDim >= 7680 {
            return .t8K
        } else if maxDim >= 3840 {
            return .t4K
        } else if maxDim >= 2560 {
            return .t2K      // NEW: Support t2K
        } else if maxDim >= 1920 {
            return .t1080p
        } else if maxDim >= 1280 {
            return .t720p
        } else if maxDim >= 640 {
            return .t480p   // NEW: Support t480p
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

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
    
    func startRecording(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        sessionQueue.async { [weak self] in
            self?.startRecordingWhenReady(
                to: url,
                delegate: delegate,
                mode: .gated,
                remainingAttempts: self?.recordingStartRetryAttempts ?? 0
            )
        }
    }

    func startRecordingWithoutGates(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        sessionQueue.async { [weak self] in
            self?.startRecordingWhenReady(
                to: url,
                delegate: delegate,
                mode: .ungated,
                remainingAttempts: self?.recordingStartRetryAttempts ?? 0
            )
        }
    }
    
    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.movieOutput?.stopRecording()
        }
    }
    
    func reconfigureAfterInterruption(orientation: UIInterfaceOrientation) throws {
        try sessionQueue.sync {
            try reconfigureAfterInterruptionInternal(orientation: orientation)
        }
    }
    
    private func reconfigureAfterInterruptionInternal(orientation: UIInterfaceOrientation) throws {
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
            try configureInternal(orientation: orientation, profile: .defaultRecording)
        }
        
        // Start running if not already
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    private func applyVideoOrientation(connection: AVCaptureConnection, orientation: UIInterfaceOrientation) {
        let angle = rotationAngle(for: orientation)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func startRecordingWhenReady(
        to url: URL,
        delegate: AVCaptureFileOutputRecordingDelegate,
        mode: RecordingStartMode,
        remainingAttempts: Int
    ) {
        guard let output = movieOutput else { return }

        let readiness = recordingReadiness(for: output)
        guard readiness.ready else {
            if remainingAttempts > 0 {
                os_log(
                    "[ObjectModeV2] recording_not_ready running=%{public}@ connection=%{public}@ enabled=%{public}@ active=%{public}@ attempts_left=%d",
                    readiness.isRunning.description,
                    readiness.hasConnection.description,
                    readiness.isEnabled.description,
                    readiness.isActive.description,
                    remainingAttempts
                )
                sessionQueue.asyncAfter(deadline: .now() + recordingStartRetryDelay) { [weak self] in
                    self?.startRecordingWhenReady(
                        to: url,
                        delegate: delegate,
                        mode: mode,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            } else {
                os_log(
                    "[ObjectModeV2] recording_force_start running=%{public}@ connection=%{public}@ enabled=%{public}@ active=%{public}@",
                    readiness.isRunning.description,
                    readiness.hasConnection.description,
                    readiness.isEnabled.description,
                    readiness.isActive.description
                )
                configureRecordingGates(output: output, mode: mode)
                output.startRecording(to: url, recordingDelegate: delegate)
            }
            return
        }

        configureRecordingGates(output: output, mode: mode)
        output.startRecording(to: url, recordingDelegate: delegate)
    }

    private func configureRecordingGates(output: AVCaptureMovieFileOutput, mode: RecordingStartMode) {
        switch mode {
        case .gated:
            output.maxRecordedDuration = cmTime(seconds: CaptureRecordingConstants.maxDurationSeconds)
            output.maxRecordedFileSize = CaptureRecordingConstants.maxBytes

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
        case .ungated:
            output.maxRecordedDuration = .invalid
            output.maxRecordedFileSize = 0
            os_log("[PR4] object_mode_recording_without_gates")
        }
    }

    private func recordingReadiness(for output: AVCaptureMovieFileOutput) -> (ready: Bool, isRunning: Bool, hasConnection: Bool, isEnabled: Bool, isActive: Bool) {
        let isRunning = captureSession.isRunning
        guard let connection = output.connection(with: .video) else {
            return (false, isRunning, false, false, false)
        }

        let isEnabled = connection.isEnabled
        let isActive = connection.isActive
        let ready = isRunning && isEnabled && isActive
        return (ready, isRunning, true, isEnabled, isActive)
    }

    private func rotationAngle(for orientation: UIInterfaceOrientation) -> Double {
        switch orientation {
        case .landscapeLeft:
            return 270
        case .landscapeRight:
            return 90
        case .portraitUpsideDown:
            return 180
        default:
            return 0
        }
    }
}

// MARK: - String Extensions

extension String {
    var fourCharCode: FourCharCode {
        guard count == 4 else { return 0 }
        var result: FourCharCode = 0
        for char in utf16 {
            result = (result << 8) | FourCharCode(char)
        }
        return result
    }
}

// MARK: - AVCaptureDevice.Format Extensions

extension AVCaptureDevice.Format {
    /// Check if a video codec is generally supported for this format.
    /// On iOS 16+ (our minimum target), HEVC and H.264 are universally supported.
    /// ProRes requires specific hardware (detected via device model constants).
    func isVideoCodecSupported(_ codecType: AVVideoCodecType) -> Bool {
        codecType == .hevc || codecType == .h264
    }
}
