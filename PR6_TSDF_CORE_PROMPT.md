# PR#6: TSDF Core Engine — Implementation Prompt

## Context

You are implementing PR#6 for the Aether3D project — a LiDAR-based 3D scanning iOS app written in Swift (swift-tools-version: 5.9, building with Swift 6.2.3). The project is at `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/`.

**Branch:** `pr6/tsdf-core` (already created, based on main with sceneDepth commit)

PR#6 replaces the current ARMeshAnchor-based 3D reconstruction with a self-built TSDF (Truncated Signed Distance Function) volume fusion pipeline. This is the foundational "ground floor" that PR#7 (Filament rendering), PR#4 (camera abstraction), and PR#5 (quality detection) all depend on.

**Minimum target device:** iPhone 12 Pro (A14 Bionic, 4 GPU cores, 34.1 GB/s memory bandwidth, 4 GB RAM)

---

## Pre-existing Foundation (DO NOT modify these files)

PR#4 has already prepared the depth data pipeline:

1. **`App/Capture/LiDARDepthProcessor.swift`** — Contains:
   - `public actor LiDARDepthProcessor` — actor isolation (validates our TSDFVolume actor pattern)
   - `processSceneDepth(frame: ARFrame)` — extracts CVPixelBuffer depth + confidence from ARFrame (zero-copy, retains CVPixelBuffer reference)
   - `SceneDepthFrame` struct (`@unchecked Sendable`) — holds `depthMap: CVPixelBuffer` (Float32, 256×192), `confidenceMap: CVPixelBuffer?` (UInt8, 256×192, values 0/1/2), `camera: ARCamera` (behind `#if canImport(ARKit)`, provides intrinsics 3×3 `fx,fy,cx,cy` + extrinsics 4×4 `viewMatrix`), `timestamp: TimeInterval`
   - `latestSceneDepth() -> SceneDepthFrame?` — returns most recent frame for real-time consumers (actor-isolated, must be awaited)

2. **`App/Scan/ARCameraPreview.swift`** — Already enables `frameSemantics.insert(.sceneDepth)` with `supportsFrameSemantics` runtime guard

3. **`App/Capture/ARKitSessionManager.swift`** — Same sceneDepth enablement

4. **Core/ algorithm files** (pure Swift, reusable):
   - `Core/Constants/ScanGuidanceConstants.swift` — 65+ SSOT constants in 9 sections with `allSpecs: [AnyConstantSpec]` registration + `validateRelationships()` cross-validation. **Follow this exact SSOT pattern for TSDFConstants.**
   - `Core/Constants/SSOTTypes.swift` — Defines `ThresholdSpec` (Double values with min/max/onExceed/onUnderflow), `SystemConstantSpec` (Int values), `MinLimitSpec`, `FixedConstantSpec`, `AnyConstantSpec` enum (.threshold/.systemConstant/.minLimit/.fixedConstant), `SSOTUnit` enum (.meters/.seconds/.milliseconds/.count/.dimensionless/.ratio/.pixels/.frames/.variance/.percent/.degrees/.degreesPerSecond etc.), `ThresholdCategory` enum (.quality/.performance/.safety/.resource/.motion/.photometric), `ExceedBehavior`/`UnderflowBehavior` enums (.clamp/.reject/.warn). **TSDFConstants MUST reuse these exact types.**
   - `Core/Quality/Performance/ThermalQualityAdapter.swift` — `final class` (NOT actor) with 4 `RenderTier` levels controlling **rendering** quality: nominal(60fps)/fair(60fps)/serious(30fps)/critical(24fps). Also controls LOD, maxTriangles, animation enables. Uses `ScanGuidanceConstants.thermalHysteresisS` (10.0s) for tier change cooldown. Frame budget P95 tracking with auto-degrade.
   - `App/Capture/ThermalMonitor.swift` — Monitors `ProcessInfo.processInfo.thermalState` every 5 seconds, maps to internal ThermalState enum
   - `App/Scan/ScanViewModel.swift` — Observes `ProcessInfo.thermalStateDidChangeNotification` via NotificationCenter, forwards to ThermalQualityAdapter on @MainActor. **PR#6 must add the same forwarding pattern for TSDFVolume thermal handling.**
   - `Core/Evidence/Grid/` — ADR-PR6-005 established deterministic open-addressing index map pattern (stableKeyList + indexMap). Consider this for SpatialHashTable iteration determinism.

   **CRITICAL: Two independent thermal pipelines — same trigger, DIFFERENT strategies**
   ```
   ProcessInfo.thermalStateDidChangeNotification
       ├─→ ThermalQualityAdapter (existing, PR#7 rendering)
       │     STRATEGY: Static tier mapping. System state → tier → done.
       │     P95 frame budget can UPGRADE tier but NEVER auto-downgrades.
       │     .nominal → 60fps render, LOD full, all animations
       │     .fair    → 60fps render, LOD medium, all animations
       │     .serious → 30fps render, LOD low, no flip/ripple/metallic
       │     .critical→ 24fps render, LOD flat, no animations, no haptics
       │
       └─→ TSDFVolume.handleThermalState() (NEW, PR#6 integration)
             STRATEGY: AIMD (Additive Increase, Multiplicative Decrease).
             System state → CEILING. AIMD explores within ceiling.
             GPU overrun → instantly double skip count (multiplicative decrease).
             N good frames → subtract 1 from skip (additive increase).
             Auto-recovers when GPU load drops — BETTER than ThermalQualityAdapter.
             .nominal → ceiling=1  (AIMD range: 1, i.e. every frame)
             .fair    → ceiling=2  (AIMD range: 1-2, recovers to 1 when GPU is cool)
             .serious → ceiling=4  (AIMD range: 1-4, GPU load determines actual)
             .critical→ ceiling=12 (AIMD range: 1-12, absolute floor 5fps)
             Asymmetric hysteresis: 10s to degrade, 5s to recover (user benefits faster).
   ```
   **Why two different strategies?**
   - **Rendering** uses static tiers because users DIRECTLY SEE dropped frames. Conservative = safe.
   - **Integration** uses AIMD because users DON'T see integration rate — they see mesh staleness. Being stuck at 15fps when GPU has recovered = wasted quality. AIMD self-corrects.
   - **This is a genuine innovation over the existing codebase**, applying UX-9's TCP congestion control principle (already proven for meshing) to thermal management.

---

## Architecture

### Two-Layer Design

```
Core/ (Pure Swift, no Apple frameworks, Linux-compilable) — 16 files
├── Constants/
│   └── MetalConstants.swift               — Shared Metal config (inflightBufferCount, threadgroup)
├── TSDF/
│   ├── TSDFMathTypes.swift                — Cross-platform math: TSDFFloat3, TSDFMatrix3x3/4x4 (Section 0.1)
│   ├── VoxelTypes.swift                   — SDFStorage: Float16 on Apple, UInt16 IEEE 754 on Linux (Section 0.2)
│   ├── BlockIndex.swift                   — Block coordinate type + Nießner hash + Hashable (Section 0.3)
│   ├── TSDFTypes.swift                    — MemoryPressureLevel enum + IntegrationRecord.empty (Section 0.4)
│   ├── TSDFConstants.swift                — SSOT constants (77 registered, cross-validated)
│   ├── VoxelBlock.swift                   — Voxel (8 bytes, SDFStorage) + VoxelBlock (4 KB) + .empty sentinel
│   ├── ManagedVoxelStorage.swift          — Stable-address UnsafeMutablePointer storage (Section 0.7)
│   ├── VoxelBlockPool.swift               — Pre-allocated pool wrapping ManagedVoxelStorage + free-list
│   ├── SpatialHashTable.swift             — Compact metadata array + separate block storage
│   ├── TSDFIntegrationBackend.swift       — Protocol + VoxelBlockAccessor + DepthDataProvider (Section 0.6)
│   ├── TSDFVolume.swift                   — Actor: gates + AIMD + ring buffer + backend dispatch
│   ├── AdaptiveResolution.swift           — Near/mid/far selection + distance/angle/confidence weight (Section 0.9)
│   ├── MarchingCubes.swift                — Isosurface extraction (CPU, incremental, neighbor-dirty)
│   ├── MeshOutput.swift                   — MeshVertex, MeshTriangle (index-based), MeshOutput (Section 0.5)
│   │   (IntegrationRecord is in TSDFTypes.swift — no separate file)
│   └── ArrayDepthData.swift               — DepthDataProvider for CPU backend + tests (Section 0.6)

App/ (Apple-platform, Metal compute) — 4 files
├── TSDF/
│   ├── MetalTSDFIntegrator.swift          — TSDFIntegrationBackend impl + CVMetalTextureCache + 2-CB sync
│   ├── TSDFShaders.metal                  — 2 GPU kernels (allocation + integration/carving)
│   ├── TSDFShaderTypes.h                  — Shared C header: TSDFVoxel, GPUBlockIndex, BlockEntry, TSDFParams
│   └── MetalBufferPool.swift              — Triple-buffered per-frame data + semaphore management
```

### Data Flow (60fps input → 3 decoupled pipelines)

```
ARFrame.sceneDepth (CVPixelBuffer Float32, 256×192, 60fps)
    + ARCamera.intrinsics (fx,fy,cx,cy) + ARCamera.transform (4×4)
    ↓
[App/ layer: ScanViewModel] Construct IntegrationInput (pure numerics) from SceneDepthFrame
    + Pass SceneDepthFrame to MetalTSDFIntegrator (CVPixelBuffer → MTLTexture zero-copy)
    ↓
[Core/ layer: TSDFVolume.integrate(input: IntegrationInput)]
[GATE 1] input.trackingState == 2?  (Guardrail #9: skip if .limited/.notAvailable)
[GATE 2] Pose teleport < 10cm/frame?  (Guardrail #10: skip if teleport detected)
[GATE 3] Pose jitter > 1mm translation OR > 0.002rad rotation?  (UX-7: skip if camera nearly still)
[GATE 4] Thermal AIMD: frameCount % currentIntegrationSkip != 0?  (Guardrail #2: AIMD-managed skip)
[GATE 5] Valid pixel ratio > 30%?  (Guardrail #15: skip if mostly invalid, checked after GPU pass)
    ↓  (all gates passed → this frame will be integrated)
[Optional: EP-1 Bilateral depth filter — GPU, ~0.3ms]
    ↓
[CVMetalTextureCache] Zero-copy wrap CVPixelBuffer → MTLTexture (no memcpy)
    ↓
[Metal Compute — Kernel 1: Block Allocation]
    For each depth pixel (u,v) in 256×192:
        1. depth = depthTexture.read(u,v).r  (meters, Float32)
        2. IF depth < 0.1m OR depth > 5.0m → skip pixel
        3. confidence = confidenceTexture.read(u,v).r  (0/1/2)
        4. IF confidence == 0 → skip pixel (too noisy, σ > 5cm)
        5. p_cam = K_inv * [u, v, 1] * depth  (camera space, 3D)
        6. p_world = T_cam_to_world * p_cam  (world space, 3D)
        7. voxelSize = selectVoxelSize(depth)  (0.5cm / 1.0cm / 2.0cm)
        8. blockIdx = floor(p_world / (voxelSize * 8))
        9. Atomic append blockIdx to allocation list
    ↓
[CPU — Actor: allocate new blocks from VoxelBlockPool free-list]
    ↓
[Metal Compute — Kernel 2: TSDF Integration + Space Carving]
    For each allocated voxel in truncation band τ = 3 × voxelSize:
        1. Project voxel center → camera pixel (u', v')
        2. IF u',v' outside [0,255]×[0,191] → skip
        3. measured_depth = depthTexture.sample(u', v')  (bilinear)
        4. sdf = measured_depth - voxel_depth_along_ray
        5. IF sdf > τ → skip (too far in front of surface)
        6. IF sdf < -τ → space carving: decay weight by carvingDecayRate
        7. ELSE (within truncation band):
            a. w_conf = confidenceWeight[confidence]  (0.1 / 0.5 / 1.0)
            b. w_angle = max(0.1, dot(viewRay, normalEstimate))  (grazing rejection)
            c. w_dist = 1.0 / (1.0 + 0.1 * depth²)  (distance decay)
            d. w_obs = w_conf * w_angle * w_dist
            e. sdf_clamped = clamp(sdf / τ, -1.0, +1.0)  (normalized)
            f. tsdf_new = (tsdf_old * w_old + sdf_clamped * w_obs) / (w_old + w_obs)
            g. w_new = min(w_old + w_obs, W_MAX)
            h. block.integrationGeneration += 1
    ↓
    Integration complete. Block integrationGeneration incremented.

═══ PIPELINE SPLIT: Integration and Meshing are DECOUPLED ═══

[CPU Swift — Incremental Marching Cubes]  (10-20 Hz, NOT every frame)
    Trigger: meshExtractionTimer fires (UX-3: every 100ms target)
    Skip if: camera moving fast (UX-11: > 0.5 m/s)
    Budget: congestion-controlled block count (UX-9: 50-250 blocks)
    Priority queue: blocks where integrationGeneration > meshGeneration
    For each dirty VoxelBlock + 6 face-adjacent neighbors:
        Extract triangles where SDF crosses zero
        Reject degenerate triangles (area < 1e-8 m², ratio > 100:1)
        SDF-gradient normals (UX-5) + cross-block averaging (UX-10)
        Vertex quantization to 0.5mm grid (UX-2)
    Write to BACK mesh buffer (UX-4)
    Atomic swap front↔back on completion
    ↓

═══ PIPELINE SPLIT: Meshing and Rendering are DECOUPLED ═══

[Rendering — 60fps ALWAYS, reads FRONT mesh buffer]  (UX-4)
    Never waits for meshing. Draws whatever mesh was last swapped in.
    Per-block alpha from progressive reveal (UX-8)
    ↓
Mesh → PR#7 Filament Renderer
Mesh → PR#5 Evidence Coverage Calculator
```

---

## Cross-Platform Type Foundation

These types form the **base layer** that ALL subsequent code depends on. Implement them FIRST.

### 0.1. TSDFMathTypes (`Core/TSDF/TSDFMathTypes.swift`)

```swift
/// Cross-platform math types for TSDF pipeline.
/// Apple: zero-overhead typealias to simd (hardware SIMD instructions).
/// Linux: minimal hand-written types implementing ONLY the operations TSDF uses.
///
/// Follows Core/Quality/ pattern: 8 files already use #if canImport(simd) successfully.
/// ForbiddenPatternLint only bans import simd in Core/Evidence/, NOT Core/TSDF/.
///
/// CRITICAL: Both platforms must provide the SAME API surface:
///   - TSDFFloat3: +, -, *(scalar), /(scalar), .length(), .normalized(), .zero
///   - Free functions: dot(), cross(), normalize(), mix(_:_:t:), round()
///   - TSDFMatrix3x3: * operator (matrix × vector)
///   - TSDFMatrix4x4: tsdTranslation(), tsdTransform()
///   - Cross-platform identity: .tsdIdentity4x4, .tsdIdentity3x3

#if canImport(simd)
import simd
public typealias TSDFFloat3 = SIMD3<Float>
public typealias TSDFFloat4 = SIMD4<Float>
public typealias TSDFMatrix3x3 = simd_float3x3
public typealias TSDFMatrix4x4 = simd_float4x4

// ── Apple compatibility extensions ──
// simd types lack some API that our cross-platform code needs.

extension SIMD3 where Scalar == Float {
    /// simd_length() is a free function; we add .length() for cross-platform API parity.
    @inlinable public func length() -> Float { simd_length(self) }
    @inlinable public func normalized() -> Self { simd_normalize(self) }
}

/// Cross-platform identity constants (simd_float4x4 has no static .identity member)
extension simd_float4x4 {
    public static let tsdIdentity4x4 = matrix_identity_float4x4
}
extension simd_float3x3 {
    public static let tsdIdentity3x3 = simd_float3x3(
        SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0), SIMD3<Float>(0,0,1))
}

/// Cross-platform mix() with labeled scalar `t:` (simd_mix uses vector t, unlabeled)
@inlinable public func mix(_ a: TSDFFloat3, _ b: TSDFFloat3, t: Float) -> TSDFFloat3 {
    simd_mix(a, b, TSDFFloat3(repeating: t))
}

/// Cross-platform round() for TSDFFloat3 (UX-2 vertex quantization)
@inlinable public func round(_ v: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(v.x.rounded(), v.y.rounded(), v.z.rounded())
}

/// Extract translation from 4×4 transform
@inlinable public func tsdTranslation(_ m: TSDFMatrix4x4) -> TSDFFloat3 {
    TSDFFloat3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
}
/// Matrix × vector (homogeneous, returns 3D)
@inlinable public func tsdTransform(_ m: TSDFMatrix4x4, _ v: TSDFFloat3) -> TSDFFloat3 {
    let r = m * SIMD4<Float>(v, 1.0)
    return TSDFFloat3(r.x, r.y, r.z) / r.w
}

#else
// ── Linux fallback: minimal implementations ──

public struct TSDFFloat3: Sendable, Codable, Equatable, Hashable {
    public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public init(repeating v: Float) { x = v; y = v; z = v }

    @inlinable public static func +(l: Self, r: Self) -> Self { Self(l.x+r.x, l.y+r.y, l.z+r.z) }
    @inlinable public static func -(l: Self, r: Self) -> Self { Self(l.x-r.x, l.y-r.y, l.z-r.z) }
    @inlinable public static func *(l: Self, s: Float) -> Self { Self(l.x*s, l.y*s, l.z*s) }
    @inlinable public static func *(s: Float, r: Self) -> Self { Self(s*r.x, s*r.y, s*r.z) }  // Commutative
    @inlinable public static func /(l: Self, s: Float) -> Self { Self(l.x/s, l.y/s, l.z/s) }

    @inlinable public func length() -> Float { (x*x + y*y + z*z).squareRoot() }
    @inlinable public func normalized() -> Self { let l = length(); return l > 0 ? self / l : .zero }
    public static let zero = Self(0, 0, 0)
}
@inlinable public func dot(_ a: TSDFFloat3, _ b: TSDFFloat3) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
@inlinable public func cross(_ a: TSDFFloat3, _ b: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
}
@inlinable public func normalize(_ v: TSDFFloat3) -> TSDFFloat3 { v.normalized() }
@inlinable public func mix(_ a: TSDFFloat3, _ b: TSDFFloat3, t: Float) -> TSDFFloat3 {
    a * (1 - t) + b * t
}
@inlinable public func round(_ v: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(v.x.rounded(), v.y.rounded(), v.z.rounded())
}

public struct TSDFFloat4: Sendable, Codable, Equatable {
    public var x, y, z, w: Float
    public init(_ xyz: TSDFFloat3, _ w: Float) { x = xyz.x; y = xyz.y; z = xyz.z; self.w = w }
}

public struct TSDFMatrix3x3: Sendable, Codable, Equatable {
    /// Column-major storage (matches simd_float3x3 layout)
    public var c0, c1, c2: TSDFFloat3
    public init(c0: TSDFFloat3, c1: TSDFFloat3, c2: TSDFFloat3) { self.c0 = c0; self.c1 = c1; self.c2 = c2 }

    /// Matrix × vector
    @inlinable public func multiply(_ v: TSDFFloat3) -> TSDFFloat3 {
        TSDFFloat3(dot(TSDFFloat3(c0.x, c1.x, c2.x), v),
                   dot(TSDFFloat3(c0.y, c1.y, c2.y), v),
                   dot(TSDFFloat3(c0.z, c1.z, c2.z), v))
    }

    /// Cross-platform identity
    public static let tsdIdentity3x3 = TSDFMatrix3x3(
        c0: TSDFFloat3(1,0,0), c1: TSDFFloat3(0,1,0), c2: TSDFFloat3(0,0,1))
}

/// Operator: matrix × vector (cross-platform parity with simd_float3x3 * SIMD3<Float>)
@inlinable public func *(m: TSDFMatrix3x3, v: TSDFFloat3) -> TSDFFloat3 { m.multiply(v) }

public struct TSDFMatrix4x4: Sendable, Codable, Equatable {
    public var c0, c1, c2, c3: TSDFFloat4
    /// Cross-platform identity
    public static let tsdIdentity4x4 = TSDFMatrix4x4(
        c0: TSDFFloat4(TSDFFloat3(1,0,0),0), c1: TSDFFloat4(TSDFFloat3(0,1,0),0),
        c2: TSDFFloat4(TSDFFloat3(0,0,1),0), c3: TSDFFloat4(TSDFFloat3(0,0,0),1))
}

@inlinable public func tsdTranslation(_ m: TSDFMatrix4x4) -> TSDFFloat3 {
    TSDFFloat3(m.c3.x, m.c3.y, m.c3.z)
}
@inlinable public func tsdTransform(_ m: TSDFMatrix4x4, _ v: TSDFFloat3) -> TSDFFloat3 {
    let r = TSDFFloat4(
        TSDFFloat3(m.c0.x*v.x + m.c1.x*v.y + m.c2.x*v.z + m.c3.x,
                   m.c0.y*v.x + m.c1.y*v.y + m.c2.y*v.z + m.c3.y,
                   m.c0.z*v.x + m.c1.z*v.y + m.c2.z*v.z + m.c3.z),
        m.c0.w*v.x + m.c1.w*v.y + m.c2.w*v.z + m.c3.w)
    return TSDFFloat3(r.x/r.w, r.y/r.w, r.z/r.w)
}
#endif
```

### 0.2. SDFStorage (`Core/TSDF/VoxelTypes.swift`)

```swift
/// Cross-platform SDF storage type — 2 bytes, IEEE 754 half-precision.
/// Apple: typealias to Float16 (native ALU, 2× throughput on A14+).
/// Linux: UInt16 wrapper with IEEE 754 encode/decode (bit-identical across platforms).
///
/// CRITICAL: Both platforms produce the SAME bit pattern for the same Float value.
/// This guarantees cross-platform determinism for serialization and testing.

#if canImport(simd) || arch(arm64)
public typealias SDFStorage = Float16
#else
public struct SDFStorage: Sendable, Codable, Equatable, Hashable {
    public var bitPattern: UInt16

    public init(_ value: Float) {
        // IEEE 754 single→half conversion
        let bits = value.bitPattern
        let sign = (bits >> 16) & 0x8000
        let exp = Int((bits >> 23) & 0xFF) - 127
        let frac = bits & 0x7FFFFF
        if exp > 15 { bitPattern = UInt16(sign | 0x7C00) }       // overflow → inf
        else if exp < -14 { bitPattern = UInt16(sign) }           // underflow → 0
        else { bitPattern = UInt16(sign | UInt32((exp + 15) << 10) | (frac >> 13)) }
    }

    public var floatValue: Float {
        let sign = UInt32(bitPattern & 0x8000) << 16
        let exp = UInt32(bitPattern >> 10) & 0x1F
        let frac = UInt32(bitPattern & 0x3FF)
        if exp == 0 { return Float(bitPattern: sign) }            // zero/subnormal
        if exp == 31 { return Float(bitPattern: sign | 0x7F800000) } // inf/nan
        return Float(bitPattern: sign | ((exp + 112) << 23) | (frac << 13))
    }

    public init(floatLiteral value: Float) { self.init(value) }
}
#endif
```

### 0.3. BlockIndex (`Core/TSDF/BlockIndex.swift`)

```swift
/// Block coordinate in voxel grid space.
/// 12 bytes: 3 × Int32. Packed for minimal memory in hash table entries.
///
/// NOT SIMD3<Int32> — SIMD3 is 16 bytes (4-byte aligned with padding).
/// We need exactly 12 bytes for GPU buffer compatibility (Metal int3 is also 16 bytes,
/// but we pad explicitly in the Metal struct to control layout).
///
/// Implements Hashable using Nießner 2013 primes for SpatialHashTable,
/// AND Swift's standard Hashable for use as Dictionary key.
public struct BlockIndex: Sendable, Codable, Equatable, Hashable {
    public var x: Int32
    public var y: Int32
    public var z: Int32

    public init(_ x: Int32, _ y: Int32, _ z: Int32) {
        self.x = x; self.y = y; self.z = z
    }

    /// Nießner 2013 spatial hash — used by SpatialHashTable for slot selection.
    /// NOT used for Swift Hashable (Swift uses its own SipHash via Hasher).
    /// These two hash functions serve different purposes:
    ///   - niessnerHash: deterministic slot index for open-addressing
    ///   - Hashable.hash(into:): Swift dictionary/set operations
    @inlinable
    public func niessnerHash(tableSize: Int) -> Int {
        let h = Int(x) &* 73856093 ^ Int(y) &* 19349669 ^ Int(z) &* 83492791
        return abs(h) % tableSize
    }

    // Hashable conformance (Swift standard, for Dictionary<BlockIndex, _>)
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x); hasher.combine(y); hasher.combine(z)
    }

    /// 6 face-adjacent neighbors
    public static let faceNeighborOffsets: [BlockIndex] = [
        BlockIndex(1,0,0), BlockIndex(-1,0,0),
        BlockIndex(0,1,0), BlockIndex(0,-1,0),
        BlockIndex(0,0,1), BlockIndex(0,0,-1)
    ]

    @inlinable
    public static func +(lhs: BlockIndex, rhs: BlockIndex) -> BlockIndex {
        BlockIndex(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
}
```

### 0.4. Shared Types (`Core/TSDF/TSDFTypes.swift`)

