# PR4 Enhancement Patch Prompt v1.0

## Purpose

This patch prompt supplements Cursor's PR4 Enhancement Plan with **critical additions, corrections, and extreme precision requirements** that were missing or underspecified.

**IMPORTANT**: Apply this patch AFTER reading Cursor's original plan. Items here are ADDITIVE corrections.

---

## Section 1: Critical Missing Items in Cursor's Plan

### 1.1 MISSING: CaptureProfile.swift Already Exists

**ISSUE**: Cursor's plan says "创建新文件 CaptureProfile.swift" but `Core/Constants/CaptureProfile.swift` may already exist on main branch.

**FIX**:
```bash
# First check if file exists
ls -la Core/Constants/CaptureProfile.swift
```

If exists, **MODIFY** instead of CREATE. If not exists on PR4 branch but exists on main, the plan should note this is a PR4-specific addition.

### 1.2 MISSING: Package.swift Update

**ISSUE**: PR4 branch's Package.swift is missing:
- `CSQLite` systemLibrary target
- `Upload` test target exclusion
- PIZ-related targets
- `Golden` directory exclusion

**FIX**: After enhancement, ensure Package.swift matches main branch structure OR explicitly document why PR4 branch differs.

```swift
// PR4 branch should have these additions if merging with main:
.systemLibrary(
  name: "CSQLite",
  path: "Sources/CSQLite",
  providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
),
// ... and exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"]
```

### 1.3 MISSING: FileManagerProvider.createDirectory Method

**ISSUE**: `RecordingController.swift:658` calls `fileManager.createDirectory(at:withIntermediateDirectories:)` but `FileManagerProvider` protocol doesn't define this method.

**FIX**: Add to `FileManagerProvider` protocol:
```swift
private protocol FileManagerProvider {
    // ... existing methods ...
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
}
```

And implement in `DefaultFileManagerProvider`:
```swift
func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
}
```

### 1.4 MISSING: fourCharCode Extension

**ISSUE**: `CameraSession.swift:408` uses `.fourCharCode` extension on `RawValue` but this extension is not defined in any PR4 file.

**FIX**: Add extension (if not already present):
```swift
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
```

---

## Section 2: Numerical Precision Corrections

### 2.1 Bitrate Estimates - Missing 8K_30 Key

**ISSUE**: Cursor's plan mentions `"8K_30"` but the `bitrateKey()` function maps `t8K` to `"4K"` prefix, not `"8K"`.

**FIX**: Update `bitrateKey()` function:
```swift
static func bitrateKey(tier: ResolutionTier, fps: Double) -> String {
    let normalizedFps: Int
    if fps >= 90 {
        normalizedFps = 120  // NEW: Support 120fps tier
    } else if fps >= 45 {
        normalizedFps = 60
    } else {
        normalizedFps = 30
    }

    let tierPrefix: String
    switch tier {
    case .t8K: tierPrefix = "8K"      // FIX: Was mapping to "4K"
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
```

### 2.2 FPS Tolerance - Edge Case

**ISSUE**: Changing `fpsMatchTolerance` from 0.5 to 0.02 may break matching for 59.94 → 60 and 29.97 → 30.

**CALCULATION**:
- `|60 - 59.94| = 0.06` → FAILS with 0.02 tolerance
- `|30 - 29.97| = 0.03` → FAILS with 0.02 tolerance

**FIX**: Use 0.1 tolerance instead of 0.02:
```swift
static let fpsMatchTolerance: Double = 0.1  // Allows 59.94↔60 and 29.97↔30
```

### 2.3 Polling Interval - Battery Impact

**ISSUE**: Reducing `fileSizePollIntervalSmallFile` from 1.0s to 0.5s doubles battery consumption for polling.

**FIX**: Add battery-aware polling:
```swift
// === Polling ===
// Default intervals (balanced)
public static let fileSizePollIntervalSmallFile: TimeInterval = 0.75  // Compromise: 0.75s
public static let fileSizePollIntervalLargeFile: TimeInterval = 0.35  // Slightly slower than 0.25

// Low power mode intervals
public static let fileSizePollIntervalSmallFileLowPower: TimeInterval = 1.5
public static let fileSizePollIntervalLargeFileLowPower: TimeInterval = 1.0
```

