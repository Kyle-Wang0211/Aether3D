# CURSOR v8.3 SWIFT6 CROSS-PLATFORM MOBILE OPTIMIZATION PROMPT

## Document Metadata
- **Version**: 8.3 HYPERION
- **Created**: 2026-02-07
- **Purpose**: Comprehensive fix for all build warnings, Swift 6.2 strict concurrency, iOS/Linux cross-platform, and mobile optimization
- **Prerequisite**: v8.2 IRONCLAD security fixes applied

---

## PART 1: CRITICAL BUILD ERRORS (MUST FIX FIRST)

### 1.1 SQLite Import Missing in CounterStore.swift

**File**: `Core/DeviceAttestation/CounterStore.swift`

**Error**:
```
error: cannot find 'sqlite3_open' in scope
error: cannot find 'SQLITE_OK' in scope
error: cannot find 'sqlite3_prepare_v2' in scope
```

**Root Cause**: Missing `import CSQLite` statement

**Fix**:
```swift
// Line 9 - Add import
import Foundation
import CSQLite  // ADD THIS LINE
```

**Verification**: All SQLite files must use `import CSQLite` (NOT `import SQLite3` which is Apple-only):
- ✅ `Core/Persistence/SQLiteWALStorage.swift` - already has `import CSQLite`
- ✅ `Core/Quality/WhiteCommitter/QualityDatabase.swift` - already has `import CSQLite`
- ❌ `Core/DeviceAttestation/CounterStore.swift` - MISSING, must add

---

### 1.2 GLTFExporter Type Conformance Error

**Files**:
- `Core/FormatBridge/GLTFExporter.swift` (line 147)
- `Core/FormatBridge/GLTFGaussianSplattingExporter.swift` (line 133)

**Error**:
```
error: type 'Any' cannot conform to 'Encodable'
```

**Root Cause**: `[String: Any]` dictionary cannot be encoded with `JSONEncoder`

**Fix for GLTFExporter.swift**:
Replace the `createJSONChunk` method (lines 94-134) with:

```swift
/// Create JSON chunk
private func createJSONChunk(mesh: MeshData, provenanceBundle: ProvenanceBundle, options: GLTFExportOptions) throws -> Data {
    // Use JSONSerialization instead of Encodable for [String: Any]
    var gltf: [String: Any] = [
        "asset": [
            "version": "2.0",
            "generator": "Aether3D"
        ],
        "scenes": [[
            "nodes": [0]
        ]],
        "nodes": [[
            "mesh": 0
        ]],
        "meshes": [[
            "primitives": [[
                "attributes": [
                    "POSITION": 0
                ],
                "indices": 1
            ]]
        ]],
        "accessors": [] as [[String: Any]],
        "bufferViews": [] as [[String: Any]],
        "buffers": [[
            "uri": "data:application/octet-stream;base64,"
        ]]
    ]

    // Embed provenance bundle in extras
    let provenanceJSON = try provenanceBundle.encode()
    gltf["extras"] = [
        "provenanceBundle": String(data: provenanceJSON, encoding: .utf8) ?? ""
    ]

    // Use JSONSerialization with sorted keys for canonical output
    let jsonData = try JSONSerialization.data(
        withJSONObject: gltf,
        options: [.sortedKeys, .fragmentsAllowed]
    )

    // Pad to 4-byte alignment per glTF spec
    let padding = (4 - (jsonData.count % 4)) % 4
    var paddedData = jsonData
    paddedData.append(contentsOf: [UInt8](repeating: 0x20, count: padding))

    return paddedData
}
```

**Apply same fix to GLTFGaussianSplattingExporter.swift** (lines 116-148)

---

### 1.3 DeterministicScheduler Mutability Error

**File**: `Core/Replay/DeterministicScheduler.swift`

**Error**:
```
error: cannot use mutating member on immutable 'splitMix' constant
```

**Root Cause**: `SplitMix64` is a struct with mutating `next()`, but used as `let` constant