```swift
/// Memory pressure levels for tiered eviction response.
/// Triggered by UIApplication.didReceiveMemoryWarningNotification (App/ layer),
/// forwarded to TSDFVolume.handleMemoryPressure(level:).
public enum MemoryPressureLevel: Int, Sendable {
    /// Level 1: OS warning. Evict stale blocks (lastObserved > 30s).
    case warning = 1
    /// Level 2: Critical. Evict all blocks > 3m from camera, reduce maxBlocks by 50%.
    case critical = 2
    /// Level 3: Terminal. Evict all blocks except nearest 1m radius.
    case terminal = 3
}

/// Ring buffer entry for integration history + keyframe marking.
/// Core/ only — all types are cross-platform (TSDFMatrix, TimeInterval, Int32, Bool, UInt32).
/// Used by: TSDFVolume (ring buffer), PR#7 (projective texturing keyframe poses), cloud upload.
public struct IntegrationRecord: Sendable {
    public let timestamp: TimeInterval
    public let cameraPose: TSDFMatrix4x4       // Camera-to-world transform
    public let intrinsics: TSDFMatrix3x3        // Camera intrinsics (for projective texturing)
    public let affectedBlockIndices: [Int32]    // For loop closure
    public let isKeyframe: Bool                 // Keyframe flag
    public let keyframeId: UInt32?              // Non-nil if isKeyframe==true

    public init(timestamp: TimeInterval, cameraPose: TSDFMatrix4x4, intrinsics: TSDFMatrix3x3,
                affectedBlockIndices: [Int32], isKeyframe: Bool, keyframeId: UInt32?) {
        self.timestamp = timestamp; self.cameraPose = cameraPose; self.intrinsics = intrinsics
        self.affectedBlockIndices = affectedBlockIndices; self.isKeyframe = isKeyframe; self.keyframeId = keyframeId
    }

    /// Empty sentinel for ring buffer initialization.
    /// Uses cross-platform identity constants from TSDFMathTypes (Section 0.1).
    public static let empty = IntegrationRecord(
        timestamp: 0,
        cameraPose: .tsdIdentity4x4,
        intrinsics: .tsdIdentity3x3,
        affectedBlockIndices: [],
        isKeyframe: false,
        keyframeId: nil
    )
}
```

### 0.5. MeshOutput Types (`Core/TSDF/MeshOutput.swift`)

```swift
/// Per-vertex data extracted by Marching Cubes.
/// 32 bytes per vertex (naturally aligned for GPU vertex buffer).
public struct MeshVertex: Sendable {
    public var position: TSDFFloat3    // World-space position (12 bytes)
    public var normal: TSDFFloat3      // SDF-gradient normal (12 bytes)
    public var alpha: Float            // Fade-in from UX-8: 0→1 (4 bytes)
    public var quality: Float          // Block convergence: weight/maxWeight 0→1 (4 bytes)

    public init(position: TSDFFloat3, normal: TSDFFloat3, alpha: Float, quality: Float) {
        self.position = position; self.normal = normal
        self.alpha = alpha; self.quality = quality
    }
}

/// Single triangle — 3 vertex indices into MeshOutput.vertices array.
/// Index-based (not embedded vertices) to enable vertex sharing across adjacent triangles,
/// reducing memory by ~50% vs storing 3 full MeshVertex per triangle.
public struct MeshTriangle: Sendable {
    public var i0: UInt32  // Index into vertices array
    public var i1: UInt32
    public var i2: UInt32

    public init(_ i0: UInt32, _ i1: UInt32, _ i2: UInt32) {
        self.i0 = i0; self.i1 = i1; self.i2 = i2
    }
}

/// Complete mesh output from one extraction cycle.
/// Double-buffered: extraction writes to back, renderer reads front, swap atomically.
public struct MeshOutput: Sendable {
    public var vertices: ContiguousArray<MeshVertex>
    public var triangles: ContiguousArray<MeshTriangle>
    public var triangleCount: Int { triangles.count }
    public var vertexCount: Int { vertices.count }

    /// Metadata for consumers
    public var extractionTimestamp: TimeInterval = 0
    public var dirtyBlocksRemaining: Int = 0

    public init() {
        vertices = ContiguousArray()
        triangles = ContiguousArray()
    }

    /// Check degenerate triangle by vertex positions (for rejection)
    public func isDegenerate(triangle t: MeshTriangle) -> Bool {
        let v0 = vertices[Int(t.i0)].position
        let v1 = vertices[Int(t.i1)].position
        let v2 = vertices[Int(t.i2)].position
        let area = cross(v1 - v0, v2 - v0).length() * 0.5
        if area < TSDFConstants.minTriangleArea { return true }
        let edges = [(v1 - v0).length(), (v2 - v1).length(), (v0 - v2).length()]
        let maxEdge = edges.max()!
        let minEdge = max(edges.min()!, 1e-10)
        return maxEdge / minEdge > TSDFConstants.maxTriangleAspectRatio
    }
}
```

### 0.6. TSDFIntegrationBackend Protocol (`Core/TSDF/TSDFIntegrationBackend.swift`)

```swift
/// Abstraction over depth-to-voxel integration computation.
///
/// TSDFVolume (Core/ actor) handles: gates, AIMD thermal, ring buffer, keyframe marking.
/// Backend handles: actual depth pixel processing and voxel SDF/weight updates.
///
/// Three implementations:
///   1. CPUIntegrationBackend (Core/) — pure Swift, pixel-by-pixel. For tests + Mac Catalyst fallback.
///   2. MetalIntegrationBackend (App/) — GPU compute shaders. Production path on iOS.
///   3. MockIntegrationBackend (Tests/) — returns preset results. For unit testing gates/AIMD.
///
/// This follows the existing TimeProvider protocol pattern in Core/Infrastructure/.
public protocol TSDFIntegrationBackend: Sendable {
    /// Process one frame's depth data into the voxel volume.
    ///
    /// - Parameters:
    ///   - input: Camera matrices and metadata (from TSDFVolume gate chain)
    ///   - depthData: Pixel-level depth and confidence access
    ///   - volume: Read/write access to voxel block storage
    ///   - activeBlocks: Block indices to update (from TSDFVolume allocation)
    /// - Returns: Per-frame statistics for AIMD thermal feedback
    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [BlockIndex]
    ) async -> IntegrationStats
}

/// Read/write access to voxel block storage.
/// Abstracts over ManagedVoxelStorage — both CPU and GPU backends use this.
public protocol VoxelBlockAccessor: Sendable {
    func readBlock(at poolIndex: Int) -> VoxelBlock
    func writeBlock(at poolIndex: Int, _ block: VoxelBlock)
    /// Stable base address for Metal makeBuffer(bytesNoCopy:).
    /// CPU backend ignores this. GPU backend uses it for zero-copy binding.
    var baseAddress: UnsafeMutableRawPointer { get }
    var byteCount: Int { get }
    var capacity: Int { get }
}

/// Depth pixel data access — abstraction over CVPixelBuffer (App/) and [Float] (Core/Tests/).
public protocol DepthDataProvider: Sendable {
    var width: Int { get }     // 256
    var height: Int { get }    // 192
    func depthAt(x: Int, y: Int) -> Float       // Meters, NaN if invalid
    func confidenceAt(x: Int, y: Int) -> UInt8   // 0=low, 1=mid, 2=high
}

/// Concrete implementation for CPU backend and tests.
/// App/ layer constructs this by copying CVPixelBuffer contents.
public struct ArrayDepthData: DepthDataProvider, Sendable {
    public let width: Int
    public let height: Int
    private let depths: [Float]       // row-major, width × height
    private let confidences: [UInt8]  // row-major, width × height

    public init(width: Int, height: Int, depths: [Float], confidences: [UInt8]) {
        precondition(depths.count == width * height)
        precondition(confidences.count == width * height)
        self.width = width; self.height = height
        self.depths = depths; self.confidences = confidences
    }

    public func depthAt(x: Int, y: Int) -> Float { depths[y * width + x] }
    public func confidenceAt(x: Int, y: Int) -> UInt8 { confidences[y * width + x] }
}
```

### 0.7. ManagedVoxelStorage (`Core/TSDF/ManagedVoxelStorage.swift`)

```swift
/// Reference-semantics voxel block storage with stable base address.
///
/// WHY NOT ContiguousArray<VoxelBlock>:
///   ContiguousArray is a value type. Swift's CoW may relocate its buffer on mutation.
///   Metal's makeBuffer(bytesNoCopy:) requires a pointer that NEVER moves.
///   A single CoW relocation = GPU reads stale/freed memory = crash or corruption.
///
/// WHY NOT ManagedBuffer:
///   ManagedBuffer's API is complex and designed for COW reference types.
///   We need simpler semantics: allocate once, never move, deallocate at end.
///
/// This is a standard pattern in the codebase (38 files use UnsafeMutableBufferPointer).
/// @unchecked Sendable because TSDFVolume actor provides all synchronization.
public final class ManagedVoxelStorage: @unchecked Sendable, VoxelBlockAccessor {
    private let pointer: UnsafeMutablePointer<VoxelBlock>
    public let capacity: Int

    public init(capacity: Int = TSDFConstants.maxTotalVoxelBlocks) {
        self.capacity = capacity
        pointer = .allocate(capacity: capacity)
        pointer.initialize(repeating: VoxelBlock.empty, count: capacity)
    }

    deinit {
        pointer.deinitialize(count: capacity)
        pointer.deallocate()
    }

    // ── VoxelBlockAccessor conformance ──

    public var baseAddress: UnsafeMutableRawPointer { UnsafeMutableRawPointer(pointer) }
    public var byteCount: Int { capacity * MemoryLayout<VoxelBlock>.stride }

    @inlinable
    public func readBlock(at poolIndex: Int) -> VoxelBlock {
        precondition(poolIndex >= 0 && poolIndex < capacity)
        return pointer[poolIndex]
    }

    @inlinable
    public func writeBlock(at poolIndex: Int, _ block: VoxelBlock) {
        precondition(poolIndex >= 0 && poolIndex < capacity)
        pointer[poolIndex] = block
    }

    public subscript(index: Int) -> VoxelBlock {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
}
```

### 0.8. Metal Struct Definitions (`App/TSDF/TSDFShaderTypes.h`)

```c
/// Shared header between Swift and Metal — defines GPU-side struct layouts.
/// Include this in both TSDFShaders.metal and bridge via Swift.
///
/// CRITICAL ALIGNMENT RULES:
///   - Metal float3 is 16 bytes (4-byte aligned, with 4 bytes padding)
///   - Metal int3 is 16 bytes (same padding)
///   - Must match Swift struct layouts EXACTLY or data corruption occurs

#ifndef TSDFShaderTypes_h
#define TSDFShaderTypes_h

#include <simd/simd.h>

/// GPU-side voxel — must match Swift Voxel struct layout (8 bytes)
struct TSDFVoxel {
    half sdf;              // 2 bytes — SDFStorage on Swift side
    uint8_t weight;        // 1 byte — NOT half, UInt8
    uint8_t confidence;    // 1 byte
    uint8_t reserved[4];   // 4 bytes
};
// static_assert(sizeof(TSDFVoxel) == 8, "Voxel must be 8 bytes");

/// GPU-side block index — 16 bytes (padded from Swift's 12-byte BlockIndex)
struct GPUBlockIndex {
    int32_t x;
    int32_t y;
    int32_t z;
    int32_t _pad;  // Explicit padding to match Metal int3 alignment
};

/// Active block entry for integration kernel dispatch
struct BlockEntry {
    struct GPUBlockIndex blockIndex;
    int32_t poolOffset;      // Index into voxel buffer (pool index × 512)
    float voxelSize;         // Adaptive: 0.005 / 0.01 / 0.02
    float blockWorldOriginX; // Pre-computed world-space origin
    float blockWorldOriginY;
    float blockWorldOriginZ;
    int32_t _pad2;           // Align to 32 bytes
};

/// Per-frame parameters — all constants the GPU kernels need
struct TSDFParams {
    // Depth filtering
    float depthMin;
    float depthMax;
    int skipLowConfidence;   // bool as int for Metal
    int _pad0;

    // Adaptive resolution thresholds
    float depthNearThreshold;
    float depthFarThreshold;
    float voxelSizeNear;
    float voxelSizeMid;
    float voxelSizeFar;

    // Truncation
    float truncationMultiplier;
    float truncationMinimum;

    // Fusion weights
    float confidenceWeights[3];  // [low, mid, high] = [0.1, 0.5, 1.0]
    float distanceDecayAlpha;
    float viewingAngleFloor;
    uint8_t weightMax;
    uint8_t carvingDecayRate;
    uint8_t _pad1[2];

    // Block geometry
    int blockSize;           // 8

    // Limits
    int maxOutputBlocks;     // Allocation kernel output cap
};

#endif /* TSDFShaderTypes_h */
```

### 0.9. AdaptiveResolution (`Core/TSDF/AdaptiveResolution.swift`)

```swift
/// Depth-to-voxel-size selection and distance-dependent integration weight.
///
/// Three resolution tiers based on LiDAR noise model:
///   Near (<1m): 5mm voxels, σ_integrated ≈ 0.8mm → 6× margin
///   Mid (1-3m): 10mm voxels, σ_integrated ≈ 3-18mm → adequate
///   Far (>3m): 20mm voxels, σ_integrated ≈ 18mm → structural detail only
public enum AdaptiveResolution {

    /// Select voxel size based on measured depth (meters).
    @inlinable
    public static func voxelSize(forDepth depth: Float) -> Float {
        if depth < TSDFConstants.depthNearThreshold { return TSDFConstants.voxelSizeNear }
        if depth < TSDFConstants.depthFarThreshold { return TSDFConstants.voxelSizeMid }
        return TSDFConstants.voxelSizeFar
    }

    /// Compute truncation distance for a given voxel size.
    @inlinable
    public static func truncationDistance(voxelSize: Float) -> Float {
        max(TSDFConstants.truncationMultiplier * voxelSize, TSDFConstants.truncationMinimum)
    }

    /// Distance-dependent observation weight: w = 1 / (1 + α × d²).
    @inlinable
    public static func distanceWeight(depth: Float) -> Float {
        1.0 / (1.0 + TSDFConstants.distanceDecayAlpha * depth * depth)
    }

    /// Confidence-to-weight mapping.
    @inlinable
    public static func confidenceWeight(level: UInt8) -> Float {
        switch level {
        case 0: return TSDFConstants.confidenceWeightLow
        case 1: return TSDFConstants.confidenceWeightMid
        default: return TSDFConstants.confidenceWeightHigh
        }
    }

    /// Viewing angle weight: max(floor, |dot(viewRay, normal)|).
    @inlinable
    public static func viewingAngleWeight(viewRay: TSDFFloat3, normal: TSDFFloat3) -> Float {
        max(TSDFConstants.viewingAngleWeightFloor, abs(dot(viewRay, normal)))
    }

    /// Compute world-space block index from a world position and voxel size.
    @inlinable
    public static func blockIndex(worldPosition: TSDFFloat3, voxelSize: Float) -> BlockIndex {
        let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
        return BlockIndex(
            Int32(floor(worldPosition.x / blockWorldSize)),
            Int32(floor(worldPosition.y / blockWorldSize)),
            Int32(floor(worldPosition.z / blockWorldSize))
        )
    }
}
```

---

## Implementation Specifications

### 1. VoxelBlock (`Core/TSDF/VoxelBlock.swift`)

```swift
/// Single voxel — 8 bytes, GPU cache-line friendly
/// 4 bytes active + 4 bytes reserved for future color fusion (RGB8 + pad)
///
/// SDF: SDFStorage (see Section 0.2) — Float16 on Apple (native ALU, 2× throughput on A14+),
///   UInt16 IEEE 754 wrapper on Linux. Bit-identical across platforms.
///   At typical SDF range [-0.05m, +0.05m], precision is ~0.05mm (sufficient).
/// Weight: UInt8 — clamped to W_MAX=64. At W_MAX=64, each new observation has
///   1.5% influence, balancing convergence quality with adaptivity to ARKit pose corrections.
///   (KinectFusion uses 128 but targets static scenes; nvblox uses 5.0 for dynamic; 64 is optimal for mobile scanning.)
/// Confidence: UInt8 — stores max observed ARKit confidence (0=low, 1=mid, 2=high)
/// Reserved: 4 bytes — future: RGB8 color (3 bytes) + 1 byte flags
///
/// METAL ALIGNMENT: sdf is `half` (2 bytes) on GPU side. weight is `uint8_t` (NOT `half`).
/// The GPU kernel MUST read weight as uint8_t and cast to float for arithmetic.
/// Reading weight as `half` would reinterpret the UInt8 bit pattern → DATA CORRUPTION.
public struct Voxel: Sendable {
    public var sdf: SDFStorage     // Normalized signed distance [-1.0, +1.0], scaled by truncation distance
    public var weight: UInt8       // Accumulated observation weight, clamped to W_MAX=64
    public var confidence: UInt8   // Max observed confidence (0=low, 1=mid, 2=high)
    public var reserved: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)  // Future: RGB8 + flags

    public static let empty = Voxel(sdf: SDFStorage(1.0), weight: 0, confidence: 0)

    public init(sdf: SDFStorage, weight: UInt8, confidence: UInt8) {
        self.sdf = sdf; self.weight = weight; self.confidence = confidence
    }
}
// sizeof(Voxel) = 8 bytes, naturally aligned

/// 8×8×8 voxel block — the fundamental storage unit
/// Memory: 8 bytes × 512 voxels = 4096 bytes (4 KB) per block
/// Fits in L1 cache line on Apple GPU (64 KB L1 per EU)
///
/// Generation counters replace boolean isDirty to prevent lost-update race:
///   dirty iff integrationGeneration > meshGeneration
///   staleness = integrationGeneration - meshGeneration → natural priority score
public struct VoxelBlock: Sendable {
    public static let size: Int = 8  // 8×8×8 = 512 voxels
    public var voxels: ContiguousArray<Voxel>  // 512 voxels, initialized to sdf=1.0 weight=0
    public var integrationGeneration: UInt32 = 0  // Incremented on every integration touch
    public var meshGeneration: UInt32 = 0         // Set to integrationGeneration after meshing
    public var lastObservedTimestamp: TimeInterval = 0
    public var voxelSize: Float  // Adaptive: 0.005 or 0.01 or 0.02

    /// Empty block sentinel — used to pre-fill ManagedVoxelStorage on init.
    public static let empty = VoxelBlock(
        voxels: ContiguousArray(repeating: Voxel.empty, count: 512),
        integrationGeneration: 0, meshGeneration: 0,
        lastObservedTimestamp: 0, voxelSize: 0.01
    )
}
```

**Critical design notes:**
- 8-byte Voxel alignment doubles GPU cache utilization vs 4-byte (prevents straddling cache lines)
- `ContiguousArray<Voxel>` (NOT `Array`) guarantees no bridging overhead and contiguous memory for Metal buffer wrapping
- Generation counters prevent the race where a block is cleared during meshing but dirtied again by concurrent integration
- `voxelSize` stored per-block enables adaptive multi-resolution within the same hash table
- `SDFStorage` (Section 0.2) replaces direct `Float16` — cross-platform compatible
- `Voxel.empty` and `VoxelBlock.empty` provide explicit sentinels for pool initialization

### 2. VoxelBlockPool (`Core/TSDF/VoxelBlockPool.swift`)

```swift
/// Pre-allocated contiguous pool for O(1) alloc/dealloc with zero fragmentation.
///
/// Wraps ManagedVoxelStorage (Section 0.7) for stable-address voxel data.
/// Free-list stack: O(1) push/pop. No heap allocation after init.
/// The Metal layer uses storage.baseAddress with MTLBuffer(bytesNoCopy:)
/// for zero-copy GPU access (Apple Silicon unified memory).
///
/// Memory budget: 100,000 blocks × 4 KB = 400 MB
/// iPhone 12 Pro (4 GB): safe at ~10% of total RAM
/// iPhone 15 Pro (8 GB): safe at ~5% of total RAM
///
/// NOTE: VoxelBlockPool is a struct but holds a reference to ManagedVoxelStorage.
/// This is intentional — the struct provides value-semantic API (alloc/dealloc)
/// while the underlying storage pointer never moves (required for Metal).
public struct VoxelBlockPool: Sendable {
    private let storage: ManagedVoxelStorage  // Reference type — pointer never moves
    private var freeStack: ContiguousArray<Int>  // Indices of free blocks
    public private(set) var allocatedCount: Int = 0

    public init(capacity: Int = TSDFConstants.maxTotalVoxelBlocks) {
        storage = ManagedVoxelStorage(capacity: capacity)
        freeStack = ContiguousArray((0..<capacity).reversed())
    }

    /// O(1) allocation from free-list
    public mutating func allocate(voxelSize: Float) -> Int? {
        guard let index = freeStack.popLast() else { return nil }
        storage[index] = VoxelBlock(
            voxels: ContiguousArray(repeating: Voxel.empty, count: 512),
            integrationGeneration: 0, meshGeneration: 0,
            lastObservedTimestamp: 0, voxelSize: voxelSize
        )
        allocatedCount += 1
        return index
    }

    /// O(1) deallocation back to free-list
    public mutating func deallocate(index: Int) {
        storage[index] = VoxelBlock.empty
        freeStack.append(index)
        allocatedCount -= 1
    }

    /// VoxelBlockAccessor for TSDFIntegrationBackend protocol
    public var accessor: VoxelBlockAccessor { storage }

    /// Direct access to underlying storage (for MetalTSDFIntegrator buffer binding)
    public var baseAddress: UnsafeMutableRawPointer { storage.baseAddress }
    public var byteCount: Int { storage.byteCount }
}
```

### 3. SpatialHashTable (`Core/TSDF/SpatialHashTable.swift`)

```swift
/// Sparse voxel storage using spatial hashing with separated metadata
///
/// Architecture (Kähler 2015 "Very High Frame Rate Volumetric Integration"):
///   - Compact metadata array: [HashEntry] — 16 bytes per entry (fits in cache during probing)
///   - Separate block storage: VoxelBlockPool — 4 KB per block (accessed only on hit)
///   This prevents cache pollution: probing touches only the small metadata array.
///
/// Hash function: Nießner 2013 primes — industry standard used by nvblox, Voxblox, InfiniTAM
///   h(x,y,z) = (x*73856093 ^ y*19349669 ^ z*83492791) % tableSize
///   Verified: equivalent distribution to MurmurHash for 3-integer keys, fewer multiplications
///
/// Collision resolution: Linear probing with max probe length 128
///   At load factor 0.7: expected probe length = 3.3 (acceptable)
///   At load factor 0.8: expected probe length = 5.0 (trigger rehash before this)
///
/// Iteration determinism: stableKeyList (append-only) for deterministic iteration order
///   (ADR-PR6-005 pattern from existing EvidenceGrid)
struct HashEntry: Sendable {
    var key: BlockIndex    // Int32 x, Int32 y, Int32 z — 12 bytes
    var blockPoolIndex: Int32  // Index into VoxelBlockPool, -1 if empty — 4 bytes
}
// sizeof(HashEntry) = 16 bytes

public struct SpatialHashTable: Sendable {
    private var entries: ContiguousArray<HashEntry>
    private var stableKeyList: ContiguousArray<BlockIndex>  // Deterministic iteration
    private var pool: VoxelBlockPool
    public private(set) var count: Int = 0

    /// Initial table size: 2^16 = 65,536
    /// Room-scale scan at 1cm/8cm blocks needs ~60K blocks before first resize
    public init(
        initialSize: Int = TSDFConstants.hashTableInitialSize,
        poolCapacity: Int = TSDFConstants.maxTotalVoxelBlocks
    ) { ... }

    public mutating func insertOrGet(key: BlockIndex, voxelSize: Float) -> Int? { ... }
    public func lookup(key: BlockIndex) -> Int? { ... }
    public mutating func remove(key: BlockIndex) { ... }

    /// Load factor check — rehash at 0.7
    public var loadFactor: Float { Float(count) / Float(entries.count) }
    public mutating func rehashIfNeeded() { ... }  // 2× growth

    // ── Exposed for TSDFVolume and MetalTSDFIntegrator ──

    /// VoxelBlockAccessor for TSDFIntegrationBackend protocol dispatch.
    /// TSDFVolume passes this to backend.processFrame(volume:).
    public var voxelAccessor: VoxelBlockAccessor { pool.accessor }

    /// Stable base address for Metal MTLBuffer(bytesNoCopy:) binding.
    public var voxelBaseAddress: UnsafeMutableRawPointer { pool.baseAddress }
    public var voxelByteCount: Int { pool.byteCount }

    /// Read a voxel block by pool index (for MarchingCubes).
    public func readBlock(at poolIndex: Int) -> VoxelBlock { pool.accessor.readBlock(at: poolIndex) }
}
```

### 3.5. MetalConstants (`Core/Constants/MetalConstants.swift`) — NEW shared file

