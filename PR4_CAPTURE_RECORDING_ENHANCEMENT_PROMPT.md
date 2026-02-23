# PR4 Capture Recording Enhancement Prompt v1.0

## Overview

This prompt defines **precision enhancements** for PR#4 Capture Recording module. All changes must maintain:
- Cross-platform compatibility (iOS + Linux CI)
- CI-hardened determinism
- Constitutional Contract compliance
- Zero regressions in existing static scan tests

**Contract Version**: PR4-CAPTURE-1.1 (upgrade from implicit 1.0)

---

## Part 1: Constants Numerical Optimization

### File: `Core/Constants/CaptureRecordingConstants.swift`

#### 1.1 Bitrate Estimation Refinements

**Current State (Suboptimal)**:
```swift
static let bitrateEstimates: [String: Int64] = [
    "4K_60": 100_000_000,   // 100 Mbps
    "4K_30": 60_000_000,    // 60 Mbps
    "1080p_60": 40_000_000, // 40 Mbps
    "1080p_30": 25_000_000, // 25 Mbps
    "720p_30": 15_000_000,  // 15 Mbps
    "default": 50_000_000   // fallback
]
```

**Target State (Optimized for 3D Reconstruction)**:
```swift
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

// === Minimum Bitrate for 3D Reconstruction ===
// Below this threshold, texture quality degrades significantly
public static let minBitrateFor3DReconstruction: Int64 = 50_000_000  // 50 Mbps

// === ProRes Constants (iPhone 15 Pro+ only) ===
public static let proResMinStorageWriteSpeedMBps: Int = 220  // Required for 4K60 ProRes
public static let proResMinimumDeviceModel: String = "iPhone15,2"  // iPhone 15 Pro
public static let proRes422HQBitrate4K30: Int64 = 165_000_000  // 165 Mbps
public static let proRes422HQBitrate4K60: Int64 = 330_000_000  // 330 Mbps
```

#### 1.2 Duration Constants Refinement

**Current State**:
```swift
public static let minDurationSeconds: TimeInterval = 2
public static let maxDurationSeconds: TimeInterval = 900
public static let durationTolerance: TimeInterval = 0.25
```

**Target State (Precision Enhancement)**:
```swift
// === Duration ===
public static let minDurationSeconds: TimeInterval = 2.0
public static let maxDurationSeconds: TimeInterval = 900.0
public static let durationTolerance: TimeInterval = 0.1  // Reduced from 0.25 for tighter validation

// === Duration Thresholds ===
// Short recordings may lack sufficient frames for 3D reconstruction
public static let minRecommendedDuration3D: TimeInterval = 15.0  // Minimum for decent coverage
public static let optimalDuration3D: TimeInterval = 60.0  // Sweet spot for object scanning
public static let maxRecommendedDuration3D: TimeInterval = 300.0  // Beyond this, diminishing returns
```

#### 1.3 FPS Candidate List Enhancement

**Current State**:
```swift
static let candidateFps: [Double] = [120, 100, 60, 59.94, 50, 30, 29.97, 25, 24]
```

**Target State (Complete Coverage)**:
```swift
// === Format Selection ===
// Complete FPS candidate list (sorted descending for priority)
// Includes all standard broadcast + cinematic rates
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
static let fpsMatchTolerance: Double = 0.02  // Tightened from 0.5 for precision matching
```

#### 1.4 Polling Interval Optimization

**Current State**:
```swift
public static let fileSizePollStartDelaySeconds: TimeInterval = 1.0
public static let fileSizePollMaxWaitSeconds: TimeInterval = 5.0
public static let fileSizePollIntervalLargeFile: TimeInterval = 0.5
public static let fileSizePollIntervalSmallFile: TimeInterval = 1.0
public static let fileSizeLargeThresholdBytes: Int64 = 100 * 1024 * 1024
```