**Fix** (lines 54-67):
```swift
public init(seed: UInt64) {
    let actualSeed = seed == 0 ? 1 : seed
    self.seed = actualSeed

    // Initialize Xoshiro256** state using SplitMix64
    var splitMix = SplitMix64(seed: actualSeed)  // CHANGE: let → var
    let state = Xoshiro256State(
        state0: splitMix.next(),
        state1: splitMix.next(),
        state2: splitMix.next(),
        state3: splitMix.next()
    )
    self.prng = Xoshiro256StarStar(state: state)
}
```

---

### 1.4 WALRecovery Access Level Mismatch

**File**: `Core/Persistence/WALRecovery.swift`

**Error**:
```
error: initializer cannot be declared public because its parameter uses an internal type
```

**Root Cause**: Public initializer uses internal types (`WriteAheadLog`, `SignedAuditLog`, `MerkleTree`)

**Fix Options**:

**Option A - Make initializer internal** (recommended for internal use):
```swift
// Line 27 - Change public to internal
internal init(wal: WriteAheadLog, auditLog: SignedAuditLog, merkleTree: MerkleTree) {
```

**Option B - Make dependent types public** (if external API is needed):
Ensure `WriteAheadLog`, `SignedAuditLog`, and `MerkleTree` are all marked `public`.

---

## PART 2: SWIFT 6.2 STRICT CONCURRENCY COMPLIANCE

### 2.1 Actor Isolation Warnings

**Pattern**: `actor-isolated instance method 'xxx' cannot be referenced from nonisolated context`

**Files Affected** (common pattern):
- `Core/DeviceAttestation/*.swift`
- `Core/Persistence/*.swift`
- `Core/Jobs/*.swift`
- `Sources/PR5Capture/**/*.swift`

**Fix Strategy**:

#### 2.1.1 For async methods called from nonisolated context:
```swift
// WRONG - calling actor method from nonisolated
func doSomething() {
    actorInstance.someMethod() // ❌ Warning
}

// RIGHT - make the calling context async
func doSomething() async {
    await actorInstance.someMethod() // ✅
}
```

#### 2.1.2 For synchronous access patterns:
```swift
// WRONG - trying to access actor state synchronously
var value: Int {
    return actorInstance.currentValue // ❌ Not allowed
}

// RIGHT - use nonisolated(unsafe) for truly thread-safe values
// OR restructure to use async
nonisolated var cachedValue: Int {
    // Only for genuinely immutable data
}
```

#### 2.1.3 For closures capturing actor-isolated state:
```swift
// WRONG
Task {
    // This closure may not be on actor's executor
    self.actorProperty = value // ❌ Warning
}

// RIGHT - explicitly await actor operations
Task { @MainActor in
    self.actorProperty = value // ✅ For @MainActor
}

// OR for regular actors
Task {
    await self.updateProperty(value) // ✅ Use actor method
}
```

---

### 2.2 Sendable Conformance Warnings

**Pattern**: `stored property 'xxx' of 'Sendable'-conforming struct 'Yyy' has non-Sendable type`

**Fix Strategy**:

#### 2.2.1 For closures stored in Sendable structs:
```swift
// WRONG
public struct ScheduledTask: Sendable {
    let task: () async throws -> Void // ❌ Non-Sendable closure
}

// RIGHT - Mark closure as @Sendable
public struct ScheduledTask: Sendable {
    let task: @Sendable () async throws -> Void // ✅
}
```

#### 2.2.2 For OpaquePointer (SQLite):
```swift
// WRONG
public actor SQLiteCounterStore: Sendable {
    private var db: OpaquePointer? // ❌ OpaquePointer not Sendable
}

// RIGHT - Use @unchecked Sendable wrapper
@unchecked Sendable
private final class SQLiteHandle {
    var db: OpaquePointer?

    init(db: OpaquePointer?) {
        self.db = db
    }
}

public actor SQLiteCounterStore: Sendable {
    private let handle: SQLiteHandle // ✅
}
```

#### 2.2.3 For Date in timestamps:
`Date` is already `Sendable` in Swift 6 - no action needed.

---

### 2.3 @MainActor + async setUp/tearDown

**CRITICAL**: Per MEMORY.md, `@MainActor` with `async setUp/tearDown` causes XCTest deadlocks on Linux.