```swift
/// Shared Metal pipeline configuration — single source of truth for ALL PRs.
///
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ INNOVATION 3: Eliminate duplicated Metal magic numbers           │
/// │                                                                 │
/// │ Before: ScanGuidanceConstants.kMaxInflightBuffers = 3 (PR#7)   │
/// │         TSDFConstants.metalInflightBuffers = 3 (PR#6)          │
/// │         Future PR#N: someConstant = 3 (same mistake)           │
/// │                                                                 │
/// │ After: Single MetalConstants.inflightBufferCount = 3            │
/// │        All PRs reference this. Change once, all PRs update.    │
/// │        ScanGuidanceConstants.kMaxInflightBuffers deprecated.    │
/// │                                                                 │
/// │ Future-proof: If Metal 4 command allocators make quad-buffer   │
/// │ optimal, change ONE number. If command allocators eliminate     │
/// │ the need for inflight buffers, remove ONE constant.            │
/// └──────────────────────────────────────────────────────────────────┘
public enum MetalConstants {

    /// Triple-buffer count for per-frame GPU data
    /// Standard Apple recommendation (WWDC "Modern Rendering with Metal").
    /// Absorbs CPU/GPU frame time variance without pipeline stalls.
    /// Used by: PR#6 TSDF integration, PR#7 rendering, future Metal PRs.
    public static let inflightBufferCount: Int = 3

    /// Default threadgroup width for compute kernels
    /// 8×8 = 64 threads = 2 SIMD-groups on Apple GPU.
    /// Optimal for high-register-pressure kernels (TSDF, image processing).
    /// Low-register kernels may prefer 16×16 or 32×1.
    public static let defaultThreadgroupSize: Int = 8

    // MARK: - SSOT Registration
    public static let allSpecs: [AnyConstantSpec] = [
        .fixedConstant(FixedConstantSpec(
            ssotId: "MetalConstants.inflightBufferCount",
            name: "Inflight Buffer Count",
            unit: .count,
            value: inflightBufferCount,
            documentation: "Triple-buffer count for all Metal per-frame data. Shared across all PRs."
        )),
        .fixedConstant(FixedConstantSpec(
            ssotId: "MetalConstants.defaultThreadgroupSize",
            name: "Default Threadgroup Size",
            unit: .count,
            value: defaultThreadgroupSize,
            documentation: "Default compute threadgroup edge size (8×8=64 threads)"
        ))
    ]
}
```

**Migration:** After creating MetalConstants.swift, update `ScanGuidanceConstants`:
```swift
// BEFORE (current):
public static let kMaxInflightBuffers: Int = 3

// AFTER (PR#6 migration):
@available(*, deprecated, renamed: "MetalConstants.inflightBufferCount")
public static let kMaxInflightBuffers: Int = MetalConstants.inflightBufferCount
```
This is backward-compatible: existing code still compiles, but shows deprecation warning guiding to the new location.

### 4. TSDFConstants (`Core/TSDF/TSDFConstants.swift`)

Follow the existing `ScanGuidanceConstants.swift` SSOT pattern exactly. All values must be compile-time constants with `allSpecs` registration and `validateRelationships()` cross-validation.

**SSOT type mapping rules** (from `Core/Constants/SSOTTypes.swift`):
- `Float`/`Double` constants → `.threshold(ThresholdSpec(...))` — requires min, max, defaultValue (as Double), onExceed, onUnderflow
- `Int` constants → `.systemConstant(SystemConstantSpec(...))` — value is Int, immutable
- Physical constants (blockSize=8) → `.fixedConstant(FixedConstantSpec(...))` — truly immutable, never tunable
- `Bool` constants → **NOT registered** in allSpecs (no BoolConstantSpec exists in AnyConstantSpec)
- Use `SSOTUnit` for units: `.meters`, `.seconds`, `.milliseconds`, `.count`, `.dimensionless`, `.ratio`, `.frames`, `.pixels`, `.percent`, `.degrees`, `.degreesPerSecond`, `.variance`
- Use `ThresholdCategory` for categories: `.quality`, `.performance`, `.safety`, `.resource`, `.motion`, `.photometric`

