//
//  CaptureRecordingConstants.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation

// CI-HARDENED: Core must compile on non-Apple platforms. No AVFoundation imports allowed.

public struct CaptureRecordingConstants {
    // === Duration ===
    /// Minimum recording duration in seconds
    public static let minDurationSeconds: TimeInterval = 2.0
    /// Maximum recording duration in seconds
    public static let maxDurationSeconds: TimeInterval = 900.0
    /// Duration validation tolerance in seconds (tighter for precision)
    public static let durationTolerance: TimeInterval = 0.1  // Reduced from 0.25 for tighter validation
    
    // === Duration Thresholds ===
    /// Minimum recommended duration for 3D reconstruction (seconds)
    /// Short recordings may lack sufficient frames for 3D reconstruction
    public static let minRecommendedDuration3D: TimeInterval = 15.0
    /// Optimal duration for object scanning (seconds)
    public static let optimalDuration3D: TimeInterval = 60.0
    /// Maximum recommended duration for 3D reconstruction (seconds)
    /// Beyond this, diminishing returns
    public static let maxRecommendedDuration3D: TimeInterval = 300.0
    // CMTime timescale for AVFoundation conversion (used in App/Capture only)
    // Single source of truth - must be referenced, never hardcoded as 600
    public static let cmTimePreferredTimescale: Int32 = 600
    
    // === Size ===
    public static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024 * 1024  // 2 TiB
    
    // === Polling ===
    /// Initial delay before starting file size polling (seconds)
    public static let fileSizePollStartDelaySeconds: TimeInterval = 0.5  // Faster initial response
    /// Maximum wait time for file size polling (seconds)
    public static let fileSizePollMaxWaitSeconds: TimeInterval = 3.0     // Reduced for responsiveness
    /// Polling interval for large files (seconds)
    public static let fileSizePollIntervalLargeFile: TimeInterval = 0.35  // More frequent for large files
    /// Polling interval for small files (seconds)
    public static let fileSizePollIntervalSmallFile: TimeInterval = 0.75  // Balanced for battery
    /// Threshold for large file classification (bytes)
    public static let fileSizeLargeThresholdBytes: Int64 = 50 * 1024 * 1024  // 50MB threshold (down from 100MB)
    
    // === Adaptive Polling Tiers ===
    /// File size tier thresholds for adaptive polling
    public static let fileSizeTierSmall: Int64 = 10 * 1024 * 1024      // < 10MB
    public static let fileSizeTierMedium: Int64 = 50 * 1024 * 1024     // 10-50MB
    public static let fileSizeTierLarge: Int64 = 200 * 1024 * 1024     // 50-200MB
    public static let fileSizeTierVeryLarge: Int64 = 500 * 1024 * 1024 // 200-500MB
    
    /// Polling intervals for each tier
    public static let fileSizePollIntervalTierSmall: TimeInterval = 1.0
    public static let fileSizePollIntervalTierMedium: TimeInterval = 0.5
    public static let fileSizePollIntervalTierLarge: TimeInterval = 0.35
    public static let fileSizePollIntervalTierVeryLarge: TimeInterval = 0.1
    
    // === Low Power Mode Polling ===
    /// Polling intervals for low power mode
    public static let fileSizePollIntervalSmallFileLowPower: TimeInterval = 1.5
    public static let fileSizePollIntervalLargeFileLowPower: TimeInterval = 1.0
    
    // === Thermal ===
    /// Thermal state weights (0=nominal, 1=fair, 2=serious, 3=critical)
    static let thermalWeightNominal: Int = 0
    static let thermalWeightFair: Int = 1
    static let thermalWeightSerious: Int = 2
    static let thermalWeightCritical: Int = 3
    
    /// Thresholds for thermal actions
    static let thermalWeightWarnUser: Int = 1      // Show warning at fair
    static let thermalWeightReduceQuality: Int = 2  // Reduce bitrate/FPS at serious
    static let thermalWeightStopRecording: Int = 3  // Force stop at critical
    
    /// Quality reduction factors at thermal states
    static let thermalBitrateFactorFair: Double = 1.0       // No reduction
    static let thermalBitrateFactorSerious: Double = 0.75  // 25% reduction
    static let thermalFpsFactorSerious: Double = 0.5        // Drop to half FPS (60→30, 30→24)
    
    // Note: @unknown default is detected via ThermalStateProvider.isCurrentStateUnknown, not weight
    