**Target State (Adaptive Polling)**:
```swift
// === Polling ===
public static let fileSizePollStartDelaySeconds: TimeInterval = 0.5  // Faster initial response
public static let fileSizePollMaxWaitSeconds: TimeInterval = 3.0     // Reduced for responsiveness
public static let fileSizePollIntervalLargeFile: TimeInterval = 0.25  // More frequent for large files
public static let fileSizePollIntervalSmallFile: TimeInterval = 0.5   // Halved for better tracking
public static let fileSizeLargeThresholdBytes: Int64 = 50 * 1024 * 1024  // 50MB threshold (down from 100MB)

// === Adaptive Polling Tiers ===
// For precise storage estimation during recording
public static let fileSizeTierSmall: Int64 = 10 * 1024 * 1024      // < 10MB
public static let fileSizeTierMedium: Int64 = 50 * 1024 * 1024     // 10-50MB
public static let fileSizeTierLarge: Int64 = 200 * 1024 * 1024     // 50-200MB
public static let fileSizeTierVeryLarge: Int64 = 500 * 1024 * 1024 // 200-500MB

public static let fileSizePollIntervalTierSmall: TimeInterval = 1.0
public static let fileSizePollIntervalTierMedium: TimeInterval = 0.5
public static let fileSizePollIntervalTierLarge: TimeInterval = 0.25
public static let fileSizePollIntervalTierVeryLarge: TimeInterval = 0.1
```

#### 1.5 Thermal Management Enhancement

**Current State**:
```swift
static let thermalWeightSerious: Int = 2
```

**Target State (Granular Thermal Response)**:
```swift
// === Thermal ===
// Thermal state weights (0=nominal, 1=fair, 2=serious, 3=critical)
static let thermalWeightNominal: Int = 0
static let thermalWeightFair: Int = 1
static let thermalWeightSerious: Int = 2
static let thermalWeightCritical: Int = 3

// Thresholds for actions
static let thermalWeightWarnUser: Int = 1      // Show warning at fair
static let thermalWeightReduceQuality: Int = 2 // Reduce bitrate/FPS at serious
static let thermalWeightStopRecording: Int = 3 // Force stop at critical

// Quality reduction factors at thermal states
static let thermalBitrateFactorFair: Double = 1.0       // No reduction
static let thermalBitrateFactorSerious: Double = 0.75   // 25% reduction
static let thermalFpsFactorSerious: Double = 0.5        // Drop to half FPS (60→30, 30→24)
```

#### 1.6 Storage Management Enhancement

**Current State**:
```swift
static let minFreeSpaceBytesBase: Int64 = 1024 * 1024 * 1024  // 1 GB
static let minFreeSpaceSecondsBuffer: TimeInterval = 10
```

**Target State (Proactive Storage Management)**:
```swift
// === Storage ===
// Base minimum free space (always reserved)
static let minFreeSpaceBytesBase: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB (up from 1GB)

// Buffer for recording continuation
static let minFreeSpaceSecondsBuffer: TimeInterval = 30  // 30 seconds buffer (up from 10)

// Warning thresholds
static let lowStorageWarningBytes: Int64 = 5 * 1024 * 1024 * 1024  // Warn at 5GB remaining
static let criticalStorageBytes: Int64 = 1 * 1024 * 1024 * 1024    // Critical at 1GB remaining

// ProRes storage requirements (per minute, 4K60)
static let proRes422HQBytesPerMinute4K60: Int64 = 2_475_000_000  // ~2.3GB/min
static let hevcBytesPerMinute4K60Estimate: Int64 = 900_000_000   // ~850MB/min at 120Mbps
```

#### 1.7 Timeout Refinements

**Current State**:
```swift
static let finalizeTimeoutSeconds: TimeInterval = 10
static let assetCheckTimeoutSeconds: TimeInterval = 2.0
static let reconfigureDelaySeconds: TimeInterval = 0.5
static let reconfigureDebounceSeconds: TimeInterval = 3.0
```