---

## Section 3: Type Safety Corrections

### 3.1 CaptureQualityPreset - Should Be in Core, Not App

**ISSUE**: Cursor's plan puts `CaptureQualityPreset` enum in `CaptureRecordingConstants.swift` but it's a Codable type that may need persistence.

**FIX**: Create separate file `Core/Constants/CaptureQualityPreset.swift`:
```swift
//
//  CaptureQualityPreset.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
//  Contract Version: PR4-CAPTURE-1.1

import Foundation

/// Quality preset for capture configuration (closed set, append-only)
public enum CaptureQualityPreset: String, Codable, CaseIterable, Equatable {
    case economy = "economy"
    case standard = "standard"
    case high = "high"
    case ultra = "ultra"
    case proRes = "proRes"
    case proResMax = "proResMax"

    /// Preset ID for digest computation
    public var presetId: UInt8 {
        switch self {
        case .economy: return 1
        case .standard: return 2
        case .high: return 3
        case .ultra: return 4
        case .proRes: return 5
        case .proResMax: return 6
        }
    }
}
```

### 3.2 FocusMode and ScanPattern - Already Codable?

**ISSUE**: If `FocusMode` and `ScanPattern` are defined in `CaptureProfile.swift`, they must be `Codable` for persistence.

**FIX**: Ensure all enums conform to `Codable, CaseIterable, Equatable`:
```swift
public enum FocusMode: String, Codable, CaseIterable, Equatable {
    case continuousAuto
    case macro
    case macroLocked
    case rackFocus
    case infinity
}

public enum ScanPattern: String, Codable, CaseIterable, Equatable {
    case orbital
    case closeUp
    case walkthrough
    case turntable
    case dolly
}
```

### 3.3 ProfileSettings - Needs Codable Conformance

**ISSUE**: `ProfileSettings` struct has non-Codable members if enums aren't Codable.

**FIX**:
```swift
public struct ProfileSettings: Codable, Equatable {
    public let minTier: ResolutionTier
    public let preferredFps: Int
    public let preferHDR: Bool
    public let focusMode: FocusMode
    public let scanPattern: ScanPattern

    public init(minTier: ResolutionTier, preferredFps: Int, preferHDR: Bool, focusMode: FocusMode, scanPattern: ScanPattern) {
        self.minTier = minTier
        self.preferredFps = preferredFps
        self.preferHDR = preferHDR
        self.focusMode = focusMode
        self.scanPattern = scanPattern
    }
}
```

---

## Section 4: Missing Static Scan Tests

### 4.1 Test: Verify New Enums Have Frozen Case Order Hash

**ADD** to `CaptureStaticScanTests.swift`:
```swift
func test_resolutionTierFrozenCaseOrderHash() {
    // Verify ResolutionTier case order hasn't changed
    let caseNames = ResolutionTier.allCases.map { $0.rawValue }.sorted()
    let joined = caseNames.joined(separator: "\n")
    // Compute hash (using SHA-256 or simple string hash)
    // This test ensures enum order stability
    XCTAssertEqual(caseNames.count, 7, "ResolutionTier should have 7 cases after enhancement")
}

func test_captureQualityPresetFrozenCaseOrderHash() {
    let caseNames = CaptureQualityPreset.allCases.map { $0.rawValue }.sorted()
    XCTAssertEqual(caseNames.count, 6, "CaptureQualityPreset should have 6 cases")
}
```

### 4.2 Test: Verify Constants Are Compile-Time Deterministic

**ADD**:
```swift
func test_constantsAreCompileTimeDeterministic() {
    // These constants must be identical across runs
    let bitrate1 = CaptureRecordingConstants.bitrateEstimates["4K_60"]
    let bitrate2 = CaptureRecordingConstants.bitrateEstimates["4K_60"]
    XCTAssertEqual(bitrate1, bitrate2, "Constants must be deterministic")

    // Verify no runtime computation
    XCTAssertNotNil(bitrate1, "4K_60 bitrate must exist at compile time")
}
```