```swift
public enum TSDFConstants {

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 1: Adaptive Voxel Resolution (5 constants)
    // ════════════════════════════════════════════════════════════════

    /// Near-range voxel size: 5mm (depth < 1.0m)
    /// Justification: iPhone LiDAR noise σ ≈ 4mm at 0.5m. With ~25-frame TSDF integration,
    /// effective σ ≈ 0.8mm. 5mm voxel is ~6× integrated noise → high-quality surface.
    /// Reference: KinectFusion default 5.86mm/512³; nvblox indoor default 5mm.
    public static let voxelSizeNear: Float = 0.005      // 0.5cm

    /// Mid-range voxel size: 10mm (depth 1.0–3.0m)
    /// Justification: LiDAR noise σ ≈ 12–92mm across this range. After integration,
    /// effective σ ≈ 3–18mm. 10mm voxel captures furniture-scale detail.
    /// Reference: nvblox indoor default; Open3D default.
    public static let voxelSizeMid: Float = 0.01         // 1.0cm

    /// Far-range voxel size: 20mm (depth > 3.0m)
    /// Justification: LiDAR noise σ ≈ 92mm+ at 3m+. After integration, σ ≈ 18mm.
    /// 20mm captures walls/ceiling structure without wasting memory.
    /// Changed from 40mm: 4cm loses architectural molding and door frame detail at 3–5m.
    /// 20mm costs 8× more blocks than 40mm per volume, but far regions are sparse.
    public static let voxelSizeFar: Float = 0.02          // 2.0cm

    /// Near/mid depth threshold
    /// Where 5mm voxels drop below 2× effective noise
    public static let depthNearThreshold: Float = 1.0     // meters

    /// Mid/far depth threshold
    /// Where 10mm voxels become marginal vs integrated noise
    public static let depthFarThreshold: Float = 3.0      // meters

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 2: Truncation Distance (2 constants)
    // ════════════════════════════════════════════════════════════════

    /// Truncation multiplier: τ = 3 × voxel_size
    /// Near: τ = 15mm, Mid: τ = 30mm, Far: τ = 60mm
    /// Standard across KinectFusion, VDBFusion, AGS-Mesh, BundleFusion.
    /// 2× is too tight (misses surface boundary); 4× wastes computation on empty space.
    /// nvblox uses 4× but targets robotics navigation (coarser voxels).
    public static let truncationMultiplier: Float = 3.0

    /// Minimum truncation distance (safety floor)
    /// Ensures truncation >= 2× voxel_size even for near-range blocks
    public static let truncationMinimum: Float = 0.01     // 10mm

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 3: Fusion Weights (7 constants)
    // ════════════════════════════════════════════════════════════════

    /// Maximum accumulated weight per voxel
    /// At W_MAX=64: each new observation contributes 1/(64+1) = 1.5% influence on converged voxels.
    /// KinectFusion=128 (too rigid, no adaptivity to ARKit relocalization).
    /// nvblox=5 (too fluid, surface flickers). Open3D tensor=64 (our choice).
    /// Sweet spot: converges in ~30 observations but still responds to genuine changes.
    public static let weightMax: UInt8 = 64

    /// Confidence weight for ARKit level 0 (low confidence)
    /// Low-confidence pixels have 5–15cm noise at 2m — severely unreliable.
    /// 0.0 would lose depth edges entirely; 0.1 contributes minimally but preserves coverage.
    public static let confidenceWeightLow: Float = 0.1

    /// Confidence weight for ARKit level 1 (medium confidence)
    /// Quasi-exponential spacing: 0.1 / 0.5 / 1.0 matches the roughly exponential
    /// noise distribution across ARKit confidence levels.
    public static let confidenceWeightMid: Float = 0.5

    /// Confidence weight for ARKit level 2 (high confidence)
    public static let confidenceWeightHigh: Float = 1.0

    /// Distance-dependent weight decay coefficient
    /// w_dist = 1.0 / (1.0 + alpha * depth²)
    /// At alpha=0.1: weight is 0.91 at 1m, 0.71 at 2m, 0.53 at 3m, 0.29 at 5m
    /// Models the quadratic depth noise model of iPhone dToF LiDAR: σ(d) ≈ 2mm + 10mm*(d/1m)²
    public static let distanceDecayAlpha: Float = 0.1

    /// Minimum viewing angle weight (cosine threshold)
    /// At grazing angles, depth error scales as 1/cos(θ).
    /// Floor at 0.1 prevents total rejection while severely downweighting grazing observations.
    /// Reference: Curless & Levoy, SIGGRAPH 1996
    public static let viewingAngleWeightFloor: Float = 0.1

    /// Space carving weight decay rate per frame
    /// When ray passes through previously-observed surface (sdf < -τ):
    /// weight -= carvingDecayRate each frame. When weight reaches 0, voxel resets.
    /// Removes ghost geometry when objects move or doors open.
    /// Reference: KinectFusion + FlashFusion weight-decay carving
    public static let carvingDecayRate: UInt8 = 2

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 4: Depth Filtering (4 constants)
    // ════════════════════════════════════════════════════════════════

    /// Minimum reliable depth (meters)
    /// iPhone dToF has multipath artifacts below 0.2m. 0.1m is absolute hardware floor.
    public static let depthMin: Float = 0.1

    /// Maximum reliable depth (meters)
    /// LiDAR noise σ ≈ 250mm at 5m. Beyond 5m: data is too noisy for useful reconstruction.
    public static let depthMax: Float = 5.0

    /// Minimum valid pixel ratio to accept a frame
    /// Below 30%: mostly invalid/NaN pixels → frame is unreliable
    public static let minValidPixelRatio: Float = 0.3

    /// Skip low-confidence pixels entirely (confidence == 0)
    /// ARKit confidence 0 means the hardware has very low trust in the measurement.
    /// These pixels dominate near depth edges and reflective surfaces.
    public static let skipLowConfidencePixels: Bool = true

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 5: Performance Budget (5 constants)
    // ════════════════════════════════════════════════════════════════

    /// Max voxels updated per frame (GPU dispatch cap)
    /// A14 bandwidth: 34.1 GB/s. 500K × 8 bytes = 4 MB = 0.12ms theoretical.
    /// Safe even on the lowest-tier LiDAR device (iPhone 12 Pro).
    public static let maxVoxelsPerFrame: Int = 500_000

    /// Max triangles extracted per meshing cycle (CPU marching cubes hard cap)
    /// CPU can process 50K triangles at ~1.7ms on A14.
    /// Previous value 20K caused dirty-block backlog during rapid scanning.
    /// This is a HARD safety cap. The SOFT limit is congestion-controlled via
    /// maxBlocksPerExtraction (UX-9), which typically produces 5K-30K triangles.
    /// Both limits apply: whichever is hit first stops extraction for this cycle.
    public static let maxTrianglesPerCycle: Int = 50_000

    /// Integration timeout (milliseconds)
    /// At 60fps: frame budget = 16.67ms.
    /// ARKit overhead: ~2–3ms. Rendering: ~3–5ms. TSDF gets the remainder.
    /// 10ms leaves 6.67ms for rendering — safe headroom.
    /// Previous value 12ms left only 4.67ms for rendering — too tight.
    public static let integrationTimeoutMs: Double = 10.0

    /// Metal threadgroup size for pixel-parallel dispatch
    /// 8×8 = 64 threads = 2 SIMD-groups. Optimal for TSDF's high register pressure.
    /// Smaller threadgroups allow more concurrent threadgroups per EU, improving latency hiding.
    /// Validated on A14–A17 Pro.
    public static let metalThreadgroupSize: Int = 8

    /// Metal triple-buffer count for per-frame data (depth, camera params)
    /// References shared constant: MetalConstants.inflightBufferCount
    /// The voxel volume itself is single-persistent (NOT triple-buffered).
    ///
    /// ┌──────────────────────────────────────────────────────────────────┐
    /// │ INNOVATION 3: Shared Metal Constants                            │
    /// │                                                                 │
    /// │ Before: ScanGuidanceConstants.kMaxInflightBuffers = 3 (PR#7)   │
    /// │         TSDFConstants.metalInflightBuffers = 3 (PR#6)          │
    /// │         Two magic numbers, cross-validated.                     │
    /// │ Problem: If Metal 4 command allocators change optimal buffer    │
    /// │ count, you must find and update BOTH. Miss one = bug.          │
    /// │                                                                 │
    /// │ After: MetalConstants.inflightBufferCount = 3 (single truth)   │
    /// │        Both PR#6 and PR#7 reference it.                        │
    /// │        ScanGuidanceConstants.kMaxInflightBuffers → deprecated,  │
    /// │        replaced by MetalConstants.inflightBufferCount.          │
    /// └──────────────────────────────────────────────────────────────────┘
    public static let metalInflightBuffers: Int = MetalConstants.inflightBufferCount

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 6: Memory Management (7 constants)
    // ════════════════════════════════════════════════════════════════

    /// Maximum total voxel blocks across all resolution levels
    /// 100,000 blocks × 4 KB = 400 MB
    /// iPhone 12 Pro (4 GB): ~10% of RAM. iPhone 15 Pro (8 GB): ~5%.
    public static let maxTotalVoxelBlocks: Int = 100_000

    /// Hash table initial size (must be power of 2)
    /// Room-scale scan needs ~60K blocks. 2^16 accommodates this before first resize.
    public static let hashTableInitialSize: Int = 65_536

    /// Hash table max load factor before rehash
    /// At 0.7: expected linear probe length = 3.3.
    /// At 0.8: jumps to 5.0 — unacceptable for real-time.
    public static let hashTableMaxLoadFactor: Float = 0.7

    /// Max linear probe length before giving up (indicates hash quality issue)
    public static let hashMaxProbeLength: Int = 128

    /// Dirty threshold: relative to voxel size
    /// A block is dirty when surface shifts by more than 50% of a voxel width.
    /// dirtyThreshold = 0.5 × voxelSize → near: 2.5mm, mid: 5mm, far: 10mm
    /// Previous fixed value of 0.01 (1%) triggered on 0.3mm SDF change — nearly every
    /// integration dirtied the block, defeating incremental meshing.
    public static let dirtyThresholdMultiplier: Float = 0.5

    /// Stale block age: low-priority eviction after 30s of no observation
    public static let staleBlockEvictionAge: TimeInterval = 30.0

    /// Stale block age: forced eviction after 60s
    public static let staleBlockForceEvictionAge: TimeInterval = 60.0

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 7: Block Geometry (1 constant)
    // ════════════════════════════════════════════════════════════════

    /// Voxels per block edge (8×8×8 = 512 voxels)
    /// Used by nvblox, KinectFusion, Voxblox, InfiniTAM.
    /// 512 voxels × 8 bytes = 4 KB — fits in Apple GPU L1 cache (64 KB per EU).
    /// 16³ = 4096 voxels = 32 KB — wastes memory near surfaces and 8× slower to re-mesh.
    public static let blockSize: Int = 8

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 8: Camera Pose Safety (5 constants)
    // ════════════════════════════════════════════════════════════════

    /// Maximum position delta between consecutive frames before rejecting
    /// At 60fps, 10cm/frame = 6 m/s — faster than any reasonable handheld motion.
    /// Exceeding this indicates ARKit tracking failure / teleport.
    public static let maxPoseDeltaPerFrame: Float = 0.1   // 10cm

    /// Maximum angular velocity before rejecting (radians/second)
    /// 2.0 rad/s = 115°/s. Above this: motion blur corrupts depth map.
    public static let maxAngularVelocity: Float = 2.0

    /// Consecutive rejected frames before warning toast
    public static let poseRejectWarningCount: Int = 30     // 0.5s at 60fps

    /// Consecutive rejected frames before fail state
    public static let poseRejectFailCount: Int = 180       // 3.0s at 60fps

    /// Loop closure discontinuity threshold
    /// When ARKit anchor transforms shift > 2cm, mark affected blocks stale
    public static let loopClosureDriftThreshold: Float = 0.02  // 2cm

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 9: Keyframe Selection (4 constants)
    // ════════════════════════════════════════════════════════════════
    //
    // Keyframes serve TWO consumers:
    //   1. PR#7 projective texturing: RGB texture + pose for coloring mesh surface
    //   2. Cloud pipeline: keyframe poses + RGB for 3DGS/NeRF warm start
    //

    /// Keyframe interval: every Nth successfully integrated frame
    /// At 60fps → ~10 keyframes/second. Sufficient for smooth projective texturing.
    public static let keyframeInterval: Int = 6

    /// Keyframe angular trigger: degrees of viewpoint change since last keyframe
    /// 15° ensures new surface regions get a dedicated keyframe
    public static let keyframeAngularTriggerDeg: Float = 15.0

    /// Keyframe translation trigger: meters of camera movement since last keyframe
    public static let keyframeTranslationTrigger: Float = 0.3

    /// Maximum keyframes per scan session (memory budget for retained RGB textures)
    /// 30 keyframes × ~2MB each (downsampled RGB) = ~60MB peak
    public static let maxKeyframesPerSession: Int = 30

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 10: GPU Safety (4 constants)
    // ════════════════════════════════════════════════════════════════

    /// Triple-buffer semaphore wait timeout (milliseconds)
    /// If GPU takes longer than this, skip frame rather than deadlock
    public static let semaphoreWaitTimeoutMs: Double = 100.0

    /// GPU memory proactive eviction threshold (bytes)
    /// At 500 MB allocated: start evicting far/stale blocks proactively
    public static let gpuMemoryProactiveEvictBytes: Int = 500_000_000

    /// GPU memory aggressive eviction threshold (bytes)
    /// At 800 MB allocated: aggressive eviction of all non-essential blocks
    public static let gpuMemoryAggressiveEvictBytes: Int = 800_000_000

    /// World origin recentering distance (meters)
    /// Float32 loses precision at large distances from origin.
    /// At 100m: Float32 precision is ~0.008mm (acceptable).
    /// At 1000m: Float32 precision is ~0.06mm (problematic for 5mm voxels).
    /// Recenter when camera drifts > 100m from world origin.
    public static let worldOriginRecenterDistance: Float = 100.0

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 11: AIMD Thermal Management (5 constants)
    // ════════════════════════════════════════════════════════════════
    //
    // INNOVATION: Surpasses ThermalQualityAdapter's single-tier approach.
    // System thermal state sets a CEILING. AIMD explores within it.
    // Auto-recovers when GPU load drops (ThermalQualityAdapter cannot).
    //

    /// Degradation hysteresis: wait 10s before accepting worse thermal ceiling
    /// Matches ScanGuidanceConstants.thermalHysteresisS for consistency
    public static let thermalDegradeHysteresisS: Double = 10.0

    /// Recovery hysteresis: wait 5s before accepting better thermal ceiling
    /// ASYMMETRIC vs degradation: recovery helps user, so be responsive
    /// ThermalQualityAdapter uses symmetric 10s — we improve on this.
    public static let thermalRecoverHysteresisS: Double = 5.0

    /// Consecutive good frames before AIMD additive-increase (reduce skip by 1)
    /// "Good" = GPU integration time < integrationTimeoutMs × thermalGoodFrameRatio
    /// At 60fps, 30 frames = 0.5 seconds of sustained good performance
    public static let thermalRecoverGoodFrames: Int = 30

    /// Good frame threshold ratio: GPU time / integrationTimeoutMs < this ratio
    /// At 0.8: GPU must be under 8ms (at 10ms budget) for 30 consecutive frames
    public static let thermalGoodFrameRatio: Float = 0.8

    /// Maximum integration skip count (absolute floor = 5fps at 60Hz input)
    /// Even at critical thermal: 1 frame per 200ms preserves minimal scanning
    public static let thermalMaxIntegrationSkip: Int = 12

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 12: Mesh Extraction Quality (3 constants)
    // ════════════════════════════════════════════════════════════════

    /// Minimum triangle area (m²) — reject degenerate slivers
    public static let minTriangleArea: Float = 1e-8

    /// Maximum triangle aspect ratio — reject needles
    public static let maxTriangleAspectRatio: Float = 100.0

    /// Integration record ring buffer size (frames)
    /// Stores {timestamp, cameraPose, affectedBlockIndices} for future loop closure.
    /// 300 frames ≈ 5 seconds at 60fps. Zero runtime cost now.
    public static let integrationRecordCapacity: Int = 300

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 13: UX Stability (11 constants)
    // ════════════════════════════════════════════════════════════════
    //
    // These constants are referenced by UX-1 through UX-8.
    // Defined here as SSOT; UX sections reference these constants.
    //

    /// SDF dead zone base: 1mm for fresh voxels (UX-1)
    public static let sdfDeadZoneBase: Float = 0.001
    /// SDF dead zone at max weight: 5mm for fully converged voxels (UX-1)
    public static let sdfDeadZoneWeightScale: Float = 0.004

    /// Vertex position quantization step (meters) (UX-2)
    public static let vertexQuantizationStep: Float = 0.0005

    /// Mesh extraction target rate (Hz) (UX-3)
    public static let meshExtractionTargetHz: Float = 10.0
    /// Mesh extraction maximum time budget per cycle (ms) (UX-3)
    public static let meshExtractionBudgetMs: Double = 5.0

    /// MC interpolation t-parameter clamp range (UX-6)
    public static let mcInterpolationMin: Float = 0.1
    public static let mcInterpolationMax: Float = 0.9

    /// Minimum camera translation to trigger integration (meters) (UX-7)
    public static let poseJitterGateTranslation: Float = 0.001
    /// Minimum camera rotation to trigger integration (radians) (UX-7)
    public static let poseJitterGateRotation: Float = 0.002

    /// Minimum integration observations before mesh extraction (UX-8)
    public static let minObservationsBeforeMesh: UInt32 = 3
    /// Fade-in duration in frames after minimum observations met (UX-8)
    public static let meshFadeInFrames: Int = 7

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 14: Congestion Control (9 constants)
    // ════════════════════════════════════════════════════════════════
    //
    // TCP AIMD-inspired mesh extraction pacing (UX-9).
    //

    public static let meshBudgetTargetMs: Double = 4.0
    public static let meshBudgetGoodMs: Double = 3.0
    public static let meshBudgetOverrunMs: Double = 5.0
    public static let minBlocksPerExtraction: Int = 50
    public static let maxBlocksPerExtraction: Int = 250
    public static let blockRampPerCycle: Int = 15
    public static let consecutiveGoodCyclesBeforeRamp: Int = 3
    public static let forgivenessWindowCycles: Int = 5
    public static let slowStartRatio: Float = 0.25

    // ════════════════════════════════════════════════════════════════
    // MARK: - Section 15: Motion Tiers (6 constants)
    // ════════════════════════════════════════════════════════════════
    //
    // UX-10, UX-11, UX-12: cross-block normals, motion deferral, idle utilization.
    //

    /// Distance from block boundary to apply normal averaging (meters) (UX-10)
    public static let normalAveragingBoundaryDistance: Float = 0.001

    /// Translation speed above which mesh extraction defers (m/s) (UX-11)
    public static let motionDeferTranslationSpeed: Float = 0.5
    /// Angular speed above which mesh extraction defers (rad/s) (UX-11)
    public static let motionDeferAngularSpeed: Float = 1.0

    /// Idle detection thresholds (UX-12)
    public static let idleTranslationSpeed: Float = 0.01      // m/s
    public static let idleAngularSpeed: Float = 0.05           // rad/s (~3°/s)
    public static let anticipatoryPreallocationDistance: Float = 0.5

    // ════════════════════════════════════════════════════════════════
    // MARK: - SSOT Registration
    // ════════════════════════════════════════════════════════════════

    /// All numeric constants registered as AnyConstantSpec
    /// Follows ScanGuidanceConstants.allSpecs pattern exactly
    /// Bool constants excluded (no BoolConstantSpec case in AnyConstantSpec)
    ///
    /// IMPORTANT: Register EVERY Float/Double/Int constant — no exceptions.
    /// ScanGuidanceConstants registers 65 specs. TSDFConstants registers 77 specs (Sections 1-15).
    /// Use `.threshold()` for Float/Double, `.systemConstant()` for Int, `.fixedConstant()` for physics constants.
    public static let allSpecs: [AnyConstantSpec] = [
        // Section 1: Adaptive Voxel Resolution (5 constants: 3 Float → threshold, 2 Float → threshold)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeNear",
            name: "Near Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.003, max: 0.008,
            defaultValue: Double(voxelSizeNear),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Near-range voxel size in meters (depth < 1.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeMid",
            name: "Mid Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.008, max: 0.015,
            defaultValue: Double(voxelSizeMid),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Mid-range voxel size in meters (depth 1.0–3.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.voxelSizeFar",
            name: "Far Voxel Size",
            unit: .meters,
            category: .quality,
            min: 0.015, max: 0.04,
            defaultValue: Double(voxelSizeFar),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Far-range voxel size in meters (depth > 3.0m)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthNearThreshold",
            name: "Near/Mid Depth Threshold",
            unit: .meters,
            category: .quality,
            min: 0.5, max: 2.0,
            defaultValue: Double(depthNearThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Depth threshold for near→mid voxel size transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthFarThreshold",
            name: "Mid/Far Depth Threshold",
            unit: .meters,
            category: .quality,
            min: 2.0, max: 5.0,
            defaultValue: Double(depthFarThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Depth threshold for mid→far voxel size transition"
        )),

        // Section 2: Truncation Distance (2 constants: Float → threshold)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.truncationMultiplier",
            name: "Truncation Multiplier",
            unit: .dimensionless,
            category: .quality,
            min: 2.0, max: 5.0,
            defaultValue: Double(truncationMultiplier),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Truncation band = multiplier × voxel_size"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.truncationMinimum",
            name: "Truncation Minimum",
            unit: .meters,
            category: .safety,
            min: 0.005, max: 0.02,
            defaultValue: Double(truncationMinimum),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Absolute minimum truncation distance (safety floor)"
        )),

        // Section 3: Fusion Weights — weightMax is UInt8 but register as systemConstant
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.weightMax",
            name: "Maximum Voxel Weight",
            unit: .count,
            value: Int(weightMax),
            documentation: "Maximum accumulated weight per voxel (UInt8, clamped)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightLow",
            name: "Confidence Weight Low",
            unit: .dimensionless,
            category: .quality,
            min: 0.0, max: 0.3,
            defaultValue: Double(confidenceWeightLow),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Weight multiplier for ARKit confidence level 0 (low)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightMid",
            name: "Confidence Weight Mid",
            unit: .dimensionless,
            category: .quality,
            min: 0.3, max: 0.8,
            defaultValue: Double(confidenceWeightMid),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Weight multiplier for ARKit confidence level 1 (medium)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.confidenceWeightHigh",
            name: "Confidence Weight High",
            unit: .dimensionless,
            category: .quality,
            min: 0.8, max: 1.0,
            defaultValue: Double(confidenceWeightHigh),
            onExceed: .warn, onUnderflow: .clamp,
            documentation: "Weight multiplier for ARKit confidence level 2 (high)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.distanceDecayAlpha",
            name: "Distance Decay Alpha",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.5,
            defaultValue: Double(distanceDecayAlpha),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Quadratic depth weight decay: w = 1/(1 + α × d²)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.viewingAngleWeightFloor",
            name: "Viewing Angle Weight Floor",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.3,
            defaultValue: Double(viewingAngleWeightFloor),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum weight at grazing angles: max(floor, cos(θ))"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.carvingDecayRate",
            name: "Space Carving Decay Rate",
            unit: .count,
            value: Int(carvingDecayRate),
            documentation: "Weight decay per frame for space carving (UInt8)"
        )),

        // Section 4: Depth Filtering
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthMin",
            name: "Minimum Depth",
            unit: .meters,
            category: .safety,
            min: 0.05, max: 0.2,
            defaultValue: Double(depthMin),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum reliable depth (hardware floor)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.depthMax",
            name: "Maximum Depth",
            unit: .meters,
            category: .safety,
            min: 3.0, max: 8.0,
            defaultValue: Double(depthMax),
            onExceed: .clamp, onUnderflow: .warn,
            documentation: "Maximum reliable depth"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.minValidPixelRatio",
            name: "Min Valid Pixel Ratio",
            unit: .ratio,
            category: .quality,
            min: 0.1, max: 0.5,
            defaultValue: Double(minValidPixelRatio),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Minimum fraction of valid depth pixels to accept frame"
        )),

        // Section 5: Performance Budget
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxVoxelsPerFrame",
            name: "Max Voxels Per Frame",
            unit: .count,
            value: maxVoxelsPerFrame,
            documentation: "Maximum voxels updated per GPU frame"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxTrianglesPerCycle",
            name: "Max Triangles Per Meshing Cycle",
            unit: .count,
            value: maxTrianglesPerCycle,
            documentation: "Hard safety cap on triangles per meshing cycle"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.integrationTimeoutMs",
            name: "Integration Timeout",
            unit: .milliseconds,
            category: .performance,
            min: 5.0, max: 14.0,
            defaultValue: integrationTimeoutMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Maximum CPU+GPU time for integration pass"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.metalThreadgroupSize",
            name: "Metal Threadgroup Size",
            unit: .count,
            value: metalThreadgroupSize,
            documentation: "Threadgroup edge size (8×8=64 threads)"
        )),
        // metalInflightBuffers: references MetalConstants.inflightBufferCount (shared truth)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.metalInflightBuffers",
            name: "Metal Inflight Buffers",
            unit: .count,
            value: metalInflightBuffers,
            documentation: "Triple-buffer count for per-frame TSDF data. References MetalConstants.inflightBufferCount (single truth for all PRs)."
        )),

        // Section 6: Memory Management
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxTotalVoxelBlocks",
            name: "Max Total Voxel Blocks",
            unit: .count,
            value: maxTotalVoxelBlocks,
            documentation: "Maximum voxel blocks across all resolutions"
        )),

        // Section 6: Memory Management (remaining)
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.hashTableInitialSize",
            name: "Hash Table Initial Size",
            unit: .count,
            value: hashTableInitialSize,
            documentation: "Initial hash table capacity (power of 2)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.hashTableMaxLoadFactor",
            name: "Hash Table Max Load Factor",
            unit: .ratio,
            category: .performance,
            min: 0.5, max: 0.85,
            defaultValue: Double(hashTableMaxLoadFactor),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Load factor threshold triggering rehash"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.hashMaxProbeLength",
            name: "Hash Max Probe Length",
            unit: .count,
            value: hashMaxProbeLength,
            documentation: "Maximum linear probe before giving up"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.dirtyThresholdMultiplier",
            name: "Dirty Threshold Multiplier",
            unit: .dimensionless,
            category: .quality,
            min: 0.1, max: 1.0,
            defaultValue: Double(dirtyThresholdMultiplier),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Block dirty threshold = multiplier × voxelSize"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.staleBlockEvictionAge",
            name: "Stale Block Eviction Age",
            unit: .seconds,
            category: .resource,
            min: 10.0, max: 60.0,
            defaultValue: staleBlockEvictionAge,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Age threshold for low-priority block eviction"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.staleBlockForceEvictionAge",
            name: "Stale Block Force Eviction Age",
            unit: .seconds,
            category: .resource,
            min: 30.0, max: 120.0,
            defaultValue: staleBlockForceEvictionAge,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Age threshold for forced block eviction"
        )),

        // Section 7: Block Geometry — use fixedConstant for physics constant
        .fixedConstant(FixedConstantSpec(
            ssotId: "TSDFConstants.blockSize",
            name: "Block Size",
            unit: .count,
            value: blockSize,
            documentation: "Voxels per block edge (8³=512). Industry standard: nvblox, KinectFusion, InfiniTAM."
        )),

        // Section 8: Camera Pose Safety
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxPoseDeltaPerFrame",
            name: "Max Pose Delta Per Frame",
            unit: .meters,
            category: .safety,
            min: 0.05, max: 0.2,
            defaultValue: Double(maxPoseDeltaPerFrame),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Position delta threshold for teleport rejection"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxAngularVelocity",
            name: "Max Angular Velocity",
            unit: .degreesPerSecond, // stored as rad/s but SSOTUnit uses degreesPerSecond
            category: .motion,
            min: 1.0, max: 4.0,
            defaultValue: Double(maxAngularVelocity),
            onExceed: .reject, onUnderflow: .warn,
            documentation: "Angular velocity threshold for frame rejection (rad/s)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.poseRejectWarningCount",
            name: "Pose Reject Warning Count",
            unit: .frames,
            value: poseRejectWarningCount,
            documentation: "Consecutive rejected frames before warning toast"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.poseRejectFailCount",
            name: "Pose Reject Fail Count",
            unit: .frames,
            value: poseRejectFailCount,
            documentation: "Consecutive rejected frames before fail state"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.loopClosureDriftThreshold",
            name: "Loop Closure Drift Threshold",
            unit: .meters,
            category: .quality,
            min: 0.01, max: 0.05,
            defaultValue: Double(loopClosureDriftThreshold),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Anchor shift threshold to mark blocks stale"
        )),

        // Section 9: Keyframe Selection
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.keyframeInterval",
            name: "Keyframe Interval",
            unit: .frames,
            value: keyframeInterval,
            documentation: "Every Nth integrated frame is a keyframe candidate"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.keyframeAngularTriggerDeg",
            name: "Keyframe Angular Trigger",
            unit: .degrees,
            category: .quality,
            min: 5.0, max: 30.0,
            defaultValue: Double(keyframeAngularTriggerDeg),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Viewpoint angular change threshold for keyframe"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.keyframeTranslationTrigger",
            name: "Keyframe Translation Trigger",
            unit: .meters,
            category: .quality,
            min: 0.1, max: 0.5,
            defaultValue: Double(keyframeTranslationTrigger),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Camera movement threshold for keyframe"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxKeyframesPerSession",
            name: "Max Keyframes Per Session",
            unit: .count,
            value: maxKeyframesPerSession,
            documentation: "Memory budget cap for retained RGB keyframes"
        )),

        // Section 10: GPU Safety
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.semaphoreWaitTimeoutMs",
            name: "Semaphore Wait Timeout",
            unit: .milliseconds,
            category: .safety,
            min: 50.0, max: 200.0,
            defaultValue: semaphoreWaitTimeoutMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "GPU fence timeout before frame skip"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.gpuMemoryProactiveEvictBytes",
            name: "GPU Memory Proactive Evict",
            unit: .count, // bytes, no .bytes unit in SSOTUnit
            value: gpuMemoryProactiveEvictBytes,
            documentation: "Allocated GPU memory threshold for proactive eviction (bytes)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.gpuMemoryAggressiveEvictBytes",
            name: "GPU Memory Aggressive Evict",
            unit: .count,
            value: gpuMemoryAggressiveEvictBytes,
            documentation: "Allocated GPU memory threshold for aggressive eviction (bytes)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.worldOriginRecenterDistance",
            name: "World Origin Recenter Distance",
            unit: .meters,
            category: .safety,
            min: 50.0, max: 500.0,
            defaultValue: Double(worldOriginRecenterDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Camera distance from origin before recentering"
        )),

        // Section 11: AIMD Thermal Management
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalDegradeHysteresisS",
            name: "Thermal Degrade Hysteresis",
            unit: .seconds,
            category: .performance,
            min: 5.0, max: 20.0,
            defaultValue: thermalDegradeHysteresisS,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Cooldown before accepting worse thermal ceiling"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalRecoverHysteresisS",
            name: "Thermal Recover Hysteresis",
            unit: .seconds,
            category: .performance,
            min: 2.0, max: 10.0,
            defaultValue: thermalRecoverHysteresisS,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Cooldown before accepting better thermal ceiling (asymmetric)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.thermalRecoverGoodFrames",
            name: "Thermal Recover Good Frames",
            unit: .frames,
            value: thermalRecoverGoodFrames,
            documentation: "Consecutive good frames before AIMD additive-increase"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.thermalGoodFrameRatio",
            name: "Thermal Good Frame Ratio",
            unit: .ratio,
            category: .performance,
            min: 0.5, max: 0.95,
            defaultValue: Double(thermalGoodFrameRatio),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "GPU time / timeout ratio threshold for 'good' frame"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.thermalMaxIntegrationSkip",
            name: "Thermal Max Integration Skip",
            unit: .count,
            value: thermalMaxIntegrationSkip,
            documentation: "Maximum frame skip count (absolute floor = 5fps)"
        )),

        // Section 12: Mesh Extraction Quality
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.minTriangleArea",
            name: "Min Triangle Area",
            unit: .meters, // m²
            category: .quality,
            min: 1e-10, max: 1e-6,
            defaultValue: Double(minTriangleArea),
            onExceed: .warn, onUnderflow: .reject,
            documentation: "Degenerate triangle area rejection threshold (m²)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.maxTriangleAspectRatio",
            name: "Max Triangle Aspect Ratio",
            unit: .dimensionless,
            category: .quality,
            min: 10.0, max: 500.0,
            defaultValue: Double(maxTriangleAspectRatio),
            onExceed: .clamp, onUnderflow: .warn,
            documentation: "Degenerate triangle needle rejection threshold"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.integrationRecordCapacity",
            name: "Integration Record Capacity",
            unit: .frames,
            value: integrationRecordCapacity,
            documentation: "Ring buffer size for IntegrationRecord history"
        )),

        // Section 13: UX Stability Constants (from UX-1 through UX-12)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.sdfDeadZoneBase",
            name: "SDF Dead Zone Base",
            unit: .meters,
            category: .quality,
            min: 0.0005, max: 0.003,
            defaultValue: Double(sdfDeadZoneBase),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "SDF update dead zone for fresh voxels (UX-1)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.sdfDeadZoneWeightScale",
            name: "SDF Dead Zone Weight Scale",
            unit: .meters,
            category: .quality,
            min: 0.001, max: 0.01,
            defaultValue: Double(sdfDeadZoneWeightScale),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Additional dead zone at max weight (UX-1)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.vertexQuantizationStep",
            name: "Vertex Quantization Step",
            unit: .meters,
            category: .quality,
            min: 0.0002, max: 0.001,
            defaultValue: Double(vertexQuantizationStep),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Grid snap step for extracted vertices (UX-2)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshExtractionTargetHz",
            name: "Mesh Extraction Target Hz",
            unit: .count, // Hz
            category: .performance,
            min: 5.0, max: 30.0,
            defaultValue: Double(meshExtractionTargetHz),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Target mesh extraction rate (UX-3)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshExtractionBudgetMs",
            name: "Mesh Extraction Budget",
            unit: .milliseconds,
            category: .performance,
            min: 2.0, max: 8.0,
            defaultValue: meshExtractionBudgetMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Max wall-clock time per meshing cycle (UX-3)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.mcInterpolationMin",
            name: "MC Interpolation Min",
            unit: .dimensionless,
            category: .quality,
            min: 0.01, max: 0.2,
            defaultValue: Double(mcInterpolationMin),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Lower clamp for MC zero-crossing t parameter (UX-6)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.mcInterpolationMax",
            name: "MC Interpolation Max",
            unit: .dimensionless,
            category: .quality,
            min: 0.8, max: 0.99,
            defaultValue: Double(mcInterpolationMax),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Upper clamp for MC zero-crossing t parameter (UX-6)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.poseJitterGateTranslation",
            name: "Pose Jitter Gate Translation",
            unit: .meters,
            category: .motion,
            min: 0.0005, max: 0.005,
            defaultValue: Double(poseJitterGateTranslation),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Min camera movement to trigger integration (UX-7)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.poseJitterGateRotation",
            name: "Pose Jitter Gate Rotation",
            unit: .dimensionless, // radians
            category: .motion,
            min: 0.001, max: 0.01,
            defaultValue: Double(poseJitterGateRotation),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Min camera rotation to trigger integration (rad, UX-7)"
        )),
        .fixedConstant(FixedConstantSpec(
            ssotId: "TSDFConstants.minObservationsBeforeMesh",
            name: "Min Observations Before Mesh",
            unit: .count,
            value: Int(minObservationsBeforeMesh),
            documentation: "Minimum integration touches before mesh extraction (UX-8)"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.meshFadeInFrames",
            name: "Mesh Fade-In Frames",
            unit: .frames,
            value: meshFadeInFrames,
            documentation: "Fade-in duration after min observations met (UX-8)"
        )),

        // Section 14: Congestion Control Constants (UX-9)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetTargetMs",
            name: "Mesh Budget Target",
            unit: .milliseconds,
            category: .performance,
            min: 2.0, max: 6.0,
            defaultValue: meshBudgetTargetMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Target meshing cycle time for congestion control"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetGoodMs",
            name: "Mesh Budget Good",
            unit: .milliseconds,
            category: .performance,
            min: 1.0, max: 4.0,
            defaultValue: meshBudgetGoodMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Good cycle threshold for additive increase"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.meshBudgetOverrunMs",
            name: "Mesh Budget Overrun",
            unit: .milliseconds,
            category: .performance,
            min: 4.0, max: 10.0,
            defaultValue: meshBudgetOverrunMs,
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Overrun threshold for multiplicative decrease"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.minBlocksPerExtraction",
            name: "Min Blocks Per Extraction",
            unit: .count,
            value: minBlocksPerExtraction,
            documentation: "Floor: always make meshing progress"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.maxBlocksPerExtraction",
            name: "Max Blocks Per Extraction",
            unit: .count,
            value: maxBlocksPerExtraction,
            documentation: "Ceiling: per-device max blocks per cycle"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.blockRampPerCycle",
            name: "Block Ramp Per Cycle",
            unit: .count,
            value: blockRampPerCycle,
            documentation: "Additive increase per good meshing cycle"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.consecutiveGoodCyclesBeforeRamp",
            name: "Consecutive Good Cycles Before Ramp",
            unit: .count,
            value: consecutiveGoodCyclesBeforeRamp,
            documentation: "Good cycles required before block count increase"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "TSDFConstants.forgivenessWindowCycles",
            name: "Forgiveness Window Cycles",
            unit: .count,
            value: forgivenessWindowCycles,
            documentation: "Cooldown cycles after overrun"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.slowStartRatio",
            name: "Slow Start Ratio",
            unit: .ratio,
            category: .performance,
            min: 0.1, max: 0.5,
            defaultValue: Double(slowStartRatio),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Recovery start ratio after overrun"
        )),

        // Section 15: Motion Tier Constants (UX-10, UX-11, UX-12)
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.normalAveragingBoundaryDistance",
            name: "Normal Averaging Boundary Distance",
            unit: .meters,
            category: .quality,
            min: 0.0005, max: 0.003,
            defaultValue: Double(normalAveragingBoundaryDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Distance from block edge for normal averaging (UX-10)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.motionDeferTranslationSpeed",
            name: "Motion Defer Translation Speed",
            unit: .meters, // m/s
            category: .motion,
            min: 0.2, max: 1.0,
            defaultValue: Double(motionDeferTranslationSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Translation speed above which meshing defers (UX-11)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.motionDeferAngularSpeed",
            name: "Motion Defer Angular Speed",
            unit: .dimensionless, // rad/s
            category: .motion,
            min: 0.5, max: 1.5,
            defaultValue: Double(motionDeferAngularSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Angular speed above which meshing defers (rad/s, UX-11)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.idleTranslationSpeed",
            name: "Idle Translation Speed",
            unit: .meters, // m/s
            category: .motion,
            min: 0.005, max: 0.05,
            defaultValue: Double(idleTranslationSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Speed below which camera is considered idle (UX-12)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.idleAngularSpeed",
            name: "Idle Angular Speed",
            unit: .dimensionless, // rad/s
            category: .motion,
            min: 0.02, max: 0.1,
            defaultValue: Double(idleAngularSpeed),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Angular speed below which camera is idle (rad/s, UX-12)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "TSDFConstants.anticipatoryPreallocationDistance",
            name: "Anticipatory Preallocation Distance",
            unit: .meters,
            category: .performance,
            min: 0.2, max: 1.0,
            defaultValue: Double(anticipatoryPreallocationDistance),
            onExceed: .warn, onUnderflow: .warn,
            documentation: "Look-ahead distance for idle block preallocation (UX-12)"
        )),

        // TOTAL: 77 specs registered (Sections 1-15). Remaining EP/FP constants are optional/future
        // and NOT registered (their enable flags are Bool → excluded by SSOTTypes).
    ]

    // ════════════════════════════════════════════════════════════════
    // MARK: - Cross-Validation
    // ════════════════════════════════════════════════════════════════

    public static func validateRelationships() -> [String] {
        var errors: [String] = []

        // ═══ Internal consistency ═══

        // Voxel sizes must be strictly increasing
        if voxelSizeNear >= voxelSizeMid { errors.append("voxelSizeNear must be < voxelSizeMid") }
        if voxelSizeMid >= voxelSizeFar { errors.append("voxelSizeMid must be < voxelSizeFar") }

        // Depth thresholds must be ordered
        if depthNearThreshold >= depthFarThreshold { errors.append("depthNearThreshold must be < depthFarThreshold") }
        if depthMin >= depthNearThreshold { errors.append("depthMin must be < depthNearThreshold") }

        // Truncation must be >= 2× voxel size (safety floor from nvblox)
        let minTruncation = truncationMultiplier * voxelSizeNear
        if minTruncation < 2.0 * voxelSizeNear { errors.append("truncationMultiplier too small for near voxels") }

        // Memory budget sanity
        let totalMemoryBytes = maxTotalVoxelBlocks * blockSize * blockSize * blockSize * 8  // 8 bytes/voxel
        if totalMemoryBytes > 800_000_000 { errors.append("Total voxel memory exceeds 800 MB safety limit") }

        // Weight hierarchy
        if confidenceWeightLow >= confidenceWeightMid { errors.append("confidenceWeightLow must be < confidenceWeightMid") }
        if confidenceWeightMid >= confidenceWeightHigh { errors.append("confidenceWeightMid must be < confidenceWeightHigh") }

        // Performance budget: integration + render must fit in frame
        if integrationTimeoutMs > 14.0 { errors.append("integrationTimeoutMs too large for 60fps frame budget") }

        // Congestion control consistency
        if meshBudgetGoodMs >= meshBudgetOverrunMs { errors.append("meshBudgetGoodMs must be < meshBudgetOverrunMs") }
        if meshBudgetTargetMs >= meshBudgetOverrunMs { errors.append("meshBudgetTargetMs must be < meshBudgetOverrunMs") }
        if minBlocksPerExtraction >= maxBlocksPerExtraction { errors.append("minBlocksPerExtraction must be < maxBlocksPerExtraction") }

        // Motion tiers: UX-11 motionDeferAngularSpeed < Guardrail#11 maxAngularVelocity
        if motionDeferAngularSpeed >= maxAngularVelocity {
            errors.append("motionDeferAngularSpeed (\(motionDeferAngularSpeed)) must be < maxAngularVelocity (\(maxAngularVelocity))")
        }

        // Motion tiers ordering: idle < defer (UX-12 < UX-11)
        if idleTranslationSpeed >= motionDeferTranslationSpeed {
            errors.append("idleTranslationSpeed must be < motionDeferTranslationSpeed")
        }
        if idleAngularSpeed >= motionDeferAngularSpeed {
            errors.append("idleAngularSpeed must be < motionDeferAngularSpeed")
        }

        // Pose jitter gate must be below motion defer threshold (UX-7 < UX-11)
        if poseJitterGateTranslation >= motionDeferTranslationSpeed / 60.0 {
            errors.append("poseJitterGateTranslation (per-frame) must be << motionDeferTranslationSpeed (per-second)")
        }

        // Keyframe constraints (Section 9)
        if keyframeInterval < 1 { errors.append("keyframeInterval must be >= 1") }
        if maxKeyframesPerSession < 5 { errors.append("maxKeyframesPerSession too small for projective texturing") }
        if keyframeAngularTriggerDeg <= 0 { errors.append("keyframeAngularTriggerDeg must be > 0") }
        if keyframeTranslationTrigger <= 0 { errors.append("keyframeTranslationTrigger must be > 0") }

        // Stale block ages must be ordered
        if staleBlockEvictionAge >= staleBlockForceEvictionAge {
            errors.append("staleBlockEvictionAge must be < staleBlockForceEvictionAge")
        }

        // GPU memory thresholds must be ordered
        if gpuMemoryProactiveEvictBytes >= gpuMemoryAggressiveEvictBytes {
            errors.append("gpuMemoryProactiveEvictBytes must be < gpuMemoryAggressiveEvictBytes")
        }

        // Thermal hysteresis: recover must be <= degrade
        if thermalRecoverHysteresisS > thermalDegradeHysteresisS {
            errors.append("thermalRecoverHysteresisS must be <= thermalDegradeHysteresisS (asymmetric: recover is faster)")
        }

        // MC interpolation: min < max
        if mcInterpolationMin >= mcInterpolationMax {
            errors.append("mcInterpolationMin must be < mcInterpolationMax")
        }

        // Dead zone sanity: total dead zone at max weight should be < voxelSizeNear
        let maxDeadZone = sdfDeadZoneBase + sdfDeadZoneWeightScale
        if maxDeadZone >= voxelSizeNear {
            errors.append("sdfDeadZoneBase + sdfDeadZoneWeightScale must be < voxelSizeNear")
        }

        // ═══ Cross-module consistency ═══

        // metalInflightBuffers references MetalConstants.inflightBufferCount (single source of truth)
        // No cross-validation needed — it's the same constant, not a duplicated value.

        return errors
    }
}
```

### 5. TSDFVolume (`Core/TSDF/TSDFVolume.swift`)