    // === Storage ===
    /// Base minimum free space (always reserved) in bytes
    static let minFreeSpaceBytesBase: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB (up from 1GB)
    
    /// Buffer for recording continuation (seconds)
    static let minFreeSpaceSecondsBuffer: TimeInterval = 30  // 30 seconds buffer (up from 10)
    
    /// Warning thresholds for storage
    static let lowStorageWarningBytes: Int64 = 5 * 1024 * 1024 * 1024  // Warn at 5GB remaining
    static let criticalStorageBytes: Int64 = 1 * 1024 * 1024 * 1024    // Critical at 1GB remaining
    
    /// ProRes storage requirements (per minute, 4K60)
    static let proRes422HQBytesPerMinute4K60: Int64 = 2_475_000_000  // ~2.3GB/min
    static let hevcBytesPerMinute4K60Estimate: Int64 = 900_000_000   // ~850MB/min at 120Mbps
    
    // === Bitrate Estimation (bps) by tier+fps ===
    // 3D Reconstruction requires high detail preservation:
    // - Minimum 50 Mbps for any 4K content (industry standard for photogrammetry)
    // - 8K support for future iPhone 17+ models
    // - ProRes awareness (220+ Mbps sustained write for 4K60 ProRes)
    static let bitrateEstimates: [String: Int64] = [
        // 8K tier (future-proofing for iPhone 17+ / external cameras)
        "8K_60": 400_000_000,   // 400 Mbps (ProRes 422 HQ @ 8K30 = 330 Mbps, estimate 8K60)
        "8K_30": 200_000_000,   // 200 Mbps
        
        // 4K tier (current flagship tier)
        "4K_120": 200_000_000,  // 200 Mbps (iPhone 15 Pro+ supports 4K120 in HEVC)
        "4K_60": 120_000_000,   // 120 Mbps (up from 100, aligns with Apple ProRes Proxy 4K60)
        "4K_30": 75_000_000,    // 75 Mbps (up from 60, ensures detail for photogrammetry)
        
        // 1080p tier
        "1080p_120": 80_000_000,  // 80 Mbps (high-speed capture)
        "1080p_60": 50_000_000,   // 50 Mbps (up from 40)
        "1080p_30": 30_000_000,   // 30 Mbps (up from 25)
        
        // 720p tier (legacy/low-power fallback)
        "720p_60": 25_000_000,    // 25 Mbps
        "720p_30": 18_000_000,    // 18 Mbps (up from 15)
        
        // Fallback (conservative, assumes 4K30 minimum quality)
        "default": 75_000_000     // 75 Mbps (up from 50)
    ]
    
    /// Minimum bitrate (bits per second) for acceptable 3D reconstruction quality.
    /// Below this threshold, texture detail degrades significantly.
    /// - Note: Based on photogrammetry industry standards (50 Mbps minimum for 4K content).
    /// - SeeAlso: `bitrateEstimates` for tier-specific recommendations.
    public static let minBitrateFor3DReconstruction: Int64 = 50_000_000  // 50 Mbps
    
    // Bitrate key mapping: tier + normalized fps → lookup key
    // fps normalization: >= 90 → 120, >= 45 → 60, < 45 → 30
    static func bitrateKey(tier: ResolutionTier, fps: Double) -> String {
        let normalizedFps: Int
        if fps >= 90 {
            normalizedFps = 120  // Support 120fps tier
        } else if fps >= 45 {
            normalizedFps = 60
        } else {
            normalizedFps = 30
        }
        
        let tierPrefix: String
        switch tier {
        case .t8K: tierPrefix = "8K"      // FIX: Correctly map t8K to "8K"
        case .t4K: tierPrefix = "4K"
        case .t2K: tierPrefix = "2K"      // NEW: Add t2K support
        case .t1080p: tierPrefix = "1080p"
        case .t720p: tierPrefix = "720p"
        case .t480p: tierPrefix = "480p"  // NEW: Add t480p support
        case .lower: tierPrefix = "480p"  // Conservative fallback
        }
        
        let key = "\(tierPrefix)_\(normalizedFps)"
        return bitrateEstimates[key] != nil ? key : "default"
    }
    
    public static func estimatedBitrate(tier: ResolutionTier, fps: Double) -> Int64 {
        let key = bitrateKey(tier: tier, fps: fps)
        return bitrateEstimates[key] ?? bitrateEstimates["default"]!
    }
    