**Files Affected**: `Tests/PR5CaptureTests/**/*.swift` (80+ files)

**CI Workaround** (already in place):
```yaml
# Linux CI
- name: Run tests
  run: swift test --skip PR5CaptureTests --disable-swift-testing
```

**Long-term Fix**:
1. Remove `@MainActor` from test classes
2. Use explicit `@MainActor` only on specific test methods that need it
3. Or convert to Swift Testing framework (`@Test` annotation)

---

## PART 3: iOS/LINUX CROSS-PLATFORM COMPATIBILITY

### 3.1 Platform-Specific Imports

**Pattern**: Use conditional compilation for platform-specific APIs

```swift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto for Linux
#endif

#if os(iOS) || os(macOS)
import Security  // Keychain/SecureEnclave
#endif
```

### 3.2 Security API Availability

**SecureEnclave/Keychain** - iOS/macOS only:
```swift
#if os(iOS) || os(macOS)
public actor SecureKeyManager {
    // SecureEnclave implementation
}
#else
public actor SecureKeyManager {
    // Linux fallback - use file-based encrypted storage
    // NEVER store keys in plaintext on Linux
}
#endif
```

**Code Signing** - macOS only:
```swift
#if os(macOS)
func validateCodeSignature() -> Bool {
    // SecStaticCodeCheckValidity implementation
}
#else
func validateCodeSignature() -> Bool {
    // Linux: Always return true or use alternative verification
    // Consider checksums, embedded signatures, or trusted paths
    return true
}
#endif
```

**Debugger Detection** - Platform-specific:
```swift
#if os(iOS) || os(macOS)
func detectDebugger() -> Bool {
    // sysctl, ptrace implementation
}
#elseif os(Linux)
func detectDebugger() -> Bool {
    // Check /proc/self/status for TracerPid
    // Check LD_PRELOAD for injection
}
#endif
```

### 3.3 SQLite Cross-Platform

**Use CSQLite system library** (already configured in Package.swift):
```swift
.systemLibrary(
    name: "CSQLite",
    path: "Sources/CSQLite",
    providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
)
```

**NEVER use `import SQLite3`** - it's Apple-only.

### 3.4 File System Paths

```swift
#if os(iOS)
let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
#elseif os(macOS)
let documentsPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
#elseif os(Linux)
let documentsPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? "/tmp")
    .appendingPathComponent(".aether3d")
#endif
```

---

## PART 4: MOBILE OPTIMIZATION (iOS)

### 4.1 Thermal Throttling Response

```swift
/// Thermal State Handler - Adaptive quality based on device temperature
public actor ThermalStateHandler {

    #if os(iOS)
    private var thermalStateObserver: NSObjectProtocol?
    #endif

    /// Quality level based on thermal state
    public enum QualityLevel: Sendable {
        case maximum    // Full quality
        case high       // 90% quality, reduced frame rate
        case medium     // 70% quality, significant reduction
        case minimum    // 50% quality, emergency mode
    }

    public func currentQualityLevel() -> QualityLevel {
        #if os(iOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .maximum
        case .fair:
            return .high
        case .serious:
            return .medium
        case .critical:
            return .minimum
        @unknown default:
            return .high
        }
        #else
        return .maximum
        #endif
    }

    /// Invariant INV-MOBILE-001: Thermal throttle response < 100ms
    public func adaptToThermalState() async {
        let level = currentQualityLevel()
        await applyQualitySettings(level)
    }

    private func applyQualitySettings(_ level: QualityLevel) async {
        switch level {
        case .maximum:
            // Full 3DGS point count, 60 FPS target
            break
        case .high:
            // 90% points, 30 FPS target
            break
        case .medium:
            // 70% points, 24 FPS target, reduce SH bands
            break
        case .minimum:
            // 50% points, 15 FPS, position-only rendering
            break
        }
    }
}
```

### 4.2 Memory Pressure Handler