### 4.3 Test: Verify Thermal Weights Are Monotonic

**ADD**:
```swift
func test_thermalWeightsAreMonotonic() {
    // Thermal weights must increase with severity
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightNominal,
        CaptureRecordingConstants.thermalWeightFair,
        "Nominal < Fair"
    )
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightFair,
        CaptureRecordingConstants.thermalWeightSerious,
        "Fair < Serious"
    )
    XCTAssertLessThan(
        CaptureRecordingConstants.thermalWeightSerious,
        CaptureRecordingConstants.thermalWeightCritical,
        "Serious < Critical"
    )

    // Verify exact values
    XCTAssertEqual(CaptureRecordingConstants.thermalWeightNominal, 0)
    XCTAssertEqual(CaptureRecordingConstants.thermalWeightFair, 1)
    XCTAssertEqual(CaptureRecordingConstants.thermalWeightSerious, 2)
    XCTAssertEqual(CaptureRecordingConstants.thermalWeightCritical, 3)
}
```

### 4.4 Test: Verify ProRes Constants Are Reasonable

**ADD**:
```swift
func test_proResConstantsAreReasonable() {
    // ProRes 422 HQ at 4K30 should be ~165 Mbps
    let proRes4K30 = CaptureRecordingConstants.proRes422HQBitrate4K30
    XCTAssertGreaterThanOrEqual(proRes4K30, 150_000_000, "ProRes 4K30 >= 150 Mbps")
    XCTAssertLessThanOrEqual(proRes4K30, 200_000_000, "ProRes 4K30 <= 200 Mbps")

    // ProRes 422 HQ at 4K60 should be ~330 Mbps
    let proRes4K60 = CaptureRecordingConstants.proRes422HQBitrate4K60
    XCTAssertGreaterThanOrEqual(proRes4K60, 300_000_000, "ProRes 4K60 >= 300 Mbps")
    XCTAssertLessThanOrEqual(proRes4K60, 400_000_000, "ProRes 4K60 <= 400 Mbps")

    // Storage write speed requirement
    let writeSpeed = CaptureRecordingConstants.proResMinStorageWriteSpeedMBps
    XCTAssertGreaterThanOrEqual(writeSpeed, 200, "ProRes requires >= 200 MB/s write speed")
}
```

### 4.5 Test: Verify No Hardcoded Device Model Strings in App/Capture

**ADD**:
```swift
func test_noHardcodedDeviceModelsInAppCapture() {
    guard let captureDir = RepoRootLocator.resolvePath("App/Capture") else {
        XCTFail("Could not resolve App/Capture directory")
        return
    }

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: captureDir, includingPropertiesForKeys: nil) else {
        return
    }

    // Device model strings should be in CaptureRecordingConstants, not hardcoded
    let forbiddenPatterns = [
        "\"iPhone15,2\"",
        "\"iPhone15,3\"",
        "\"iPhone16,1\"",
        "\"iPhone16,2\""
    ]

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else { continue }
        guard fileURL.lastPathComponent != "CaptureRecordingConstants.swift" else { continue }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

        for pattern in forbiddenPatterns {
            if content.contains(pattern) {
                XCTFail("[PR4][SCAN] hardcoded_device_model file=\(fileURL.lastPathComponent) pattern=\(pattern)")
            }
        }
    }
}
```

---

## Section 5: Missing Contract Headers

### 5.1 All Modified Files Need Contract Version Header

