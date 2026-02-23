// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CaptureMetadata.swift
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
import AVFoundation

// MARK: - Error Types

enum RecordingError: Error, Equatable {
    case permissionDenied
    case configurationFailed(ConfigFailCode)
    case alreadyRecording
    case tooShort(min: Double, actual: Double)
    case fileTooLarge(maxBytes: Int64, actualBytes: Int64)
    case thermalNotAllowed(stateWeight: Int)
    case interrupted(InterruptionReasonCode)
    case insufficientStorage(required: Int64, available: Int64)
    case finalizeFailed(FinalizeFailCode)
    case unknownFailure(UnknownFailCode)
}

enum ConfigFailCode: String, Codable {
    case cameraUnavailable
    case formatSelectionFailed
    case sessionStartFailed
    case outputDirectoryFailed
    case reconfigureFailed
    case permissionNotDetermined
}

enum FinalizeFailCode: String, Codable {
    case timeout
    case fileMissing
    case moveFailed
    case unknown
    case destinationUnavailable
}

enum UnknownFailCode: String, Codable {
    case finishWithoutStart
    case systemError
    case diskFull
}

enum InterruptionReasonCode: String, Codable {
    case cameraInUseByOtherApp
    case multitaskingNotSupported
    case audioConflict
    case unknown
    
    var isRecoverable: Bool {
        // All interruption reasons are recoverable in PR#4
        return true
    }
}

enum StopReason: String, Codable {
    case userStopped
    case maxDurationReached
    case maxSizeReached
    case thermalLimitReached
    case interrupted
}

enum FormatFallbackReason: String, Codable {
    case sessionStartFailed
    case formatSelectionFailed
}

enum DurationSource: String, Codable {
    case asset
    case wallclock
}

// ResolutionTier is now defined in Core/Constants/ResolutionTier.swift
// Import via Aether3DCore module (or Foundation if in same module)

enum WarningCode: String, Codable {
    // Device/Thermal Warnings
    case thermalStateFair
    case thermalStateUnknown
    case lowPowerModeOn
    
    // Format/Codec Warnings
    case formatFallback
    case codecFallbackH264
    
    // File System Warnings
    case diskSpaceUnknown
    case fileSizePollDelayed
    case fileSizeReadFailed
    case filenameCollision
    case cleanupFailed
    case moveFailed
    case backupExcludeFailed
    case fileProtectionFailed
    
    // Recording Flow Warnings
    case durationSourceWallclock
    case multipleInterruptions
    case reconfigureAfterInterruption
    case startCallbackAfterFinish
    case staleFinishCallback
    
    // Video Verification Warnings
    case audioTrackDetected
    case playableCheckFalse
    
    // NEW: Quality Warnings
    case bitrateBelow3DMinimum    // Bitrate < 50 Mbps
    case resolutionBelow4K        // Not 4K+ tier
    case fpsBelow30               // < 30 FPS
    case noHDRAvailable           // HDR not available/enabled
    
    // NEW: Thermal Warnings
    case thermalQualityReduced    // Quality reduced due to thermal
    case thermalFpsReduced        // FPS reduced due to thermal
    
    // NEW: Storage Warnings
    case storageLow5GB            // < 5GB remaining
    case storageCritical1GB       // < 1GB remaining
    case estimatedRecordingTruncated  // May hit storage limit before duration
    
    // NEW: Device Capability Warnings
    case proResUnavailable        // Device doesn't support ProRes
    case appleLogUnavailable      // Device doesn't support Apple Log
    case hdr10PlusUnavailable     // Device doesn't support HDR10+
    
    // NEW: Focus/Exposure Warnings
    case continuousFocusHunting   // Focus instability detected
    case exposureFluctuating      // Exposure changes frequently
    case motionBlurDetected       // Motion blur in frames
}

// MARK: - v4.2 Types

enum VideoCodec: String, Codable {
    case hevc
    case h264
    case unknown
}

enum DiagnosticEventCode: String, Codable {
    case startRequested
    case sessionConfigured
    case formatSelected
    case recordingDidStart
    case stopRequested
    case didFinishArrived
    case fileMissingAtFinish
    case assetChecksSkippedBudget
    case moveAttempted
    case moveSucceeded
    case copyFallbackUsed
    case evidencePreservedOnTimeout
    case finalizeDelivered
    case staleFinishDiscardedEpoch
    case staleFinishDiscardedURL
    case duplicateFinishIgnored
    
    // NEW: Thermal response events
    case thermalWarningTriggered
    case thermalQualityReduced
    case thermalFpsReduced
    case thermalRecordingStopped
    
    // NEW: Storage events
    case storageLowWarning
    case storageCriticalWarning
    case storageEstimatedTruncation
    