```swift
/// Central TSDF volume manager — the heart of PR#6
///
/// Actor isolation ensures:
///   - hashTable is never accessed concurrently
///   - All mutations go through actor-isolated methods
///   - Metal dispatch is non-isolated (@concurrent) for GPU parallelism
///
/// Performance targets (A14 baseline):
///   - integrate(): < 2ms CPU dispatch + < 5ms GPU compute = < 7ms total
///   - extractMesh(): < 3ms for dirty blocks (incremental, P0 priority)
///
/// Memory targets:
///   - Idle: ~1 MB (hash table + empty pool metadata)
///   - Active room scan: ~100–200 MB (25K–50K blocks)
///   - Maximum: 400 MB (100K blocks, safety cap)
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ INNOVATION 1: IntegrationInput — Platform-Agnostic Input       │
/// │                                                                 │
/// │ SceneDepthFrame.camera is ARCamera behind #if canImport(ARKit).│
/// │ Core/ CANNOT import ARKit (Linux/visionOS portability).        │
/// │ Solution: App/ layer unpacks SceneDepthFrame into              │
/// │ IntegrationInput (pure numerics, no platform types).           │
/// │ This is BETTER than existing patterns: ThermalQualityAdapter   │
/// │ avoids platform types via raw Int — we go further by           │
/// │ designing a complete platform-free input struct.               │
/// └──────────────────────────────────────────────────────────────────┘
///
/// Platform-agnostic integration input — constructed by App/ layer from SceneDepthFrame
/// Core/ TSDFVolume never touches CVPixelBuffer, ARCamera, or any Apple framework type.
///
/// Construction (in App/ layer, MetalTSDFIntegrator):
///   let input = IntegrationInput(
///       timestamp: sceneDepthFrame.timestamp,
///       intrinsics: sceneDepthFrame.camera.intrinsics,      // 3×3
///       cameraToWorld: sceneDepthFrame.camera.transform,     // 4×4
///       depthWidth: CVPixelBufferGetWidth(sceneDepthFrame.depthMap),   // 256
///       depthHeight: CVPixelBufferGetHeight(sceneDepthFrame.depthMap), // 192
///       trackingState: arFrame.camera.trackingState == .normal ? 2 : ...
///   )
///   // CVPixelBuffer → MTLTexture conversion stays in App/ Metal layer (zero-copy via CVMetalTextureCache)
///   // Core/ only needs the numeric matrices for gate checks and ring buffer recording.
/// FILE LOCATION: Core/TSDF/MeshOutput.swift (alongside MeshVertex, MeshTriangle, MeshOutput)
public struct IntegrationInput: Sendable {
    public let timestamp: TimeInterval
    public let intrinsics: TSDFMatrix3x3      // Camera intrinsics (fx,fy,cx,cy)
    public let cameraToWorld: TSDFMatrix4x4   // Camera extrinsics (pose)
    public let depthWidth: Int                 // 256 (for valid pixel ratio calculation)
    public let depthHeight: Int                // 192
    public let trackingState: Int              // 0=notAvailable, 1=limited, 2=normal
}

public actor TSDFVolume {
    private var hashTable: SpatialHashTable
    private var integrationRecordRing: [IntegrationRecord]  // 300-frame ring buffer
    private var ringIndex: Int = 0
    private var frameCount: UInt64 = 0
    private var lastCameraPose: TSDFMatrix4x4?

    /// Backend for depth-to-voxel computation (injected, see Section 0.6).
    /// CPU backend for tests/fallback, Metal backend for production.
    private let backend: TSDFIntegrationBackend

    // ┌──────────────────────────────────────────────────────────────────┐
    // │ INNOVATION 2: AIMD Thermal — Surpasses ThermalQualityAdapter   │
    // │                                                                 │
    // │ ThermalQualityAdapter (existing, PR#7) has a critical flaw:    │
    // │ P95 frame budget can UPGRADE tier (nominal→fair→serious) but   │
    // │ NEVER auto-DOWNGRADES when load recovers. Only the system      │
    // │ thermal notification can lower it. This means: one GPU spike   │
    // │ → stuck at low quality until phone physically cools down.      │
    // │                                                                 │
    // │ For rendering, this conservatism is acceptable (users see       │
    // │ choppy frames). For TSDF integration, it's NOT — users don't  │
    // │ see integration rate, they see mesh staleness. Being stuck at  │
    // │ 15fps integration when GPU load is back to normal = wasted    │
    // │ quality for no reason.                                         │
    // │                                                                 │
    // │ Solution: Apply the same TCP AIMD principle from UX-9          │
    // │ (congestion control) to thermal management. Integration rate    │
    // │ has its own additive-increase, multiplicative-decrease cycle.  │
    // │ System thermal state sets a CEILING. AIMD explores within it. │
    // └──────────────────────────────────────────────────────────────────┘
    //
    // Thermal AIMD state:
    //   systemThermalCeiling: max integration rate allowed by ProcessInfo.ThermalState
    //   currentIntegrationSkip: actual skip count (1=every frame, 2=every other, 4=every 4th)
    //   consecutiveGoodFrames: frames where GPU time < integrationTimeoutMs × 0.8
    //   lastThermalChangeTime: hysteresis timer (10s cooldown for system-driven changes)
    //
    // AIMD rules:
    //   System thermal change → immediately apply ceiling (with 10s hysteresis for upgrades)
    //   GPU frame overrun → multiply skip by 2 (multiplicative decrease, instant)
    //   N consecutive good frames → subtract 1 from skip (additive increase, gradual)
    //   skip never drops below 1 (= every frame) or above systemThermalCeiling
    //   skip never exceeds 12 (= 5fps at 60Hz input, our absolute floor)
    //
    // Why this is better than ThermalQualityAdapter:
    //   1. Auto-recovers when GPU load drops (additive increase)
    //   2. Responds instantly to spikes (multiplicative decrease)
    //   3. System thermal state is a ceiling, not the whole answer
    //   4. Asymmetric hysteresis: 10s to degrade (conservative), 5s to recover (responsive)
    //
    private var systemThermalCeiling: Int = 1       // skip count ceiling from system thermal state
    private var currentIntegrationSkip: Int = 1     // actual skip count (AIMD-managed)
    private var consecutiveGoodFrames: Int = 0
    private var lastThermalChangeTime: TimeInterval = 0

    public init(backend: TSDFIntegrationBackend) {
        self.backend = backend
        hashTable = SpatialHashTable()
        integrationRecordRing = Array(repeating: .empty, count: TSDFConstants.integrationRecordCapacity)
    }

    /// Integrate a single depth frame into the volume.
    /// Called every frame (~60fps) from App/ layer.
    ///
    /// NOTE: Takes IntegrationInput (platform-agnostic) + DepthDataProvider (pixel access).
    /// App/ layer constructs IntegrationInput by unpacking SceneDepthFrame + ARCamera.
    /// TSDFVolume handles ALL gate checks and AIMD logic, then delegates pixel-level
    /// integration work to the injected backend (CPU or Metal).
    ///
    /// Returns IntegrationResult with statistics for telemetry.
    /// MUST be async — backend.processFrame() is async.
    public func integrate(
        input: IntegrationInput,
        depthData: DepthDataProvider
    ) async -> IntegrationResult {
        // Gate 1: Tracking state
        guard input.trackingState == 2 else { return .skipped(.trackingLost) }

        // Gate 2: Pose teleport detection
        if let lastPose = lastCameraPose {
            let translation = tsdTranslation(input.cameraToWorld)
            let lastTranslation = tsdTranslation(lastPose)
            let delta = (translation - lastTranslation).length()
            guard delta < TSDFConstants.maxPoseDeltaPerFrame else {
                return .skipped(.poseTeleport)
            }
        }

        // Gate 3: Pose jitter gate (UX-7) — skip if camera nearly still
        // Gate 4: Thermal AIMD skip — frameCount % currentIntegrationSkip != 0 → skip
        // Gate 5: Valid pixel ratio (checked by Metal kernel, reported back)

        // Determine active blocks from hash table
        // (For Metal: allocation kernel handles this; for CPU: explicit loop)

        // Dispatch to backend
        let stats = await backend.processFrame(
            input: input,
            depthData: depthData,
            volume: hashTable.voxelAccessor,
            activeBlocks: /* blocks to integrate */
        )

        // AIMD feedback: if stats.gpuTimeMs < integrationTimeoutMs × 0.8
        //   consecutiveGoodFrames += 1
        //   if consecutiveGoodFrames > thermalRecoverGoodFrames → decrease skip (additive increase)
        // else → consecutiveGoodFrames = 0, double skip (multiplicative decrease)

        // Update ring buffer with IntegrationRecord
        lastCameraPose = input.cameraToWorld
        frameCount += 1

        return .success(stats)
    }

    /// Extract mesh from dirty blocks with priority ordering
    ///
    /// Priority = integrationGeneration - meshGeneration (higher = dirtier = higher priority)
    /// Budget: maxTrianglesPerCycle triangles per call
    ///
    /// IMPORTANT: When meshing a dirty block, also mesh its 6 face-adjacent neighbors.
    /// Marching Cubes samples voxels across block boundaries — without neighbor meshing,
    /// visible seam artifacts appear. (Reference: nvblox ICRA 2024)
    public func extractMesh() -> MeshOutput { ... }

    /// Query voxel at world position (for PR#5 evidence system)
    public func queryVoxel(at worldPosition: TSDFFloat3) -> Voxel? { ... }

    /// Memory pressure handler — tiered response
    /// Level 1 (warning): Evict stale blocks (lastObserved > 30s)
    /// Level 2 (critical): Evict all blocks > 3m from camera, reduce maxBlocks by 50%
    /// Level 3 (terminal): Evict all blocks except nearest 1m radius
    public func handleMemoryPressure(level: MemoryPressureLevel) { ... }

    /// System thermal state changed — update the CEILING for AIMD
    ///
    /// Called by ScanViewModel when ProcessInfo.thermalStateDidChangeNotification fires.
    /// This sets the MAXIMUM integration rate (ceiling). The actual rate may be lower
    /// if GPU frame times are high (AIMD manages the actual skip count).
    ///
    /// ┌──────────────────────────────────────────────────────────────────┐
    /// │ INNOVATION vs ThermalQualityAdapter:                            │
    /// │                                                                 │
    /// │ ThermalQualityAdapter: system state → tier → done.              │
    /// │   Problem: If P95 GPU time spikes, tier goes up but never      │
    /// │   comes back down until the phone physically cools.            │
    /// │                                                                 │
    /// │ TSDFVolume AIMD: system state → ceiling. AIMD explores within.│
    /// │   System says .fair → ceiling = skip-2 (30fps max).           │
    /// │   GPU is fast → AIMD keeps skip at 2 (enjoying full ceiling). │
    /// │   GPU spike → AIMD doubles skip to 4 (15fps, within ceiling). │
    /// │   GPU recovers → AIMD additive-increases back to 2.           │
    /// │   System says .nominal → ceiling = skip-1. AIMD recovers to 1.│
    /// │                                                                 │
    /// │ The insight: system thermal state and GPU load are TWO         │
    /// │ independent signals. The existing code conflates them into one │
    /// │ tier. We separate them: ceiling + AIMD.                        │
    /// └──────────────────────────────────────────────────────────────────┘
    ///
    /// State mapping (ProcessInfo.ThermalState.rawValue):
    ///   0 = .nominal → ceiling = 1  (every frame, 60fps)
    ///   1 = .fair    → ceiling = 2  (every 2nd frame, 30fps)
    ///   2 = .serious → ceiling = 4  (every 4th frame, 15fps)
    ///   3 = .critical→ ceiling = 12 (every 12th frame, 5fps)
    ///
    /// Hysteresis: 10s for degradation (ceiling increase), 5s for recovery (ceiling decrease).
    /// Asymmetric because recovery benefits the user immediately.
    public func handleThermalState(_ state: Int) {
        let targetCeiling: Int
        switch state {
        case 0: targetCeiling = 1
        case 1: targetCeiling = 2
        case 2: targetCeiling = 4
        case 3: targetCeiling = 12
        default: targetCeiling = 2
        }

        let now = ProcessInfo.processInfo.systemUptime
        let hysteresis = targetCeiling > systemThermalCeiling
            ? TSDFConstants.thermalDegradeHysteresisS     // 10s to degrade (conservative)
            : TSDFConstants.thermalRecoverHysteresisS     // 5s to recover (responsive)

        if (now - lastThermalChangeTime) > hysteresis {
            let oldCeiling = systemThermalCeiling
            systemThermalCeiling = targetCeiling

            if targetCeiling > oldCeiling {
                // Thermal WORSENED (ceiling increased = more aggressive skipping).
                // Force skip UP to at least the new ceiling immediately.
                // AIMD will NOT auto-recover past this ceiling.
                currentIntegrationSkip = max(currentIntegrationSkip, targetCeiling)
            } else {
                // Thermal IMPROVED (ceiling decreased = less skipping allowed).
                // Clamp skip DOWN to new ceiling. AIMD may further decrease within ceiling.
                currentIntegrationSkip = min(currentIntegrationSkip, targetCeiling)
            }

            lastThermalChangeTime = now
            consecutiveGoodFrames = 0
        }
    }

    /// Reset volume (new scan session)
    public func reset() { ... }
}

/// Integration result for telemetry and guardrail feedback.
/// FILE LOCATION: Core/TSDF/MeshOutput.swift (alongside IntegrationInput)
public enum IntegrationResult {
    case success(IntegrationStats)
    case skipped(SkipReason)

    public struct IntegrationStats {
        public let blocksUpdated: Int
        public let blocksAllocated: Int
        public let voxelsUpdated: Int
        public let gpuTimeMs: Double
        public let totalTimeMs: Double
    }

    public enum SkipReason {
        case trackingLost
        case poseTeleport          // Guardrail #10: position delta > maxPoseDeltaPerFrame
        case poseJitter            // UX-7: camera nearly still, skip to preserve quality
        case thermalThrottle       // Guardrail #2: AIMD skip
        case frameTimeout          // Guardrail #3: integration > integrationTimeoutMs
        case lowValidPixels        // Guardrail #15: valid pixel ratio < minValidPixelRatio
        case memoryPressure        // Guardrail #1: memory warning
    }
}
```

### 6. Metal Compute Shaders (`App/TSDF/TSDFShaders.metal`)

Three kernels (not two — space carving is logically separate from integration):

**Kernel 1: Depth Projection + Block Allocation**
```metal
/// For each depth pixel, compute world-space position and determine which VoxelBlocks are needed.
/// Threadgroup: 8×8 = 64 threads (2 SIMD-groups, optimal for high register pressure)
/// Dispatch: ceil(256/8) × ceil(192/8) = 32 × 24 = 768 threadgroups
kernel void projectDepthAndAllocate(
    texture2d<float, access::read> depthMap [[texture(0)]],       // Zero-copy from CVMetalTextureCache
    texture2d<uint, access::read> confidenceMap [[texture(1)]],   // UInt8 confidence (0/1/2), uint preserves integer values
    constant float3x3& intrinsicsInverse [[buffer(0)]],
    constant float4x4& cameraToWorld [[buffer(1)]],
    constant TSDFParams& params [[buffer(2)]],                    // Contains all constants
    device BlockIndex* outputBlocks [[buffer(3)]],
    device atomic_uint& blockCount [[buffer(4)]],
    device atomic_uint& validPixelCount [[buffer(5)]],            // For valid pixel ratio gate
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check: depth map is 256×192
    if (gid.x >= 256 || gid.y >= 192) return;

    float depth = depthMap.read(gid).r;

    // Depth range filter
    if (depth < params.depthMin || depth > params.depthMax || isnan(depth) || isinf(depth)) return;

    // Confidence filter: skip confidence 0 if configured
    // confidenceMap is texture2d<uint> — .r returns uint directly, no cast needed
    uint confidence = confidenceMap.read(gid).r;
    if (params.skipLowConfidence && confidence == 0) return;

    // Count valid pixels (for frame quality gate)
    atomic_fetch_add_explicit(&validPixelCount, 1, memory_order_relaxed);

    // Back-project to camera space
    float3 pixel = float3(float(gid.x), float(gid.y), 1.0) * depth;
    float3 p_cam = intrinsicsInverse * pixel;
    float4 p_world = cameraToWorld * float4(p_cam, 1.0);

    // Select voxel size based on depth
    float voxelSize = depth < params.depthNearThreshold ? params.voxelSizeNear
                    : depth < params.depthFarThreshold  ? params.voxelSizeMid
                    :                                     params.voxelSizeFar;

    float blockWorldSize = voxelSize * float(params.blockSize);
    int3 blockIdx = int3(floor(p_world.xyz / blockWorldSize));

    // Atomic append (with overflow guard)
    uint idx = atomic_fetch_add_explicit(&blockCount, 1, memory_order_relaxed);
    if (idx < params.maxOutputBlocks) {
        outputBlocks[idx] = BlockIndex(blockIdx);
    }
}
```

**Kernel 2: TSDF Integration**
```metal
/// For each active voxel in truncation band, update SDF and weight.
/// Uses texture sampling for depth (hardware bilinear interpolation, 2D spatial cache).
/// Threadgroup: 8×8×1 = 64 threads per block (iterates over 8 Z-layers per thread)
///
/// IMPORTANT: Use `precise` qualifier on SDF arithmetic to prevent Metal compiler
/// reordering float ops, which would break cross-frame determinism.
kernel void integrateTSDF(
    texture2d<float, access::sample> depthMap [[texture(0)]],      // Sampler for bilinear
    texture2d<uint, access::read> confidenceMap [[texture(1)]],
    constant float3x3& intrinsics [[buffer(0)]],
    constant float4x4& worldToCamera [[buffer(1)]],
    constant float3& cameraPosition [[buffer(2)]],
    device TSDFVoxel* voxelBuffer [[buffer(3)]],                   // From VoxelBlockPool
    constant TSDFParams& params [[buffer(4)]],
    device BlockEntry* activeBlocks [[buffer(5)]],                 // From allocation pass
    uint3 gid [[thread_position_in_grid]],
    uint3 tgid [[threadgroup_position_in_grid]]                    // Which block
) {
    // Map threadgroup → active block
    BlockEntry block = activeBlocks[tgid.x];
    float voxelSize = block.voxelSize;
    float truncation = max(params.truncationMultiplier * voxelSize, params.truncationMinimum);

    // Map local thread position → voxel world position
    // Each thread handles one column of 8 voxels (Z-axis)
    for (int z = 0; z < 8; z++) {
        float3 voxelCenter = blockOrigin + float3(gid.x, gid.y, z) * voxelSize + voxelSize * 0.5;

        // Project to camera space
        float4 p_cam = worldToCamera * float4(voxelCenter, 1.0);
        if (p_cam.z <= 0) continue;  // Behind camera

        // Project to pixel coordinates
        float2 pixel = float2(
            intrinsics[0][0] * p_cam.x / p_cam.z + intrinsics[0][2],
            intrinsics[1][1] * p_cam.y / p_cam.z + intrinsics[1][2]
        );

        // Bounds check
        if (pixel.x < 0 || pixel.x >= 255 || pixel.y < 0 || pixel.y >= 191) continue;

        // Bilinear-sampled depth (hardware-accelerated, improves sub-pixel quality)
        constexpr sampler depthSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        float measured_depth = depthMap.sample(depthSampler, pixel + 0.5).r;

        if (isnan(measured_depth) || measured_depth < params.depthMin) continue;

        precise float sdf = measured_depth - p_cam.z;  // precise: prevent reordering

        if (sdf > truncation) continue;  // Too far in front

        // Load current voxel
        uint voxelIdx = block.poolOffset * 512 + gid.x * 64 + gid.y * 8 + z;
        half old_sdf = voxelBuffer[voxelIdx].sdf;
        // CRITICAL: weight is uint8_t on both Swift and Metal side.
        // Read as uint8_t, cast to float for arithmetic. NEVER read as half.
        // Reading uint8_t bits as half would reinterpret the bit pattern → DATA CORRUPTION.
        float old_weight = float(voxelBuffer[voxelIdx].weight);

        if (sdf < -truncation) {
            // SPACE CARVING: ray passed through previously-observed surface
            if (old_weight > 0) {
                float decayed = max(0.0f, old_weight - float(params.carvingDecayRate));
                voxelBuffer[voxelIdx].weight = uint8_t(decayed);
                if (decayed == 0.0f) {
                    voxelBuffer[voxelIdx].sdf = half(1.0);  // Reset to empty
                }
            }
            continue;
        }

        // Within truncation band — fuse
        // NOTE: confidenceMap is texture2d<uint> in BOTH kernels (consistency).
        // ARKit confidence is UInt8 (0/1/2) — uint texture type preserves integer values.
        uint confidence = confidenceMap.read(uint2(pixel)).r;
        float w_conf = params.confidenceWeights[confidence];

        // Viewing angle weight (approximate normal from SDF gradient)
        float3 viewRay = normalize(cameraPosition - voxelCenter);
        float w_angle = max(params.viewingAngleFloor, abs(dot(viewRay, float3(0,1,0))));  // Simplified

        // Distance-dependent weight
        float depth = p_cam.z;
        float w_dist = 1.0 / (1.0 + params.distanceDecayAlpha * depth * depth);

        float w_obs = w_conf * w_angle * w_dist;
        precise float sdf_normalized = clamp(sdf / truncation, -1.0f, 1.0f);

        // Running weighted average fusion (Curless & Levoy 1996)
        precise float new_sdf = (float(old_sdf) * old_weight + sdf_normalized * w_obs)
                               / (old_weight + w_obs);
        float new_weight = min(old_weight + w_obs, float(params.weightMax));

        voxelBuffer[voxelIdx].sdf = half(new_sdf);
        voxelBuffer[voxelIdx].weight = uint8_t(clamp(new_weight, 0.0f, 255.0f));
        voxelBuffer[voxelIdx].confidence = max(voxelBuffer[voxelIdx].confidence, uint8_t(confidence));
    }
}
```

### 7. MetalTSDFIntegrator (`App/TSDF/MetalTSDFIntegrator.swift`)

```swift
/// Metal compute shader orchestrator for TSDF integration
///
/// Key design decisions:
///   - CVMetalTextureCache: zero-copy wrap of ARKit CVPixelBuffer → MTLTexture
///   - .storageModeShared: unified memory on Apple Silicon (no CPU↔GPU copy)
///   - .hazardTrackingModeUntracked on voxel buffer: manual sync via MTLSharedEvent
///   - Indirect dispatch: GPU writes block count → GPU reads for integration dispatch
///   - MTLSharedEvent for CPU-GPU synchronization (lightweight, bidirectional)
///
/// Buffer strategy:
///   - Per-frame data (depth, camera): triple-buffered (semaphore, 3 copies)
///   - Voxel volume: single persistent MTLBuffer wrapping VoxelBlockPool
///   - Hash table metadata: single persistent MTLBuffer
/// Conforms to TSDFIntegrationBackend (Section 0.6) — the Metal production implementation.
/// TSDFVolume calls backend.processFrame() after all gates pass.
public final class MetalTSDFIntegrator: TSDFIntegrationBackend {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    private let allocatePipeline: MTLComputePipelineState
    private let integratePipeline: MTLComputePipelineState

    private let inflightSemaphore = DispatchSemaphore(value: TSDFConstants.metalInflightBuffers)
    private let sharedEvent: MTLSharedEvent
    private var frameNumber: UInt64 = 0

    /// Triple-buffered per-frame parameter buffers
    private var paramBuffers: [MTLBuffer]
    private var bufferIndex: Int = 0

    /// Single persistent voxel buffer — Metal wraps VoxelBlockPool's ManagedVoxelStorage
    /// via MTLBuffer(bytesNoCopy:), sharing the same physical memory (Apple Silicon unified memory).
    private var voxelBuffer: MTLBuffer  // .storageModeShared, .hazardTrackingModeUntracked

    init(device: MTLDevice, voxelStorage: VoxelBlockAccessor) throws {
        // Create voxelBuffer via device.makeBuffer(bytesNoCopy: voxelStorage.baseAddress,
        //                                          length: voxelStorage.byteCount,
        //                                          options: [.storageModeShared, .hazardTrackingModeUntracked])
        // ...
    }

    /// ┌──────────────────────────────────────────────────────────────────┐
    /// │ KERNEL SYNCHRONIZATION: Two Command Buffers                     │
    /// │                                                                 │
    /// │ Kernel 1 (projectDepthAndAllocate) outputs a list of block     │
    /// │ indices to allocate. The CPU must process this list (allocate  │
    /// │ blocks in SpatialHashTable, build BlockEntry array with pool   │
    /// │ offsets). Only THEN can Kernel 2 (integrateTSDF) run.         │
    /// │                                                                 │
    /// │ Solution: TWO command buffers per frame.                       │
    /// │   CB1: Kernel 1 → commit → waitUntilCompleted (CPU blocks)    │
    /// │   CPU: Read outputBlocks buffer, allocate in hash table,      │
    /// │        build BlockEntry array, fill TSDFParams buffer          │
    /// │   CB2: Kernel 2 → commit → addCompletedHandler (async)        │
    /// │                                                                 │
    /// │ WHY NOT MTLSharedEvent between kernels in one CB?              │
    /// │   MTLSharedEvent can signal CPU, but the CPU work (hash table  │
    /// │   allocation) is substantial (~0.5ms). Blocking the GPU for    │
    /// │   0.5ms wastes more than the overhead of two commit() calls.   │
    /// │   Two CBs also simplify error handling (CB1 failure → skip CB2)│
    /// └──────────────────────────────────────────────────────────────────┘

    // ── TSDFIntegrationBackend protocol conformance ──
    // This is the method TSDFVolume calls via the protocol.
    // On Metal path: depthData parameter is IGNORED — we use SceneDepthFrame's
    // CVPixelBuffer directly via CVMetalTextureCache (zero-copy MTLTexture).
    // The SceneDepthFrame is captured separately by the App/ layer and passed
    // to this class before TSDFVolume calls processFrame().

    /// Stored reference to the current frame's SceneDepthFrame for Metal texture creation.
    /// Set by the App/ layer (ScanViewModel) BEFORE calling tsdfVolume.integrate().
    private var currentDepthFrame: SceneDepthFrame?

    /// App/ layer calls this to stage the CVPixelBuffer for Metal processing.
    func prepareFrame(_ depthFrame: SceneDepthFrame) {
        self.currentDepthFrame = depthFrame
    }

    /// TSDFIntegrationBackend conformance — called by TSDFVolume after all gates pass.
    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,    // Ignored on Metal path — uses CVMetalTextureCache
        volume: VoxelBlockAccessor,
        activeBlocks: [BlockIndex]
    ) async -> IntegrationStats {
        guard let depthFrame = currentDepthFrame else {
            return IntegrationStats(blocksUpdated: 0, blocksAllocated: 0,
                                    voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0)
        }

        // Wait on semaphore (with timeout guard)
        let waitResult = inflightSemaphore.wait(
            timeout: .now() + .milliseconds(Int(TSDFConstants.semaphoreWaitTimeoutMs))
        )
        if waitResult == .timedOut {
            return IntegrationStats(blocksUpdated: 0, blocksAllocated: 0,
                                    voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0)
        }

        bufferIndex = (bufferIndex + 1) % TSDFConstants.metalInflightBuffers

        // Zero-copy texture wrap via CVMetalTextureCache
        // SceneDepthFrame.depthMap is CVPixelBuffer (Float32, 256×192) → .r32Float
        // SceneDepthFrame.confidenceMap is CVPixelBuffer? (UInt8, 256×192) → .r8Uint
        let depthTexture = try! createTexture(from: depthFrame.depthMap, format: .r32Float)
        let confTexture = try! createTexture(from: depthFrame.confidenceMap!, format: .r8Uint)

        // ── COMMAND BUFFER 1: Allocation kernel ──
        guard let cb1 = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return IntegrationStats(blocksUpdated: 0, blocksAllocated: 0,
                                    voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0)
        }
        // Encode Kernel 1 (projectDepthAndAllocate)
        // ... encode allocatePipeline with depthTexture, confTexture, params ...
        cb1.commit()
        cb1.waitUntilCompleted()  // CPU blocks here (~0.3ms for 256×192)

        if cb1.status == .error {
            inflightSemaphore.signal()
            return IntegrationStats(blocksUpdated: 0, blocksAllocated: 0,
                                    voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0)
        }

        // ── CPU: Read allocation results, build block entries ──
        // Read blockCount from atomic output buffer
        // For each unique BlockIndex: allocate in hash table, get pool offset
        // Build BlockEntry array with {blockIndex, poolOffset, voxelSize, worldOrigin}

        // ── COMMAND BUFFER 2: Integration kernel ──
        guard let cb2 = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return IntegrationStats(blocksUpdated: 0, blocksAllocated: 0,
                                    voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0)
        }

        cb2.addCompletedHandler { [weak self] buffer in
            self?.inflightSemaphore.signal()
            if buffer.status == .error {
                // Log error, trigger AIMD multiplicative decrease
            }
        }

        // Encode Kernel 2 (integrateTSDF) with BlockEntry array from CPU step
        // ... encode integratePipeline with depthTexture, confTexture, blockEntries, voxelBuffer ...
        cb2.commit()
        frameNumber += 1
        currentDepthFrame = nil  // Release CVPixelBuffer reference

        return IntegrationStats(
            blocksUpdated: /* from CB2 result */, blocksAllocated: /* from CB1 result */,
            voxelsUpdated: /* from CB2 result */, gpuTimeMs: /* GPU time */,
            totalTimeMs: /* wall-clock time */
        )
    }
}
```