**Target State (Tuned for Real-World Performance)**:
```swift
// === Timeouts ===
static let finalizeTimeoutSeconds: TimeInterval = 15.0  // Increased for large files
static let assetCheckTimeoutSeconds: TimeInterval = 1.5 // Reduced budget, skip faster
static let reconfigureDelaySeconds: TimeInterval = 0.3  // Faster reconfigure
static let reconfigureDebounceSeconds: TimeInterval = 2.0  // Reduced from 3.0

// Additional timeouts
static let sessionStartTimeoutSeconds: TimeInterval = 5.0  // Max wait for session.startRunning()
static let deviceLockTimeoutSeconds: TimeInterval = 2.0    // Max wait for lockForConfiguration()
static let formatValidationTimeoutSeconds: TimeInterval = 3.0  // Max for format validation loop
```

#### 1.8 Format Selection Scoring Enhancement

**Current State**:
```swift
let score = Int64(candidateFps * 100) + (hdrCapable ? 10 : 0) + (hevcCapable ? 5 : 0)
```

**Target State (Weighted Scoring System)**:
```swift
// === Format Scoring Weights ===
// Higher score = preferred format
static let scoreWeightFps: Int64 = 1000        // FPS * 1000 (primary factor)
static let scoreWeightResolution: Int64 = 100  // maxDimension / 100
static let scoreWeightHDR: Int64 = 500         // HDR capability bonus
static let scoreWeightHEVC: Int64 = 200        // HEVC codec bonus
static let scoreWeightProRes: Int64 = 800      // ProRes capability bonus
static let scoreWeightAppleLog: Int64 = 600    // Apple Log encoding bonus
static let scoreWeightDolbyVision: Int64 = 400 // Dolby Vision bonus
static let scoreWeightHDR10Plus: Int64 = 350   // HDR10+ bonus

// Example: 4K60 HDR HEVC = 60*1000 + 3840/100 + 500 + 200 = 60,738
```

#### 1.9 Cleanup Policy Enhancement

**Current State**:
```swift
static let orphanTmpMaxAgeSeconds: TimeInterval = 12 * 60 * 60  // 12 hours
static let maxRetainedFailureFiles: Int = 20
static let maxRetainedFailureBytesTotal: Int64 = 2 * 1024 * 1024 * 1024
```

**Target State (Aggressive Mobile Cleanup)**:
```swift
// === Cleanup ===
// Orphan tmp file cleanup (faster on mobile)
static let orphanTmpMaxAgeSeconds: TimeInterval = 4 * 60 * 60   // 4 hours (down from 12)
static let orphanTmpCheckIntervalSeconds: TimeInterval = 30 * 60  // Check every 30 min

// Failure file retention (mobile storage is precious)
static let maxRetainedFailureFiles: Int = 10  // Down from 20
static let maxRetainedFailureBytesTotal: Int64 = 500 * 1024 * 1024  // 500MB (down from 2GB)
static let maxRetainedFailureAgeDays: Int = 7  // Auto-delete after 7 days

// Success file retention (for debugging)
static let maxRetainedSuccessFilesForDebug: Int = 3  // Keep last 3 successful recordings for debug
```

---

## Part 2: New Constants to Add

### 2.1 HDR and Color Space Constants

```swift
// === HDR and Color Space ===
// Prefer HDR when device supports it (richer color for 3D reconstruction)
public static let preferHDRWhenAvailable: Bool = true
public static let preferDolbyVisionWhenAvailable: Bool = true
public static let preferHDR10PlusWhenAvailable: Bool = true

// Color space preferences (for texture quality)
public static let preferredColorSpace: String = "P3_D65"  // Display P3
public static let fallbackColorSpace: String = "sRGB"

// HDR metadata
public static let hdrMaxContentLightLevel: Int = 1000     // nits (typical for iPhone)
public static let hdrMaxFrameAverageLightLevel: Int = 200 // nits
```

### 2.2 Codec Priority Constants