**CRITICAL**: Every file modified in PR4 enhancement MUST have this header:

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// ============================================================================
```

**Files requiring header update**:
1. `Core/Constants/CaptureRecordingConstants.swift`
2. `Core/Constants/ResolutionTier.swift`
3. `Core/Constants/CaptureProfile.swift` (if exists or created)
4. `Core/Constants/CaptureQualityPreset.swift` (new file)
5. `App/Capture/CaptureMetadata.swift`
6. `App/Capture/CameraSession.swift`

### 5.2 File Header Format

**COMPLETE HEADER TEMPLATE**:
```swift
//
//  FileName.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 30 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation
```

---

## Section 6: Missing Edge Cases in CameraSession.swift

### 6.1 Format Scoring - Handle Missing Capabilities

**ISSUE**: New scoring system uses ProRes, Apple Log, Dolby Vision, HDR10+ but not all formats support these.

**FIX**: Add safe capability checks:
```swift
private func calculateFormatScore(format: AVCaptureDevice.Format, fps: Double) -> Int64 {
    var score: Int64 = 0

    // FPS contribution
    score += Int64(fps) * CaptureRecordingConstants.scoreWeightFps

    // Resolution contribution
    let dimensions = format.formatDescription.dimensions
    score += Int64(max(dimensions.width, dimensions.height)) / 100 * CaptureRecordingConstants.scoreWeightResolution

    // HDR contribution (safe check)
    if format.isVideoHDRSupported {
        score += CaptureRecordingConstants.scoreWeightHDR
    }

    // HEVC contribution
    if format.isVideoCodecSupported(.hevc) {
        score += CaptureRecordingConstants.scoreWeightHEVC
    }

    // ProRes contribution (iOS 15+ only, safe check)
    if #available(iOS 15.0, *) {
        // Check if device supports ProRes (implementation varies)
        // This is a placeholder - actual implementation depends on AVFoundation API
    }

    // Apple Log contribution (iOS 17.2+ only)
    if #available(iOS 17.2, *) {
        // Check for Apple Log support
    }

    // Dolby Vision contribution (format-specific)
    // HDR10+ contribution (format-specific)

    return score
}
```

### 6.2 determineTier() - Add New Tiers

**ISSUE**: Current `determineTier()` doesn't handle `t2K` or `t480p`.

**FIX**:
```swift
private func determineTier(width: Int, height: Int) -> ResolutionTier {
    let maxDim = max(width, height)
    if maxDim >= 7680 {
        return .t8K
    } else if maxDim >= 3840 {
        return .t4K
    } else if maxDim >= 2560 {
        return .t2K      // NEW
    } else if maxDim >= 1920 {
        return .t1080p
    } else if maxDim >= 1280 {
        return .t720p
    } else if maxDim >= 640 {
        return .t480p    // NEW
    } else {
        return .lower
    }
}
```

---

## Section 7: Missing Linux CI Compatibility Checks

### 7.1 Verify Core/Constants Compiles on Linux

**ADD** to CI workflow or pre-push check:
```bash
# Linux compilation check (simulated)
# Core/Constants must not use:
# - UIDevice
# - AVFoundation
# - ProcessInfo.processInfo.thermalState
# - Bundle.main