### 8. MarchingCubes (`Core/TSDF/MarchingCubes.swift`)

```swift
/// Incremental Marching Cubes — only processes dirty blocks + neighbors
///
/// Algorithm:
///   1. Collect dirty blocks: where integrationGeneration > meshGeneration
///   2. For each dirty block, ALSO include its 6 face-adjacent neighbors
///      (MC samples voxels across block boundaries — without this, seam artifacts appear)
///      Reference: nvblox ICRA 2024
///   3. Sort by staleness (integrationGeneration - meshGeneration) descending
///   4. Process up to maxTrianglesPerCycle budget
///   5. For each 8-voxel cube: classify vertices, lookup table, interpolate
///   6. Reject degenerate triangles (area < 1e-8 m², aspect ratio > 100:1)
///   7. Compute normals from SDF gradient (central differences)
///   8. Update meshGeneration = integrationGeneration for processed blocks
///
/// Performance: ~0.034ms per block on A14 CPU → 50K triangles in ~1.7ms
public struct MarchingCubesExtractor {
    /// Paul Bourke's classic 256-entry edge table and triangle table
    private static let edgeTable: [Int] = [ /* 256 entries */ ]
    private static let triTable: [[Int]] = [ /* 256 × max 15 entries */ ]

    /// 6 face-adjacent neighbor offsets for seam-free meshing
    private static let neighborOffsets: [BlockIndex] = [
        BlockIndex(1,0,0), BlockIndex(-1,0,0),
        BlockIndex(0,1,0), BlockIndex(0,-1,0),
        BlockIndex(0,0,1), BlockIndex(0,0,-1)
    ]

    /// Extract mesh from dirty blocks with budget constraint
    public static func extractIncremental(
        hashTable: SpatialHashTable,
        maxTriangles: Int = TSDFConstants.maxTrianglesPerCycle
    ) -> MeshOutput { ... }

    /// Extract triangles from a single VoxelBlock
    /// Requires access to neighbor blocks for boundary voxels
    public static func extractBlock(
        _ block: VoxelBlock,
        neighbors: [BlockIndex: VoxelBlock],
        origin: TSDFFloat3,
        voxelSize: Float
    ) -> [MeshTriangle] { ... }

    /// Reject degenerate triangles.
    /// Takes 3 world-space vertex positions (NOT MeshTriangle indices).
    /// Called during extraction BEFORE adding to MeshOutput.
    static func isDegenerate(v0: TSDFFloat3, v1: TSDFFloat3, v2: TSDFFloat3) -> Bool {
        let area = cross(v1 - v0, v2 - v0).length() * 0.5
        if area < TSDFConstants.minTriangleArea { return true }
        let edges = [
            (v1 - v0).length(),
            (v2 - v1).length(),
            (v0 - v2).length()
        ]
        let ratio = edges.max()! / max(edges.min()!, 1e-10)
        if ratio > TSDFConstants.maxTriangleAspectRatio { return true }
        return false
    }
}
```

### 9. Integration with ScanViewModel

Replace the MeshExtractor call path. **Minimal changes — do NOT rewrite ScanViewModel; that's PR#7's job.**

**Before (current):**
```
ARFrame → MeshExtractor.extract(anchors) → meshTriangles → render
```

