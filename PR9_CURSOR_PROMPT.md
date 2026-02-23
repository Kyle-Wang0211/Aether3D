# PR9: Chunked Upload v3.0 — Ultimate Implementation Prompt

## CRITICAL: Read This First

**Branch:** `pr9/chunked-upload-v3` (created from `main`)
**Switch to it:** `git checkout pr9/chunked-upload-v3`
**DO NOT touch PR10 branch or any PR10 files.**

You are implementing PR9 for the Aether3D project — a 6-layer fusion chunked upload engine that is designed to be the most advanced mobile upload system ever built. This prompt contains the COMPLETE specification: every constant value, every algorithm, every security measure, every file to create, and every line-level integration point with existing code.

---

## TABLE OF CONTENTS

1. [Project Context & Constraints](#1-project-context--constraints)
2. [Files to Create (4 primary + 12 supporting)](#2-files-to-create)
3. [Layer 1: Device-Aware I/O Engine](#3-layer-1-device-aware-io-engine)
4. [Layer 2: Adaptive Transport Engine](#4-layer-2-adaptive-transport-engine)
5. [Layer 3: Content Addressing Engine](#5-layer-3-content-addressing-engine)
6. [Layer 4: Cryptographic Integrity Engine](#6-layer-4-cryptographic-integrity-engine)
7. [Layer 5: Erasure Resilience Engine](#7-layer-5-erasure-resilience-engine)
8. [Layer 6: Intelligent Scheduling Engine](#8-layer-6-intelligent-scheduling-engine)
9. [PR5+PR9 Fusion: Capture-Upload-Render Pipeline](#9-pr5pr9-fusion-capture-upload-render-pipeline)
10. [Unified Resource Management](#10-unified-resource-management)
11. [Security Hardening (58 items)](#11-security-hardening)
12. [Constants Tuning (56 precise changes)](#12-constants-tuning)
13. [Integration Points with Existing Code](#13-integration-points-with-existing-code)
14. [Testing Requirements](#14-testing-requirements)
15. [Acceptance Criteria](#15-acceptance-criteria)

---

## 1. PROJECT CONTEXT & CONSTRAINTS

### 1.1 Build System
- Swift Package: `swift-tools-version: 5.9` at `progect2/` subdirectory
- Cross-platform: iOS + macOS + Linux (pure Foundation, no UIKit/AppKit in Core)
- Conditional imports: `#if canImport(CryptoKit)` / `#elseif canImport(Crypto)`
- All new files MUST have SPDX header: `// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary`
- All new files MUST have Constitutional Contract header for Core modules

### 1.2 Existing Architecture You MUST Integrate With
These files already exist. Read them carefully before writing ANY code:

| File | What It Does | PR9 Relationship |
|------|-------------|-----------------|
| `Core/Upload/UploadSession.swift` | 8-state machine (initialized→uploading→paused→stalled→completing→completed→failed→cancelled), ChunkStatus tracking | PR9 ChunkedUploader orchestrates this directly |
| `Core/Upload/ChunkManager.swift` | Parallel chunk coordination, delegate pattern, decorrelated jitter retry | PR9 replaces retry algorithm, adds priority queue |
| `Core/Upload/AdaptiveChunkSizer.swift` | 3 strategies (fixed/adaptive/aggressive) | PR9 extends to 5 strategies + 4-theory fusion scheduler |
| `Core/Upload/NetworkSpeedMonitor.swift` | Weighted average speed estimation, SpeedSample, NetworkSpeedClass | PR9 adds Kalman filter alongside existing EWMA |
| `Core/Upload/UploadProgressTracker.swift` | Single-layer progress, throttled reporting | PR9 extends to 4-layer progress model |
| `Core/Upload/UploadResumeManager.swift` | UserDefaults-based session persistence | PR9 adds FileFingerprint, encryption, 3-level resume |
| `Core/Upload/HashCalculator.swift` | SHA-256 streaming file hash, timing-safe comparison | PR9 adds CRC32C parallel computation |
| `Core/Upload/ImmutableBundle.swift` | 19-step seal, Merkle tree (RFC 9162), TOCTOU prevention | PR9 integrates streaming Merkle tree |
| `Core/Upload/ACI.swift` | Aether Content Identifier `aci:1:sha256:<hex>` | PR9 adds CID v1 bidirectional mapping |
| `Core/Network/APIContract.swift` | CreateUploadRequest, UploadChunkResponse, GetChunksResponse, CompleteUploadRequest | PR9 uses these existing API contracts |
| `Core/Network/APIClient.swift` | Actor-based HTTP client with cert pinning, rate limiting | PR9 uses this for all HTTP calls |
| `Core/Network/IdempotencyHandler.swift` | Actor-based, SHA-256 key generation, 24h TTL cache | PR9 extends to chunk-level granularity |
| `Core/Constants/UploadConstants.swift` | SSOT for all upload magic numbers | PR9 updates specific values (see Section 12) |
| `Core/Mobile/MobileBatteryAwareScheduler.swift` | Low Power Mode detection | PR9 extends to 6-level energy strategy |
| `Core/Mobile/MobileMemoryPressureHandler.swift` | 3-phase memory warning response | PR9 adds `os_proc_available_memory()` integration |
| `Core/Mobile/MobileThermalStateHandler.swift` | 4-level quality based on thermal state | PR9 adds Schmitt hysteresis + unified thermal budget |
| `Core/Pipeline/PipelineRunner.swift` | Sequential pipeline: upload→startJob→pollAndDownload | PR9 replaces single `upload()` with chunked streaming |
| `Sources/PR5Capture/PR5CapturePipeline.swift` | Actor-based frame quality gating (accept/reject/pending) | PR9 bridges quality decisions to upload priority |
| `App/Capture/RecordingController.swift` | Video capture with pollFileSize during recording | PR9 uses pollFileSize as chunk trigger |
| `Core/Mobile/MobileProgressiveScanLoader.swift` | Progressive download: Coarse→Medium→Fine LOD | PR9 designs upload as symmetric mirror |

### 1.3 Key Constants Already Defined (UploadConstants.swift)
Read `Core/Constants/UploadConstants.swift` for current values. Section 12 below lists every value that needs changing.

### 1.4 Coding Conventions
- Use `actor` for thread-safe stateful components (matches existing IdempotencyHandler, MobileBatteryAwareScheduler)
- Use `final class` + `DispatchQueue` for compatibility with existing patterns (matches UploadSession, ChunkManager)
- Use `public` access for all types/methods that other modules need
- Use `Sendable` conformance on all value types
- All async operations use Swift async/await
- Error types as enums conforming to `Error, Equatable`
- Document all public APIs with `///` doc comments including invariants

---

## 2. FILES TO CREATE

### 2.1 Primary Files (4)

| # | File Path | Purpose | Lines (est.) |
|---|-----------|---------|-------------|
| 1 | `Core/Upload/ChunkedUploader.swift` | Main orchestrator — the heart of PR9. Coordinates all 6 layers, manages upload lifecycle, bridges PR5 quality gate to upload decisions | ~800 |
| 2 | `Core/Upload/ChunkIdempotencyManager.swift` | Chunk-level idempotency extending existing IdempotencyHandler. Per-chunk keys, persistent cache, replay protection | ~200 |
| 3 | `Core/Upload/EnhancedResumeManager.swift` | 3-level resume strategy with FileFingerprint, encrypted snapshots, server state verification | ~350 |
| 4 | `Core/Upload/MultiLayerProgressTracker.swift` | 4-layer progress model (Wire/ACK/Merkle/ServerReconstructed), Savitzky-Golay smoothing, monotonic guarantee | ~400 |

### 2.2 Supporting Files (12)

| # | File Path | Purpose | Lines (est.) |
|---|-----------|---------|-------------|
| 5 | `Core/Upload/HybridIOEngine.swift` | mmap/FileHandle/DispatchIO hybrid with Jetsam-aware switching, CRC32C+SHA-256+compressibility triple-pass | ~350 |
| 6 | `Core/Upload/KalmanBandwidthPredictor.swift` | 4D Kalman filter for bandwidth prediction, anomaly detection, confidence intervals | ~250 |
| 7 | `Core/Upload/ConnectionPrewarmer.swift` | 5-stage connection prewarming pipeline (DNS→TCP→TLS→HTTP2→ready) | ~200 |
| 8 | `Core/Upload/StreamingMerkleTree.swift` | Binary Carry Model incremental Merkle tree, O(log n) memory, subtree checkpoints | ~300 |
| 9 | `Core/Upload/ChunkCommitmentChain.swift` | Bidirectional hash chain with jump chain (O(√n) verification), session-bound genesis | ~200 |
| 10 | `Core/Upload/ByzantineVerifier.swift` | Random-sampling server verification via Merkle proofs, async non-blocking | ~200 |
| 11 | `Core/Upload/ErasureCodingEngine.swift` | Adaptive RS (GF(2^8)/GF(2^16)) + RaptorQ fallback, UEP per priority level | ~400 |
| 12 | `Core/Upload/FusionScheduler.swift` | MPC×ABR×EWMA×Kalman 4-theory fusion with Lyapunov DPP stability, Thompson Sampling CDN selection | ~350 |
| 13 | `Core/Upload/UnifiedResourceManager.swift` | Thermal+Battery+Memory unified decision matrix, Schmitt hysteresis, predictive throttling | ~300 |
| 14 | `Core/Upload/CIDMapper.swift` | ACI ↔ CID v1 bidirectional mapping, Multicodec compatibility | ~150 |
| 15 | `Core/Upload/ProofOfPossession.swift` | Secure instant upload protocol: partial-chunk challenges, anti-replay nonce, ECDH encrypted channel | ~250 |
| 16 | `Core/Upload/UploadTelemetry.swift` | Structured per-chunk trace with all 6 layers' metrics, HMAC-signed audit entries | ~200 |

---

## 3. LAYER 1: DEVICE-AWARE I/O ENGINE

### File: `Core/Upload/HybridIOEngine.swift`

```
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-IO-1.0
// Module: Upload Infrastructure - Hybrid I/O Engine
// Cross-Platform: macOS + Linux (pure Foundation)
```

### 3.1 HybridIOEngine (actor)

**Purpose:** Read file chunks with optimal I/O strategy per platform, compute CRC32C + SHA-256 + compressibility in a single pass.

**Decision Matrix:**
```
Platform     | File < 64MB      | 64-512MB         | > 512MB
-------------|------------------|------------------|------------------
macOS        | mmap+SEQUENTIAL  | mmap 32MB window | mmap 32MB window
iOS ≥ 200MB* | mmap+SEQUENTIAL  | FileHandle 128KB | FileHandle 128KB
iOS < 200MB* | FileHandle 128KB | FileHandle 128KB | FileHandle 128KB
Linux        | mmap+SEQUENTIAL  | FileHandle 128KB | FileHandle 128KB

* 200MB = os_proc_available_memory() threshold
```

**Triple-Pass Single-Read Engine:**

For each 128KB buffer read:
1. **CRC32C**: ARM hardware `__crc32cd` on arm64, software fallback on x86_64
   - `#if arch(arm64)` → use `crc32_arm_intrinsic()` wrapper (~20 GB/s)
   - `#else` → lookup table CRC32C (~500 MB/s)
2. **SHA-256**: Feed same buffer to `CryptoKit.SHA256.update()` (~2.3 GB/s on M1)
3. **Compressibility Sample**: Every 5MB, take 32KB sample, try LZFSE compression, record ratio

**Output struct:**
```swift
public struct IOResult: Sendable {
    public let sha256Hex: String          // 64 hex chars
    public let crc32c: UInt32             // Hardware-accelerated
    public let byteCount: Int64           // Actual bytes read (TOCTOU safe)
    public let compressibility: Double    // 0.0-1.0 (0=incompressible)
    public let ioMethod: IOMethod         // .mmap, .fileHandle, .dispatchIO
}

public enum IOMethod: String, Sendable {
    case mmap, fileHandle, dispatchIO
}
```

**Buffer alignment:** All buffers allocated with `posix_memalign(ptr, 16384, size)` (Apple Silicon 16KB page).

**Hash stream chunk size:** 128KB (NOT 256KB — fits in Apple Silicon L1 Data Cache 128KB exactly).

**Security:**
- `flock(fd, LOCK_SH)` shared lock during read (prevent concurrent writes)
- After `open()`: `fstat(fd)` and compare `st_ino` with pre-open `stat()` (TOCTOU double-check)
- mmap uses `MAP_PRIVATE` (copy-on-write protection)
- Sensitive buffers: `mlock()` + `memset_s()` before free

---

## 4. LAYER 2: ADAPTIVE TRANSPORT ENGINE

### File: `Core/Upload/KalmanBandwidthPredictor.swift`

**State vector (4D):** `[bandwidth, d_bandwidth/dt, d2_bandwidth/dt2, variance]`

**Key parameters:**
- Process noise Q: adaptive (10x increase on NWPathMonitor network change events)
- Measurement noise R: dynamic based on last 10 samples' variance
- Initial covariance P0: `diag(100, 10, 1, 50)`
- Anomaly threshold: Mahalanobis distance > 2.5σ → reduce sample weight
- Convergence indicator: `trace(P) < threshold` → mark "estimate reliable"

**Output:**
```swift
public struct BandwidthPrediction: Sendable {
    public let predictedBps: Double
    public let confidenceInterval95: (low: Double, high: Double)
    public let trend: BandwidthTrend  // .rising, .stable, .falling
    public let isReliable: Bool       // trace(P) convergence check
}
```

### File: `Core/Upload/ConnectionPrewarmer.swift`

**5-stage pipeline:**
```
Stage 0 (app launch):      DNS pre-resolve upload endpoint → cache A/AAAA
Stage 1 (enter capture UI): TCP 3-way handshake → keep-alive
Stage 2 (TCP done):         TLS 1.3 handshake → 0-RTT ready
Stage 3 (TLS done):         HTTP/2 SETTINGS exchange → stream ready
Stage 4 (first chunk ready): Immediate write to established stream
```

**URLSession configuration:**
```swift
config.timeoutIntervalForRequest = 30.0
config.timeoutIntervalForResource = 3600.0
config.httpMaximumConnectionsPerHost = 4
config.multipathServiceType = .handover       // WiFi→cellular failover
config.allowsConstrainedNetworkAccess = false  // Respect Low Data Mode
config.waitsForConnectivity = true
config.requestCachePolicy = .reloadIgnoringLocalCacheData
```

### Adaptive Compression (in ChunkedUploader)

Decision logic per chunk:
```
if chunk.compressibility > 0.25 && networkSpeed < 30Mbps:
    compress with zstd level 1 (if thermal ≥ fair) or LZ4 (if thermal < fair)
elif chunk.compressibility > 0.20 && networkSpeed < 3Mbps:
    compress with LZ4
else:
    send raw

if compressed_size >= raw_size * 0.95:
    discard compression, send raw (avoid compression expansion)
```

### 4-Layer Progress Model

**File: `Core/Upload/MultiLayerProgressTracker.swift`**

```swift
public struct MultiLayerProgress: Sendable {
    public let wireProgress: Double          // Layer A: URLSessionTask.countOfBytesSent
    public let ackProgress: Double           // Layer B: UploadChunkResponse confirmed
    public let merkleProgress: Double        // Layer C: Streaming Merkle verified
    public let serverReconstructed: Double   // Layer D: Server confirmed file reassembly
    public let displayProgress: Double       // Smoothed output for UI
    public let eta: ETAEstimate              // Range estimate
}

public struct ETAEstimate: Sendable {
    public let low: TimeInterval     // Optimistic
    public let mid: TimeInterval     // Best estimate
    public let high: TimeInterval    // Pessimistic
}
```

**Smoothing:** Savitzky-Golay filter (window=7, polynomial order=2) on `displayProgress`.

**Safety valves:**
- Wire vs ACK divergence > 8% → display ACK (more conservative) + show "network fluctuation"
- ACK vs Merkle divergence > 0 → IMMEDIATE PAUSE + reverify last 3 chunks
- Progress is monotonically non-decreasing: `displayProgress = max(lastDisplayed, computed)`
- Last-5% deceleration: when progress > 95%, scale remaining to slow approach to 100%

---

## 5. LAYER 3: CONTENT ADDRESSING ENGINE

### File: `Core/Upload/CIDMapper.swift`

**ACI → CID v1 mapping:**
```
ACI:  aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
CID:  multibase("b") + multicodec(0x12) + multihash(0x12, 32, sha256_bytes)
```

**Extend existing ACI.swift algorithm enum** to include: `"blake3"`, `"verkle"` (reserved for future).

### File: `Core/Upload/ProofOfPossession.swift`

**Protocol flow:**
```
1. Client → Server: "I have ACI=xxx, merkleRoot=yyy, totalChunks=zzz"
2. Server → Client: Challenge{
     nonce: UUID_v7 (15s expiry),
     challenges: [
       {chunkIndex: 7, type: .fullHash},
       {chunkIndex: 13, type: .partialHash, byteRange: 1024..<5120},
       {chunkIndex: 42, type: .merkleProof},
       ... (5 challenges for <100MB, 8 for 100MB-1GB, 12 for >1GB)
     ]
   }
3. Client → Server: ChallengeResponse{
     nonce: <echo back>,
     responses: [sha256_of_chunk7, sha256_of_partial_chunk13, merkle_proof_42, ...]
   }
4. Server verifies all → instant upload complete (link existing data)
```

**Security:** Challenge-response encrypted with ECDH ephemeral key + AES-GCM even within HTTPS.

---

## 6. LAYER 4: CRYPTOGRAPHIC INTEGRITY ENGINE

### File: `Core/Upload/StreamingMerkleTree.swift`

**Binary Carry Model:**
```
chunk 0: stack = [h0]
chunk 1: stack = [H(0x01||0||h0||h1)]        // merge, push level-1 node
chunk 2: stack = [H(0x01||0||h0||h1), h2]
chunk 3: stack = [H(0x01||1||H(0x01||0||h0||h1)||H(0x01||0||h2||h3))]  // double merge
```

**Leaf hash:** `SHA-256(0x00 || chunkIndex_LE32 || data)` — index prevents identical-content collision.
**Internal hash:** `SHA-256(0x01 || level_LE8 || left || right)` — level prevents cross-level attack.
**Empty tree root:** `SHA-256(0x00)` (well-known constant).

**Subtree checkpoint:** Every carry merge AND every 16 leaves → emit checkpoint to server.

**Memory:** O(log n) — only the "carry stack" is retained.

### File: `Core/Upload/ChunkCommitmentChain.swift`

```swift
// Forward chain
commit[0] = SHA-256("CCv1\0" || chunk_hash[0] || genesis)
commit[i] = SHA-256("CCv1\0" || chunk_hash[i] || commit[i-1])

// Genesis is session-specific
genesis = SHA-256("Aether3D_CC_GENESIS_" || sessionId)

// Jump chain: every sqrt(n) chunks
jump[j] = SHA-256("CCv1_JUMP\0" || commit[j * stride])
```

**Bidirectional:** Forward chain built during upload. Reverse chain verification during resume. Binary search to locate first tampered chunk.

### File: `Core/Upload/ByzantineVerifier.swift`

**Sampling count:** `max(ceil(log2(n)), ceil(sqrt(n/10)))` chunks verified.
**Coverage target:** 99.9%.
**Timing:** Initiated within 100ms of ACK, timeout 500ms.
**Failure response:** Retransmit chunk + ±2 neighbors + immediate second verification. If second also fails → Level 4 alert → switch endpoint.
**Zero trust:** If server refuses to provide Merkle proof 3 times → mark "untrusted" → switch endpoint.

---

## 7. LAYER 5: ERASURE RESILIENCE ENGINE

### File: `Core/Upload/ErasureCodingEngine.swift`

**Adaptive Reed-Solomon:**
```
Loss rate < 1%  (WiFi):     RS(20, 22)  — 10% redundancy
Loss rate 1-5%  (4G):       RS(20, 24)  — 20% redundancy
Loss rate 5-8%  (weak):     RS(20, 28)  — 40% redundancy
Loss rate > 8%:             Switch to RaptorQ fountain code
```

**Galois field:** GF(2^8) when chunk count ≤ 255, GF(2^16) otherwise.
**SIMD:** ARM NEON `vmull_p8` for polynomial multiplication.
**Systematic coding:** First k blocks = original data (no encoding overhead for those).

**Unequal Error Protection (UEP):**
```
Priority 0 (first/last frame + intrinsics): 3x redundancy
Priority 1 (key frames, quality > 0.9):     2.5x redundancy
Priority 2 (normal frames):                 1.5x redundancy
Priority 3 (low-quality frames):            1x redundancy
IMU data: same redundancy as its associated frame
```

---

## 8. LAYER 6: INTELLIGENT SCHEDULING ENGINE

### File: `Core/Upload/FusionScheduler.swift`

**4 parallel controllers:**

1. **MPC (Model Predictive Control):** Predict next 5 steps, minimize Σ(latency) + λ·Σ(energy). Output: optimal chunk size sequence.

2. **ABR (Adaptive Bitrate):** Buffer-Based Approach variant. Queue length (bytes, not count) → chunk size mapping.

3. **EWMA:** α=0.3, compute "chunk size that transmits in 3 seconds at estimated speed".

4. **Kalman:** Use KalmanBandwidthPredictor output + trend. If falling → smaller chunk, if rising → larger.

**Fusion:**
```swift
let candidates = [mpcSize, abrSize, ewmaSize, kalmanSize]
let weights = controllerAccuracies  // Updated per-chunk based on prediction error
let finalSize = weightedTrimmedMean(candidates, weights)  // Remove highest/lowest, weighted avg

// Lyapunov Drift-Plus-Penalty safety valve
if queueDriftPositive && drift > adaptiveThreshold {
    finalSize = min(finalSize, drainRateSize)  // Prevent queue explosion
}

// Align to 16KB page boundary
finalSize = (finalSize / 16384) * 16384
```

**Controller accuracy tracking:** Per-chunk, `weight_i = 1 / (1 + cumulative_error_i^2)`.

**Thompson Sampling for server selection** (when multiple endpoints available):
- Reward = throughput / (latency × (1 + error_rate))
- First 20% chunks: explore. Last 80%: exploit.
- Cold start: use prior from previous session.

---

## 9. PR5+PR9 FUSION: CAPTURE-UPLOAD-RENDER PIPELINE

### In ChunkedUploader.swift — Bridge to PR5CapturePipeline

**Quality gate → upload decision:**
```swift
// When PR5CapturePipeline.processFrame() returns:
// .accepted(quality > 0.9) → Priority 1 (HIGH), RS 2.5x redundancy
// .accepted(quality ≤ 0.9) → Priority 2 (NORMAL), RS 1.5x redundancy
// .rejected              → Priority 3 (LOW), RS 1x, upload deferred
// .pending(requiresPatchGate) → wait for patch decision, then assign priority
```

**6-level priority queue:**
```
Priority -1 (EMERGENCY): Resume metadata when device shutting down
Priority 0  (CRITICAL):  First frame + last frame + camera intrinsics + IMU calibration
Priority 1  (HIGH):      PR5 key frames (quality > 0.9)
Priority 2  (NORMAL):    Standard frames
Priority 3  (LOW):       Rejected/low-quality frames
Priority 5  (DEFERRED):  Non-critical metadata, uploadable in background WiFi
```

**Anti-starvation:** Every 8 high-priority chunks, send 1 low-priority chunk.

**Incremental render triggers:**
- Trigger 1: ≥3 key frames + camera intrinsics + ≥1 IMU segment received → start sparse SfM
- Trigger 2: ≥30% key frames received → start MVS dense reconstruction
- Trigger 3: All frames + Merkle root verified → start fine refinement

**IMU data:**
- Sampling rate: 200Hz (if hardware supports, else max available)
- Encoding: Delta encoding + zstd compression (>80% compression ratio)
- Attached to each chunk as trailing metadata
- Timestamp source: `mach_absolute_time()` for clock synchronization with video frames

---

## 10. UNIFIED RESOURCE MANAGEMENT

### File: `Core/Upload/UnifiedResourceManager.swift`

**Thermal budget allocation:**
```
             Capture%  Upload%  Render%  System%
nominal:       45        25       15       15
fair:          50        20       10       20
serious:       60        10        5       25
critical:      75         0        0       25
```

**Schmitt hysteresis:** Rise threshold = nominal×1.05, Fall threshold = nominal×0.90. Debounce 5s.
**Predictive:** If temperature slope > 0.3 C/min (Kalman estimate), preemptively reduce upload budget.
**Critical:** Upload budget = 0% (complete pause). Resume only after cooling + 30s stability.

**Battery strategy (6 levels):**
```
Charging:      Max throughput - 10% thermal deduction
100-50%:       Parallel=6, chunkMax=16MB, WiFi+5G
50-30%:        Parallel=4, chunkMax=8MB, WiFi+5G
30-15%:        Parallel=2, chunkMax=4MB, WiFi only
15-5%:         Parallel=1, chunkMax=2MB, WiFi only, pause Merkle verify
<5%:           Pause upload, write resume point, release all memory
Low Power Mode: Same as 30-15% + force compression enabled
```

**Memory (via `os_proc_available_memory()`):**
```
> 200MB:  Normal operation, mmap allowed
100-200MB: Reduce in-flight chunks, switch to FileHandle
50-100MB:  Pause upload, release buffers
< 50MB:    Emergency - write resume point, release ALL
```

---

## 11. SECURITY HARDENING

### 11.1 Transport Security (implement in ChunkedUploader + ConnectionPrewarmer)
- S-01: Certificate pinning (already exists via CertificatePinningManager) — no change needed
- S-02: Force TLS 1.3 only via URLSessionConfiguration TLS settings
- S-07: Chunk reordering protection via Commitment Chain
- S-08: Chunk replacement protection via per-chunk hash + Merkle proof
- S-09: Chunk deletion protection via `expected_total_chunks` commitment at session start
- S-10: Server forgery protection via Byzantine verification
- S-12: DNS hijack protection: pre-resolve + cache + compare with previous resolution

### 11.2 Data Security (implement across multiple files)
- D-01: Encryption key storage: Use Keychain on Apple platforms, file-based on Linux
- D-02: Sensitive buffers: `mlock()` in HybridIOEngine, `memset_s()` before deallocation
- D-04: Log truncation: All hashes/sessionIds truncated to first 8 chars in logs
- D-06: Key derivation: HKDF from master key for per-session keys
- D-08: Session snapshot encryption: AES-GCM + HMAC in EnhancedResumeManager

### 11.3 Integrity Security (implement in StreamingMerkleTree + ChunkCommitmentChain)
- I-01: TOCTOU double-check: `flock()` + `fstat()` post-open in HybridIOEngine
- I-02: Merkle leaf includes chunkIndex, internal node includes level
- I-06: Truncation protection: total_chunks commitment + final Merkle root verification
- I-07: Splicing protection: sessionId bound to Commitment Chain genesis

### 11.4 Replay Protection (update existing ReplayAttackPreventer integration)
- Change nonce cleanup from `removeAll()` at 10000 to LRU eviction by timestamp
- Reduce window from 300s to 120s
- Each chunk carries monotonic counter in header

### 11.5 Privacy (implement in UploadTelemetry + ChunkedUploader)
- P-04: Replace fileName with hash-based identifier in upload API calls
- P-08: URLCache set to `.ephemeral` (no disk caching of chunks)
- P-10: Telemetry data applies differential privacy noise (epsilon=1.0)

---

## 12. CONSTANTS TUNING

### Modify `Core/Constants/UploadConstants.swift` — change these exact values:

```swift
// CHUNK SIZES
CHUNK_SIZE_MIN_BYTES:     2MB → 512KB (512 * 1024)          // 3G timeout rate 11%→3.8%
CHUNK_SIZE_DEFAULT_BYTES: 5MB → 2MB   (2 * 1024 * 1024)     // BDP-optimal for 4G LTE
CHUNK_SIZE_MAX_BYTES:     20MB → 16MB (16 * 1024 * 1024)    // 1024 Apple Silicon pages
CHUNK_SIZE_STEP_BYTES:    1MB → 512KB (512 * 1024)           // Finer granularity

// NETWORK SPEED THRESHOLDS
NETWORK_SPEED_SLOW_MBPS:        5.0 → 3.0    // 3-5Mbps can still use 512KB chunks
NETWORK_SPEED_NORMAL_MBPS:      50.0 → 30.0  // 30-50 classified as fast → larger chunks
NETWORK_SPEED_MIN_SAMPLES:      3 → 5         // Kalman needs ≥5 for reliable state estimation
NETWORK_SPEED_WINDOW_SECONDS:   30.0 → 45.0  // Capture full 5G oscillation cycle
NETWORK_SPEED_MAX_SAMPLES:      20 → 30       // 45s / 1.5s = 30 samples

// PARALLELISM
MAX_PARALLEL_CHUNK_UPLOADS:     4 → 6         // HTTP/2 multiplexing handles 6 well
PARALLEL_RAMP_UP_DELAY_SECONDS: 0.1 → 0.05   // 50ms sufficient with HTTP/2
PARALLELISM_ADJUST_INTERVAL:    5.0 → 3.0     // Track 5G fluctuations faster

// SESSION
SESSION_MAX_AGE_SECONDS:        86400 → 172800   // 48h for next-day resume
SESSION_CLEANUP_INTERVAL:       3600 → 1800      // 30min cleanup
SESSION_MAX_CONCURRENT:         3 → 5             // Multi-device support

// TIMEOUTS
CHUNK_TIMEOUT_SECONDS:          60.0 → 45.0   // Faster failure detection
CONNECTION_TIMEOUT_SECONDS:     10.0 → 8.0    // 5G/WiFi connect < 3s
STALL_DETECTION_TIMEOUT:        15.0 → 10.0   // Faster stall recovery
STALL_MIN_PROGRESS_RATE_BPS:    1024 → 2048   // 2KB/s minimum meaningful

// RETRY
CHUNK_MAX_RETRIES:              3 → 5          // More resilient on weak networks
RETRY_BASE_DELAY_SECONDS:       2.0 → 1.0     // AWS best practice: base=1s
RETRY_MAX_DELAY_SECONDS:        60.0 → 30.0   // Mobile handover < 20s
RETRY_JITTER_FACTOR:            0.5 → 1.0     // Full jitter (0 to 100%)

// PROGRESS
PROGRESS_THROTTLE_INTERVAL:     0.1 → 0.066   // 15fps (ProMotion 1/2 frame)
PROGRESS_MIN_BYTES_DELTA:       64KB → 32KB   // Finer granularity
PROGRESS_SMOOTHING_FACTOR:      0.3 → 0.2     // Smoother ETA
MIN_PROGRESS_INCREMENT_PERCENT: 2.0 → 1.0     // 1% visible increments

// FILE VALIDATION
MAX_FILE_SIZE_BYTES:            10GB → 20GB    // High-density 3D scans
MIN_CHUNKED_UPLOAD_SIZE_BYTES:  5MB → 2MB      // Align with new default chunk size

// IDEMPOTENCY
IDEMPOTENCY_KEY_MAX_AGE:        86400 → 172800 // Match session max age
```

---

## 13. INTEGRATION POINTS WITH EXISTING CODE

### 13.1 ChunkedUploader ↔ PipelineRunner
In `PipelineRunner.swift`, the current `upload(videoURL:)` method does single-file upload.
PR9's `ChunkedUploader` replaces this. The integration:
```swift
// OLD (PipelineRunner):
let assetId = try await remoteClient.upload(videoURL: videoURL)

// NEW (PipelineRunner uses ChunkedUploader):
let uploader = ChunkedUploader(fileURL: videoURL, apiClient: apiClient, ...)
let assetId = try await uploader.upload()
```
**Do NOT modify PipelineRunner.swift** — instead, ChunkedUploader should conform to the same interface that PipelineRunner expects.

### 13.2 ChunkedUploader ↔ UploadSession
ChunkedUploader creates and manages UploadSession instances. Use existing UploadSession.init and state management. Do not modify UploadSession.swift — extend through composition.

### 13.3 ChunkedUploader ↔ APIContract
Use existing API types:
- `CreateUploadRequest` → to create upload session on server
- `UploadChunkResponse` → to process per-chunk ACK (Layer B progress)
- `GetChunksResponse` → for resume (server state verification)
- `CompleteUploadRequest` → to finalize upload

### 13.4 ChunkedUploader ↔ ImmutableBundle
After all chunks uploaded + verified, the existing `ImmutableBundle.seal()` flow handles bundling. PR9's StreamingMerkleTree should produce a root hash compatible with ImmutableBundle's MerkleTree.

### 13.5 ChunkedUploader ↔ PR5CapturePipeline
PR5CapturePipeline is an `actor` with `processFrame(frameId:timestamp:quality:) → FrameProcessingResult`. PR9 observes these results (via delegate or AsyncStream) and assigns upload priority. **Do NOT modify PR5CapturePipeline.swift.**

### 13.6 RecordingController.pollFileSize → Chunk Trigger
RecordingController already polls file size during recording. When file grows by ≥ chunkSize, trigger chunk read + upload. **Do NOT modify RecordingController.swift** — observe its notifications.

---

## 14. TESTING REQUIREMENTS

Create test files in `Tests/PR9Tests/`:

| Test File | What It Tests |
|-----------|--------------|
| `ChunkedUploaderTests.swift` | Full upload lifecycle, pause/resume, cancel, error handling |
| `HybridIOEngineTests.swift` | mmap vs FileHandle selection, CRC32C correctness, compressibility sampling |
| `KalmanBandwidthPredictorTests.swift` | Convergence speed, anomaly detection, network switch adaptation |
| `StreamingMerkleTreeTests.swift` | Binary carry correctness, subtree checkpoints, RFC 9162 compliance |
| `ChunkCommitmentChainTests.swift` | Forward/reverse verification, jump chain, tampering detection |
| `MultiLayerProgressTrackerTests.swift` | 4-layer consistency, monotonic guarantee, safety valve triggers |
| `EnhancedResumeManagerTests.swift` | FileFingerprint validation, encrypted persistence, 3-level resume |
| `FusionSchedulerTests.swift` | 4-theory fusion, Lyapunov stability, controller weight adaptation |
| `ErasureCodingEngineTests.swift` | RS encode/decode correctness, RaptorQ fallback, UEP levels |
| `ProofOfPossessionTests.swift` | Challenge-response protocol, anti-replay, partial chunk verification |

**Test conventions:**
- `@MainActor` + `async setUp/tearDown` is BROKEN on Linux (xctest #504). Use synchronous setUp or `--skip` on Linux.
- Use `--disable-swift-testing` flag if mixing XCTest with Swift Testing.
- All tests must pass on macOS. Linux tests may skip PR5-dependent tests.

---

## 15. ACCEPTANCE CRITERIA

### Must Have (PR9 merge blockers)
- [ ] `ChunkedUploader` can upload a 100MB file in 5MB chunks with parallel upload
- [ ] Resume works after simulated network disconnect (3-level verification)
- [ ] Progress reports are monotonically non-decreasing
- [ ] CRC32C + SHA-256 computed in single file pass
- [ ] Streaming Merkle tree produces same root as ImmutableBundle's MerkleTree for same data
- [ ] Commitment Chain detects chunk reordering
- [ ] All constants updated per Section 12
- [ ] All 16 files created per Section 2
- [ ] All test files pass on macOS
- [ ] `swift build` succeeds on macOS and Linux

### Should Have (PR9 v3.0 complete)
- [ ] Kalman filter converges within 5 samples on stable network
- [ ] Byzantine verification catches simulated corrupt chunk
- [ ] Reed-Solomon recovers from simulated 2-chunk loss in RS(20,24)
- [ ] Proof-of-Possession protocol completes < 50ms for 100MB file
- [ ] Unified thermal management prevents upload during critical thermal state
- [ ] 4-layer progress divergence triggers safety valve
- [ ] Connection prewarmer reduces first-chunk latency vs cold start

### Nice to Have (future PR9.1)
- [ ] RaptorQ fountain code implementation
- [ ] Thompson Sampling CDN selection
- [ ] Full ECDH-encrypted PoP channel
- [ ] ACI ↔ CID v1 bidirectional mapping with Multicodec registration

---

## FINAL NOTES

1. **Read existing code FIRST.** Every file listed in Section 1.2 must be read before writing any code.
2. **Do NOT modify existing files** except `UploadConstants.swift` (Section 12 changes only).
3. **Compose, don't inherit.** Wrap existing classes (UploadSession, ChunkManager) rather than subclassing.
4. **All new types must be `Sendable`** (value types) or `actor`/`final class` with queue synchronization.
5. **Test on macOS first.** Linux compatibility is secondary.
6. **No external dependencies.** Pure Foundation + CryptoKit/swift-crypto only.
7. **Every public API gets a `///` doc comment** with invariant documentation.
8. **The branch is `pr9/chunked-upload-v3`.** Switch to it before writing any code. `git checkout pr9/chunked-upload-v3`.
