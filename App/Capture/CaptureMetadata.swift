//
//  CaptureMetadata.swift
//  progect2
//
//  Created for PR#4 Capture Recording
//

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