**After (PR#6):**
```
ARFrame → LiDARDepthProcessor.processSceneDepth(frame)
       → TSDFVolume.integrate(depthFrame, trackingState)
       → TSDFVolume.extractMesh()
       → render
```

**ScanViewModel additions (minimal):**
```swift
// In ScanViewModel:
private var tsdfVolume: TSDFVolume?         // NEW: actor, created in startScan()
private var metalIntegrator: MetalTSDFIntegrator?  // NEW: Metal orchestrator

// In ARSessionDelegate callback — construct IntegrationInput from SceneDepthFrame:
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // Existing: thermalAdapter, evidence system, etc.

    // NEW: TSDF integration
    guard let sceneDepth = frame.sceneDepth else { return }
    let input = IntegrationInput(
        timestamp: frame.timestamp,
        intrinsics: frame.camera.intrinsics,
        cameraToWorld: frame.camera.transform,
        depthWidth: CVPixelBufferGetWidth(sceneDepth.depthMap),
        depthHeight: CVPixelBufferGetHeight(sceneDepth.depthMap),
        trackingState: frame.camera.trackingState == .normal ? 2 : 1
    )
    Task {
        // Stage the CVPixelBuffer for Metal zero-copy texture creation
        metalIntegrator?.prepareFrame(SceneDepthFrame(from: frame))

        // For Metal path: depthData is ignored by MetalIntegrationBackend
        // (it uses CVMetalTextureCache zero-copy directly from SceneDepthFrame).
        // We pass an empty ArrayDepthData as placeholder — TSDFVolume only needs
        // the input matrices for gate checks. The backend receives depth via MTLTexture.
        let depthData = ArrayDepthData(width: 0, height: 0, depths: [], confidences: [])
        let result = await tsdfVolume?.integrate(input: input, depthData: depthData)
    }
}

// In setupThermalMonitoring() — ADD parallel forwarding:
thermalObserver = NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, ...
) { [weak self] _ in
    Task { @MainActor in
        let state = ProcessInfo.processInfo.thermalState
        self?.thermalAdapter.updateThermalState(state)       // EXISTING: rendering (static tier)
        await self?.tsdfVolume?.handleThermalState(state.rawValue)  // NEW: integration (AIMD ceiling)
    }
}

// Memory pressure — ADD:
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification, ...
) { [weak self] _ in
    Task {
        await self?.tsdfVolume?.handleMemoryPressure(level: .warning)
    }
}
```

**Key design: separation of platform types from Core/ logic.**
- `IntegrationInput` is `Sendable` struct with pure numerics → Core/ layer, Linux-compilable
- `SceneDepthFrame` has CVPixelBuffer + ARCamera → App/ layer only
- App/ constructs IntegrationInput from SceneDepthFrame, passes to TSDFVolume
- App/ simultaneously passes SceneDepthFrame to MetalTSDFIntegrator for GPU zero-copy
- This is cleaner than the existing pattern where SceneDepthFrame crosses the Core/App boundary

---

## Safety & Stability Guardrails (32 total)

### Category A: Core Guardrails (8)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 1 | Memory pressure | `didReceiveMemoryWarning` | Tiered eviction (stale → far → all) | iOS notification |
| 2 | Thermal AIMD | `thermalState >= .fair` OR GPU overrun | **INNOVATION: AIMD replaces static tiers.** System thermal sets CEILING (`.fair`→skip-2, `.serious`→skip-4, `.critical`→skip-12). Within ceiling, AIMD adapts: GPU overrun → 2× skip (instant), N good frames → skip-1 (gradual). Auto-recovers when load drops — ThermalQualityAdapter (rendering) CANNOT do this. Asymmetric hysteresis: 10s degrade / 5s recover. | Ceiling: 30/15/5fps. Actual: AIMD within ceiling. |
| 3 | Frame timeout | `integrate() > integrationTimeoutMs` | Skip frame, log | 10ms |
| 4 | Voxel block cap | `pool.allocatedCount > maxTotalVoxelBlocks` | LRU eviction by lastObservedTimestamp | 100,000 blocks |
| 5 | NaN/Inf guard | `isnan(depth)` or `isinf(sdf)` | Skip voxel update | Any NaN/Inf |
| 6 | Hash probe overflow | Linear probe > `hashMaxProbeLength` | Rehash with 2× table | 128 probes |
| 7 | Depth range | `depth < 0.1m` or `depth > 5.0m` | Skip pixel | 0.1m / 5.0m |
| 8 | Weight overflow | `weight + w_obs > 255` | Clamp to `weightMax` | 64 |

### Category B: Camera Pose Quality (6)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 9 | Tracking state | `trackingState != .normal` | Skip entire frame | `.limited` or `.notAvailable` |
| 10 | Pose teleport | Position delta > threshold | Skip integration; 3 consecutive → pause integration + toast (rendering continues) | 10cm/frame |
| 11 | Rotation speed | Angular velocity > threshold | Skip frame, fire haptic | 2.0 rad/s (115°/s) |
| 12 | Consecutive rejections | N frames rejected in a row | 30 frames: toast "Move slower"; 180 frames: prominent warning overlay (rendering continues with stale mesh) | 0.5s / 3.0s |
| 13 | Loop closure drift | Anchor transform shift | Mark affected blocks stale, skip 5 frames | 2cm |
| 14 | Pose smoothness | Sudden acceleration spike | Reduce integration weight by 50% | Jerk > 10m/s³ |

### Category C: Depth Map Quality (4)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 15 | Valid pixel ratio | % valid depth pixels too low | Skip frame entirely | < 30% |
| 16 | Confidence filter | ARKit confidence == 0 | Skip pixel (configurable) | Per-pixel |
| 17 | Distance-dependent weight | Quadratic noise model | Weight *= 1/(1+0.1×d²) | α = 0.1 |
| 18 | Viewing angle weight | Grazing angle observation | Weight *= max(0.1, cos(θ)) | Floor: 0.1 |

### Category D: GPU / Metal Safety (5)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 19 | Command buffer error | `MTLCommandBuffer.status == .error` | Log, recreate resources if needed | Every frame |
| 20 | GPU buffer overflow | Write exceeds `MTLBuffer.length` | Grow buffer or evict blocks | Usage > 80% |
| 21 | Semaphore deadlock | Wait timeout exceeded | Skip frame | 100ms |
| 22 | Threadgroup validation | Threads exceed pipeline limit | Clamp to `maxTotalThreadsPerThreadgroup` | At pipeline creation |
| 23 | GPU memory tracking | `device.currentAllocatedSize` high | Proactive eviction → aggressive eviction | 500MB / 800MB |

### Category E: Volume Integrity (4)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 24 | Hash load factor | Load > threshold | Proactive rehash at 0.7 | 0.6 warn / 0.7 rehash |
| 25 | Truncation sanity | τ < 2 × voxelSize | Force minimum: `max(2×voxelSize, configured)` | Safety floor |
| 26 | SDF range | Normalized SDF outside [-1.0, +1.0] | Clamp; log if > 1% of voxels affected | ±1.0 |
| 27 | Stale block age | Block not observed for extended time | 30s: low-priority evict; 60s: force evict | 30s / 60s |

### Category F: Mesh Quality (3)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 28 | Degenerate triangle | Area < threshold or aspect > threshold | Reject triangle | area < 1e-8 m², ratio > 100:1 |
| 29 | Neighbor-dirty | Block dirty → neighbors must re-mesh | Include 6 face-adjacent blocks | Always |
| 30 | Mesh vertex cap | Total triangles exceed rendering budget | Stop extraction, carry over dirty list | 50,000 triangles |

### Category G: Numerical Precision (2)

| # | Guardrail | Trigger | Action | Threshold |
|---|-----------|---------|--------|-----------|
| 31 | World origin drift | Camera far from origin | Recenter origin, offset all blocks | 100m |
| 32 | Shader determinism | Metal compiler float reordering | Use `precise` qualifier on SDF math | Compile-time |

---

## User Experience: Buttery-Smooth Scanning (CRITICAL)

These optimizations are **not optional polish** — they are the difference between a professional scanning experience and a jittery tech demo. Implement ALL of them.

### UX-1: SDF Dead Zone — Eliminate Vertex "Swimming" at the Source

**The #1 user-visible quality killer.** Each frame's TSDF running-average shifts voxel SDF values by micrometers. Marching Cubes repositions vertices accordingly, making the entire surface appear to "breathe" underwater.

**Fix:** Skip voxel SDF updates when the change is below perceptual threshold:
```swift
// In integration kernel / CPU loop:
let sdfDelta = abs(newSDF - currentSDF)
let deadZone = TSDFConstants.sdfDeadZoneBase + TSDFConstants.sdfDeadZoneWeightScale * (Float(weight) / Float(TSDFConstants.weightMax))
if sdfDelta < deadZone { return }  // Skip update — no visible change
```
Constants:
```swift
/// SDF dead zone base: 1mm for fresh voxels (weight ≈ 0)
public static let sdfDeadZoneBase: Float = 0.001
/// SDF dead zone at max weight: 5mm for fully converged voxels
public static let sdfDeadZoneWeightScale: Float = 0.004
```
**Effect:** Eliminates ~60-70% of vertex jitter with zero visual quality loss.

### UX-2: Vertex Grid Quantization — Snap to Perceptual Grid

After Marching Cubes extracts vertices, snap to a 0.5mm grid:
```swift
let step: Float = TSDFConstants.vertexQuantizationStep  // 0.0005m
vertex.position = round(vertex.position / step) * step
```
Constants:
```swift
/// Vertex position quantization step (meters)
/// 0.5mm = below visual perception at any scanning distance
public static let vertexQuantizationStep: Float = 0.0005
```
**Effect:** Perturbations under 0.25mm produce zero vertex movement.

### UX-3: Decoupled Integration/Meshing/Rendering Rates

**Integration:** Up to 60fps — GPU, ~1-2ms. May be skipped by pose jitter gate (UX-7), thermal throttle (Guardrail #2), or depth-adaptive rate (EP-8). Skipping integration is FINE — it preserves converged quality.
**Mesh extraction:** Adaptive 10-20 Hz — CPU, ~3-6ms. Deferred during rapid motion (UX-11). Budget-capped by congestion control (UX-9).
**Rendering:** Every frame (60fps) — ALWAYS draws the previous mesh. NEVER waits on integration or extraction. This is the one rate that never drops.

The three pipelines are fully independent. Rendering is never gated by the other two.

**Timing budget per 16.67ms render frame (worst case, all pipelines active):**
```
ARKit callback overhead:          ~1-2ms
Integration gates (CPU):          ~0.1ms  (gates are trivial comparisons)
GPU integration dispatch (CPU):   ~0.5ms  (encode + commit)
GPU integration compute:          ~2-5ms  (async, overlaps with CPU work)
Meshing (CPU, if this is a mesh cycle): ~3-5ms  (amortized: runs 1 in 6 frames)
Rendering:                        ~3-5ms  (PR#7 Filament draws front buffer)
Idle/headroom:                    ~2-5ms
───────────────────────────────────────
Total:                            ≤ 16.67ms
```
Note: GPU integration and CPU meshing CAN overlap (GPU runs async after commit). The critical path is: callback → gates → GPU encode → [GPU runs async] → [CPU meshes while GPU works] → render.

Constants:
```swift
/// Mesh extraction target rate (Hz) — NOT tied to display refresh
/// 10Hz = 100ms latency (acceptable), 6× fewer jitter events than 60Hz
public static let meshExtractionTargetHz: Float = 10.0

/// Mesh extraction maximum time budget per cycle (milliseconds)
/// Must leave room for integration + rendering within 16.67ms frame
public static let meshExtractionBudgetMs: Double = 5.0
```
**Critical rule:** Renderer ALWAYS draws the previous mesh. Never block rendering waiting for new mesh.

### UX-4: Double-Buffered Mesh Output

Two mesh buffers. Extraction writes to back buffer, renderer reads front buffer, swap atomically on completion.
```swift
/// Two mesh buffers: front (rendering) and back (extraction)
/// Swap is a pointer swap — zero copy, zero contention
private var meshBuffers: [MeshOutput] = [MeshOutput(), MeshOutput()]
private var frontIndex: Int = 0
```
**Effect:** Zero contention between extraction thread and render thread. Impossible to see a half-updated mesh.

### UX-5: SDF-Gradient Normals (NOT Triangle Normals)

Compute vertex normals from the SDF field gradient using central differences, NOT from triangle cross products. The SDF field is inherently smooth (weighted average of many frames), producing dramatically smoother lighting than per-triangle normals.

```swift
// In MarchingCubes vertex extraction:
func sdfGradientNormal(at position: TSDFFloat3, voxelSize: Float) -> TSDFFloat3 {
    let dx = querySDF(position + TSDFFloat3(voxelSize, 0, 0)) - querySDF(position - TSDFFloat3(voxelSize, 0, 0))
    let dy = querySDF(position + TSDFFloat3(0, voxelSize, 0)) - querySDF(position - TSDFFloat3(0, voxelSize, 0))
    let dz = querySDF(position + TSDFFloat3(0, 0, voxelSize)) - querySDF(position - TSDFFloat3(0, 0, voxelSize))
    return normalize(TSDFFloat3(dx, dy, dz))
}
```
**Effect:** Lighting quality comparable to offline rendering. Used by KinectFusion and InfiniTAM.

### UX-6: Marching Cubes Interpolation Clamping

Clamp the `t` parameter in zero-crossing interpolation to `[0.1, 0.9]`:
```swift
// Standard MC interpolation: t = -sdf0 / (sdf1 - sdf0)
// Clamped: prevents vertices from sitting at voxel corners where noise sensitivity is highest
let t = clamp(-sdf0 / (sdf1 - sdf0), TSDFConstants.mcInterpolationMin, TSDFConstants.mcInterpolationMax)
```
Constants:
```swift
/// MC interpolation t-parameter clamp range
/// Prevents vertices at voxel corners (maximum noise sensitivity)
public static let mcInterpolationMin: Float = 0.1
public static let mcInterpolationMax: Float = 0.9
```
**Effect:** Reduces worst-case vertex jitter by ~5×.

### UX-7: Pose Jitter Gate — Skip Redundant Integrations

When the user holds the camera nearly still, each frame's tiny pose noise DEGRADES already-converged voxels. Skip integration entirely when motion is below threshold:
```swift
// Skip if camera barely moved since last integration
if translationDelta < TSDFConstants.poseJitterGateTranslation
    && rotationDelta < TSDFConstants.poseJitterGateRotation {
    return .skipped(.poseJitter)
}
```
Constants:
```swift
/// Minimum camera translation to trigger integration (meters)
/// Below 1mm: pose noise dominates, integration hurts quality
public static let poseJitterGateTranslation: Float = 0.001

/// Minimum camera rotation to trigger integration (radians)
/// Below 0.002 rad (0.11°): rotational noise dominates
public static let poseJitterGateRotation: Float = 0.002
```
**Effect:** Skips 50-80% of frames when user is "still", preserving surface quality.

### UX-8: Progressive Mesh Reveal (Anti-Pop-In)

New blocks should NOT instantly appear as solid mesh. Require minimum observations before meshing, then fade in:
```swift
// Gate: do not extract mesh for blocks with fewer than 3 observations
guard block.integrationGeneration >= TSDFConstants.minObservationsBeforeMesh else { continue }

// Fade-in: ease-out curve over ~230ms
let age = Float(block.integrationGeneration - TSDFConstants.minObservationsBeforeMesh)
let t = min(age / Float(TSDFConstants.meshFadeInFrames), 1.0)
let alpha = 1.0 - pow(1.0 - t, 2.5)  // Ease-out
```
Constants:
```swift
/// Minimum integration observations before mesh extraction
/// 3 frames at 30Hz = 100ms — enough for basic surface convergence
public static let minObservationsBeforeMesh: UInt32 = 3

/// Fade-in duration (frames after minimum observations met)
/// 7 frames at 30Hz ≈ 230ms — smooth perceptual reveal
public static let meshFadeInFrames: Int = 7
```
**How alpha reaches the renderer:** MeshOutput includes a per-vertex `alpha: Float` field (packed alongside position + normal). During extraction, each vertex inherits its parent block's fade-in alpha. The renderer (PR#7 Filament) reads this as vertex color alpha. Blocks that have fully faded in (alpha=1.0) are compacted to save bandwidth — their alpha field is omitted.

**How quality reaches the renderer (for glass-shard tessellation):** MeshOutput includes a per-vertex `quality: Float` field ∈ [0.0, 1.0], computed as:
```swift
quality = Float(block.weight) / Float(TSDFConstants.weightMax)
// weight=0 → quality=0.0 (freshly allocated, coarse visualization)
// weight=64 → quality=1.0 (fully converged, finest visualization)
```
PR#7 uses this `quality` value to drive GPU tessellation:
- quality < 0.2 → no subdivision (large coarse triangles, glass-shard初期)
- quality 0.2–0.6 → 4× subdivision (碎片化开始)
- quality 0.6–0.9 → 16× subdivision (密集的小碎片)
- quality > 0.9 → 64× subdivision + alpha→0 (碎片消失，露出颜色)

PR#6 只负责输出 quality 值。tessellation 细分和视觉效果完全是 PR#7 的工作。

**MeshVertex layout (PR#6 output, PR#7 consumes):**
```swift
public struct MeshVertex: Sendable {
    public var position: TSDFFloat3   // World-space position (cross-platform, Section 0.1)
    public var normal: TSDFFloat3     // SDF-gradient normal (UX-5)
    public var alpha: Float           // Fade-in from UX-8 (0→1)
    public var quality: Float         // Block convergence from weight/maxWeight (0→1)
}
```

**Effect:** New geometry appears with a smooth "growing" animation, not jarring pop-in.

### UX-9: TCP-Style Congestion Control on Dirty Block Budget

Prevent stutter-burst cascades with game-engine-inspired adaptive budgeting.

**Measured quantity:** `meshExtractionTimeMs` — the wall-clock time of each meshing cycle (runs at 10-20Hz, NOT every render frame). Measured by `CFAbsoluteTimeGetCurrent()` around `extractMesh()`.

```swift
// On meshing cycle overrun (>5ms): halve dirty block batch immediately
if meshExtractionTimeMs > TSDFConstants.meshBudgetOverrunMs {
    maxBlocksPerExtraction = max(maxBlocksPerExtraction / 2, TSDFConstants.minBlocksPerExtraction)
    goodCycleStreak = 0
    enterForgiveness(cycles: TSDFConstants.forgivenessWindowCycles)
}
// On good meshing cycle (<3ms) after 3 consecutive good cycles: add blocks
else if meshExtractionTimeMs < TSDFConstants.meshBudgetGoodMs {
    goodCycleStreak += 1
    if goodCycleStreak >= TSDFConstants.consecutiveGoodCyclesBeforeRamp {
        maxBlocksPerExtraction = min(maxBlocksPerExtraction + TSDFConstants.blockRampPerCycle,
                                      TSDFConstants.maxBlocksPerExtraction)
    }
}
```
Constants:
```swift
/// Mesh extraction budget thresholds for congestion control
/// These apply to meshing cycles (10-20Hz), NOT render frames (60Hz)
public static let meshBudgetTargetMs: Double = 4.0     // Target per meshing cycle
public static let meshBudgetGoodMs: Double = 3.0       // "Good" cycle
public static let meshBudgetOverrunMs: Double = 5.0    // Overrun trigger (= meshExtractionBudgetMs)

/// Congestion control parameters (TCP AIMD-inspired)
public static let minBlocksPerExtraction: Int = 50       // Floor: always make progress
public static let maxBlocksPerExtraction: Int = 250      // Ceiling: per-device calibration
public static let blockRampPerCycle: Int = 15             // Additive increase per meshing cycle
public static let consecutiveGoodCyclesBeforeRamp: Int = 3
public static let forgivenessWindowCycles: Int = 5       // Cooldown after overrun

/// Slow start after recovery: begin at 25% of previous throughput
public static let slowStartRatio: Float = 0.25
```
**Effect:** Mesh extraction never blocks rendering. Overrun in meshing reduces next cycle's work; render frame rate stays locked at 60fps regardless.

### UX-10: Cross-Block Normal Averaging

Average normals for vertices within 1mm of block boundaries to eliminate visible seams:
```swift
/// Distance from block boundary to apply normal averaging (meters)
/// 1mm = one voxel at near resolution. Eliminates seam lighting artifacts.
public static let normalAveragingBoundaryDistance: Float = 0.001
```
**Effect:** Block boundaries become invisible under any lighting condition.

### UX-11: Motion-Adaptive Mesh Deferral

When user moves fast, they can't see mesh detail anyway. Defer mesh extraction during rapid motion, giving all budget to integration:
```swift
/// Translation speed above which mesh extraction is deferred (m/s)
/// 0.5 m/s = brisk walking pace. User notices motion blur, not mesh staleness.
public static let motionDeferTranslationSpeed: Float = 0.5

/// Angular speed above which mesh extraction is deferred (rad/s)
/// Set BELOW Guardrail #11 (2.0 rad/s, which skips the entire frame).
/// At 1.0 rad/s, the frame still integrates (capturing geometry), but meshing is deferred.
/// At 2.0 rad/s, Guardrail #11 kicks in and skips the frame entirely.
/// So: 0-1.0 = normal, 1.0-2.0 = integrate but defer mesh, >2.0 = skip everything.
public static let motionDeferAngularSpeed: Float = 1.0
```
**Effect:** Three-tier motion response: slow=full pipeline, medium=integrate only, fast=skip all. Smooth degradation instead of a hard cliff.

### UX-12: Idle Budget Utilization

When camera is nearly still (`<1cm/s translation, <3°/s rotation`), use spare frame budget productively:

1. **Priority 1:** Process deferred dirty blocks from backlog
2. **Priority 2:** Refine normals for near-camera blocks (higher-quality gradient computation)
3. **Priority 3:** Pre-allocate blocks along predicted motion vector, 0.5m ahead

```swift
/// Idle detection thresholds
public static let idleTranslationSpeed: Float = 0.01     // m/s
public static let idleAngularSpeed: Float = 0.05          // rad/s (~3°/s)

/// Anticipatory pre-allocation distance (meters ahead of camera)
public static let anticipatoryPreallocationDistance: Float = 0.5
```
**Effect:** Idle time is never wasted. User sees progressively improving mesh when holding still.

### UX Summary: The "Buttery Smooth" Stack

```
Layer 0 (Gate Chain): Track→Teleport→JitterGate→Thermal→ValidPixels (5 gates, <0.1ms)
Layer 1 (Input):      Bilateral filter + temporal accumulator (clean depth data)
Layer 2 (Fusion):     SDF dead zone + distance/angle weighting (stable voxels)
Layer 3 (Meshing):    Decoupled 10Hz rate + interpolation clamping + vertex quantization (stable vertices)
Layer 4 (Normals):    SDF-gradient normals + cross-block averaging (smooth lighting)
Layer 5 (Reveal):     Min 3 observations + per-vertex alpha fade-in (no pop-in)
Layer 6 (Pacing):     TCP congestion control + 3-tier motion response + idle utilization (zero stutter)
Layer 7 (Output):     Double-buffered mesh + atomic front/back swap (no tearing)
Layer 8 (Rendering):  60fps locked, reads front buffer only, never waits (guaranteed smoothness)
```

**Motion response tiers (UX-7 + UX-11 + Guardrail #11):**
```
Camera speed:        |  Still  |  Slow   |  Medium  |  Fast   |  Very fast  |
                     | <1mm/s  | <0.5m/s | 0.5-1m/s | 1-2m/s  | >2m/s       |
Integration:         | Skip    | 60fps   | 60fps    | 60fps   | Skip frame  |
                     | (UX-7)  | (full)  | (full)   | (full)  | (Guard #11) |
Meshing:             | Backlog | Normal  | Deferred | Deferred| N/A         |
                     | (UX-12) | (10Hz)  | (UX-11)  | (UX-11) | (skipped)   |
Idle work:           | Yes     | No      | No       | No      | No          |
                     | (UX-12) |         |          |         |             |
```

Each layer attacks a different source of visual instability. Together they produce a scanning experience where the mesh appears to "grow" smoothly and solidly, never jittering, never popping, never stuttering.

---

## Competitive Edge: Industry Technique Library

**Our architecture: 端侧实时TSDF重建 + 云端高精度后处理渲染。** PR#6 负责端侧部分。

Below is every technique we borrow from competitors and big tech, with:
- **Origin**: Who does it and how
- **Principle**: The underlying technical mechanism
- **Why we borrow it**: What gap in our pipeline it fills
- **How we surpass it**: Our adaptation that goes beyond the original

### Scanning UX Techniques (from competitors)

#### CE-1: Sub-Second First Mesh (from Polycam)
- **Origin:** Polycam shows a rough mesh within ~1 second of starting a LiDAR scan, then progressively refines.
- **Principle:** First frame's depth map → instant point cloud or coarse mesh. Subsequent frames refine via TSDF convergence. The key is NOT waiting for convergence before showing anything.
- **Why we borrow:** Users perceive "nothing happening" as broken. First visual feedback must appear in < 1 second.
- **How we surpass:** Our UX-8 (progressive reveal) already gates mesh on 3 observations + fade-in. We add a **Phase 0 point cloud**: on the very first frame, render the raw 256×192 depth pixels as a colored point cloud (< 0.1ms). This transitions to TSDF mesh as blocks converge. The point cloud becomes invisible once real mesh covers the same region. Polycam doesn't blend — they cut. We cross-fade.

#### CE-2: Semantic Object Masking (from Polycam)
- **Origin:** Polycam can isolate the scanned object from background clutter, showing only the target.
- **Principle:** ARKit's `personSegmentationWithDepth` or custom ML segmentation generates a per-pixel mask. Pixels outside the mask are excluded from TSDF integration.
- **Why we borrow:** Users scanning a single object don't want the table, floor, and wall in their model.
- **How we surpass:** Our Voxel `reserved[3]` byte can store a semantic label (0=background, 1=target, 2=support surface). During integration, ARKit's `sceneUnderstanding` semantics classify each pixel. During mesh extraction, blocks with label=0 are skipped. This is more principled than a binary mask — it enables selective export per semantic class. Implementation is a future PR, but the data path is ready now.

#### CE-3: On-Device Post-Processing Pipeline (from Scaniverse)
- **Origin:** Scaniverse performs 100% on-device processing including Gaussian Splatting training in ~1 minute.
- **Principle:** After scan stops, a local optimization pass refines geometry and/or trains 3DGS using captured frames.
- **Why we borrow the technique, NOT the destination:** We use端侧TSDF for real-time preview quality, then upload to cloud for production-grade rendering. But the technique of using TSDF geometry as initialization for a refinement pass is valuable — our cloud pipeline can start from our TSDF mesh instead of raw point cloud, cutting cloud processing time significantly.
- **How we surpass:** Scaniverse is limited to local device compute. We use local TSDF mesh as a warm start for cloud 3DGS/NeRF, achieving quality impossible on-device. The端侧mesh is "good enough" for instant preview; cloud delivers the final product. Best of both worlds.

#### CE-4: Auto-Completion Detection (from RealityScan)
- **Origin:** RealityScan detects when an object is fully covered from all angles and prompts the user to stop scanning.
- **Principle:** Track the ratio of observed surface area to estimated total surface area. When coverage exceeds a threshold, the object is "complete."
- **Why we borrow:** Users don't know when to stop scanning. Scanning too little = holes. Scanning too much = wasted time + thermal throttling.
- **How we surpass:** RealityScan uses image overlap heuristics. We have per-voxel observation counts (weight field) + PR#5's evidence grid. We can compute **per-block coverage confidence**: a block with all voxels at weight > 10 from 3+ distinct viewing angles is "fully converged." Sum across blocks = overall completion percentage. More rigorous than image-based heuristics.

#### CE-5: Transparent Degradation with Continued Operation (from KIRI Engine)
- **Origin:** KIRI offloads complex scans to the cloud when device compute is insufficient, with status messaging.
- **Principle:** Detect when the scan approaches device limits and communicate this to the user rather than silently failing.
- **Why we borrow:** Silent degradation is the worst UX. Users must understand what's happening.
- **How we surpass:** KIRI's approach is binary: "device can't handle it, wait for cloud." We **never stop scanning**. Our 32 guardrails handle every limit scenario with graduated degradation — not shutdown:
  - Memory pressure → tiered eviction reclaims space, scanning continues at the same quality for nearby geometry (Guardrails #1/#4/#27)
  - Thermal critical → reduce integration rate 60→30→15fps, scanning continues with slightly longer convergence time (Guardrail #2)
  - Block cap → LRU eviction of far/stale blocks, scanning continues in the current region (Guardrail #4)
  - Each degradation triggers a **specific, honest toast message** (e.g., "Far-away geometry simplified to free up memory") instead of a generic error
  - Cloud post-processing receives whatever the端侧 captured — even a degraded端侧 scan gives cloud a better warm start than no scan at all
  - **Key difference from KIRI:** We never ask the user to wait. The scanning experience is continuous and responsive at all times. Degradation is invisible to the user in the common case.

#### CE-6: Multi-Format Export with LOD (from Scaniverse + Polycam)
- **Origin:** Both apps offer mesh simplification and multi-format export (USDZ, OBJ, GLTF, STL, PLY).
- **Principle:** Quadric error metric (QEM) edge collapse to reduce triangle count while preserving visual quality. Multiple LOD levels for different use cases.
- **Why we borrow:** Users export to wildly different targets — 3D printing needs watertight OBJ, AR preview needs lightweight USDZ, engineering needs precise STL.
- **How we surpass:** Our MeshOutput includes `triangleCount` metadata. MeshSimplifier (FP-5) will generate LODs on-device for instant preview export, while cloud generates the final high-poly textured model. Neither Polycam nor Scaniverse can produce cloud-refined output.

### Platform Techniques (from big tech)

#### CE-7: Parametric Surface Fitting (from Apple RoomPlan)
- **Origin:** RoomPlan uses ML to detect walls, floors, ceilings and fits parametric planes/boxes to them, producing clean CAD-like geometry.
- **Principle:** Plane detection via RANSAC on point clusters → least-squares plane fitting → replace noisy mesh region with clean parametric surface.
- **Why we borrow:** TSDF Marching Cubes produces noisy flat surfaces (walls look bumpy). Parametric fitting cleans them up.
- **How we surpass:** RoomPlan only fits pre-defined categories (wall, floor, window, door). Our TSDF has the actual SDF field — we can detect ANY large planar region (> 0.5m²) by analyzing SDF gradient consistency within block clusters, then snap the MC vertices to the fitted plane. This is geometry-aware, not category-aware. Cloud post-processing can do this even more aggressively.

#### CE-8: Metal 4 Unified Compute Architecture (from Apple WWDC 2025)
- **Origin:** Metal 4 introduces unified compute encoder, MTL4ArgumentTable (bindless), MTLTensor, command allocators, and pass barriers.
- **Principle:** Eliminate per-encoder overhead by consolidating all GPU work (compute dispatch, blit, sync) into a single encoder. Bindless resource model moves binding off the hot path. Command allocators reuse memory instead of allocating per frame.
- **Why we borrow:** Our Metal pipeline currently needs 2 compute encoders (allocation + integration) + 1 blit. Metal 4 unifies these into 1 encoder, reducing CPU overhead significantly.
- **How we surpass:** We design a dual-path Metal layer: Metal 3 baseline (A14+), Metal 4 progressive enhancement (A18+). Runtime `device.supportsFamily(.metal4)` detection. Metal 4 path uses:
  - Single `MTL4ComputeCommandEncoder` for all 3 passes
  - `MTL4ArgumentTable` with pre-built bindings (created at init, not per-frame)
  - Command allocators for zero per-frame allocation
  - Pass barriers for intra-encoder sync (replacing MTLSharedEvent)
  - **Estimated: 20-30% CPU encoding time reduction on Metal 4 devices**

**Design rule:** All Metal code behind `#if canImport(Metal)`. Metal 3 APIs as baseline, Metal 4 as opt-in enhancement.

#### CE-9: Multi-Layer Co-Registered Volumes (from NVIDIA nvblox)
- **Origin:** nvblox stores TSDF, ESDF, color, occupancy, and mesh as separate but aligned voxel grids (called a "LayerCake"). Each layer serves a different consumer.
- **Principle:** Separation of concerns: TSDF stores geometry, color stores appearance, ESDF stores navigation distance, occupancy stores dynamic objects. All share the same spatial hash, so lookups are O(1) across layers.
- **Why we borrow:** Our current design stores everything in one VoxelBlock. Future color, semantics, and dynamic-object tracking each need their own data without bloating the core struct.
- **How we surpass:** nvblox uses separate GPU buffers per layer, which wastes memory bandwidth on cache misses during cross-layer queries. Our `reserved[4]` bytes in each Voxel provide inline color/flags with zero cache miss penalty for the common case (geometry+color). For additional layers (ESDF, occupancy), we use nvblox's approach of separate hash entries pointing to the same spatial coordinates. Hybrid: inline for hot data, separate for cold data.

#### CE-10: Dynamic Object Exclusion (from NVIDIA nvblox)
- **Origin:** nvblox uses people segmentation (from Isaac Perceptor) to separate humans from the static TSDF, storing them in a separate occupancy grid.
- **Principle:** Per-pixel semantic mask (person/not-person) → pixels classified as "person" are excluded from TSDF integration and integrated into a separate transient occupancy volume instead.
- **Why we borrow:** Users scanning a room don't want their own legs or a passing pet baked into the mesh. Dynamic objects create ghost geometry.
- **How we surpass:** nvblox relies on external segmentation. We leverage ARKit's built-in `personSegmentationWithDepth` (available since ARKit 3) — zero additional ML inference cost. Pixels with personSegmentation > 0.5 are excluded from integration. Our space carving (weight decay, carvingDecayRate) also handles missed detections: if a person moves away, ghost geometry self-erases over time.

#### CE-11: LOD-Controlled Mesh Density (from Microsoft HoloLens)
- **Origin:** HoloLens exposes a "Triangles Per Cubic Meter" parameter letting apps trade mesh quality for performance at runtime.
- **Principle:** During Marching Cubes extraction, skip blocks or reduce voxel resolution based on a target density metric. Higher density = more triangles = more accurate but slower.
- **Why we borrow:** Different consumers need different mesh density: real-time preview needs lightweight mesh; export needs maximum detail; evidence coverage needs approximate mesh.
- **How we surpass:** HoloLens applies uniform density across the whole scene. Our adaptive multi-resolution TSDF naturally provides distance-based LOD (near=0.5cm, mid=1cm, far=2cm). We add a `meshDensityMultiplier` parameter to MarchingCubes that scales the extraction budget per-consumer:
  - Real-time preview: 1.0× (50K triangles)
  - Evidence coverage: 0.3× (15K triangles, faster)
  - Export: 2.0× (100K triangles, maximum detail before QEM simplification)

#### CE-12: Spatial Persistence via Anchors (from Microsoft HoloLens + Apple ARKit)
- **Origin:** HoloLens correlates mesh sections with Wi-Fi fingerprints and device location for relocalization. ARKit uses WorldAnchors and image-based relocalization.
- **Principle:** Store TSDF volume snapshots keyed by spatial anchors. On revisit, relocalize via anchor matching, then resume integration into the existing volume.
- **Why we borrow:** Users may scan a room over multiple sessions, or return to add more detail.
- **How we surpass:** HoloLens mesh is low-resolution (~7.5cm). Our TSDF volume at 0.5-2cm resolution provides 15× more detail. Combined with cloud post-processing, a resumed scan can achieve quality that neither HoloLens nor any current mobile app can match. Our IntegrationRecord ring buffer stores recent poses for alignment verification on resume.

#### CE-13: Scene Understanding Semantic Output (from Microsoft + Apple)
- **Origin:** HoloLens Scene Understanding Runtime abstracts raw mesh into semantic objects (walls, floors, furniture). Apple's ARKit provides `sceneUnderstanding` frame semantics (floor, wall, ceiling, seat, table, etc.).
- **Principle:** Classify spatial regions by semantic type using ML inference on the depth/color data. Attach semantic labels to mesh regions or voxel blocks.
- **Why we borrow:** Semantic-aware scanning enables: auto-crop (remove floor), smart LOD (higher detail on furniture, lower on walls), intelligent cloud processing (process objects individually).
- **How we surpass:** We combine ARKit's per-pixel semantics (free, runs on Neural Engine) with our per-voxel observation data. Each VoxelBlock's `reserved[3]` byte stores the dominant semantic class observed across all frames. Majority-vote across observations is more robust than single-frame classification. Cloud pipeline receives semantically-tagged geometry for per-object optimization.

#### CE-14: MTLTensor and Neural Rendering (from Apple Metal 4 WWDC 2025)
- **Origin:** Metal 4 introduces `MTLTensor` as a first-class GPU resource type, and supports inline neural network inference in compute/fragment shaders.
- **Principle:** Small neural networks can run inside shader code for tasks like neural texture decompression, learned SDF refinement, or neural super-resolution. Metal 4 provides native tensor operations without leaving the GPU pipeline.
- **Why we borrow:** Future potential for learned depth denoising (replace bilateral filter with 3-layer MLP), neural SDF refinement (smooth noisy voxels), or neural texture synthesis during cloud upload preparation.
- **How we surpass:** This is a future-proofing hook, not a PR#6 implementation. Our Voxel struct and pipeline design must NOT preclude neural augmentation. The `reserved` bytes and modular Metal pipeline architecture ensure we can inject ML stages without re-architecture.

#### CE-15: RealityKit Observable Integration (from Apple WWDC 2025)
- **Origin:** WWDC 2025 made RealityKit entities SwiftUI-observable. SceneKit is soft-deprecated with Apple guiding migration to RealityKit.
- **Principle:** RealityKit `Entity` objects now conform to `@Observable`, enabling direct SwiftUI binding. Meshes created from raw vertex data can be displayed as RealityKit entities.
- **Why we borrow:** Our MeshOutput must be consumable by RealityKit for visionOS rendering and future SwiftUI-native AR views (replacing SceneKit in PR#7+).
- **How we surpass:** Our MeshOutput type includes vertex positions + normals in a flat `ContiguousArray<Float>` layout. We add a `toMeshResource()` conversion method that creates a `RealityKit.MeshResource` from our data with zero-copy where possible (.storageModeShared buffers). This makes our TSDF output a first-class citizen in Apple's spatial computing ecosystem.

### Summary: 15 Techniques, Our Edge

| # | Technique | Source | Status in PR#6 | Our Advantage |
|---|-----------|--------|----------------|---------------|
| CE-1 | Sub-second first mesh | Polycam | Phase 0 point cloud + UX-8 fade | Cross-fade vs hard cut |
| CE-2 | Semantic object masking | Polycam | reserved[3] semantic byte ready | Per-class export, not binary mask |
| CE-3 | TSDF as warm start for cloud | Scaniverse | IntegrationRecord + cloud upload | 端+云 > pure local |
| CE-4 | Auto-completion detection | RealityScan | Per-voxel weight + PR#5 evidence | Multi-angle coverage, not image overlap |
| CE-5 | Transparent degradation | KIRI Engine | 32 guardrails + specific toast | Never stop, graduated response |
| CE-6 | Multi-format LOD export | Scaniverse+Polycam | MeshOutput metadata | Local LOD + cloud high-poly |
| CE-7 | Parametric surface fitting | Apple RoomPlan | SDF gradient analysis | Geometry-aware, not category-limited |
| CE-8 | Metal 4 unified compute | Apple WWDC 2025 | Dual-path Metal 3/4 | Runtime feature detection |
| CE-9 | Multi-layer volumes | NVIDIA nvblox | Hybrid inline+separate layers | Zero cache miss for hot data |
| CE-10 | Dynamic object exclusion | NVIDIA nvblox | ARKit personSegmentation | Free ML + space carving backup |
| CE-11 | LOD-controlled mesh density | Microsoft HoloLens | Per-consumer density multiplier | Distance-adaptive, not uniform |
| CE-12 | Spatial persistence | HoloLens + ARKit | IntegrationRecord + Codable types | 15× resolution + cloud refinement |
| CE-13 | Scene semantic output | Microsoft + Apple | Majority-vote semantic labels | Multi-frame robust vs single-frame |
| CE-14 | Neural rendering hooks | Apple Metal 4 | Pipeline architecture ready | reserved bytes + modular Metal |
| CE-15 | RealityKit integration | Apple WWDC 2025 | MeshOutput.toMeshResource() | First-class visionOS citizen |

---

## Future-Proofing: 1–2 Year Architecture Horizon

These design decisions ensure our TSDF engine remains competitive through 2027 without re-architecture.

### FP-1: Color/Texture Integration Path

**Why now:** PR#6 delivers geometry-only mesh for real-time preview. Cloud pipeline handles final textured output. However, per-voxel color can enhance端侧preview quality (colored wireframe, confidence heatmap). The Voxel struct MUST be designed for zero-cost color upgrade.

**Architecture (already prepared):**
```swift
public struct Voxel: Sendable {
    public var sdf: SDFStorage    // 2 bytes — geometry (cross-platform, Section 0.2)
    public var weight: UInt8      // 1 byte — fusion weight
    public var confidence: UInt8  // 1 byte — ARKit confidence
    public var reserved: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    // ↑ Future: reserved.0 = R, reserved.1 = G, reserved.2 = B, reserved.3 = flags
}
```

**Color fusion approach (for future PR):**
- Per-voxel running-average RGB (same weighted average as SDF fusion)
- Color weight tracks separately from SDF weight (color from distant observations is noisy)
- Reference: RGBTSDF (2024) — interpolated depth map for accurate voxel-to-pixel mapping
- Reference: TextureFusion (Microsoft Research) — texture-tile voxel grid for higher resolution
- Performance impact: Zero until activated. Color integration adds ~15% to GPU kernel time.

**Constants (pre-registered, inactive):**
```swift
/// Color fusion weight multiplier (0 = disabled, 1.0 = same as depth weight)
public static let colorFusionWeightMultiplier: Float = 0.0  // Set to 1.0 to enable

/// Minimum weight before color is considered reliable for rendering
public static let colorMinWeightForRender: UInt8 = 5
```

### FP-2: Cloud Rendering Pipeline Bridge (端云协同)

**Why now:** Our architecture is端侧TSDF real-time + cloud high-quality rendering. The TSDF mesh is not the final product — it's the real-time preview and the warm start for cloud processing.

**Architecture bridge (端 → 云):**
- After scanning stops,端侧 exports: TSDF mesh (geometry) + keyframe camera poses + selected RGB keyframes
- Cloud receives pre-built geometry → skips coarse reconstruction → goes straight to refinement
- Cloud options: Gaussian Splatting, NeRF, or photogrammetry refinement starting from TSDF mesh
- MetalSplatter (open-source Swift/Metal library) can render cloud-generated 3DGS result locally on iOS/visionOS

**What端侧 must prepare for cloud AND for PR#7 projective texturing:**
1. `IntegrationRecord` ring buffer: camera poses with timestamps (already designed)
2. **IntegrationRecord MUST include keyframe support (PR#6 deliverable, NOT future)**:
   ```swift
   public struct IntegrationRecord: Sendable {
       public let timestamp: TimeInterval
       public let cameraPose: TSDFMatrix4x4       // Camera-to-world transform (cross-platform, Section 0.1)
       public let intrinsics: TSDFMatrix3x3        // Camera intrinsics (cross-platform, Section 0.1)
       public let affectedBlockIndices: [Int32]    // For loop closure
       public let isKeyframe: Bool                 // Keyframe flag
       public let keyframeId: UInt32?              // Non-nil if isKeyframe==true
   }
   ```
   **Keyframe selection policy (PR#6 decides, PR#7 consumes):**
   - Every 6th successfully integrated frame (≈10Hz at 60fps input) = keyframe candidate
   - OR: viewpoint angular change > 15° since last keyframe
   - OR: translation > 0.3m since last keyframe
   - Whichever triggers first. Max 30 keyframes per scan session (memory budget for RGB textures).

   **Why PR#6 must do this, not PR#7:**
   PR#7's projective texturing fragment shader needs `{pose, intrinsics}` for each keyframe to project mesh vertices → RGB texture UV. These matrices come from the integration pipeline — PR#7 cannot reconstruct them. The keyframe decision must happen AT integration time because only then do we have the ARFrame + camera state. By the time PR#7 renders, the ARFrame is gone.

   **App/ layer responsibility:** When `isKeyframe==true`, App/ layer retains the ARFrame's RGB CVPixelBuffer (or downsampled copy) and associates it with `keyframeId`. PR#6 Core/ never touches RGB data — it only marks which frames are keyframes and stores their poses.

3. `MeshOutput.toCompressedUpload()` — serialize mesh + poses for efficient upload
4. Estimated upload payload: mesh (~5 MB) + poses (~100 KB) + keyframe references (~50 KB) = < 10 MB base (RGB keyframes uploaded separately)

**Design rule:** PR#6 does NOT implement cloud upload or projective texturing. It provides the keyframe-marked pose data that both PR#7 (端侧 projective texturing) and cloud pipeline need.

### FP-3: Metal 4 Progressive Enhancement

**Current baseline:** Metal 3 (A14–A17 Pro, M1–M3)
**Future target:** Metal 4 (A18+, M4+) when available

**Migration path:**
```swift
#if canImport(Metal)
class MetalTSDFIntegrator {
    private let useMetal4: Bool

    init(device: MTLDevice) {
        // Runtime feature detection
        useMetal4 = device.supportsFamily(.metal4)  // When SDK available
        // ... setup appropriate encoder strategy
    }
}
#endif
```

**Metal 4 benefits for TSDF (when adopted):**
- Unified compute encoder: one encoder for all 3 passes (allocation + integration + readback)
- MTL4ArgumentTable: pre-built resource bindings off critical path
- Command allocators: reuse command buffer memory, zero per-frame allocation
- Pass barriers: replace manual MTLSharedEvent sync for intra-encoder dependencies
- Estimated improvement: ~20-30% reduction in CPU encoding time

### FP-4: visionOS Compatibility

**Why now:** Apple Vision Pro is a target platform. Our architecture must not preclude visionOS deployment.

**Requirements:**
- `Core/TSDF/` already Linux-compilable → visionOS-compilable by extension
- `App/TSDF/` uses Metal (available on visionOS) and ARKit (available on visionOS via enterprise API)
- visionOS uses `ARKitSession` with `WorldTrackingProvider` instead of `ARSession`
- SceneDepthFrame struct is framework-agnostic (CVPixelBuffer + matrix, no ARKit type dependency in Core/)
- MeshOutput must support conversion to RealityKit `MeshResource` for spatial rendering

**Design rule:** Never import ARKit directly in Core/ types. All ARKit interaction goes through App/ layer protocol abstractions.

### FP-5: Mesh Simplification for Upload and Preview

**Why now:** Raw Marching Cubes output has too many triangles for both real-time rendering and cloud upload. Simplified mesh reduces端侧rendering load AND upload bandwidth.

**Architecture:**
```swift
/// Mesh simplification via Quadric Error Metric (QEM) edge collapse
/// Reference: Garland & Heckbert (SIGGRAPH 1997)
/// Future file: Core/TSDF/MeshSimplifier.swift
///
/// Target: 10K–50K triangles for export (vs 50K–200K raw output)
/// Quality: < 0.5mm Hausdorff distance from original at typical scanning distances
```

**Constants (pre-registered):**
```swift
/// Default export triangle budget
public static let exportTargetTriangles: Int = 30_000

/// Maximum Hausdorff distance allowed during simplification (meters)
public static let exportMaxHausdorffDistance: Float = 0.0005  // 0.5mm
```

### FP-6: Spatial Persistence and Session Resume

**Why now:** Users may pause and resume scans, or the app may need to serialize the volume for cloud upload or session recovery after app termination.

**Architecture:**
- `TSDFVolume.serialize()` → Codable snapshot of hash table + voxel blocks
- Key by ARKit relocalization anchors (GeoAnchors or WorldAnchors)
- IntegrationRecord ring buffer provides recent pose history for alignment verification
- Estimated serialized size: 50K blocks × 4 KB = 200 MB (compressible to ~50 MB with LZ4)
- Cloud upload path: serialized volume + keyframe poses → cloud reconstructor uses as warm start

**Design rule:** All Core/ types must be `Codable` for future serialization. Use fixed-size types only (no String, no Array<Any>).

### FP-7: Loop Closure Integration

**Why now:** ARKit occasionally corrects its pose estimate, causing existing TSDF data to be slightly misaligned. Full loop closure requires pose graph optimization + TSDF re-integration.

**Architecture (already partially prepared):**
- IntegrationRecord stores `{timestamp, cameraPose, affectedBlockIndices}` for last 300 frames
- When ARKit fires anchor transform update (> `loopClosureDriftThreshold` = 2cm):
  1. Mark all blocks in affected IntegrationRecords as stale
  2. Re-integrate those frames with corrected poses (from ring buffer)
  3. Or: simply mark blocks dirty and let natural scanning re-observe them
- Option 2 (passive) is MVP; Option 1 (active re-integration) is future enhancement

---

## Extreme Performance Optimizations (Beyond MVP)

These are additional performance techniques from production systems that push our engine to the absolute limit.

### EP-1: Bilateral Depth Filter (Pre-Integration)

Apply edge-preserving bilateral filter to depth map before TSDF integration:
```swift
/// Bilateral filter parameters for depth pre-processing
/// Reduces depth noise while preserving edges (doors, furniture boundaries)
/// σ_spatial = 2 pixels, σ_depth = 0.02m (20mm)
/// Reference: KinectFusion + BundleFusion both use this
public static let bilateralFilterSpatialSigma: Float = 2.0    // pixels
public static let bilateralFilterDepthSigma: Float = 0.02     // meters
public static let enableBilateralFilter: Bool = true
```
**Effect:** Reduces voxel noise by ~40% with < 0.5ms GPU cost. Eliminates most "bubbling" artifacts on flat surfaces.

### EP-2: Temporal Depth Accumulator

Instead of integrating every single frame, accumulate N depth maps and integrate the median:
```swift
/// Number of depth frames to accumulate before integration
/// Median of 3 frames eliminates most transient noise spikes
/// 3 frames at 60fps = 50ms accumulation latency (imperceptible)
public static let temporalAccumulatorFrames: Int = 3
```
**Effect:** Median filtering removes ~70% of single-frame depth outliers. Combined with bilateral filter, produces near-offline quality from real-time input.

### EP-3: Hierarchical Block Allocation

Instead of checking every depth pixel for block allocation, use a 2-level hierarchy:
1. **Level 1 (coarse):** 16×12 tiles (each covering 16×16 depth pixels) — check if any valid pixel exists
2. **Level 2 (fine):** Only process tiles that passed Level 1

```swift
/// Hierarchical allocation tile size
/// 16×16 = 256 pixels per tile. 256/16 × 192/16 = 16×12 = 192 tile checks
/// vs 256×192 = 49,152 pixel checks — 256× fewer atomic operations
public static let allocationTileSize: Int = 16
```
**Effect:** Reduces atomic contention in allocation kernel by ~10×. Critical on A14 where atomics are slow.

### EP-4: Warp-Level Block Deduplication

In the allocation kernel, many pixels in the same threadgroup map to the same block. Use warp-level intrinsics to deduplicate:
```metal
// Metal: use simd_shuffle to share blockIdx within SIMD group
// If all 32 threads in a SIMD group produce the same blockIdx, only 1 atomic add
int3 myBlock = computeBlockIndex(depth, pixel);
bool isFirst = simd_is_first();  // Only first lane writes
if (isFirst) {
    atomic_fetch_add_explicit(&blockCount, 1, memory_order_relaxed);
}
```
**Effect:** Reduces atomic write contention by ~8–16× within each SIMD group.

### EP-5: Lazy Hash Table Growth

Don't rehash at a fixed load factor. Instead, track probe-length P95:
```swift
/// Maximum acceptable P95 probe length before triggering rehash
/// At P95 < 5: hash table performance is acceptable regardless of load factor
/// This avoids unnecessary rehashes at low load factors with pathological key distributions
public static let hashRehashProbeP95Threshold: Int = 5
```
**Effect:** Avoids 2× memory spike from premature rehash. More memory-efficient for long scanning sessions.

### EP-6: SIMD-Optimized Marching Cubes

Use Swift SIMD intrinsics for vertex interpolation and normal computation:
```swift
// Use TSDFFloat3 operations for all vertex math (SIMD3<Float> on Apple, hand-written on Linux)
// Apple CPUs have 4-wide NEON SIMD — 4 vertices per cycle
let t = TSDFFloat3(repeating: clamp(-sdf0 / (sdf1 - sdf0), mcInterpolationMin, mcInterpolationMax))
let vertex = mix(p0, p1, t: t)  // SIMD lerp, single instruction
```
**Effect:** ~2× speedup for CPU Marching Cubes on Apple Silicon NEON.

### EP-7: Predictive Block Prefetch

During idle time (UX-12), predict which blocks the user will scan next based on camera trajectory:
```swift
/// Predictive prefetch: linear extrapolation of camera motion
/// Pre-allocate blocks along predicted path, 0.5–1.0m ahead
/// Uses last 10 camera poses to estimate velocity vector
public static let prefetchLookAheadDistance: Float = 0.75    // meters
public static let prefetchPoseHistoryCount: Int = 10
```
**Effect:** Eliminates allocation stalls when user scans in a consistent direction. Blocks are already warm when the camera arrives.

### EP-8: Depth-Adaptive Integration Rate

Instead of integrating every frame at full resolution, adapt based on **median scene depth** (the median of all valid depth pixels in the current frame — a single scalar per frame, not per-pixel):

- Median depth < 0.5m (close-up): integrate every frame (60Hz) — maximum detail for near voxels
- Median depth 0.5–2.0m (typical room): integrate every 2nd frame (30Hz) — sufficient for 1cm voxels
- Median depth > 2.0m (far wall/ceiling): integrate every 4th frame (15Hz) — sufficient for 2cm voxels

**Why median depth, not per-pixel:** A single frame contains pixels at all depths. The median represents the dominant scene distance. Near-range close-up scanning (inspecting a detail) gets maximum rate. Room-scale scanning (furniture at 1-2m) gets reduced rate. This is a coarse per-frame decision, not per-pixel.

```swift
/// Depth-adaptive integration rate based on median scene depth
public static let adaptiveIntegrationNearRange: Float = 0.5    // meters
public static let adaptiveIntegrationMidRange: Float = 2.0     // meters
public static let adaptiveIntegrationNearSkip: Int = 1         // Every frame
public static let adaptiveIntegrationMidSkip: Int = 2          // Every 2nd
public static let adaptiveIntegrationFarSkip: Int = 4          // Every 4th
```
**Effect:** Reduces GPU integration cost by ~40-50% for typical room scanning. Minimal quality loss because far voxels are 2cm and don't benefit from 60Hz sampling. The median depth can be computed cheaply from the allocation kernel's valid pixel scan (no extra GPU pass).

---

## Cross-Platform Safety

- All `Core/TSDF/` files must compile on Linux (`swift build` on Linux CI)
- Use `#if canImport(Metal)` / `#if canImport(ARKit)` guards in App/ files
- Do NOT import Metal, ARKit, UIKit, CoreVideo, or any Apple framework in Core/ files
- `SDFStorage` (Section 0.2) replaces direct `Float16`. Float16 is unavailable on x86_64 Linux. SDFStorage provides cross-platform coverage with identical bit patterns.
- Use `ContiguousArray` (not `Array`) for voxel storage — no bridging overhead
- All constants in TSDFConstants must be `public static let` (SSOT pattern)
- BlockIndex uses `Int32` (not `Int`) for cross-platform 32-bit determinism and Metal compatibility

## Swift 6.2 Concurrency

- `TSDFVolume` MUST be an `actor` — primary data protection mechanism (matches existing `LiDARDepthProcessor` which is also an actor)
- `MetalTSDFIntegrator` is a `final class` conforming to `TSDFIntegrationBackend` (Sendable) — matches existing `ThermalQualityAdapter` pattern. Metal command buffers manage their own synchronization via semaphores.
- `SceneDepthFrame` is `@unchecked Sendable` (CVPixelBuffer is refcounted, thread-safe) — already defined in LiDARDepthProcessor.swift
- Do NOT use `DispatchQueue` or `OperationQueue` — use structured concurrency (Task, TaskGroup)
- Exception: `DispatchSemaphore` is acceptable for Metal triple-buffer synchronization (industry standard)
- Mark GPU submission functions with `@concurrent` if they should run off-actor
- All public API must be `async` or actor-isolated
- nonisolated(nonsending) is the default in Swift 6.2 — be explicit about isolation
- `ThermalQualityAdapter` (existing, final class) runs on @MainActor via ScanViewModel — coordinate with TSDFVolume actor via `await`

---

## File Inventory (create these files)

### Core/ (Pure Swift — 16 files)
0. `Core/Constants/MetalConstants.swift` — **Shared Metal configuration constants** (inflightBufferCount, threadgroup defaults). Extracted from ScanGuidanceConstants.kMaxInflightBuffers. SSOT-registered.
1. `Core/TSDF/TSDFMathTypes.swift` — Cross-platform math types: TSDFFloat3, TSDFFloat4, TSDFMatrix3x3, TSDFMatrix4x4 (Section 0.1)
2. `Core/TSDF/VoxelTypes.swift` — SDFStorage: Float16 on Apple, UInt16 IEEE 754 on Linux (Section 0.2)
3. `Core/TSDF/BlockIndex.swift` — Block coordinate (3×Int32) + Nießner hash + Hashable + faceNeighborOffsets (Section 0.3)
4. `Core/TSDF/TSDFTypes.swift` — MemoryPressureLevel + IntegrationRecord struct + .empty sentinel (Section 0.4)
5. `Core/TSDF/TSDFConstants.swift` — 77 registered SSOT specs in 15 sections + validateRelationships() cross-validation
6. `Core/TSDF/VoxelBlock.swift` — Voxel (8 bytes, SDFStorage) + VoxelBlock (4 KB) + Voxel.empty + VoxelBlock.empty
7. `Core/TSDF/ManagedVoxelStorage.swift` — Stable-address UnsafeMutablePointer<VoxelBlock> + VoxelBlockAccessor (Section 0.7)
8. `Core/TSDF/VoxelBlockPool.swift` — Pre-allocated pool wrapping ManagedVoxelStorage + free-list stack
9. `Core/TSDF/SpatialHashTable.swift` — Separated metadata + block storage + deterministic iteration
10. `Core/TSDF/TSDFIntegrationBackend.swift` — Protocol + VoxelBlockAccessor + DepthDataProvider (Section 0.6)
11. `Core/TSDF/ArrayDepthData.swift` — DepthDataProvider impl for CPU backend and tests (Section 0.6)
12. `Core/TSDF/TSDFVolume.swift` — Actor: gates + AIMD thermal + ring buffer + backend dispatch + memory management
13. `Core/TSDF/AdaptiveResolution.swift` — Near/mid/far selection + distance/angle/confidence weight (Section 0.9)
14. `Core/TSDF/MarchingCubes.swift` — Incremental CPU extraction + neighbor-dirty + degenerate rejection
15. `Core/TSDF/MeshOutput.swift` — MeshVertex (TSDFFloat3), MeshTriangle (index-based UInt32), MeshOutput + IntegrationResult + IntegrationInput (Section 0.5)
16. IntegrationRecord is defined in `TSDFTypes.swift` (item 4 above) — no separate file needed

### App/ (Metal + ARKit — 4 files)
17. `App/TSDF/MetalTSDFIntegrator.swift` — TSDFIntegrationBackend impl + CVMetalTextureCache + 2-command-buffer sync
18. `App/TSDF/TSDFShaders.metal` — 2 GPU kernels (allocation + integration/carving)
19. `App/TSDF/TSDFShaderTypes.h` — Shared C header: TSDFVoxel, GPUBlockIndex, BlockEntry, TSDFParams (Section 0.8)
20. `App/TSDF/MetalBufferPool.swift` — Triple-buffered per-frame data + semaphore management

### Tests/ (6 files)
21. `Tests/TSDF/TSDFConstantsTests.swift` — SSOT validation + validateRelationships() + range checks
22. `Tests/TSDF/SpatialHashTableTests.swift` — Insert/lookup/remove + load factor + rehash + determinism
23. `Tests/TSDF/VoxelBlockPoolTests.swift` — Alloc/dealloc + exhaustion + reuse + ManagedVoxelStorage
24. `Tests/TSDF/MarchingCubesTests.swift` — Known-geometry extraction (sphere, plane) + degenerate rejection
25. `Tests/TSDF/TSDFVolumeTests.swift` — Integration + meshing + memory pressure + pose gates + keyframe marking
26. `Tests/TSDF/MockIntegrationBackendTests.swift` — Gate/AIMD logic tests using MockIntegrationBackend

### Future files (NOT created in PR#6 — placeholders for architecture awareness)
- `Core/TSDF/MeshSimplifier.swift` — QEM edge collapse (FP-5)
- `Core/TSDF/ColorFusion.swift` — Per-voxel RGB weighted average (FP-1)
- `Core/TSDF/TSDFSerializer.swift` — Codable snapshot for persistence (FP-6)
- `App/TSDF/GaussianSplatBridge.swift` — Post-scan 3DGS optimization (FP-2)
- `App/TSDF/Metal4Adapter.swift` — Metal 4 progressive enhancement (FP-3)

---

## Build & Test

```bash
# Build (must pass)
swift build

# Run TSDF tests only
swift test --filter TSDF

# Full test suite (must still pass — zero regressions)
swift test --disable-xctest
```

---

## Commit Convention

```
feat(pr6): <description>

SSOT-Change: no
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Use `SSOT-Change: yes` if the commit adds/modifies constants in TSDFConstants.

---

## Implementation Order (7 phases — write order, NOT commit order)

**Git strategy: Write all 26 files, then `git add` + one single commit + push.**
The phases below define the ORDER you should write files in (because of dependency chains), NOT separate commits.

1. **Phase 1: Foundation types** — TSDFMathTypes, VoxelTypes (SDFStorage), BlockIndex, TSDFTypes, MetalConstants, TSDFConstants, VoxelBlock, ManagedVoxelStorage, VoxelBlockPool, TSDFIntegrationBackend, ArrayDepthData, MeshOutput, IntegrationInput, IntegrationRecord
   - TSDFMathTypes + VoxelTypes FIRST: cross-platform type layer everything else depends on (Section 0.1-0.2).
   - BlockIndex + TSDFTypes: shared data types (Section 0.3-0.4).
   - MetalConstants: shared foundation for all Metal PRs. Deprecate ScanGuidanceConstants.kMaxInflightBuffers.
   - TSDFConstants: SSOT constants with full registration + validateRelationships().
   - VoxelBlock + ManagedVoxelStorage + VoxelBlockPool: storage layer (Sections 0.7, 1, 2).
   - TSDFIntegrationBackend + ArrayDepthData: protocol definitions + CPU test impl (Section 0.6).
   - MeshOutput: vertex/triangle types (Section 0.5). IntegrationInput/Record: platform-agnostic structs.
   - Testable immediately. Zero dependencies on Metal or ARKit.

2. **Phase 2: SpatialHashTable** — Insert/lookup/remove, rehash, deterministic iteration
   - Depends on Phase 1 types.

3. **Phase 3: TSDFVolume actor** — CPU-only integration (loop over depth pixels in Swift)
   - Depends on Phase 1 + 2.
   - Uses SceneDepthFrame data directly, no GPU yet.
   - Implement ALL 32 guardrails at this layer (gates, memory, thermal, pose).

4. **Phase 4: MarchingCubes** — CPU mesh extraction with neighbor-dirty and degenerate rejection
   - Depends on Phase 1 + 2 + 3.
   - Test with synthetic sphere/plane geometry.

5. **Phase 5: Metal compute shaders** — GPU-accelerated integration via TSDFIntegrationBackend
   - Depends on Phase 3.
   - MetalTSDFIntegrator implements TSDFIntegrationBackend protocol (Section 0.6).
   - TSDFShaderTypes.h shared header (Section 0.8) — include in both .metal and Swift bridging.
   - Two-command-buffer pattern: CB1 (allocation) → CPU hash table work → CB2 (integration).
   - CVMetalTextureCache, triple-buffer, MTLSharedEvent, `precise` qualifier.
   - CPU integration backend (CPUIntegrationBackend) remains as fallback for tests and Mac Catalyst.

6. **Phase 6: ScanViewModel hookup** — Replace MeshExtractor path with TSDFVolume
   - Minimal changes. Do NOT rewrite ScanViewModel.
   - Wire up ARSessionDelegate → integrate → extractMesh → render.
   - **Thermal forwarding:** ScanViewModel already has `setupThermalMonitoring()` that observes
     `ProcessInfo.thermalStateDidChangeNotification` and forwards to `thermalAdapter`.
     Add parallel forwarding to `tsdfVolume.handleThermalState(ProcessInfo.processInfo.thermalState.rawValue)`.
   - **Memory pressure:** Register for `UIApplication.didReceiveMemoryWarningNotification`,
     forward to `tsdfVolume.handleMemoryPressure(level:)`.
   - `LiDARDepthProcessor.latestSceneDepth()` already provides `SceneDepthFrame` — use directly.

7. **Phase 7: Tests** — Unit tests + integration tests + memory pressure + thermal + benchmarks
   - Verify zero regressions on existing 91+ tests.
   - Add performance benchmarks for integration and meshing times.
   - Run `swift test` to confirm everything passes.

Write files in Phase 1→2→3→4→5→6→7 order. After ALL files are written, do one single commit.

---

## References

### Foundational Papers
- [KinectFusion (Newcombe et al., ISMAR 2011)](https://dl.acm.org/doi/10.1145/2047196.2047270) — Original real-time TSDF fusion
- [Voxel Hashing (Nießner et al., TOG 2013)](https://niessnerlab.org/papers/2013/4hashing/niessner2013hashing.pdf) — Spatial hash architecture
- [Curless & Levoy (SIGGRAPH 1996)](https://graphics.stanford.edu/papers/volrange/) — Weighted average fusion formula

### Modern Systems
- [nvblox (Millane et al., ICRA 2024)](https://arxiv.org/abs/2311.00626) — GPU TSDF, incremental meshing, neighbor-dirty
- [MrHash (Nov 2025)](https://arxiv.org/html/2511.21459) — Variance-adaptive multi-resolution voxels on GPU
- [AGS-Mesh (2024)](https://arxiv.org/html/2411.19271v2) — Adaptive truncation distance
- [DB-TSDF (Sep 2025)](https://arxiv.org/html/2509.20081v1) — Integer-optimized TSDF (validates our approach differently)
- [FlashFusion (Han & Fang, RSS 2018)](https://www.roboticsproceedings.org/rss14/p06.pdf) — Incremental marching cubes

### Architecture References
- [Kähler et al. (IEEE TVCG 2015)](https://doi.org/10.1109/TVCG.2015.2459694) — Separated metadata hash table
- [Open3D TSDF](https://www.open3d.org/docs/release/tutorial/t_reconstruction_system/integration.html) — Reference pipeline
- [Paul Bourke MC Tables](http://paulbourke.net/geometry/polygonise/) — Edge/triangle lookup tables
- [Google Filament PBR](https://google.github.io/filament/Filament.md.html) — Rendering engine (PR#7 dep)
- [Swift 6.2 Concurrency](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/) — Actor isolation changes
- [Metal Best Practices Guide](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/) — Buffer management, compute optimization

### Color/Texture Fusion
- [RGBTSDF (2024)](https://www.mdpi.com/2072-4292/16/17/3188) — Efficient color TSDF with octree grid management
- [GSFusion (2024)](https://arxiv.org/html/2408.12677v1) — Gaussian Splatting + TSDF hybrid (TSDF geometry + 3DGS appearance)
- [TextureFusion (Microsoft Research)](https://www.microsoft.com/en-us/research/lab/microsoft-research-asia/articles/texturefusion-enabling-high-quality-texture-acquisition-for-real-time-rgb-d-scanning/) — Texture-tile voxel grid
- [TextureMe (ACM TOG)](https://dl.acm.org/doi/10.1145/3503926) — Real-time joint geometry + texture reconstruction

### Platform & Future
- [Metal 4 "Discover Metal 4" (WWDC 2025)](https://developer.apple.com/videos/play/wwdc2025/205/) — Unified encoder, MTL4ArgumentTable, MTLTensor, command allocators
- [Metal 4 ML + Graphics (WWDC 2025)](https://developer.apple.com/videos/play/wwdc2025/262/) — Neural rendering, inline ML in shaders
- [Object Capture Area Mode (WWDC 2024)](https://developer.apple.com/videos/play/wwdc2024/10107/) — Large-environment scanning
- [What's new in RealityKit (WWDC 2025)](https://developer.apple.com/videos/play/wwdc2025/287/) — Observable entities, object manipulation
- [MetalSplatter (GitHub)](https://github.com/scier/MetalSplatter) — Swift/Metal Gaussian Splatting renderer for iOS/visionOS
- [Mobile-GS (OpenReview)](https://openreview.net/forum?id=vRegY0pgvQ) — Real-time 3DGS on mobile devices
- [Garland & Heckbert (SIGGRAPH 1997)](https://www.cs.cmu.edu/~garland/Papers/quadrics.pdf) — Quadric error metric mesh simplification