```swift
// === Codec Priority ===
// Codec preference order (higher index = higher priority)
public static let codecPriorityOrder: [String] = [
    "h264",         // 0: Legacy fallback
    "hevc",         // 1: Default (good quality/size)
    "hevcWithAlpha",// 2: HEVC with alpha channel
    "appleProRes422",      // 3: ProRes 422
    "appleProRes422HQ",    // 4: ProRes 422 HQ
    "appleProRes4444",     // 5: ProRes 4444 (with alpha)
    "appleProRes4444XQ"    // 6: ProRes 4444 XQ (highest quality)
]

// Codec feature flags
public static let hevcSupportsAppleLog: Bool = true  // iPhone 15 Pro+ with iOS 17.2+
public static let proResRequiresExternalStorage: Bool = false  // iPhone 15 Pro+ has internal ProRes
```

### 2.3 Device Capability Constants

```swift
// === Device Capability Detection ===
// Device model identifiers for feature gates
public static let iPhone15ProModelIdentifiers: [String] = ["iPhone15,2", "iPhone15,3"]  // Pro, Pro Max
public static let iPhone16ProModelIdentifiers: [String] = ["iPhone16,1", "iPhone16,2"]  // Pro, Pro Max (estimated)
public static let proResCapableModels: [String] = ["iPhone15,2", "iPhone15,3", "iPhone16,1", "iPhone16,2"]
public static let appleLogCapableModels: [String] = ["iPhone15,2", "iPhone15,3", "iPhone16,1", "iPhone16,2"]
public static let spatial4KCapableModels: [String] = ["iPhone15,2", "iPhone15,3"]  // Spatial video

// Feature minimum iOS versions
public static let appleLogMinimumIOSVersion: String = "17.2"
public static let proResMinimumIOSVersion: String = "15.0"
public static let spatialVideoMinimumIOSVersion: String = "17.2"
```

### 2.4 Quality Presets

```swift
// === Quality Presets ===
public enum CaptureQualityPreset: String, Codable, CaseIterable {
    case economy = "economy"      // 720p30, low bitrate, longest battery
    case standard = "standard"    // 1080p30, balanced
    case high = "high"            // 4K30, high quality
    case ultra = "ultra"          // 4K60 HDR, maximum quality
    case proRes = "proRes"        // 4K30 ProRes (iPhone 15 Pro+ only)
    case proResMax = "proResMax"  // 4K60 ProRes HQ (iPhone 15 Pro+ only)
}

// Preset configurations
public static let presetConfigs: [String: [String: Any]] = [
    "economy": ["tier": "720p", "fps": 30, "codec": "h264", "bitrateMbps": 15],
    "standard": ["tier": "1080p", "fps": 30, "codec": "hevc", "bitrateMbps": 30],
    "high": ["tier": "4K", "fps": 30, "codec": "hevc", "bitrateMbps": 75],
    "ultra": ["tier": "4K", "fps": 60, "codec": "hevc", "bitrateMbps": 120, "hdr": true],
    "proRes": ["tier": "4K", "fps": 30, "codec": "appleProRes422", "bitrateMbps": 165],
    "proResMax": ["tier": "4K", "fps": 60, "codec": "appleProRes422HQ", "bitrateMbps": 330]
]
```

### 2.5 3D Reconstruction Optimization Constants

```swift
// === 3D Reconstruction Optimization ===
// Frame sampling for photogrammetry
public static let minFramesFor3DReconstruction: Int = 30      // Absolute minimum
public static let recommendedFramesFor3DReconstruction: Int = 200  // Good coverage
public static let optimalFramesFor3DReconstruction: Int = 500    // Excellent detail

// Motion blur prevention
public static let maxAcceptableMotionBlurMs: Double = 16.67  // 1/60th second
public static let recommendedShutterSpeedForScanning: Double = 1.0 / 250.0  // 1/250s

// Focus quality
public static let preferContinuousAutoFocus: Bool = true
public static let focusHysteresisSeconds: TimeInterval = 0.5  // Minimum time between focus changes

// Exposure stability
public static let preferLockedExposure: Bool = false  // Let camera adapt for indoor/outdoor
public static let exposureStabilizationDelaySeconds: TimeInterval = 0.3  // Wait after exposure change
```