    // NEW: Quality events
    case qualityPresetApplied
    case qualityFallbackTriggered
    case proResActivated
    case proResUnavailable
}

// MARK: - v4.3 Types

enum FinishDeliveryWinner: String, Codable {
    case didFinish
    case finalizeTimeout
}

enum DiagnosticNote: Codable, Equatable {
    case tierFpsCodec(tier: ResolutionTier, fps: Int, codec: VideoCodec)
    case elapsedSeconds(Int)
    case reasonCode(String)  // Closed set: "diskFull", "systemError", "finishWithoutStart", "unknown"
    case winner(FinishDeliveryWinner)
    case destUnavailable
}

struct DiagnosticEvent: Codable, Equatable {
    let code: DiagnosticEventCode
    let at: Date
    let note: DiagnosticNote?
}

// MARK: - Supporting Types

struct VideoDimensions: Codable, Equatable {
    let width: Int
    let height: Int
    var maxDimension: Int { max(width, height) }
}

// MARK: - v4.1 Types

struct CaptureCapabilitySnapshot: Codable, Equatable {
    let resolutionTier: ResolutionTier
    let width: Int
    let height: Int
    let fps: Double
    let isHDR: Bool
    let codec: VideoCodec
}

enum StopTriggerSource: String, Codable {
    case user
    case durationLimit
    case sizeLimit
    case thermal
    case interruption
    case error
    case unknown
}

enum AudioPolicy: String, Codable {
    case ignored
    case expected
    case required
}

// MARK: - CaptureMetadata

struct CaptureMetadata: Codable, Equatable {
    // Schema
    let schemaVersion: Int = 1
    
    // Identity
    var recordingId: UUID
    var epoch: Int
    
    // Timing
    var requestedAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var assetDurationSeconds: Double?
    var wallclockDurationSeconds: Double?
    var rawDurationSeconds: Double?
    var durationSeconds: Double?
    var durationSource: DurationSource?
    
    // Output
    var fileURL: URL?
    var fileName: String?
    var fileSizeBytes: Int64?
    
    // Device
    var deviceModel: String
    var osVersion: String
    var appVersion: String
    var devicePosition: String = "back"
    var isVirtualDevice: Bool = false
    
    // Capture Config
    var videoDimensions: VideoDimensions?
    var resolutionTier: ResolutionTier?
    var targetFrameRate: Double?
    var actualFrameRate: Double?
    var codecPreference: String = "hevc"
    var hdrCapable: Bool = false
    var container: String = "mov"
    var estimatedBitrateBps: Int64?
    
    // Format Selection
    var formatScore: Int64?
    var formatFallbackReason: FormatFallbackReason?
    
    // Thermal
    var thermalPreflightWeight: Int
    var thermalStartWeight: Int?
    var thermalMaxWeight: Int
    var thermalPlatform: String
    var thermalStateWasUnknown: Bool = false
    
    // Interruption
    var wasInterrupted: Bool = false
    var interruptionReason: InterruptionReasonCode?
    
    // Stop
    var stopReason: StopReason?
    
    // Warnings
    var warnings: [WarningCode] = []
    
    // Constraint Audit
    var maxBytesConfigured: Int64
    var maxDurationConfigured: TimeInterval
    
    // v4.1 Fields
    var capabilitySnapshot: CaptureCapabilitySnapshot?
    var stopTriggerSource: StopTriggerSource?
    var audioPolicy: AudioPolicy = .ignored
    var buildVersion: String
    
    // v4.2 Fields
    var diagnostics: [DiagnosticEvent] = []
    var stopRequestedAt: Date?
    
    // v4.3 Fields
    var finishDeliveredBy: FinishDeliveryWinner?
    
    // MARK: - v4.3 Methods
    
    mutating func addDiagnostic(code: DiagnosticEventCode, at: Date, note: DiagnosticNote?) {
        // Check for existing event with same code
        if let existingIndex = diagnostics.firstIndex(where: { $0.code == code }) {
            // Exception: finalizeDelivered and duplicateFinishIgnored can update note
            if code == .finalizeDelivered || code == .duplicateFinishIgnored {
                // Update note only, keep original at and position
                diagnostics[existingIndex] = DiagnosticEvent(
                    code: code,
                    at: diagnostics[existingIndex].at,
                    note: note
                )
            }
            // Default: keep first occurrence, do nothing
            return
        }
        
        // Add new event
        var newList = diagnostics
        newList.append(DiagnosticEvent(code: code, at: at, note: note))
        
        // Enforce max 24 events (FIFO)
        if newList.count > 24 {
            newList.removeFirst(newList.count - 24)
        }
        
        diagnostics = newList
    }
}