```swift
/// Memory Pressure Handler - Adaptive memory management
public actor MemoryPressureHandler {

    /// Invariant INV-MOBILE-002: Memory warning response < 50ms
    public func handleMemoryWarning() async {
        // Phase 1: Drop non-essential caches
        await dropRenderingCaches()

        // Phase 2: Reduce Gaussian count
        await reduceActiveGaussianCount(by: 0.3) // 30% reduction

        // Phase 3: Emergency - drop spherical harmonics
        if ProcessInfo.processInfo.physicalMemory < memoryThresholdCritical {
            await dropSphericalHarmonics()
        }
    }

    /// Progressive Gaussian dropout (StreamLoD-GS technique)
    private func reduceActiveGaussianCount(by fraction: Float) async {
        // Prioritize visible, high-contribution Gaussians
        // Drop background/low-opacity Gaussians first
    }

    /// Drop SH coefficients, keep only DC term (position + base color)
    private func dropSphericalHarmonics() async {
        // Reduce memory by ~75% at cost of view-dependent effects
    }
}
```

### 4.3 Frame Pacing & Smoothness

```swift
/// Frame Pacing Controller - Consistent frame delivery
public actor FramePacingController {

    private var targetFrameTime: TimeInterval = 1.0 / 60.0 // 60 FPS
    private var frameTimeHistory: [TimeInterval] = []
    private let historySize = 30

    /// Invariant INV-MOBILE-003: Frame time variance < 2ms for 95th percentile
    public func recordFrameTime(_ frameTime: TimeInterval) async -> FramePacingAdvice {
        frameTimeHistory.append(frameTime)
        if frameTimeHistory.count > historySize {
            frameTimeHistory.removeFirst()
        }

        let variance = calculateVariance()
        let p95 = calculateP95()

        // If consistently missing target, reduce quality
        if p95 > targetFrameTime * 1.2 {
            return .reduceQuality
        }

        // If variance too high, enable frame smoothing
        if variance > 0.002 { // 2ms
            return .enableSmoothing
        }

        return .maintain
    }

    public enum FramePacingAdvice: Sendable {
        case maintain
        case reduceQuality
        case enableSmoothing
        case increaseQuality
    }
}
```

### 4.4 Battery-Aware Processing

```swift
/// Battery Aware Scheduler - Power-efficient processing
public actor BatteryAwareScheduler {

    #if os(iOS)
    /// Invariant INV-MOBILE-004: Low Power Mode reduces GPU usage by 40%
    public var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    #else
    public var isLowPowerModeEnabled: Bool { false }
    #endif

    /// Invariant INV-MOBILE-005: Background processing suspended when battery < 10%
    public func shouldAllowBackgroundProcessing() async -> Bool {
        #if os(iOS)
        // Check battery level via UIDevice (requires bridging)
        // For now, check Low Power Mode as proxy
        return !isLowPowerModeEnabled
        #else
        return true
        #endif
    }

    /// Adaptive scan quality based on power state
    public func recommendedScanQuality() -> ScanQuality {
        #if os(iOS)
        if isLowPowerModeEnabled {
            return .efficient // Reduced point density, lower SH bands
        }
        #endif
        return .balanced
    }

    public enum ScanQuality: Sendable {
        case maximum    // Full quality, high power
        case balanced   // Good quality, moderate power
        case efficient  // Lower quality, low power
    }
}
```

### 4.5 Touch Response Optimization

```swift
/// Touch Response Optimizer - UI responsiveness
public actor TouchResponseOptimizer {

    /// Invariant INV-MOBILE-006: Touch-to-visual response < 16ms (single frame)
    /// Invariant INV-MOBILE-007: Gesture recognition latency < 32ms

    private let mainThreadQueue = DispatchQueue.main

    /// High-priority touch handling
    public func handleTouch(_ touch: TouchEvent) async {
        // Touch handling must complete within 8ms
        // Heavy processing deferred to background

        await withTaskGroup(of: Void.self) { group in
            // High priority: Visual feedback (main thread)
            group.addTask { @MainActor in
                self.provideHapticFeedback()
                self.updateVisualState()
            }

            // Lower priority: Processing (background)
            group.addTask {
                await self.processGestureAsync()
            }
        }
    }

    @MainActor
    private func provideHapticFeedback() {
        #if os(iOS)
        // UIImpactFeedbackGenerator
        #endif
    }
}

public struct TouchEvent: Sendable {
    let timestamp: TimeInterval
    let location: CGPoint
    let phase: TouchPhase
}

public enum TouchPhase: Sendable {
    case began, moved, ended, cancelled
}
```