    // === Timeouts ===
    /// Timeout for finalization operations (seconds)
    static let finalizeTimeoutSeconds: TimeInterval = 15.0  // Increased for large files
    // assetCheckTimeoutSeconds: Budget time for asset checks in Phase 1
    // If exceeded, skip remaining checks (tracks/isPlayable) and proceed with fileExists/duration only
    // HARD CONSTRAINT FOR AI/CURSOR:
    // - This is a SOFT BUDGET, NOT a hard timeout
    // - MUST NOT introduce async loading (loadValuesAsynchronously)
    // - MUST NOT use DispatchSemaphore or blocking waits
    // - If budget exceeded, skip remaining checks IMMEDIATELY
    // This design prioritizes determinism over completeness
    static let assetCheckTimeoutSeconds: TimeInterval = 1.5 // Reduced budget, skip faster
    static let reconfigureDelaySeconds: TimeInterval = 0.3  // Faster reconfigure
    static let reconfigureDebounceSeconds: TimeInterval = 2.0  // Reduced from 3.0
    
    /// Additional timeouts
    static let sessionStartTimeoutSeconds: TimeInterval = 5.0  // Max wait for session.startRunning()
    static let deviceLockTimeoutSeconds: TimeInterval = 2.0    // Max wait for lockForConfiguration()
    static let formatValidationTimeoutSeconds: TimeInterval = 3.0  // Max for format validation loop
    
    // === Format Selection ===
    /// Complete FPS candidate list (sorted descending for priority)
    /// Includes all standard broadcast + cinematic rates
    static let candidateFps: [Double] = [
        240,    // iPhone 15 Pro+ slo-mo (1080p only)
        120,    // iPhone 15 Pro 4K120 HEVC
        100,    // PAL high-speed
        60,     // Standard high-speed
        59.94,  // NTSC drop-frame
        50,     // PAL standard
        48,     // Cinema 2x (for 24fps post)
        30,     // Standard (NTSC)
        29.97,  // NTSC drop-frame
        25,     // PAL standard
        24,     // Cinema
        23.976  // NTSC cinema (3:2 pulldown source)
    ]
    /// FPS matching tolerance (allows 59.94↔60 and 29.97↔30)
    static let fpsMatchTolerance: Double = 0.1  // Tightened from 0.5, but preserves NTSC compatibility
    static let maxFormatAttempts: Int = 5
    static let formatWarmupDelaySeconds: TimeInterval = 0.3
    static let sessionRunningCheckMaxSeconds: TimeInterval = 1.0
    
    // === Format Scoring Weights ===
    /// Higher score = preferred format
    static let scoreWeightFps: Int64 = 1000        // FPS * 1000 (primary factor)
    static let scoreWeightResolution: Int64 = 100  // maxDimension / 100
    static let scoreWeightHDR: Int64 = 500         // HDR capability bonus
    static let scoreWeightHEVC: Int64 = 200        // HEVC codec bonus
    static let scoreWeightProRes: Int64 = 800      // ProRes capability bonus
    static let scoreWeightAppleLog: Int64 = 600    // Apple Log encoding bonus
    static let scoreWeightDolbyVision: Int64 = 400 // Dolby Vision bonus
    static let scoreWeightHDR10Plus: Int64 = 350   // HDR10+ bonus
    // Example: 4K60 HDR HEVC = 60*1000 + 3840/100 + 500 + 200 = 60,738
    
    // === File Naming ===
    static let maxFileNameLength: Int = 120
    static let maxFilenameCollisionRetries: Int = 3  // prevent infinite loop
    static let timestampFormat: String = "yyyyMMdd'T'HHmmss'Z'"
    static let timestampLocale: String = "en_US_POSIX"
    static let uuidStyle: String = "lowercase_no_hyphens"  // 32 chars
    
    // === Cleanup ===
    /// Orphan tmp file cleanup (faster on mobile)
    static let orphanTmpMaxAgeSeconds: TimeInterval = 4 * 60 * 60   // 4 hours (down from 12)
    static let orphanTmpCheckIntervalSeconds: TimeInterval = 30 * 60  // Check every 30 min
    
    /// Failure file retention (mobile storage is precious)
    static let maxRetainedFailureFiles: Int = 10  // Down from 20
    static let maxRetainedFailureBytesTotal: Int64 = 500 * 1024 * 1024  // 500MB (down from 2GB)
    static let maxRetainedFailureAgeDays: Int = 7  // Auto-delete after 7 days
    
    /// Success file retention (for debugging)
    static let maxRetainedSuccessFilesForDebug: Int = 3  // Keep last 3 successful recordings for debug
    