---

## Part 3: ResolutionTier Enhancement

### File: `Core/Constants/ResolutionTier.swift`

**Current State**:
```swift
public enum ResolutionTier: String, Codable, CaseIterable, Equatable {
    case t8K = "8K"
    case t4K = "4K"
    case t1080p = "1080p"
    case t720p = "720p"
    case lower = "lower"
}
```

**Target State (With Metadata)**:
```swift
public enum ResolutionTier: String, Codable, CaseIterable, Equatable {
    case t8K = "8K"
    case t4K = "4K"
    case t2K = "2K"       // NEW: 2560x1440 (QHD)
    case t1080p = "1080p"
    case t720p = "720p"
    case t480p = "480p"   // NEW: Legacy SD
    case lower = "lower"

    /// Minimum dimension threshold for this tier
    public var minDimension: Int {
        switch self {
        case .t8K: return 7680
        case .t4K: return 3840
        case .t2K: return 2560
        case .t1080p: return 1920
        case .t720p: return 1280
        case .t480p: return 640
        case .lower: return 0
        }
    }

    /// Recommended bitrate (bps) for this tier at 30fps
    public var recommendedBitrate30fps: Int64 {
        switch self {
        case .t8K: return 200_000_000
        case .t4K: return 75_000_000
        case .t2K: return 50_000_000
        case .t1080p: return 30_000_000
        case .t720p: return 18_000_000
        case .t480p: return 8_000_000
        case .lower: return 4_000_000
        }
    }

    /// Quality score (higher = better)
    public var qualityScore: Int {
        switch self {
        case .t8K: return 100
        case .t4K: return 80
        case .t2K: return 60
        case .t1080p: return 50
        case .t720p: return 30
        case .t480p: return 15
        case .lower: return 5
        }
    }

    /// Suitable for 3D reconstruction?
    public var suitableFor3DReconstruction: Bool {
        switch self {
        case .t8K, .t4K, .t2K, .t1080p: return true
        case .t720p, .t480p, .lower: return false
        }
    }
}
```

---

## Part 4: CaptureProfile Enhancement

### File: `Core/Constants/CaptureProfile.swift`

**Add New Profile**:
```swift
public enum CaptureProfile: UInt8, Codable, CaseIterable {
    case standard = 1
    case smallObjectMacro = 2
    case largeScene = 3
    case proMacro = 4           // NEW: Pro-level macro scanning
    case cinematicScene = 5     // NEW: Cinematic capture mode

    /// Recommended settings for each profile
    public var recommendedSettings: ProfileSettings {
        switch self {
        case .standard:
            return ProfileSettings(
                minTier: .t1080p,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .orbital
            )
        case .smallObjectMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macro,
                scanPattern: .closeUp
            )
        case .largeScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .walkthrough
            )
        case .proMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macroLocked,
                scanPattern: .turntable
            )
        case .cinematicScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 24,
                preferHDR: true,
                focusMode: .rackFocus,
                scanPattern: .dolly
            )
        }
    }
}

public struct ProfileSettings {
    public let minTier: ResolutionTier
    public let preferredFps: Int
    public let preferHDR: Bool
    public let focusMode: FocusMode
    public let scanPattern: ScanPattern
}

public enum FocusMode: String, Codable {
    case continuousAuto
    case macro
    case macroLocked
    case rackFocus
    case infinity
}

public enum ScanPattern: String, Codable {
    case orbital      // Circle around object
    case closeUp      // Detailed surface scan
    case walkthrough  // Move through space
    case turntable    // Object on turntable
    case dolly        // Cinematic camera movement
}
```

---

## Part 5: New Warning Codes

### File: `App/Capture/CaptureMetadata.swift`

**Add to WarningCode enum**:
```swift
enum WarningCode: String, Codable {
    // ... existing codes ...

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
```

---