### 4.6 Progressive Loading for Large Scans

```swift
/// Progressive Scan Loader - Stream large scans without blocking
public actor ProgressiveScanLoader {

    /// Invariant INV-MOBILE-008: Initial render within 500ms of scan load
    /// Invariant INV-MOBILE-009: Progressive loading step < 50ms each

    public func loadScan(from url: URL) async throws -> AsyncStream<ScanLoadProgress> {
        return AsyncStream { continuation in
            Task {
                // Phase 1: Load coarse LOD (500ms target)
                let coarseLOD = try await loadCoarseLOD(url)
                continuation.yield(.initialRender(coarseLOD))

                // Phase 2: Stream medium LOD chunks
                for await chunk in streamMediumLOD(url) {
                    continuation.yield(.chunk(chunk))
                }

                // Phase 3: Stream fine LOD (background)
                for await chunk in streamFineLOD(url) {
                    continuation.yield(.chunk(chunk))
                }

                continuation.finish()
            }
        }
    }

    public enum ScanLoadProgress: Sendable {
        case initialRender(CoarseLOD)
        case chunk(LODChunk)
        case complete
    }
}
```

---

## PART 5: NEW MOBILE INVARIANTS

Add these invariants to the main implementation plan:

```
## Mobile Platform Invariants (INV-MOBILE-001 to INV-MOBILE-020)

### Thermal Management
- INV-MOBILE-001: Thermal throttle detection < 100ms response time
- INV-MOBILE-002: Quality reduction smooth over 500ms (no jarring transitions)
- INV-MOBILE-003: Critical thermal state triggers 50% quality cap

### Memory Management
- INV-MOBILE-004: Memory warning response < 50ms
- INV-MOBILE-005: Active Gaussian count adaptive to available memory
- INV-MOBILE-006: Progressive cache eviction on memory pressure
- INV-MOBILE-007: Peak memory usage < 80% of device total

### Frame Pacing
- INV-MOBILE-008: Frame time variance < 2ms for 95th percentile
- INV-MOBILE-009: Frame drops < 1% in steady state
- INV-MOBILE-010: Adaptive frame rate (60→30→24) based on load

### Battery Efficiency
- INV-MOBILE-011: Low Power Mode reduces GPU usage by 40%
- INV-MOBILE-012: Background processing suspended at battery < 10%
- INV-MOBILE-013: Idle power draw < 5% of active scanning

### Touch Responsiveness
- INV-MOBILE-014: Touch-to-visual response < 16ms (single frame)
- INV-MOBILE-015: Gesture recognition latency < 32ms
- INV-MOBILE-016: No touch events dropped during heavy processing

### Progressive Loading
- INV-MOBILE-017: Initial scan render within 500ms
- INV-MOBILE-018: Progressive loading step < 50ms each
- INV-MOBILE-019: Visible region prioritized in loading order

### Network Efficiency
- INV-MOBILE-020: Cellular data usage minimized (WiFi-preferred uploads)
```

---

## PART 6: IMPLEMENTATION CHECKLIST

### Phase 1: Critical Build Fixes (Priority: BLOCKING)
- [ ] Add `import CSQLite` to `CounterStore.swift`
- [ ] Fix GLTFExporter JSON encoding with `JSONSerialization`
- [ ] Fix GLTFGaussianSplattingExporter JSON encoding
- [ ] Fix DeterministicScheduler `let` → `var` for SplitMix64
- [ ] Fix WALRecovery access level (make init internal or types public)

### Phase 2: Swift 6.2 Concurrency (Priority: HIGH)
- [ ] Audit all `actor` types for proper isolation
- [ ] Add `@Sendable` to all stored closures in Sendable structs
- [ ] Wrap `OpaquePointer` in `@unchecked Sendable` container
- [ ] Review `@MainActor` usage in test files