    // === Update Frequency ===
    static let recordingUpdateIntervalSeconds: TimeInterval = 1.0
    
    // === Platform ===
    static let thermalPlatform: String = "ios"
    
    // === HDR and Color Space ===
    /// Prefer HDR when device supports it (richer color for 3D reconstruction)
    public static let preferHDRWhenAvailable: Bool = true
    public static let preferDolbyVisionWhenAvailable: Bool = true
    public static let preferHDR10PlusWhenAvailable: Bool = true
    
    /// Color space preferences (for texture quality)
    public static let preferredColorSpace: String = "P3_D65"  // Display P3
    public static let fallbackColorSpace: String = "sRGB"
    
    /// HDR metadata
    public static let hdrMaxContentLightLevel: Int = 1000     // nits (typical for iPhone)
    public static let hdrMaxFrameAverageLightLevel: Int = 200 // nits
    
    // === Codec Priority ===
    /// Codec preference order (higher index = higher priority)
    public static let codecPriorityOrder: [String] = [
        "h264",         // 0: Legacy fallback
        "hevc",         // 1: Default (good quality/size)
        "hevcWithAlpha",// 2: HEVC with alpha channel
        "appleProRes422",      // 3: ProRes 422
        "appleProRes422HQ",    // 4: ProRes 422 HQ
        "appleProRes4444",     // 5: ProRes 4444 (with alpha)
        "appleProRes4444XQ"    // 6: ProRes 4444 XQ (highest quality)
    ]
    
    /// Codec feature flags
    public static let hevcSupportsAppleLog: Bool = true  // iPhone 15 Pro+ with iOS 17.2+
    public static let proResRequiresExternalStorage: Bool = false  // iPhone 15 Pro+ has internal ProRes
    
    // === Device Capability Detection ===
    /// Device model identifiers for feature gates
    public static let iPhone15ProModelIdentifiers: [String] = ["iPhone15,2", "iPhone15,3"]  // Pro, Pro Max
    public static let iPhone16ProModelIdentifiers: [String] = ["iPhone16,1", "iPhone16,2"]  // Pro, Pro Max (estimated)
    public static let proResCapableModels: [String] = ["iPhone15,2", "iPhone15,3", "iPhone16,1", "iPhone16,2"]
    public static let appleLogCapableModels: [String] = ["iPhone15,2", "iPhone15,3", "iPhone16,1", "iPhone16,2"]
    public static let spatial4KCapableModels: [String] = ["iPhone15,2", "iPhone15,3"]  // Spatial video
    
    /// Feature minimum iOS versions
    public static let appleLogMinimumIOSVersion: String = "17.2"
    public static let proResMinimumIOSVersion: String = "15.0"
    public static let spatialVideoMinimumIOSVersion: String = "17.2"
    
    // === ProRes Constants (iPhone 15 Pro+ only) ===
    /// Required storage write speed for ProRes (MB/s)
    public static let proResMinStorageWriteSpeedMBps: Int = 220  // Required for 4K60 ProRes
    /// Minimum device model for ProRes support
    public static let proResMinimumDeviceModel: String = "iPhone15,2"  // iPhone 15 Pro
    /// ProRes 422 HQ bitrate at 4K30 (bps)
    public static let proRes422HQBitrate4K30: Int64 = 165_000_000  // 165 Mbps
    /// ProRes 422 HQ bitrate at 4K60 (bps)
    public static let proRes422HQBitrate4K60: Int64 = 330_000_000  // 330 Mbps
    
    // === 3D Reconstruction Optimization ===
    /// Frame sampling for photogrammetry
    public static let minFramesFor3DReconstruction: Int = 30      // Absolute minimum
    public static let recommendedFramesFor3DReconstruction: Int = 200  // Good coverage
    public static let optimalFramesFor3DReconstruction: Int = 500    // Excellent detail
    
    /// Motion blur prevention
    public static let maxAcceptableMotionBlurMs: Double = 16.67  // 1/60th second
    public static let recommendedShutterSpeedForScanning: Double = 1.0 / 250.0  // 1/250s
    
    /// Focus quality
    public static let preferContinuousAutoFocus: Bool = true
    public static let focusHysteresisSeconds: TimeInterval = 0.5  // Minimum time between focus changes
    
    /// Exposure stability
    public static let preferLockedExposure: Bool = false  // Let camera adapt for indoor/outdoor
    public static let exposureStabilizationDelaySeconds: TimeInterval = 0.3  // Wait after exposure change
}