## Part 6: Static Scan Test Enhancements

### File: `Tests/CaptureTests/CaptureStaticScanTests.swift`

**Add New Test Cases**:

```swift
// MARK: - New Constants Validation

func test_bitrateEstimatesHaveAllTiers() {
    let requiredKeys = [
        "8K_60", "8K_30",
        "4K_120", "4K_60", "4K_30",
        "1080p_120", "1080p_60", "1080p_30",
        "720p_60", "720p_30",
        "default"
    ]

    for key in requiredKeys {
        XCTAssertNotNil(
            CaptureRecordingConstants.bitrateEstimates[key],
            "[PR4][SCAN] missing_bitrate_key: \(key)"
        )
    }
}

func test_minBitrateFor3DReconstructionIsReasonable() {
    let minBitrate = CaptureRecordingConstants.minBitrateFor3DReconstruction
    XCTAssertGreaterThanOrEqual(minBitrate, 30_000_000, "Min 3D bitrate should be >= 30 Mbps")
    XCTAssertLessThanOrEqual(minBitrate, 100_000_000, "Min 3D bitrate should be <= 100 Mbps")
}

func test_fpsMatchToleranceIsTight() {
    let tolerance = CaptureRecordingConstants.fpsMatchTolerance
    XCTAssertLessThanOrEqual(tolerance, 0.1, "FPS tolerance should be <= 0.1 for precision")
}

func test_thermalWeightsAreOrdered() {
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightNominal,
        CaptureRecordingConstants.thermalWeightFair
    )
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightFair,
        CaptureRecordingConstants.thermalWeightSerious
    )
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightSerious,
        CaptureRecordingConstants.thermalWeightCritical
    )
}

func test_storageThresholdsAreReasonable() {
    let base = CaptureRecordingConstants.minFreeSpaceBytesBase
    let warning = CaptureRecordingConstants.lowStorageWarningBytes
    let critical = CaptureRecordingConstants.criticalStorageBytes

    XCTAssertGreaterThan(warning, critical, "Warning threshold should be > critical")
    XCTAssertGreaterThanOrEqual(base, critical, "Base minimum should be >= critical")
}

// MARK: - Cross-Platform Compatibility Scan

func test_coreConstantsContainNoPlatformSpecificCode() {
    guard let constantsPath = RepoRootLocator.resolvePath("Core/Constants") else {
        XCTFail("Could not resolve Core/Constants directory")
        return
    }

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: constantsPath, includingPropertiesForKeys: nil) else {
        XCTFail("Could not enumerate Core/Constants")
        return
    }

    let forbiddenPlatformPatterns = [
        "UIDevice",
        "UIKit",
        "AppKit",
        "ProcessInfo.processInfo.thermalState",
        "Bundle.main",
        "#if os(iOS)",
        "#if os(macOS)",
        "#if targetEnvironment"
    ]

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }

            for pattern in forbiddenPlatformPatterns {
                if line.contains(pattern) {
                    XCTFail("[PR4][SCAN] platform_specific_code file=\(fileURL.lastPathComponent) pattern=\(pattern) line=\(index + 1)")
                }
            }
        }
    }
}

// MARK: - Linux CI Compatibility

func test_noAppleOnlyAPIsInCoreConstants() {
    let forbiddenAPIs = [
        "CMTime(",
        "AVAsset",
        "AVCapture",
        "CIImage",
        "CGImage",
        "UIImage",
        "NSImage"
    ]

    // This test validates Core/Constants can compile on Linux
    guard let path = RepoRootLocator.resolvePath("Core/Constants") else {
        XCTFail("Could not resolve path")
        return
    }

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil) else {
        return
    }

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

        for api in forbiddenAPIs {
            if content.contains(api) {
                XCTFail("[PR4][SCAN] apple_only_api file=\(fileURL.lastPathComponent) api=\(api)")
            }
        }
    }
}
```

---

## Part 7: Verification Commands

After implementing all changes, run:

```bash
# 1. Build verification (must pass on macOS and Linux)
swift build

# 2. Core portability check (no AVFoundation in Core/)
grep -r "import AVFoundation" Core/
# Expected: NO matches

# 3. Run all capture tests
swift test --filter CaptureStaticScanTests
swift test --filter CaptureMetadataTests
swift test --filter CorePortabilitySmokeTests
swift test --filter CaptureProfileTests

# 4. Verify no magic numbers leaked
grep -rn "= 100_000_000" App/Capture/  # Should be empty (use constants)
grep -rn "= 0.5" App/Capture/          # Should reference constants

# 5. Header consistency check
grep -l "PR4-CAPTURE-1.1" Core/Constants/CaptureRecordingConstants.swift
grep -l "PR4-CAPTURE-1.1" Core/Constants/CaptureProfile.swift
grep -l "PR4-CAPTURE-1.1" Core/Constants/ResolutionTier.swift
```

---

## Part 8: Git Commit Template

```bash
git commit -m "$(cat <<'EOF'
feat(pr4): enhance capture recording constants for 3D reconstruction

BREAKING CHANGE: Contract version updated to PR4-CAPTURE-1.1

## Numerical Optimizations
- Bitrate estimates: +8K tiers, +4K120, increased minimums for photogrammetry
- Duration tolerance: 0.25s → 0.1s (tighter validation)
- FPS candidates: added 240, 48, 23.976 for complete coverage
- FPS match tolerance: 0.5 → 0.02 (precision matching)
- Polling intervals: halved for faster file size tracking
- Storage minimum: 1GB → 2GB base reserve

## New Constants
- minBitrateFor3DReconstruction: 50 Mbps
- ProRes support constants (iPhone 15 Pro+)
- HDR/Dolby Vision/HDR10+ preference flags
- Quality presets (economy → proResMax)
- Thermal granular response factors
- 3D reconstruction frame recommendations

## Enhanced Types
- ResolutionTier: added t2K, t480p with metadata methods
- CaptureProfile: added proMacro, cinematicScene profiles
- WarningCode: 15 new quality/thermal/storage warnings

## CI Hardening
- New static scan tests for cross-platform compatibility
- Linux API ban verification for Core/Constants

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Part 9: Checklist

Before marking PR4 enhancement complete:

- [ ] All numerical constants updated per Part 1
- [ ] All new constants added per Part 2
- [ ] ResolutionTier enhanced per Part 3
- [ ] CaptureProfile enhanced per Part 4
- [ ] WarningCode extended per Part 5
- [ ] Static scan tests added per Part 6
- [ ] All verification commands pass per Part 7
- [ ] No Apple-only imports in Core/Constants
- [ ] Build succeeds on macOS
- [ ] Build succeeds on Linux (CI)
- [ ] All existing tests still pass
- [ ] Contract version updated to PR4-CAPTURE-1.1
- [ ] Git commit follows template

---

## Appendix A: Cross-Reference Table

| Constant | Current Value | Target Value | Improvement |
|----------|---------------|--------------|-------------|
| 4K_60 bitrate | 100 Mbps | 120 Mbps | +20% for photogrammetry |
| 4K_30 bitrate | 60 Mbps | 75 Mbps | +25% for detail |
| 1080p_60 bitrate | 40 Mbps | 50 Mbps | +25% |
| durationTolerance | 0.25s | 0.1s | 2.5x tighter |
| fpsMatchTolerance | 0.5 | 0.02 | 25x tighter |
| pollIntervalLargeFile | 0.5s | 0.25s | 2x faster |
| pollIntervalSmallFile | 1.0s | 0.5s | 2x faster |
| minFreeSpaceBase | 1 GB | 2 GB | 2x safety margin |
| orphanTmpMaxAge | 12h | 4h | 3x faster cleanup |
| maxRetainedFailureFiles | 20 | 10 | 50% less storage |
| maxRetainedFailureBytes | 2 GB | 500 MB | 75% less storage |

---

**END OF PROMPT**
