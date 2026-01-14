//
//  CaptureRecordingConstants.swift
//  Aether3D
//
//  Created for PR#4 Capture Recording
//

import Foundation
import AVFoundation

struct CaptureRecordingConstants {
    // === Duration ===
    static let minDurationSeconds: TimeInterval = 2
    static let maxDurationSeconds: TimeInterval = 900
    static let durationTolerance: TimeInterval = 0.25
    static let preferredTimescale: CMTimeScale = 600
    
    // === Size ===
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024 * 1024  // 2 TiB
    
    // === Polling ===
    static let fileSizePollStartDelaySeconds: TimeInterval = 1.0
    static let fileSizePollMaxWaitSeconds: TimeInterval = 5.0
    static let fileSizePollIntervalLargeFile: TimeInterval = 0.5  // >= 100MB
    static let fileSizePollIntervalSmallFile: TimeInterval = 1.0  // < 100MB
    static let fileSizeLargeThresholdBytes: Int64 = 100 * 1024 * 1024
    
    // === Thermal ===
    static let thermalWeightSerious: Int = 2  // weight >= this triggers stop/refuse
    // Note: @unknown default is detected via ThermalStateProvider.isCurrentStateUnknown, not weight
    
    // === Storage ===
    static let minFreeSpaceBytesBase: Int64 = 1024 * 1024 * 1024  // 1 GB
    static let minFreeSpaceSecondsBuffer: TimeInterval = 10
    
    // === Bitrate Estimation (bps) by tier+fps ===
    static let bitrateEstimates: [String: Int64] = [
        "4K_60": 100_000_000,   // 100 Mbps
        "4K_30": 60_000_000,    // 60 Mbps
        "1080p_60": 40_000_000, // 40 Mbps
        "1080p_30": 25_000_000, // 25 Mbps
        "720p_30": 15_000_000,  // 15 Mbps
        "default": 50_000_000   // fallback
    ]
    
    // Bitrate key mapping: tier + normalized fps → lookup key
    // fps normalization: >= 45 → 60, < 45 → 30 (conservative)
    static func bitrateKey(tier: ResolutionTier, fps: Double) -> String {
        let normalizedFps: Int
        if fps >= 45 {
            normalizedFps = 60
        } else {
            normalizedFps = 30
        }
        
        let tierPrefix: String
        switch tier {
        case .t8K, .t4K: tierPrefix = "4K"
        case .t1080p: tierPrefix = "1080p"
        case .t720p: tierPrefix = "720p"
        case .lower: tierPrefix = "720p"  // conservative: use 720p rates for lower
        }
        
        let key = "\(tierPrefix)_\(normalizedFps)"
        return bitrateEstimates[key] != nil ? key : "default"
    }
    
    static func estimatedBitrate(tier: ResolutionTier, fps: Double) -> Int64 {
        let key = bitrateKey(tier: tier, fps: fps)
        return bitrateEstimates[key] ?? bitrateEstimates["default"]!
    }
    
    // === Timeouts ===
    static let finalizeTimeoutSeconds: TimeInterval = 10
    // assetCheckTimeoutSeconds: Budget time for asset checks in Phase 1
    // If exceeded, skip remaining checks (tracks/isPlayable) and proceed with fileExists/duration only
    // HARD CONSTRAINT FOR AI/CURSOR:
    // - This is a SOFT BUDGET, NOT a hard timeout
    // - MUST NOT introduce async loading (loadValuesAsynchronously)
    // - MUST NOT use DispatchSemaphore or blocking waits
    // - If budget exceeded, skip remaining checks IMMEDIATELY
    // This design prioritizes determinism over completeness
    static let assetCheckTimeoutSeconds: TimeInterval = 2.0
    static let reconfigureDelaySeconds: TimeInterval = 0.5
    static let reconfigureDebounceSeconds: TimeInterval = 3.0  // reduced from 10s for better UX
    
    // === Format Selection ===
    static let candidateFps: [Double] = [120, 100, 60, 59.94, 50, 30, 29.97, 25, 24]
    static let fpsMatchTolerance: Double = 0.5  // |actual - target| < tolerance → match
    static let maxFormatAttempts: Int = 5
    static let formatWarmupDelaySeconds: TimeInterval = 0.3
    static let sessionRunningCheckMaxSeconds: TimeInterval = 1.0
    
    // === File Naming ===
    static let maxFileNameLength: Int = 120
    static let maxFilenameCollisionRetries: Int = 3  // prevent infinite loop
    static let timestampFormat: String = "yyyyMMdd'T'HHmmss'Z'"
    static let timestampLocale: String = "en_US_POSIX"
    static let uuidStyle: String = "lowercase_no_hyphens"  // 32 chars
    
    // === Cleanup ===
    static let orphanTmpMaxAgeSeconds: TimeInterval = 12 * 60 * 60  // 12 hours (faster cleanup)
    static let maxRetainedFailureFiles: Int = 20
    static let maxRetainedFailureBytesTotal: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB (mobile storage is precious)
    
    // === Update Frequency ===
    static let recordingUpdateIntervalSeconds: TimeInterval = 1.0
    
    // === Platform ===
    static let thermalPlatform: String = "ios"
}