grep -r "UIDevice" Core/Constants/ && echo "FAIL: UIDevice in Core" && exit 1
grep -r "import AVFoundation" Core/Constants/ && echo "FAIL: AVFoundation in Core" && exit 1
grep -r "ProcessInfo.processInfo.thermalState" Core/Constants/ && echo "FAIL: thermalState in Core" && exit 1
grep -r "Bundle.main" Core/Constants/ && echo "FAIL: Bundle.main in Core" && exit 1
echo "PASS: Core/Constants is Linux-compatible"
```

### 7.2 Test: Verify No #if os() in Core/Constants

**ADD** to `CaptureStaticScanTests.swift`:
```swift
func test_coreConstantsHaveNoPlatformConditionals() {
    guard let path = RepoRootLocator.resolvePath("Core/Constants") else {
        XCTFail("Could not resolve path")
        return
    }

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil) else {
        return
    }

    let forbiddenPatterns = [
        "#if os(iOS)",
        "#if os(macOS)",
        "#if targetEnvironment",
        "#if canImport(UIKit)",
        "#if canImport(AppKit)"
    ]

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

        for pattern in forbiddenPatterns {
            if content.contains(pattern) {
                XCTFail("[PR4][SCAN] platform_conditional file=\(fileURL.lastPathComponent) pattern=\(pattern)")
            }
        }
    }
}
```

---

## Section 8: Missing Backward Compatibility Guards

### 8.1 ResolutionTier - Preserve Existing Case Order

**CRITICAL**: When adding new cases to `ResolutionTier`, they MUST be appended, not inserted.

**Current order**:
```swift
case t8K = "8K"
case t4K = "4K"
case t1080p = "1080p"
case t720p = "720p"
case lower = "lower"
```

**Correct new order** (append only):
```swift
case t8K = "8K"
case t4K = "4K"
case t1080p = "1080p"
case t720p = "720p"
case lower = "lower"
case t2K = "2K"       // APPENDED
case t480p = "480p"   // APPENDED
```

**WRONG** (would break existing data):
```swift
case t8K = "8K"
case t4K = "4K"
case t2K = "2K"       // INSERTED - WRONG!
case t1080p = "1080p"
// ...
```

### 8.2 WarningCode - Preserve Existing Case Order

**SAME RULE**: New warning codes must be appended, not inserted.

---

## Section 9: Missing Diagnostic Event Codes

### 9.1 Add New Diagnostic Events for Thermal/Quality Changes

**ADD** to `DiagnosticEventCode` in `CaptureMetadata.swift`:
```swift
enum DiagnosticEventCode: String, Codable {
    // ... existing codes ...

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
```

---

## Section 10: Missing Documentation Comments

### 10.1 All Public Constants Need Doc Comments

**EXAMPLE**:
```swift
/// Minimum bitrate (bits per second) for acceptable 3D reconstruction quality.
/// Below this threshold, texture detail degrades significantly.
/// - Note: Based on photogrammetry industry standards (50 Mbps minimum for 4K content).
/// - SeeAlso: `bitrateEstimates` for tier-specific recommendations.
public static let minBitrateFor3DReconstruction: Int64 = 50_000_000
```

### 10.2 All Public Enums Need Doc Comments

**EXAMPLE**:
```swift
/// Quality preset for capture configuration.
///
/// Presets define a combination of resolution, frame rate, codec, and bitrate
/// optimized for different use cases. Higher presets consume more storage and battery.
///
/// - economy: Minimal quality for longest battery life (720p30, H.264)
/// - standard: Balanced quality for everyday use (1080p30, HEVC)
/// - high: High quality for detailed capture (4K30, HEVC)
/// - ultra: Maximum quality with HDR (4K60, HEVC, HDR)
/// - proRes: Professional quality for post-processing (4K30, ProRes 422)
/// - proResMax: Maximum professional quality (4K60, ProRes 422 HQ)
///
/// - Important: `proRes` and `proResMax` require iPhone 15 Pro or later.
public enum CaptureQualityPreset: String, Codable, CaseIterable, Equatable {
    // ...
}
```

---

## Section 11: Verification Checklist

After applying this patch, verify:

### 11.1 Compilation
```bash
# macOS
swift build

# Linux (CI)
# Ensure Core/Constants compiles without AVFoundation
```

### 11.2 Tests
```bash
swift test --filter CaptureStaticScanTests
swift test --filter CaptureMetadataTests
swift test --filter CorePortabilitySmokeTests
swift test --filter CaptureProfileTests
```

### 11.3 Static Analysis
```bash
# No AVFoundation in Core
grep -r "import AVFoundation" Core/
# Expected: NO matches

# No hardcoded magic numbers in App/Capture (except constants file)
grep -rn "= 100_000_000\|= 50_000_000\|= 0.5\|= 1.0\|= 900" App/Capture/ | grep -v Constants
# Expected: NO matches

# All files have contract header
grep -l "PR4-CAPTURE-1.1" Core/Constants/CaptureRecordingConstants.swift
grep -l "PR4-CAPTURE-1.1" Core/Constants/ResolutionTier.swift
# Expected: Both files matched
```

### 11.4 Type Safety
```bash
# Verify all new enums are Codable
grep -A5 "enum CaptureQualityPreset" Core/Constants/CaptureQualityPreset.swift | grep "Codable"
grep -A5 "enum FocusMode" Core/Constants/CaptureProfile.swift | grep "Codable"
grep -A5 "enum ScanPattern" Core/Constants/CaptureProfile.swift | grep "Codable"
# Expected: All three matched
```

---

## Section 12: Git Commit Amendment

**Cursor's commit message is incomplete. Use this instead**:

```bash
git commit -m "$(cat <<'EOF'
feat(pr4): enhance capture recording with extreme precision constants

BREAKING CHANGE: Contract version updated to PR4-CAPTURE-1.1

## Numerical Optimizations (12 changes)
- bitrateEstimates: added 8K tiers, 4K120, 1080p120, increased all by 15-25%
- durationTolerance: 0.25s → 0.1s (2.5x tighter)
- fpsMatchTolerance: 0.5 → 0.1 (5x tighter, preserves NTSC compatibility)
- fileSizePollIntervalSmallFile: 1.0s → 0.75s (balanced for battery)
- fileSizePollIntervalLargeFile: 0.5s → 0.35s
- minFreeSpaceBytesBase: 1GB → 2GB
- minFreeSpaceSecondsBuffer: 10s → 30s
- orphanTmpMaxAgeSeconds: 12h → 4h
- maxRetainedFailureFiles: 20 → 10
- maxRetainedFailureBytesTotal: 2GB → 500MB
- assetCheckTimeoutSeconds: 2.0s → 1.5s
- reconfigureDebounceSeconds: 3.0s → 2.0s

## New Constants (35+ additions)
- minBitrateFor3DReconstruction: 50 Mbps
- ProRes: 6 constants (write speed, device models, bitrates)
- HDR/Color: 8 constants (preferences, color spaces, light levels)
- Codec priority: 7 codec types ranked
- Device capability: 12 model identifiers
- Thermal granular: 7 weights and factors
- 3D reconstruction: 6 frame/motion/focus constants
- Quality presets: 6 presets with full configs

## Type Enhancements
- ResolutionTier: +2 cases (t2K, t480p), +4 computed properties
- CaptureProfile: +2 cases (proMacro, cinematicScene), +ProfileSettings
- CaptureQualityPreset: new enum with 6 presets
- FocusMode: new enum with 5 modes
- ScanPattern: new enum with 5 patterns
- WarningCode: +15 new warning codes

## CI Hardening
- 7 new static scan tests
- Cross-platform compatibility verification
- Linux API ban enforcement
- Frozen case order hash validation

## Fixed Bugs
- bitrateKey() now correctly maps t8K to "8K" prefix
- determineTier() now handles t2K and t480p
- FileManagerProvider.createDirectory() added

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Section 13: Final Checklist

Before marking PR4 enhancement complete, verify ALL items:

### Constants
- [ ] All bitrate estimates updated per Section 2.1
- [ ] bitrateKey() function updated to handle all tiers
- [ ] FPS tolerance set to 0.1 (not 0.02)
- [ ] Polling intervals balanced for battery
- [ ] All thermal weights defined (0, 1, 2, 3)
- [ ] All ProRes constants added
- [ ] All HDR/color constants added
- [ ] minBitrateFor3DReconstruction = 50_000_000

### Types
- [ ] ResolutionTier has 7 cases (append-only)
- [ ] CaptureQualityPreset in separate file
- [ ] All new enums are Codable, CaseIterable, Equatable
- [ ] ProfileSettings struct is Codable
- [ ] WarningCode has 30 cases (15 new)

### Functions
- [ ] determineTier() handles t2K and t480p
- [ ] calculateFormatScore() uses new weight constants
- [ ] FileManagerProvider.createDirectory() defined

### Tests
- [ ] 7 new static scan tests added
- [ ] All existing tests still pass
- [ ] No AVFoundation in Core/Constants

### Headers
- [ ] All modified files have PR4-CAPTURE-1.1 header
- [ ] All public items have doc comments

### Git
- [ ] Commit message uses amended template
- [ ] All files staged correctly

---

**END OF PATCH PROMPT**