### Phase 3: Cross-Platform (Priority: HIGH)
- [ ] Add platform guards for Security.framework APIs
- [ ] Add Linux fallbacks for debugger detection
- [ ] Verify all files use `CSQLite` not `SQLite3`
- [ ] Test on both macOS and Linux CI

### Phase 4: Mobile Optimization (Priority: MEDIUM)
- [ ] Implement ThermalStateHandler
- [ ] Implement MemoryPressureHandler
- [ ] Implement FramePacingController
- [ ] Implement BatteryAwareScheduler
- [ ] Implement ProgressiveScanLoader
- [ ] Add mobile invariants to test suite

### Phase 5: Validation (Priority: HIGH)
- [ ] Full build on macOS with Xcode 16.x
- [ ] Full build on Linux with Swift 6.2.x
- [ ] Run test suite (skip PR5CaptureTests on Linux)
- [ ] Verify no new warnings introduced

---

## PART 7: CI CONFIGURATION UPDATES

### 7.1 macOS CI (Xcode Native)
```yaml
- name: Build and Test (macOS)
  run: |
    xcodebuild -version
    swift build -c release
    swift test
```

### 7.2 Linux CI (Manual Swift Install)
```yaml
- name: Install Swift 6.2.3
  run: |
    # Pre-install ALL dependencies first
    sudo apt-get update
    sudo apt-get install -y \
      binutils git unzip gnupg2 libc6-dev libcurl4-openssl-dev \
      libedit2 libgcc-11-dev libpython3-dev libsqlite3-0 \
      libstdc++-11-dev libxml2-dev libz3-dev pkg-config tzdata \
      zlib1g-dev libsqlite3-dev

    # Download and install Swift
    SWIFT_URL="https://download.swift.org/swift-6.2.3-release/ubuntu2204/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE-ubuntu22.04.tar.gz"
    curl -fsSL "$SWIFT_URL" -o swift.tar.gz
    sudo tar xzf swift.tar.gz -C /opt
    echo "/opt/swift-6.2.3-RELEASE-ubuntu22.04/usr/bin" >> $GITHUB_PATH

- name: Build and Test (Linux)
  run: |
    swift build -c release
    swift test --skip PR5CaptureTests --disable-swift-testing
```

---

## APPENDIX A: QUICK REFERENCE - COMMON FIXES

### A.1 Actor Isolation Quick Fixes
```swift
// Pattern: Warning about calling actor method from nonisolated
// Fix: Add async/await
await actorInstance.method()

// Pattern: Accessing actor property from nonisolated
// Fix: Create async accessor or use nonisolated(unsafe) for immutable
```

### A.2 Sendable Quick Fixes
```swift
// Pattern: Closure not Sendable
// Fix: Add @Sendable
let closure: @Sendable () async -> Void = { ... }

// Pattern: Class property not Sendable
// Fix: Use final class with @unchecked Sendable
@unchecked Sendable final class Container { ... }
```

### A.3 Cross-Platform Quick Fixes
```swift
// Pattern: Platform-specific API
#if os(iOS) || os(macOS)
// Apple implementation
#else
// Linux fallback
#endif

// Pattern: SQLite import
import CSQLite  // ALWAYS use CSQLite, never SQLite3
```

---

## APPENDIX B: FILE-BY-FILE FIX LIST

| File | Issue | Fix |
|------|-------|-----|
| `Core/DeviceAttestation/CounterStore.swift` | Missing CSQLite import | Add `import CSQLite` |
| `Core/FormatBridge/GLTFExporter.swift` | [String: Any] not Encodable | Use JSONSerialization |
| `Core/FormatBridge/GLTFGaussianSplattingExporter.swift` | [String: Any] not Encodable | Use JSONSerialization |
| `Core/Replay/DeterministicScheduler.swift` | Mutating on let constant | Change `let splitMix` to `var splitMix` |
| `Core/Persistence/WALRecovery.swift` | Access level mismatch | Make init internal or types public |
| `Sources/PR5Capture/**/*.swift` | @MainActor + async | Skip tests on Linux CI |

---

**END OF CURSOR v8.3 HYPERION PROMPT**

*Apply these fixes in order. Validate build after each phase.*
