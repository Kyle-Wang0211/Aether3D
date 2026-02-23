# PR9: Chunked Upload v3.0 — Complete Implementation Specification

## CRITICAL: Read This First

**Branch:** `pr9/chunked-upload-v3` (created from `main`)
**Switch to it:** `git checkout pr9/chunked-upload-v3`
**DO NOT touch PR10 branch or any PR10 files.**

You are implementing PR9 for the Aether3D project — a **6-layer fusion chunked upload engine** designed to be the most advanced mobile upload system ever built. This document is the **SINGLE SOURCE OF TRUTH** — it contains every constant value, every algorithm, every security measure, every file to create, and every line-level integration point with existing code.

### Core Design Philosophy

> **Once the user taps "End Capture", everything is OUR responsibility.**
> - Upload speed is SACRED — we NEVER throttle for battery, thermal, or power
> - The user has a charger and cooling equipment — battery/thermal management is their choice
> - Our job: deliver the fastest possible upload at the highest quality with the strongest protection
> - Every millisecond saved is a better user experience

---

## TABLE OF CONTENTS

1. [Project Context & Constraints](#1-project-context--constraints)
2. [Files to Create (26 implementation + 27 test = 53 total)](#2-files-to-create)
3. [Layer 1: Device-Aware I/O Engine](#3-layer-1-device-aware-io-engine)
4. [Layer 2: Adaptive Transport Engine](#4-layer-2-adaptive-transport-engine)
5. [Layer 3: Content Addressing Engine](#5-layer-3-content-addressing-engine)
6. [Layer 4: Cryptographic Integrity Engine](#6-layer-4-cryptographic-integrity-engine)
7. [Layer 5: Erasure Resilience Engine](#7-layer-5-erasure-resilience-engine)
8. [Layer 6: Intelligent Scheduling Engine](#8-layer-6-intelligent-scheduling-engine)
9. [PR5+PR9 Fusion: Capture-Upload Pipeline](#9-pr5pr9-fusion-capture-upload-pipeline)
10. [Unified Resource Management (NO Throttling)](#10-unified-resource-management)
11. [Extreme Performance Optimizations](#11-extreme-performance-optimizations)
12. [Security Hardening (115+ items)](#12-security-hardening)
13. [Constants (ALL final values)](#13-constants)
14. [Feature Flags](#14-feature-flags)
15. [Wire Protocol](#15-wire-protocol)
16. [Integration Points with Existing Code](#16-integration-points-with-existing-code)
17. [Testing Requirements (27 test files, 3000+ assertions)](#17-testing-requirements)
18. [Dependency Graph and Build Order](#18-dependency-graph-and-build-order)
19. [Acceptance Criteria](#19-acceptance-criteria)

---

## 1. PROJECT CONTEXT & CONSTRAINTS

### 1.1 Build System
- Swift Package: `swift-tools-version: 5.9` at `progect2/` subdirectory
- Cross-platform: iOS + macOS + Linux (pure Foundation, no UIKit/AppKit in Core)
- Conditional imports: `#if canImport(CryptoKit)` / `#elseif canImport(Crypto)`
- All new files MUST have SPDX header: `// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary`
- All new files MUST have Constitutional Contract header for Core modules

### 1.2 Existing Architecture You MUST Integrate With

These files already exist. **Read them carefully before writing ANY code:**

| File | What It Does | PR9 Relationship |
|------|-------------|-----------------|
| `Core/Upload/UploadSession.swift` | 8-state machine (initialized→uploading→paused→stalled→completing→completed→failed→cancelled), ChunkStatus tracking | PR9 ChunkedUploader orchestrates this directly |
| `Core/Upload/ChunkManager.swift` | Parallel chunk coordination, delegate pattern, decorrelated jitter retry | PR9 replaces retry algorithm, adds priority queue |
| `Core/Upload/AdaptiveChunkSizer.swift` | 3 strategies (fixed/adaptive/aggressive) | PR9 extends to 5 strategies + 4-theory fusion scheduler + ML 5th controller |
| `Core/Upload/NetworkSpeedMonitor.swift` | Weighted average speed estimation, SpeedSample, NetworkSpeedClass. **BUG: Uses Mibps not Mbps** — PR9 uses SI Mbps: `(speedBps * 8.0) / 1_000_000.0` | PR9 adds Kalman 4D filter + ML LSTM ensemble alongside existing EWMA |
| `Core/Upload/UploadProgressTracker.swift` | Single-layer progress, throttled reporting | PR9 extends to 4-layer progress model |
| `Core/Upload/UploadResumeManager.swift` | UserDefaults-based session persistence (**BUG: plaintext**) | PR9 adds FileFingerprint, AES-GCM encryption, 3-level resume |
| `Core/Upload/HashCalculator.swift` | SHA-256 streaming file hash, timing-safe comparison. **BUG: fatalError on invalid domain tag; timingSafeEqualHex silently returns false on parse failure** | PR9 adds CRC32C parallel computation, fixes error handling |
| `Core/Upload/ImmutableBundle.swift` | 19-step seal, Merkle tree (RFC 9162), TOCTOU prevention. **BUG: exportManifest returns Data() on error; prefix sampling not random** | PR9 integrates streaming Merkle tree |
| `Core/Upload/ACI.swift` | Aether Content Identifier `aci:1:sha256:<hex>` | PR9 adds CID v1 bidirectional mapping |
| `Core/Network/APIContract.swift` | CreateUploadRequest, UploadChunkResponse, GetChunksResponse, CompleteUploadRequest | PR9 uses these existing API contracts |
| `Core/Network/APIClient.swift` | Actor-based HTTP client with cert pinning, rate limiting. **BUG: Creates new URLSession per request** | PR9 creates ONE URLSession at init and reuses |
| `Core/Network/IdempotencyHandler.swift` | Actor-based, SHA-256 key generation, 24h TTL cache | PR9 extends to chunk-level granularity |
| `Core/Constants/UploadConstants.swift` | SSOT for all upload magic numbers | PR9 updates values (see Section 13) |
| `Core/Mobile/MobileBatteryAwareScheduler.swift` | Low Power Mode detection | **PR9 IGNORES battery — always 100% upload budget** |
| `Core/Mobile/MobileMemoryPressureHandler.swift` | 3-phase memory warning response | PR9 reduces buffers but NEVER pauses upload |
| `Core/Mobile/MobileThermalStateHandler.swift` | 4-level quality based on thermal state | **PR9 IGNORES thermal — always 100% upload budget** |
| `Core/Pipeline/PipelineRunner.swift` | Sequential pipeline: upload→startJob→pollAndDownload | PR9 replaces single `upload()` with chunked streaming |
| `Sources/PR5Capture/PR5CapturePipeline.swift` | Actor-based frame quality gating (accept/reject/pending) | PR9 bridges quality decisions to upload priority |
| `App/Capture/RecordingController.swift` | Video capture with pollFileSize during recording | PR9 uses pollFileSize as chunk trigger |
| `Core/Mobile/MobileProgressiveScanLoader.swift` | Progressive download: Coarse→Medium→Fine LOD | PR9 designs upload as symmetric mirror |
| `Core/Security/CertificatePinningManager.swift` | **BUG: pinnedHashes is `let` (immutable) — pin rotation impossible** | PR9 creates independent PR9CertificatePinManager |
| `Core/Security/SecureEnclaveKeyManager.swift` | **BUG: force cast `as! SecKey`; returns hex string not SymmetricKey** | PR9 uses optional binding, returns SymmetricKey |
| `Core/Security/BootChainValidator.swift` | **BUG: returns true on Linux (fail-open)** | PR9 is fail-closed on ALL platforms |

### 1.3 Coding Conventions
- Use `actor` for thread-safe stateful components (matches existing IdempotencyHandler)
- Use `final class` + `DispatchQueue` for compatibility with existing patterns (matches UploadSession)
- Use `public` access for all types/methods that other modules need
- Use `Sendable` conformance on all value types
- All async operations use Swift async/await
- Error types as enums conforming to `Error, Sendable, Equatable`
- Document all public APIs with `///` doc comments including invariants
- **NEVER use `fatalError()` for input validation** — always `throw` recoverable errors
- **NEVER use `as!` force cast** — always `as?` with `guard let`
- **All key material as `SymmetricKey`** — never raw bytes or hex strings
- **All security checks are fail-closed** — no platform-conditional `return true`
- **All domain tags as compile-time `StaticString` constants**

---

## 2. FILES TO CREATE

### 2.1 Implementation Files (26)

| # | File Path | Purpose | Lines (est.) |
|---|-----------|---------|-------------|
| 1 | `Core/Upload/ChunkedUploader.swift` | Main orchestrator — coordinates all 6 layers, manages upload lifecycle, bridges PR5 quality gate, HTTP/3 QUIC, 12 parallel streams, zero-copy I/O, connection prewarming | ~1000 |
| 2 | `Core/Upload/ChunkIdempotencyManager.swift` | Chunk-level idempotency extending existing IdempotencyHandler. Per-chunk keys, persistent cache, replay protection | ~200 |
| 3 | `Core/Upload/EnhancedResumeManager.swift` | 3-level resume strategy with FileFingerprint, AES-GCM encrypted snapshots, server state verification, atomic persistence (write+fsync+rename) | ~400 |
| 4 | `Core/Upload/MultiLayerProgressTracker.swift` | 4-layer progress (Wire/ACK/Merkle/ServerReconstructed), Savitzky-Golay smoothing, monotonic guarantee | ~400 |
| 5 | `Core/Upload/HybridIOEngine.swift` | Zero-copy mmap + F_NOCACHE + MADV_SEQUENTIAL, CRC32C+SHA-256+compressibility triple-pass, buffer pool integration | ~400 |
| 6 | `Core/Upload/KalmanBandwidthPredictor.swift` | 4D Kalman filter, anomaly detection via Mahalanobis distance, confidence intervals, network change adaptation | ~250 |
| 7 | `Core/Upload/ConnectionPrewarmer.swift` | 5-stage pipeline (DNS→TCP→TLS→HTTP2→ready), starts at capture UI entry (not upload start), DNS pre-resolution | ~250 |
| 8 | `Core/Upload/StreamingMerkleTree.swift` | Binary Carry Model incremental Merkle tree, O(log n) memory, subtree checkpoints every 16 leaves | ~300 |
| 9 | `Core/Upload/ChunkCommitmentChain.swift` | Bidirectional hash chain with jump chain (O(√n) verification), session-bound genesis | ~200 |
| 10 | `Core/Upload/ByzantineVerifier.swift` | Random-sampling server verification via Merkle proofs, Fisher-Yates sampling, async non-blocking | ~200 |
| 11 | `Core/Upload/ErasureCodingEngine.swift` | Adaptive RS (GF(2^8)/GF(2^16)) + RaptorQ fallback, UEP per priority level, ARM NEON vmull_p8 | ~400 |
| 12 | `Core/Upload/FusionScheduler.swift` | MPC×ABR×EWMA×Kalman×ML 5-theory fusion with Lyapunov DPP stability, Thompson Sampling CDN selection | ~400 |
| 13 | `Core/Upload/UnifiedResourceManager.swift` | **NO throttling.** Always returns 100% upload budget. Reduces buffers under memory pressure but NEVER pauses. Min 2 buffers always. | ~200 |
| 14 | `Core/Upload/CIDMapper.swift` | ACI ↔ CID v1 bidirectional mapping, Multicodec compatibility | ~150 |
| 15 | `Core/Upload/ProofOfPossession.swift` | Secure instant upload: partial-chunk challenges, anti-replay nonce (UUID v7, 15s expiry), ECDH encrypted channel | ~250 |
| 16 | `Core/Upload/UploadTelemetry.swift` | Structured per-chunk trace with all 6 layers' metrics, HMAC-signed audit entries, differential privacy ε=1.0 | ~200 |
| 17 | `Core/Upload/ChunkIntegrityValidator.swift` | Central validation hub: hash check, index range, size bounds, monotonic counter, nonce freshness (LRU not removeAll), commitment chain continuity | ~250 |
| 18 | `Core/Upload/NetworkPathObserver.swift` | NWPathMonitor (Apple) / polling (Linux), feeds events to Kalman for Q adaptation, publishes AsyncStream | ~200 |
| 19 | `Core/Upload/UploadCircuitBreaker.swift` | Circuit breaker pattern: Closed→Open→Half-Open, 5 failures→open, 30s half-open test, 2 successes→close | ~150 |
| 20 | `Core/Upload/ContentDefinedChunker.swift` | FastCDC with gear hash (256-entry table, ~2 GB/s on M1), single-pass CDC+SHA-256+CRC32C, normalized chunking | ~450 |
| 21 | `Core/Upload/RaptorQEngine.swift` | Full RaptorQ fountain code (RFC 6330): LDPC+HDPC pre-coding, Gaussian elimination with inactivation decoding, rateless repair | ~600 |
| 22 | `Core/Upload/MLBandwidthPredictor.swift` | Tiny LSTM via CoreML (~50KB model), 30-sample input, 5-step lookahead, ML+Kalman ensemble with clamped weights [0.3, 0.7] | ~350 |
| 23 | `Core/Upload/CAMARAQoDClient.swift` | CAMARA Quality-on-Demand API: OAuth2 token management, QOS_E profile for max bandwidth, session lifecycle | ~250 |
| 24 | `Core/Upload/MultipathUploadManager.swift` | WiFi+5G `.aggregate` bonding (DEFAULT), path-aware chunk scheduling (priority→low-latency, bulk→high-bandwidth), per-path TLS | ~300 |
| 25 | `Core/Upload/ChunkBufferPool.swift` | Pre-allocated buffer pool, zero allocations during upload loop, memory-pressure-aware (min 2 buffers always) | ~150 |
| 26 | `Core/Upload/PR9CertificatePinManager.swift` | Independent cert pin manager (actor), var activePins + var backupPins, 72h rotation overlap, server-signed pin updates (RSA-4096) | ~200 |

### 2.2 Test Files (27)

| # | Test File | Assertions | What It Tests |
|---|-----------|-----------|--------------|
| 1 | `Tests/PR9Tests/ChunkedUploaderTests.swift` | 200 | Full upload lifecycle, pause/resume, cancel, error handling, 12-stream parallel, HTTP/3 |
| 2 | `Tests/PR9Tests/HybridIOEngineTests.swift` | 100 | mmap vs FileHandle selection, CRC32C correctness, zero-copy, compressibility sampling |
| 3 | `Tests/PR9Tests/KalmanBandwidthPredictorTests.swift` | 100 | Convergence in 5 samples, anomaly detection, network switch Q adaptation |
| 4 | `Tests/PR9Tests/StreamingMerkleTreeTests.swift` | 120 | Binary carry correctness, subtree checkpoints, RFC 9162 compliance |
| 5 | `Tests/PR9Tests/ChunkCommitmentChainTests.swift` | 100 | Forward/reverse verification, jump chain, tampering detection, session-bound genesis |
| 6 | `Tests/PR9Tests/MultiLayerProgressTrackerTests.swift` | 100 | 4-layer consistency, monotonic guarantee, safety valve triggers, Savitzky-Golay |
| 7 | `Tests/PR9Tests/EnhancedResumeManagerTests.swift` | 120 | FileFingerprint validation, AES-GCM encrypted persistence, 3-level resume, atomic write |
| 8 | `Tests/PR9Tests/FusionSchedulerTests.swift` | 100 | 5-theory fusion, Lyapunov stability, controller weight adaptation, Thompson Sampling |
| 9 | `Tests/PR9Tests/ErasureCodingEngineTests.swift` | 120 | RS encode/decode, GF(2^8)/GF(2^16), RaptorQ fallback, UEP levels, NEON operations |
| 10 | `Tests/PR9Tests/ProofOfPossessionTests.swift` | 80 | Challenge-response protocol, anti-replay, partial chunk verification, ECDH channel |
| 11 | `Tests/PR9Tests/ChunkIntegrityValidatorTests.swift` | 100 | All 7 validation types, nonce LRU eviction, monotonic counter |
| 12 | `Tests/PR9Tests/NetworkPathObserverTests.swift` | 60 | Path change detection, WiFi→Cellular handover, AsyncStream events |
| 13 | `Tests/PR9Tests/UploadCircuitBreakerTests.swift` | 60 | State transitions (closed→open→half-open→closed), failure counting, timeout |
| 14 | `Tests/PR9Tests/ChunkIdempotencyManagerTests.swift` | 60 | Per-chunk keys, cache persistence, replay detection |
| 15 | `Tests/PR9Tests/CIDMapperTests.swift` | 40 | ACI→CID roundtrip, Multicodec encoding, edge cases |
| 16 | `Tests/PR9Tests/ConnectionPrewarmerTests.swift` | 60 | 5-stage pipeline, DNS resolution, TLS preconnect, cold-start vs warm latency |
| 17 | `Tests/PR9Tests/UploadTelemetryTests.swift` | 40 | HMAC signing, differential privacy noise, log truncation |
| 18 | `Tests/PR9Tests/UnifiedResourceManagerTests.swift` | 60 | Always returns 100% budget, memory pressure buffer reduction, min-2-buffers |
| 19 | `Tests/PR9Tests/ContentDefinedChunkerTests.swift` | 180 | Gear hash determinism, CDC boundary detection, min/max/avg enforcement, normalization, single-pass hash, dedup protocol |
| 20 | `Tests/PR9Tests/RaptorQEngineTests.swift` | 200 | Systematic encoding, repair symbols, Gaussian elimination, inactivation decoding, GF(256), ErasureCoder conformance |
| 21 | `Tests/PR9Tests/MLBandwidthPredictorTests.swift` | 120 | CoreML inference, ensemble weighting, Kalman fallback, warmup behavior, accuracy tracking, model hash verification |
| 22 | `Tests/PR9Tests/CAMARAQoDClientTests.swift` | 80 | OAuth2 flow, session creation/deletion, error handling, token refresh, Keychain secret storage |
| 23 | `Tests/PR9Tests/MultipathUploadManagerTests.swift` | 100 | .aggregate default, chunk-to-path assignment, Low Data Mode fallback, per-path stats, dual-radio bonding |
| 24 | `Tests/PR9Tests/ChunkBufferPoolTests.swift` | 60 | Pre-allocation, zero-alloc loop, memory pressure adjustment, min-2-buffers |
| 25 | `Tests/PR9Tests/PR9CertificatePinManagerTests.swift` | 60 | Pin rotation, 72h overlap, signature verification, immutable vs mutable |
| 26 | `Tests/PR9Tests/PR9PerformanceTests.swift` | 100 | Zero-copy throughput, LZFSE compression ratio, 12-stream ramp-up timing, buffer pool efficiency |
| 27 | `Tests/PR9Tests/PR9SecurityTests.swift` | 65 | TLS 1.3 enforcement, HMAC-SHA256 per-chunk, buffer zeroing, timing-safe comparison, fail-closed verification |

**Grand Total: 26 implementation files + 27 test files = 53 files, ~3,000+ test assertions**

---

## 3. LAYER 1: DEVICE-AWARE I/O ENGINE

### File: `Core/Upload/HybridIOEngine.swift`

```
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-IO-1.0
// Module: Upload Infrastructure - Hybrid I/O Engine
// Cross-Platform: macOS + Linux (pure Foundation)
```

### 3.1 HybridIOEngine (actor)

**Purpose:** Read file chunks with optimal I/O strategy per platform, compute CRC32C + SHA-256 + compressibility in a single pass. Uses **zero-copy I/O**: mmap + F_NOCACHE + MADV_SEQUENTIAL.

**Decision Matrix:**
```
Platform     | File < 64MB      | 64-512MB             | > 512MB
-------------|------------------|----------------------|------------------
macOS        | mmap+SEQUENTIAL  | mmap 64MB window     | mmap 64MB window
iOS ≥ 200MB* | mmap+SEQUENTIAL  | mmap 32MB window     | mmap 32MB window
iOS < 200MB* | FileHandle 128KB | FileHandle 128KB     | FileHandle 128KB
Linux        | mmap+SEQUENTIAL  | FileHandle 128KB     | FileHandle 128KB

* 200MB = os_proc_available_memory() threshold
```

**Zero-Copy Implementation:**
```swift
// mmap with F_NOCACHE + MADV_SEQUENTIAL (bypass page cache, prefetch hint)
let fd = open(path, O_RDONLY | O_NOFOLLOW)  // NOFOLLOW prevents symlink attacks
fcntl(fd, F_NOCACHE, 1)  // Don't pollute page cache
let ptr = mmap(nil, mapSize, PROT_READ, MAP_PRIVATE, fd, offset)
madvise(ptr, mapSize, MADV_SEQUENTIAL)  // Sequential access hint

// After processing window:
madvise(ptr, mapSize, MADV_DONTNEED)  // Release pages immediately
munmap(ptr, mapSize)
```

**Triple-Pass Single-Read Engine:**

For each 128KB buffer read:
1. **CRC32C**: ARM hardware `__crc32cd` on arm64 (~20 GB/s), software fallback on x86_64 (~500 MB/s)
   - `#if arch(arm64)` → use `crc32_arm_intrinsic()` wrapper
   - `#else` → lookup table CRC32C
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

**Hash stream chunk size:** 128KB (fits in Apple Silicon L1 Data Cache 128KB exactly).

**Security:**
- `flock(fd, LOCK_SH)` shared lock during read (prevent concurrent writes)
- After `open()`: `fstat(fd)` and compare `st_ino` with pre-open `stat()` (TOCTOU double-check)
- mmap uses `MAP_PRIVATE` (copy-on-write protection)
- Sensitive buffers: `mlock()` + `memset_s()` before free

**3-Stage Prefetch Pipeline:**
```
Stage N:   Upload chunk[N] to server
Stage N+1: Compute hash for chunk[N+1]
Stage N+2: Read chunk[N+2] from disk via mmap

// 3 stages run concurrently via TaskGroup
// Net effect: disk I/O never blocks upload
```

### File: `Core/Upload/ChunkBufferPool.swift`

**Purpose:** Pre-allocated buffer pool for zero allocations during upload loop.

```swift
public actor ChunkBufferPool {
    private var available: [UnsafeMutableRawBufferPointer] = []
    private var maxBuffers: Int = 12

    /// Acquire a buffer (blocks if none available, but min 2 always exist)
    public func acquire(size: Int) -> UnsafeMutableRawBufferPointer { ... }

    /// Return a buffer to the pool (zeroed before return)
    public func release(_ buffer: UnsafeMutableRawBufferPointer) {
        memset_s(buffer.baseAddress!, buffer.count, 0, buffer.count)  // Zero before reuse
        available.append(buffer)
    }

    /// Adjust pool size for memory pressure — NEVER below 2
    public func adjustForMemoryPressure() {
        let available = os_proc_available_memory()
        switch available {
        case 200_000_000...:    maxBuffers = 12
        case 100_000_000...:    maxBuffers = 8
        case 50_000_000...:     maxBuffers = 4
        default:                maxBuffers = 2  // NEVER below 2 — NEVER pause
        }
    }
}
```

---

## 4. LAYER 2: ADAPTIVE TRANSPORT ENGINE

### File: `Core/Upload/KalmanBandwidthPredictor.swift`

**State vector (4D):** `[bandwidth, d_bandwidth/dt, d2_bandwidth/dt2, variance]`

**Key parameters:**
- Process noise Q: adaptive (10x increase on NWPathMonitor network change events)
- Measurement noise R: dynamic based on last 10 samples' variance
- Initial covariance P0: `diag(100, 10, 1, 50)`
- Anomaly threshold: Mahalanobis distance > 2.5σ → reduce sample weight
- Convergence indicator: `trace(P) < 5.0` → mark "estimate reliable"

**Conforms to `BandwidthEstimator` protocol:**
```swift
public protocol BandwidthEstimator: Sendable {
    func addSample(bytesTransferred: Int64, durationSeconds: TimeInterval)
    func predict() -> BandwidthPrediction
    func reset()
}
```

**Output:**
```swift
public struct BandwidthPrediction: Sendable {
    public let predictedBps: Double
    public let confidenceInterval95: (low: Double, high: Double)
    public let trend: BandwidthTrend  // .rising, .stable, .falling
    public let isReliable: Bool       // trace(P) convergence check
    public let source: PredictionSource  // .kalman, .ml, .ensemble
}
```

### File: `Core/Upload/MLBandwidthPredictor.swift`

**Architecture: Tiny LSTM via CoreML**
- Input: Sequence of last 30 bandwidth measurements (each: [bw_mbps, rtt_ms, loss_rate, signal_dbm, hour_of_day])
- Hidden size: 32 units
- Output: Next 5 bandwidth predictions (5-step lookahead)
- Model size: ~50KB (.mlmodelc)
- Inference time: <0.5ms on A15+ Neural Engine

```swift
#if canImport(CoreML)
import CoreML
#endif

public actor MLBandwidthPredictor: BandwidthEstimator {
    private var measurementHistory: RingBuffer<BandwidthMeasurement>
    private let historyLength: Int = 30

    #if canImport(CoreML)
    private var model: MLModel?
    #endif

    // Fallback: delegate to KalmanBandwidthPredictor
    private let kalmanFallback: KalmanBandwidthPredictor

    // Ensemble: weighted average of ML and Kalman
    // Weights based on recent accuracy, clamped to [0.3, 0.7]
    // Warmup period: pure Kalman for first 10 samples
    private func mlAccuracyWeight() -> Double {
        guard totalSamples > 10 else { return 0.5 }
        let recentErrors = predictionErrors.last(10)
        let avgError = recentErrors.reduce(0, +) / Double(recentErrors.count)
        let weight = 0.7 - (min(avgError, 0.30) / 0.30) * 0.4
        return max(0.3, min(0.7, weight))
    }
}
```

**Platform handling:** On Linux or when CoreML unavailable, falls back to pure Kalman (no crash, no error — transparent fallback).

### File: `Core/Upload/ConnectionPrewarmer.swift`

**5-stage pipeline — starts at capture UI entry (NOT upload start):**
```
Stage 0 (app launch):        DNS pre-resolve upload endpoint → cache A/AAAA
Stage 1 (enter capture UI):  TCP 3-way handshake → keep-alive
Stage 2 (TCP done):          TLS 1.3 handshake → 0-RTT ready
Stage 3 (TLS done):          HTTP/2 SETTINGS exchange → stream ready
                              OR HTTP/3 QUIC 0-RTT → immediate
Stage 4 (first chunk ready): Immediate write to established stream
```

**URLSession configuration (FINAL values):**
```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 30.0
config.timeoutIntervalForResource = 3600.0
config.httpMaximumConnectionsPerHost = 12           // 12 parallel streams
config.multipathServiceType = .aggregate             // WiFi+5G bonded (max throughput)
config.allowsConstrainedNetworkAccess = false         // Respect Low Data Mode
config.waitsForConnectivity = true
config.requestCachePolicy = .reloadIgnoringLocalCacheData
config.urlCache = nil                                 // No disk caching of chunks

// HTTP/3 QUIC with 0-RTT
if #available(iOS 15.0, macOS 12.0, *) {
    config.assumesHTTP3Capable = true
}

// Reuse this ONE session for ALL chunk uploads:
self.uploadSession = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
```

**DNS Pre-Resolution:**
```swift
// At app launch, resolve and cache upload endpoint
let host = CFHostCreateWithName(nil, "upload.aether3d.com" as CFString).takeRetainedValue()
CFHostStartInfoResolution(host, .addresses, nil)
// Cache result for immediate use when upload starts
```

### File: `Core/Upload/MultipathUploadManager.swift`

**WiFi+5G `.aggregate` bonding — DEFAULT strategy.**

```swift
public actor MultipathUploadManager {
    public enum MultipathStrategy: Sendable {
        case wifiOnly       // Only when user enables Low Data Mode
        case handover       // Legacy failover
        case interactive    // Priority scheduling
        case aggregate      // DEFAULT: Both radios bonded — MAXIMUM throughput
    }

    /// DEFAULT: .aggregate — always use maximum available throughput.
    /// User's intent: see their 3D creation FAST.
    /// Battery management is the user's choice, not ours.
    private var strategy: MultipathStrategy = .aggregate

    /// Path detection:
    /// - 2+ paths available, not constrained → .aggregate (max speed)
    /// - 2+ paths available, constrained (Low Data Mode) → .wifiOnly
    /// - 1 path → .wifiOnly

    /// Chunk-to-path assignment:
    /// - Priority 0-1 (critical/key frames) → lower-latency path
    /// - Priority 2-5 (normal/deferred) → higher-bandwidth path
    /// - Both paths active simultaneously for max throughput
}
```

### File: `Core/Upload/CAMARAQoDClient.swift`

**CAMARA Quality-on-Demand carrier QoS negotiation.**

```swift
public actor CAMARAQoDClient: NetworkQualityNegotiator {
    public enum QoSProfile: String, Sendable, Codable {
        case small = "QOS_S"      // ~1 Mbps guaranteed
        case medium = "QOS_M"     // ~10 Mbps, ~50ms latency
        case large = "QOS_L"      // ~50 Mbps guaranteed
        case extreme = "QOS_E"    // ~100 Mbps, ~20ms — DEFAULT for PR9
    }

    // OAuth2 flow → session creation → upload → session release
    // Only for large uploads (>100MB) on cellular
    // Graceful fallback if QoD unavailable (feature flag OFF by default)
    // OAuth2 secrets stored in Keychain (NEVER UserDefaults or plist)
}
```

**Conforms to protocol:**
```swift
public protocol NetworkQualityNegotiator: Sendable {
    func requestHighBandwidth(duration: TimeInterval) async throws -> QualityGrant
    func releaseHighBandwidth(_ grant: QualityGrant) async
}
```

### Adaptive Compression (in ChunkedUploader)

**LZFSE hardware-accelerated compression — DEFAULT:**
```swift
// LZFSE: ~3 GB/s on Apple Silicon, hardware-accelerated
// Only compress if savings > 10% (compressibility > 0.10)
// Previously: zstd level 1. Now: LZFSE always (faster + Apple hw accel)

if chunk.compressibility > 0.10 {
    let compressed = try compression_encode_buffer(
        dst, dstSize, src, srcSize, nil, COMPRESSION_LZFSE
    )
    if compressed < srcSize * 90 / 100 {  // >10% savings
        sendCompressed(compressed)
    } else {
        sendRaw()  // Compression didn't help enough
    }
} else {
    sendRaw()  // Incompressible data (already compressed/encrypted)
}
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
```

**Smoothing:** Savitzky-Golay filter (window=7, polynomial order=2).

**Safety valves:**
- Wire vs ACK divergence > 8% → display ACK (more conservative) + show "network fluctuation"
- ACK vs Merkle divergence > 0 → IMMEDIATE PAUSE + reverify last 3 chunks
- Progress is monotonically non-decreasing: `displayProgress = max(lastDisplayed, computed)`
- Last-5% deceleration: when progress > 95%, scale remaining to slow approach to 100%

---

## 5. LAYER 3: CONTENT ADDRESSING ENGINE

### File: `Core/Upload/ContentDefinedChunker.swift`

**FastCDC with Gear Hash — ~2 GB/s on Apple M1**

```swift
public actor ContentDefinedChunker {

    /// Pre-computed gear hash table — 256 random UInt64 values.
    /// Generated deterministically: seed = SHA-256("Aether3D_CDC_GearTable_v1")
    /// For each i in 0..<256: SHA-256(seed || UInt8(i)), first 8 bytes as LE UInt64.
    /// CRITICAL: This table MUST be identical across ALL platforms.
    private static let gearTable: [UInt64] = [
        0x88366651EA454722, 0x9F4EBF7BD09F1F51, 0x02206FDA88E8607A, 0x9259E7F86841A3A1,
        0xE51E226D84D29D5F, 0x301D89AA327C54EA, 0x30FF376E91DF0630, 0x0A6A0CB6C495092F,
        0x17F0ED1BB53B7BFD, 0xFE14DD3CF7F1C9C8, 0xD92C668128636D97, 0x51345112DB29739A,
        0x4AF550E596086B9C, 0x3FCCD02D611E090A, 0xEFC78E9CC0FD6F44, 0xFFEECBE157031E0B,
        0x4F3E8FE6539B3F35, 0xE0422A50B0E3EFF7, 0x0A7E38BC3DFD194F, 0x170987B12C9710AD,
        0xB22D35395FD0534A, 0x7DC24D738D13683A, 0x298B39B0CFA9DFC9, 0xA3CBA311221D4212,
        0xE15434A425D1ECA1, 0xA0EE5D90DE151098, 0x20876C778EAEBFD2, 0xBD52E7B8D2C1E0B5,
        0x462B72AFBA6B249F, 0x9EF2B95232F01B11, 0x3B63613BF24A80C1, 0x535F1CB9CBC17D03,
        0x92B98A78D7D93B42, 0x333287DF8C432E86, 0xBF6212AED01D2E28, 0x5CBEBDEF035D4C73,
        0xCEAE659933273AAC, 0xEEA1D816FBDF8D64, 0x639A8926E67E904E, 0x36B6254CF72F4382,
        0x42961CBAB2B6C995, 0x77EED2341643F1FA, 0xD09A18283B544FCF, 0x6F6E4457A6E2677F,
        0xC7C189F3372BA8E9, 0xEFF84C772E646E50, 0xAD54F0357EA5E1A6, 0x56F6427BFED7CD81,
        0x50D510E41E676B2E, 0x15BCF94B929A91A5, 0x3A50040CE883E6DC, 0x2A5A7F6F508A00FD,
        0x8CEA524792B07A67, 0xEB0A3BDC0535751F, 0x17ADFEFDC027FFDA, 0x8B8C01D185132621,
        0x7514726BA5D6C022, 0x19BEC8628AC7561A, 0xB158FE48AB7940C5, 0x3CE719FB0E96D143,
        0x5E50B413BEC81EFF, 0x8D03F82837FF3F73, 0xA7BCD460E9D9EDB5, 0xF70A6971B5A6837A,
        0xF4AA91B434D5A122, 0xDC5F7DC878225FD3, 0x4880136C7EF0D40A, 0xA7106EBB1D0C71B2,
        0xAC5135E6F1214D91, 0xD9C7E7CBC851B32F, 0xF71AB63C03647BC5, 0x80FE6DD6758FB7D7,
        0xBC407F16B7874086, 0xBD03682EFDF647A6, 0xA6AE96277778DF11, 0x52CBAC8243C3C972,
        0xFCEE3C3919531CFA, 0x764EDF51790A4971, 0x84C9CD02D3A97CDD, 0x55974B6DFC34F26C,
        0x71880DC5738D8AA7, 0xD30B17DEDFA27EAC, 0xFA0220FF9443EC02, 0x12BA317F26D4814B,
        0x437CBEC0DB08C9BA, 0x0FCB3271A0ED9936, 0xE8308731CC5497F3, 0x611402E980113EF9,
        0xF3601E84166D2DAF, 0xCC8AC92431B9E156, 0x689E4FF3D5FE0A2E, 0x9EDD63EB062B7442,
        0x249EF7B6E7C67834, 0x3EFDFA0F3559BFCC, 0x70C7F3199B1E5D29, 0x226E757548C963DE,
        0x06EF8F6933C1813F, 0xBF6CF09D0A682D0E, 0x0158D190EF9B92AC, 0x692FDCA19A3CCD1B,
        0x946207026777820B, 0x7C2FF2C2D2B0F655, 0x9FE60F8A79E2B39A, 0xE6A613AB65BABFF4,
        0x9D5DA92F49AB28CE, 0x9369E08A557F6F29, 0xC71C50AAFB652F4F, 0xEDA75016B5014FE3,
        0x8EBBA897FBA08BDE, 0x648C88CC5E406F4E, 0xC5AD2A28C1837F75, 0x786E1EE55E57CDD2,
        0x402633BE5EF9392C, 0xFB31EB0A7443B401, 0xAABFFE72C7C7EB59, 0x639B71460103E1A8,
        0x2DD673BBE3DEF999, 0x8FC305B1F4DBD16B, 0x0411B1CD5277F407, 0x7D9D789F64499B41,
        0x0D404A8A608F9D3C, 0x5BE4E3DE0EAA89BF, 0x784F392B06B99B94, 0x182BDBE281B29189,
        0xFA114C9153654576, 0xB9D72048B56230E4, 0x70F6A6C144302E67, 0x8493209B5E3730A7,
        0x7C784451A4415650, 0x98339596821725B0, 0x0B1C69221A22BC15, 0x6F282D68A4EE41F4,
        0xFEBA82E665123D34, 0x153E06215C603A38, 0x25B5305F343017FA, 0xBB6C68B73A7448A5,
        0xC00B6837C3F6265A, 0xC2D346E8328B8E96, 0x6B2624CE2F5F72D9, 0x313CC9876608BF08,
        0x65E9CF7EADBA14AE, 0x936D9226098C1713, 0xD26BD3B9D23F0975, 0x12BF845CDE4C1163,
        0x0C1F58972871657F, 0x81882972CE21E832, 0xBD7F0C4F4100C1F4, 0x0A046DF148BC8FFA,
        0x2104351C7D432945, 0x5D4B872DF08FC219, 0xB4253576F4172797, 0x654D57F2C5E3B3A2,
        0x7B5A7FBA8F54BE3B, 0xF6C7350EBC5BA820, 0x63F102B8BCF5532F, 0xE18AE217EB53B92A,
        0x9B80DAB5E1068516, 0x71E942540A1625F8, 0x51C2174F72D5E9CE, 0x0DA93EAB4A972915,
        0xA07E8AA6956C311D, 0x2E7927426FF1AC62, 0x377B07961B8BF261, 0xB9BA71B40577B192,
        0xB822FC310EC4FCC6, 0x8FF5104141792C36, 0x00685B09F7BEB16B, 0x1F498DC5ABEB379A,
        0x276E9B26EA7F3E72, 0xF0AF6A91D4DBB5C8, 0x58E6A31B78C2D6C1, 0xC958D2E9CB6CF9DE,
        0x9AD55C28F824FC45, 0x5967B3FADEE466C8, 0x627647D0AC33789D, 0xD839EDFE2E37B956,
        0xA6148C5D6AB83F03, 0x6B877C8AA426E47D, 0x6B10D32FFB0C518D, 0xB0859F9F621E06CE,
        0x67C2C36A8CB7F96D, 0x0C7A20D56923B263, 0xC26A121AF55BEBBB, 0x42D73F28006624EC,
        0x2DE80FC50A56D9F1, 0x7D13E96BBDFE23FA, 0x0279AB946BD14F73, 0xF4A65C8A71A8AD8D,
        0xD64BCB0364CDB2C4, 0xCF90A81827F9DFA2, 0x02A29ED9A478B895, 0x0C828F69E83B059A,
        0x64F6068FAC4BFB2C, 0xE5414B4D2DEFF015, 0x05BD284AF114D2A4, 0x16F12FA0079A4FBD,
        0xCEA58913B861FC40, 0x87FD6A25EFF4F90B, 0xC52809DCCB02C280, 0xDFBBA866FCD4E59E,
        0xF54A20B1285BD136, 0x13D942D8B0C8F2FF, 0xDE078800C6C4BB11, 0x3F3ACF2810FBAA39,
        0x601C23E198AC9728, 0x8795AB17FE9A8D00, 0xB4C129D9CB80FBDC, 0x21603DE40FEDD9E7,
        0xA5EF9CCBB5459A57, 0x3E395ED85E85B5A0, 0x64C8811F0414E7EE, 0x8D10FFEACA26F9CA,
        0x63923687C7DE15FA, 0x4E84E378748CEDA7, 0xB1BE7E952B05781A, 0xD01E91E44EF92A87,
        0xD35986036311E550, 0x814ED62EAB22AD72, 0xF8A59FA94AC5C7CA, 0xE1FCAAE77F712243,
        0x0ADB4E3DE53027DB, 0x8B837F24807998AC, 0x928F9787F13C5A8D, 0xD8236A12E49A9ED6,
        0xB283BBEDC36C33C4, 0x8E68F620E24093E6, 0x0D3F7E54ACFB4724, 0x0A4A73486526E347,
        0x7C236719918DB841, 0xF51CAEF1E9DEB14C, 0xA76DAB4E699506A0, 0x16286EDB9476486C,
        0x94FAEDBAC71D8A03, 0xC5CF18F018E4CB2B, 0xBA0911A9D9F45AF6, 0x268CCBEF290D04CF,
        0x81C089F6492E57AD, 0x247AA96AC8408DFF, 0x21C0B01C76FCB823, 0xEA024AD25CC8A051,
        0x74F11FB5C5ADFD41, 0x634981AC0F86A46A, 0x2A4476A70AAEE0C1, 0xF2C0D43D425F07FC,
        0xD4187C8E2EA497E1, 0x3B6205CA1B8153DE, 0x16266BB261F784A2, 0xA693728C23C776A7,
        0xA04DCC9ED55415D2, 0xC5B33AD7A4D5BCDF, 0xE9F7E076B4B1DECE, 0x68361D857B60BAA7,
        0xDC208FD964698AC3, 0x5A95EC7F3B93CB88, 0x9446A346C13171BA, 0x4363D0140F5AF35C
    ]

    // FastCDC parameters for 3D scan data:
    // avgChunkSize: 1MB (2^20) — optimal for 100MB-50GB binary files
    // minChunkSize: 256KB — prevents tiny chunks
    // maxChunkSize: 8MB — cap prevents single massive chunk
    // normalizationLevel: 1 — reduces variance ~30%

    private let minChunkSize: Int   // CDC_MIN_CHUNK_SIZE
    private let maxChunkSize: Int   // CDC_MAX_CHUNK_SIZE
    private let avgChunkSize: Int   // CDC_AVG_CHUNK_SIZE
    private let maskBits: Int       // = Int(log2(Double(avgChunkSize))) = 20
    private let maskS: UInt64       // Hard mask: (1 << (maskBits + 2)) - 1
    private let maskL: UInt64       // Easy mask: (1 << (maskBits - 2)) - 1
}
```

**Core algorithm:**
```swift
// For each byte:
gearHash = (gearHash << 1) &+ Self.gearTable[Int(byte)]

if chunkByteCount < minChunkSize:    shouldCut = false
elif chunkByteCount >= maxChunkSize: shouldCut = true
elif chunkByteCount < avgChunkSize:  shouldCut = (gearHash & maskS) == 0  // harder
else:                                 shouldCut = (gearHash & maskL) == 0  // easier
```

**CDC + Merkle Integration:**
```swift
// CDC Merkle leaf:
// LeafHash = SHA-256(0x00 || chunkIndex_LE32 || chunkSize_LE32 || chunkSHA256_bytes)
// No changes needed to StreamingMerkleTree — caller passes constructed leaf hash.
```

**CDC Dedup Protocol Extension:**
```swift
public struct CDCDedupRequest: Codable, Sendable {
    public let fileACI: String
    public let chunkACIs: [String]
    public let chunkBoundaries: [CDCBoundary]
    public let chunkingAlgorithm: String  // "fastcdc"
    public let gearTableVersion: String   // "v1"
}

public struct CDCDedupResponse: Codable, Sendable {
    public let existingChunks: [Int]
    public let missingChunks: [Int]
    public let savedBytes: Int64
    public let dedupRatio: Double
}
```

### File: `Core/Upload/CIDMapper.swift`

**ACI → CID v1 mapping:**
```
ACI:  aci:1:sha256:ba7816bf...
CID:  multibase("b") + multicodec(0x12) + multihash(0x12, 32, sha256_bytes)
```

Extend existing ACI.swift algorithm enum to include: `"blake3"`, `"verkle"` (reserved for future).

### File: `Core/Upload/ProofOfPossession.swift`

**Challenge-response protocol:**
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
3. Client → Server: ChallengeResponse{ nonce: <echo>, responses: [...] }
4. Server verifies all → instant upload complete (link existing data)
```

**Security:** Challenge-response encrypted with ECDH ephemeral key + AES-GCM even within HTTPS.

---

## 6. LAYER 4: CRYPTOGRAPHIC INTEGRITY ENGINE

### File: `Core/Upload/StreamingMerkleTree.swift`

**Binary Carry Model (RFC 9162):**
```
chunk 0: stack = [h0]
chunk 1: stack = [H(0x01||0||h0||h1)]
chunk 2: stack = [H(0x01||0||h0||h1), h2]
chunk 3: stack = [H(0x01||1||...)]  // double merge
```

**Leaf hash:** `SHA-256(0x00 || chunkIndex_LE32 || data)` — index prevents identical-content collision.
**Internal hash:** `SHA-256(0x01 || level_LE8 || left || right)` — level prevents cross-level attack.
**Empty tree root:** `SHA-256(0x00)` (well-known constant).

**Subtree checkpoint:** Every carry merge AND every 16 leaves → emit checkpoint to server.
**Memory:** O(log n) — only the "carry stack" is retained.

**Conforms to `IntegrityTree` protocol:**
```swift
public protocol IntegrityTree: Sendable {
    func appendLeaf(_ data: Data) async
    var rootHash: Data { get async }
    func generateProof(leafIndex: Int) async -> [Data]?
    static func verifyProof(leaf: Data, proof: [Data], root: Data, index: Int, totalLeaves: Int) -> Bool
}
```

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
**Sampling:** Fisher-Yates shuffle (CSPRNG) — NOT prefix sampling.
**Failure response:** Retransmit chunk + ±2 neighbors + immediate second verification. If second also fails → switch endpoint.
**Zero trust:** If server refuses to provide Merkle proof 3 times → mark "untrusted" → switch endpoint.

### File: `Core/Upload/ChunkIntegrityValidator.swift`

**Central validation hub — replaces scattered validation:**

```swift
public actor ChunkIntegrityValidator {
    /// Validate chunk before upload: hash, index, size, counter, nonce, commitment
    func validatePreUpload(chunk: ChunkData, session: UploadSessionContext) -> ValidationResult

    /// Validate chunk after server ACK
    func validatePostACK(chunkIndex: Int, serverResponse: UploadChunkResponse,
                         expectedHash: String) -> ValidationResult

    /// Nonce management (FIXES ReplayAttackPreventer removeAll bug):
    /// - LRU eviction: remove oldest 20% when count > 8000 (NOT removeAll!)
    /// - Each entry: (nonce: String, timestamp: Date)
    /// - Window: 120 seconds (not 300s)
    /// - Monotonic counter per session
    func validateNonce(_ nonce: String, timestamp: Date) -> Bool
}
```

**Per-chunk HMAC-SHA256 tamper detection (from v2.4):**
```swift
// Every chunk gets HMAC-SHA256 computed alongside SHA-256
// Sent in X-Chunk-HMAC header
// Server verifies before acknowledging
let hmac = HMAC<SHA256>.authenticationCode(for: chunkData, using: sessionHMACKey)
request.setValue(hmac.hexString, forHTTPHeaderField: "X-Chunk-HMAC")
```

---

## 7. LAYER 5: ERASURE RESILIENCE ENGINE

### File: `Core/Upload/ErasureCodingEngine.swift`

**Adaptive Reed-Solomon + RaptorQ decision:**
```swift
func selectCoder(chunkCount: Int, lossRate: Double) -> ErasureCodingMode {
    if chunkCount <= 255 && lossRate < 0.08 {
        return .reedSolomon(.gf256)    // Fastest for small counts, low loss
    } else if chunkCount <= 255 && lossRate >= 0.08 {
        return .raptorQ                 // Rateless for high loss
    } else if chunkCount > 255 && lossRate < 0.03 {
        return .reedSolomon(.gf65536)  // Large counts, low loss
    } else {
        return .raptorQ                 // Large counts OR high loss
    }
}
```

**RS parameters:**
```
Loss rate < 1%  (WiFi):     RS(20, 22)  — 10% redundancy
Loss rate 1-5%  (4G):       RS(20, 24)  — 20% redundancy
Loss rate 5-8%  (weak):     RS(20, 28)  — 40% redundancy
Loss rate > 8%:             Switch to RaptorQ
```

**SIMD:** ARM NEON `vmull_p8` for GF polynomial multiplication.
**Systematic coding:** First k blocks = original data.

**Unequal Error Protection (UEP):**
```
Priority 0 (first/last frame + intrinsics): 3x redundancy
Priority 1 (key frames, quality > 0.9):     2.5x redundancy
Priority 2 (normal frames):                 1.5x redundancy
Priority 3 (low-quality frames):            1x redundancy
IMU data: same redundancy as its associated frame
```

**Conforms to `ErasureCoder` protocol:**
```swift
public protocol ErasureCoder: Sendable {
    func encode(data: [Data], redundancy: Double) -> [Data]
    func decode(blocks: [Data?], originalCount: Int) throws -> [Data]
}
```

### File: `Core/Upload/RaptorQEngine.swift`

**Full RFC 6330 implementation — first-class engine alongside RS.**

Why: Rateless — generates UNLIMITED repair symbols on-demand. O(K) encoding/decoding vs RS's O(K²).

**Algorithm:**
1. **Pre-coding (LDPC + HDPC):** Build K'×K' constraint matrix (sparse LDPC rows + dense HDPC rows + LT rows)
2. **Encoding:** Systematic — first K output = original data. Repair symbols via LT distribution (Robust Soliton)
3. **Decoding:** Gaussian elimination with inactivation decoding. Needs K + ε symbols (ε ≈ 2% overhead)

**Constraint matrix parameters (RFC 6330 Section 5.6):**
- S = ceil(0.01 * K) + X (LDPC rows, degree ~3)
- H = ceil(0.01 * K) + 1 (HDPC rows, dense GF(256))
- K' = K + S + H

**SparseMatrix over GF(256):** Compressed Sparse Row (CSR) format for efficiency.

---

## 8. LAYER 6: INTELLIGENT SCHEDULING ENGINE

### File: `Core/Upload/FusionScheduler.swift`

**5 parallel controllers (4 classical + ML):**

1. **MPC (Model Predictive Control):** Predict next 5 steps, minimize Σ(latency). Output: optimal chunk size sequence.
2. **ABR (Adaptive Bitrate):** Buffer-Based Approach variant. Queue length → chunk size mapping.
3. **EWMA:** α=0.3, compute "chunk size that transmits in 3 seconds at estimated speed".
4. **Kalman:** Use KalmanBandwidthPredictor output + trend. Falling → smaller, rising → larger.
5. **ML (when available):** Use MLBandwidthPredictor 5-step lookahead for chunk size.

**Fusion:**
```swift
let candidates = [mpcSize, abrSize, ewmaSize, kalmanSize, mlSize?].compactMap { $0 }
let weights = controllerAccuracies  // Updated per-chunk based on prediction error
let finalSize = weightedTrimmedMean(candidates, weights)  // Remove highest/lowest, weighted avg

// Lyapunov Drift-Plus-Penalty safety valve
if queueDriftPositive && drift > adaptiveThreshold {
    finalSize = min(finalSize, drainRateSize)
}

// Align to 16KB page boundary
finalSize = (finalSize / 16384) * 16384
```

**Controller accuracy tracking:** `weight_i = 1 / (1 + cumulative_error_i^2)`

**Thompson Sampling for CDN selection:**
- Reward = throughput / (latency × (1 + error_rate))
- First 20% chunks: explore. Last 80%: exploit.
- Cold start: use prior from previous session.

**Anti-fighting with TCP/QUIC congestion control:**
```swift
// PR9's FusionScheduler operates ABOVE transport CC.
// When transport uses BBRv3, PR9 MUST NOT fight it:
// 1. Chunk size decisions: schedule based on APPLICATION-layer throughput, not raw socket send
// 2. Parallelism: respect HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS from server
// 3. Backoff: if 3 consecutive chunks take >2x predicted time, reduce parallelism by 1
```

---

## 9. PR5+PR9 FUSION: CAPTURE-UPLOAD PIPELINE

### In ChunkedUploader.swift — Bridge to PR5CapturePipeline

**Quality gate → upload decision:**
```swift
// .accepted(quality > 0.9) → Priority 1 (HIGH), RS 2.5x redundancy
// .accepted(quality ≤ 0.9) → Priority 2 (NORMAL), RS 1.5x redundancy
// .rejected              → Priority 3 (LOW), RS 1x, upload deferred
// .pending               → wait for patch decision, then assign priority
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
- Trigger 1: ≥3 key frames + camera intrinsics + ≥1 IMU segment → start sparse SfM
- Trigger 2: ≥30% key frames → start MVS dense reconstruction
- Trigger 3: All frames + Merkle root verified → start fine refinement

**IMU data:** 200Hz, delta encoding + LZFSE compression, attached per chunk, `mach_absolute_time()` sync.

---

## 10. UNIFIED RESOURCE MANAGEMENT (NO THROTTLING)

### File: `Core/Upload/UnifiedResourceManager.swift`

**CORE PRINCIPLE: Upload speed is SACRED. We NEVER throttle.**

```swift
public actor UnifiedResourceManager {

    /// Upload budget: ALWAYS 100%. No exceptions.
    /// No thermal throttling. No battery throttling. No power throttling.
    /// User has charger and cooling. Our job: fastest possible upload.
    public func getUploadBudget() -> Double {
        return 1.0  // ALWAYS 100%
    }

    /// shouldPauseUpload: ALWAYS false.
    /// We NEVER pause upload for resource reasons.
    /// Memory pressure? Reduce buffers. Never pause.
    public func shouldPauseUpload() -> Bool {
        return false  // NEVER
    }

    /// Memory management: reduce buffers but keep uploading.
    /// Minimum 2 buffers always available.
    public func getMemoryStrategy() -> MemoryStrategy {
        let available = os_proc_available_memory()
        switch available {
        case 200_000_000...:    return .full(buffers: 12)
        case 100_000_000...:    return .reduced(buffers: 8)
        case 50_000_000...:     return .minimal(buffers: 4)
        default:                return .emergency(buffers: 2)  // NEVER below 2
        }
    }
}
```

**Conforms to `ResourceManager` protocol:**
```swift
public protocol ResourceManager: Sendable {
    func getThermalBudget() -> ThermalBudget      // Returns .unrestricted always
    func getMemoryAvailable() -> UInt64
    func getBatteryLevel() -> Double?              // Returns nil (we don't care)
    func shouldPauseUpload() -> Bool               // Returns false always
}
```

---

## 11. EXTREME PERFORMANCE OPTIMIZATIONS

### 11.1 HTTP/3 QUIC with 0-RTT Session Resumption
```swift
if #available(iOS 15.0, macOS 12.0, *) {
    config.assumesHTTP3Capable = true
}
// QUIC provides: multiplexed streams without head-of-line blocking,
// 0-RTT session resumption, built-in TLS 1.3, connection migration
```

### 11.2 12 Parallel Streams with Gradual Ramp-Up
```swift
// Start with 4 streams, add 1 every 10ms until 12
// Prevents thundering herd on server
for i in 0..<12 {
    if i >= 4 { try await Task.sleep(nanoseconds: 10_000_000) }  // 10ms
    launchUploadStream(i)
}
```

### 11.3 32MB Maximum Chunk Size
```swift
// Up from 16MB. At 200+ Mbps, 16MB chunks complete in <1s.
// 32MB allows fewer HTTP round-trips on ultrafast networks.
CHUNK_SIZE_MAX_BYTES = 32 * 1024 * 1024
```

### 11.4 Pipelined Hashing (CRC32C + SHA-256 in Single Pass)
```swift
// ARM hardware CRC32C: __crc32cd instruction (~20 GB/s)
// CryptoKit SHA-256: hardware-accelerated (~2.3 GB/s on M1)
// Both computed simultaneously on same 128KB buffer read
// Net throughput: limited by SHA-256 at ~2.3 GB/s (CRC32C is free)
```

### 11.5 Connection Prewarming at Capture UI Entry
```swift
// NOT at upload start — at CAPTURE UI entry
// By the time user finishes capturing, connection is fully warm:
// DNS resolved, TCP connected, TLS handshaked, HTTP/2 SETTINGS exchanged
// First chunk upload: 0ms connection overhead
```

### 11.6 Triple-Layer Watchdog
```swift
// Layer 1: Per-chunk dynamic timeout
// timeout = max(10s, 2.0 × (chunkSize / estimatedBps) + 5.0)
// Adapts to actual network speed

// Layer 2: Per-session (60s no progress → reconnect)
// If no bytes uploaded for 60s, tear down and rebuild connection

// Layer 3: Global (300s no ACK → full restart)
// If no chunk ACK for 300s, restart entire upload session from last checkpoint
```

### 11.7 Atomic Resume State Persistence
```swift
// Write + fsync + rename pattern — survives crashes and power loss
let tempPath = targetPath + ".tmp"
let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
write(fd, ptr.baseAddress!, ptr.count)
fsync(fd)  // Force to disk
close(fd)
rename(tempPath, targetPath)  // Atomic on POSIX
```

### 11.8 Network Transition Zero-Downtime Handoff
```swift
// When WiFi→Cellular transition detected:
// 1. Continue sending on old connection for 2s overlap
// 2. Establish new connection on new interface
// 3. Once new connection ACKs a chunk, drop old connection
// 4. Zero gap in upload — user sees no interruption
```

### 11.9 Decorrelated Jitter Retry
```swift
// base = 0.5s, cap = 15.0s, maxRetries = 7
// sleep = min(cap, random(base, previous_sleep * 3))
// Decorrelated jitter prevents thundering herd on server recovery
```

---

## 12. SECURITY HARDENING (115+ items)

### 12.1 Transport Security (S-01 to S-20, S-CDC-1 to S-CDC-3, S-RQ-1 to S-RQ-3, S-ML-1 to S-ML-3, S-QOD-1 to S-QOD-3, S-MP-1 to S-MP-3)

| ID | Item | Implementation |
|----|------|---------------|
| S-01 | Certificate pinning | PR9CertificatePinManager (independent of broken existing) |
| S-02 | TLS 1.3 ONLY | `URLSessionConfiguration` TLS settings, reject TLS 1.2 |
| S-07 | Chunk reordering protection | Commitment Chain |
| S-08 | Chunk replacement protection | Per-chunk SHA-256 + Merkle proof |
| S-09 | Chunk deletion protection | `expected_total_chunks` commitment at session start |
| S-10 | Server forgery protection | Byzantine verification |
| S-12 | DNS hijack protection | Pre-resolve + cache + compare with previous |
| S-13 | HTTP/2 SETTINGS validation | Reject MAX_CONCURRENT_STREAMS < 2, INITIAL_WINDOW_SIZE < 65535 |
| S-14 | Request smuggling prevention | Always Content-Length, never chunked TE |
| S-15 | Connection coalescing guard | Same-origin only |
| S-16 | TLS session ticket rotation | Force new ticket every 3600s |
| S-17 | ALPN negotiation verification | Verify "h2", warn on HTTP/1.1 downgrade |
| S-18 | SNI leak prevention | Match SNI to expected hostname |
| S-19 | Certificate Transparency | Verify SCTs from ≥2 independent CT logs |
| S-20 | OCSP stapling | Prefer stapled, 5s timeout on check, soft-fail |
| S-CDC-1 | Gear table integrity | Verify checksum at startup, fallback to fixed-size |
| S-CDC-2 | Dedup oracle prevention | Server checks dedup only within same user's data |
| S-CDC-3 | CDC boundary DoS | minChunkSize floor prevents pathologically small chunks |
| S-RQ-1 | Symbol padding | Zero-padded to symbol size, length stored in metadata |
| S-RQ-2 | Repair symbol limit | Cap at 2× source symbols |
| S-RQ-3 | Matrix determinism | Seeded PRNG for reproducible constraint matrix |
| S-ML-1 | Model integrity | Hash verified against embedded expected hash |
| S-ML-2 | Input sanitization | All inputs clamped to valid ranges |
| S-ML-3 | No data exfiltration | Measurements never leave device |
| S-QOD-1 | OAuth2 secrets | Keychain only, never UserDefaults |
| S-QOD-2 | Token refresh timing | 60s before expiry |
| S-QOD-3 | Session cleanup | Always release on complete/cancel/crash |
| S-MP-1 | Per-path TLS | Each path has own TLS session |
| S-MP-2 | Path verification | Independent cert check per interface |
| S-MP-3 | Data consistency | All paths → same server endpoint (session ID check) |

### 12.2 Data Security (D-01 to D-15)

| ID | Item | Implementation |
|----|------|---------------|
| D-01 | Encryption key storage | Keychain (Apple), file 0600 (Linux) |
| D-02 | Sensitive buffers | `mlock()` + `memset_s()` before dealloc |
| D-04 | Log truncation | All hashes/sessionIds truncated to first 8 chars |
| D-06 | Key derivation | HKDF-SHA256 from master key for per-session keys |
| D-08 | Resume encryption | AES-GCM + HMAC in EnhancedResumeManager |
| D-09 | Chunk buffer zeroing | `memset_s()` after each chunk uploaded + ACKed |
| D-10 | Ephemeral URLSession | `.ephemeral` config — no disk cache of chunks |
| D-11 | Temp file cleanup | Zero before delete on complete/cancel/terminate/crash |
| D-12 | mmap access pattern | MADV_SEQUENTIAL then MADV_DONTNEED after read |
| D-13 | Auto-zeroing | Class wrapper with deinit for crypto material |
| D-14 | Keychain ACL | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| D-15 | Binary path sanitization | Never log raw data, use `"<N bytes>"` |

### 12.3 Integrity Security (I-01 to I-14)

| ID | Item | Implementation |
|----|------|---------------|
| I-01 | TOCTOU double-check | `flock()` + `fstat()` post-open |
| I-02 | Merkle domain separation | Leaf: 0x00 + chunkIndex. Internal: 0x01 + level |
| I-06 | Truncation protection | total_chunks commitment + final Merkle root |
| I-07 | Splicing protection | sessionId bound to Commitment Chain genesis |
| I-08 | Index overflow check | Validate chunkIndex fits UInt32 |
| I-09 | Total chunk commitment | Server rejects if received ≠ expected |
| I-10 | Merkle root binding | CompleteUploadRequest includes client Merkle root |
| I-11 | Timestamp monotonicity | Each chunk timestamp > previous |
| I-12 | Double-hash for dedup | PoP proves DATA possession, not just hash |
| I-13 | Session binding | sessionId in every HTTP header |
| I-14 | Nonce freshness | UUID v7, server rejects >15s old |

### 12.4 Availability (A-10 to A-16)

| ID | Item | Implementation |
|----|------|---------------|
| A-10 | Circuit breaker | 5 failures→open, 30s half-open, 2 success→close |
| A-11 | Graceful degradation | 5 levels: normal→minimal features→single chunk→pause |
| A-12 | Triple watchdog | Per-chunk/session(60s)/global(300s) |
| A-13 | Upload deadline | Optional, compress/reduce quality if behind |
| A-14 | DNS failover | System→DoH Cloudflare→DoH Google→hardcoded IP |
| A-15 | Chunk retry budget | max_total_retries = chunk_count × 2 |
| A-16 | Background upload | iOS: transfer to URLSession background session |

### 12.5 Privacy (P-04 to P-15)

| ID | Item | Implementation |
|----|------|---------------|
| P-04 | File name privacy | Hash-based identifier in API calls |
| P-08 | No URL cache | `.ephemeral` URLSession |
| P-10 | Telemetry DP | Differential privacy ε=1.0 |
| P-11 | Metadata stripping | Strip EXIF/XMP GPS, camera serial before upload |
| P-12 | Telemetry anonymization | k-anonymity (k≥5), device model generalized |
| P-13 | Server log redaction | X-Privacy-Level header (strict/standard/permissive) |
| P-14 | Right to deletion | `deleteAllUploadData()` — Keychain, UserDefaults, temp files, server sessions |
| P-15 | Consent-based telemetry | Default OFF, respect Low Power Mode |

### 12.6 Replay Protection

- LRU nonce eviction (remove oldest 20% at 8000, NOT removeAll)
- Nonce window: 120s
- Each chunk carries monotonic counter in header
- UUID v7 nonces (time-ordered, 15s expiry)

### 12.7 Per-Chunk HMAC-SHA256
```swift
// Every chunk gets HMAC-SHA256 alongside SHA-256
let hmac = HMAC<SHA256>.authenticationCode(for: chunkData, using: sessionHMACKey)
request.setValue(Data(hmac).base64EncodedString(), forHTTPHeaderField: "X-Chunk-HMAC")
```

### 12.8 Automatic Buffer Zeroing
```swift
// After chunk upload + ACK:
memset_s(buffer.baseAddress!, buffer.count, 0, buffer.count)
// memset_s cannot be optimized away by compiler (unlike memset)
```

---

## 13. CONSTANTS (ALL FINAL VALUES)

### Modify `Core/Constants/UploadConstants.swift`:

```swift
// =========================================================================
// MARK: - CHUNK SIZES (FINAL)
// =========================================================================

public static let CHUNK_SIZE_MIN_BYTES: Int = 256 * 1024          // 256KB
public static let CHUNK_SIZE_DEFAULT_BYTES: Int = 2 * 1024 * 1024  // 2MB
public static let CHUNK_SIZE_MAX_BYTES: Int = 32 * 1024 * 1024    // 32MB (v2.4: up from 16MB)
public static let CHUNK_SIZE_STEP_BYTES: Int = 512 * 1024          // 512KB

// =========================================================================
// MARK: - NETWORK SPEED THRESHOLDS (FINAL)
// =========================================================================

public static let NETWORK_SPEED_SLOW_MBPS: Double = 3.0           // SI Mbps (not Mibps!)
public static let NETWORK_SPEED_NORMAL_MBPS: Double = 30.0
public static let NETWORK_SPEED_FAST_MBPS: Double = 100.0
public static let NETWORK_SPEED_ULTRAFAST_MBPS: Double = 200.0    // 5.5G threshold
public static let NETWORK_SPEED_MIN_SAMPLES: Int = 5              // Kalman needs ≥5
public static let NETWORK_SPEED_WINDOW_SECONDS: TimeInterval = 60.0  // Full 5G oscillation cycle
public static let NETWORK_SPEED_MAX_SAMPLES: Int = 30

// =========================================================================
// MARK: - PARALLELISM (FINAL)
// =========================================================================

public static let MAX_PARALLEL_CHUNK_UPLOADS: Int = 12            // v2.4: 12 streams
public static let PARALLEL_RAMP_UP_DELAY_MS: Int = 10             // v2.4: 10ms between streams
public static let PARALLELISM_ADJUST_INTERVAL: TimeInterval = 3.0

// =========================================================================
// MARK: - SESSION (FINAL)
// =========================================================================

public static let SESSION_MAX_AGE_SECONDS: TimeInterval = 172800  // 48h for next-day resume
public static let SESSION_CLEANUP_INTERVAL: TimeInterval = 1800   // 30min
public static let SESSION_MAX_CONCURRENT: Int = 3                 // 3 × 12 = 36 connections max

// =========================================================================
// MARK: - TIMEOUTS (FINAL)
// =========================================================================

public static let CHUNK_TIMEOUT_SECONDS: TimeInterval = 45.0
public static let CONNECTION_TIMEOUT_SECONDS: TimeInterval = 8.0
public static let STALL_DETECTION_TIMEOUT: TimeInterval = 10.0
public static let STALL_MIN_PROGRESS_RATE_BPS: Int = 4096        // 4KB/s minimum

// =========================================================================
// MARK: - RETRY (FINAL)
// =========================================================================

public static let CHUNK_MAX_RETRIES: Int = 7                     // v2.4: up from 5
public static let RETRY_BASE_DELAY_SECONDS: TimeInterval = 0.5   // v2.4: 0.5s
public static let RETRY_MAX_DELAY_SECONDS: TimeInterval = 15.0   // v2.4: 15s
public static let RETRY_JITTER_FACTOR: Double = 1.0              // Full jitter

// =========================================================================
// MARK: - PROGRESS (FINAL)
// =========================================================================

public static let PROGRESS_THROTTLE_INTERVAL: TimeInterval = 0.05  // 20fps (60Hz+120Hz)
public static let PROGRESS_MIN_BYTES_DELTA: Int = 32 * 1024        // 32KB
public static let PROGRESS_SMOOTHING_FACTOR: Double = 0.2
public static let MIN_PROGRESS_INCREMENT_PERCENT: Double = 1.0

// =========================================================================
// MARK: - FILE VALIDATION (FINAL)
// =========================================================================

public static let MAX_FILE_SIZE_BYTES: Int64 = 50 * 1024 * 1024 * 1024  // 50GB
public static let MIN_CHUNKED_UPLOAD_SIZE_BYTES: Int64 = 2 * 1024 * 1024  // 2MB

// =========================================================================
// MARK: - IDEMPOTENCY (FINAL)
// =========================================================================

public static let IDEMPOTENCY_KEY_MAX_AGE: TimeInterval = 172800  // Match session max age

// =========================================================================
// MARK: - KALMAN FILTER (FINAL)
// =========================================================================

public static let KALMAN_PROCESS_NOISE_BASE: Double = 0.01
public static let KALMAN_MEASUREMENT_NOISE_FLOOR: Double = 0.001
public static let KALMAN_ANOMALY_THRESHOLD_SIGMA: Double = 2.5
public static let KALMAN_CONVERGENCE_THRESHOLD: Double = 5.0
public static let KALMAN_DYNAMIC_R_SAMPLE_COUNT: Int = 10

// =========================================================================
// MARK: - MERKLE TREE (FINAL)
// =========================================================================

public static let MERKLE_SUBTREE_CHECKPOINT_INTERVAL: Int = 16
public static let MERKLE_MAX_TREE_DEPTH: Int = 24
public static let MERKLE_LEAF_PREFIX: UInt8 = 0x00
public static let MERKLE_NODE_PREFIX: UInt8 = 0x01

// =========================================================================
// MARK: - COMMITMENT CHAIN (FINAL)
// =========================================================================

public static let COMMITMENT_CHAIN_DOMAIN: String = "CCv1\0"
public static let COMMITMENT_CHAIN_JUMP_DOMAIN: String = "CCv1_JUMP\0"
public static let COMMITMENT_CHAIN_GENESIS_PREFIX: String = "Aether3D_CC_GENESIS_"

// =========================================================================
// MARK: - BYZANTINE VERIFICATION (FINAL)
// =========================================================================

public static let BYZANTINE_VERIFY_DELAY_MS: Int = 100
public static let BYZANTINE_VERIFY_TIMEOUT_MS: Int = 500
public static let BYZANTINE_MAX_FAILURES: Int = 3
public static let BYZANTINE_COVERAGE_TARGET: Double = 0.999

// =========================================================================
// MARK: - CIRCUIT BREAKER (FINAL)
// =========================================================================

public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD: Int = 5
public static let CIRCUIT_BREAKER_HALF_OPEN_INTERVAL: TimeInterval = 30.0
public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD: Int = 2
public static let CIRCUIT_BREAKER_WINDOW_SECONDS: TimeInterval = 60.0

// =========================================================================
// MARK: - ERASURE CODING (FINAL)
// =========================================================================

public static let ERASURE_RS_DATA_SYMBOLS: Int = 20
public static let ERASURE_RAPTORQ_FALLBACK_LOSS_RATE: Double = 0.08
public static let ERASURE_MAX_OVERHEAD_PERCENT: Double = 50.0

// =========================================================================
// MARK: - CDC (FINAL)
// =========================================================================

public static let CDC_MIN_CHUNK_SIZE: Int = 256 * 1024              // 256KB
public static let CDC_MAX_CHUNK_SIZE: Int = 8 * 1024 * 1024         // 8MB
public static let CDC_AVG_CHUNK_SIZE: Int = 1 * 1024 * 1024         // 1MB
public static let CDC_GEAR_TABLE_VERSION: String = "v1"
public static let CDC_NORMALIZATION_LEVEL: Int = 1
public static let CDC_DEDUP_MIN_SAVINGS_RATIO: Double = 0.20
public static let CDC_DEDUP_QUERY_TIMEOUT: TimeInterval = 5.0

// =========================================================================
// MARK: - RAPTORQ (FINAL)
// =========================================================================

public static let RAPTORQ_OVERHEAD_TARGET: Double = 0.02
public static let RAPTORQ_MAX_REPAIR_RATIO: Double = 2.0
public static let RAPTORQ_SYMBOL_ALIGNMENT: Int = 64
public static let RAPTORQ_LDPC_DENSITY: Double = 0.01
public static let RAPTORQ_INACTIVATION_THRESHOLD: Double = 0.10
public static let RAPTORQ_CHUNK_COUNT_THRESHOLD: Int = 256

// =========================================================================
// MARK: - ML PREDICTOR (FINAL)
// =========================================================================

public static let ML_PREDICTION_HISTORY_LENGTH: Int = 30
public static let ML_MODEL_FILENAME: String = "AetherBandwidthLSTM"
public static let ML_WARMUP_SAMPLES: Int = 10
public static let ML_ENSEMBLE_WEIGHT_MIN: Double = 0.3
public static let ML_ENSEMBLE_WEIGHT_MAX: Double = 0.7
public static let ML_INFERENCE_TIMEOUT_MS: Int = 5
public static let ML_ACCURACY_WINDOW: Int = 10
public static let ML_MODEL_MAX_SIZE_BYTES: Int = 5 * 1024 * 1024    // 5MB

// =========================================================================
// MARK: - CAMARA QoD (FINAL)
// =========================================================================

public static let QOD_DEFAULT_DURATION: TimeInterval = 3600
public static let QOD_SESSION_CREATION_TIMEOUT: TimeInterval = 10.0
public static let QOD_TOKEN_REFRESH_MARGIN: TimeInterval = 60
public static let QOD_MIN_FILE_SIZE: Int64 = 100 * 1024 * 1024      // 100MB

// =========================================================================
// MARK: - MULTIPATH (FINAL)
// =========================================================================

public static let MULTIPATH_EWMA_ALPHA: Double = 0.3
public static let MULTIPATH_MEASUREMENT_WINDOW: TimeInterval = 30.0
public static let MULTIPATH_MAX_PARALLEL_PER_PATH: Int = 4
public static let MULTIPATH_EXPECTED_THROUGHPUT_GAIN: Double = 1.7

// =========================================================================
// MARK: - PERFORMANCE (FINAL — v2.4)
// =========================================================================

public static let MMAP_WINDOW_SIZE_MACOS: Int = 64 * 1024 * 1024    // 64MB
public static let MMAP_WINDOW_SIZE_IOS: Int = 32 * 1024 * 1024      // 32MB
public static let PREFETCH_PIPELINE_DEPTH: Int = 3                    // Read N+2 while uploading N
public static let LZFSE_COMPRESSION_THRESHOLD: Double = 0.10          // 10% min savings
public static let PARALLEL_STREAM_RAMP_DELAY_NS: UInt64 = 10_000_000 // 10ms
public static let BUFFER_POOL_MAX_BUFFERS: Int = 12
public static let BUFFER_POOL_MIN_BUFFERS: Int = 2                    // NEVER below 2

// =========================================================================
// MARK: - WATCHDOG (FINAL — v2.4)
// =========================================================================

public static let WATCHDOG_SESSION_TIMEOUT: TimeInterval = 60.0      // Per-session
public static let WATCHDOG_GLOBAL_TIMEOUT: TimeInterval = 300.0      // Global no-ACK
public static let WATCHDOG_CHUNK_TIMEOUT_MULTIPLIER: Double = 2.0    // Dynamic per-chunk
public static let WATCHDOG_CHUNK_TIMEOUT_PADDING: TimeInterval = 5.0

// =========================================================================
// MARK: - NETWORK TRANSITION (FINAL — v2.4)
// =========================================================================

public static let NETWORK_TRANSITION_OVERLAP_SECONDS: TimeInterval = 2.0
public static let NETWORK_TRANSITION_HANDOFF_TIMEOUT: TimeInterval = 5.0
```

---

## 14. FEATURE FLAGS

```swift
public enum PR9FeatureFlags {
    // Core features (ON by default)
    public static var enableChunkedUpload: Bool = true
    public static var enableStreamingMerkle: Bool = true
    public static var enableCommitmentChain: Bool = true
    public static var enableByzantineVerification: Bool = true
    public static var enableKalmanPredictor: Bool = true
    public static var enableFusionScheduler: Bool = true
    public static var enableErasureCoding: Bool = true
    public static var enableRaptorQ: Bool = true                    // Transparent improvement
    public static var enableMLPredictor: Bool = true                // Kalman fallback on Linux
    public static var enableMultipath: Bool = true                  // .aggregate default
    public static var enableZeroCopyIO: Bool = true                 // mmap + F_NOCACHE
    public static var enableConnectionPrewarming: Bool = true
    public static var enablePrefetchPipeline: Bool = true
    public static var enableLZFSECompression: Bool = true
    public static var enableBufferPool: Bool = true
    public static var enablePerChunkHMAC: Bool = true

    // Optional features (OFF by default — need server/config support)
    public static var enableCDC: Bool = false                       // Requires server CDC support
    public static var enableCDCDedup: Bool = false                  // Requires enableCDC + server dedup
    public static var enableCAMARAQoD: Bool = false                 // Requires operator credentials
    public static var enableProofOfPossession: Bool = false         // Requires server PoP endpoint

    // Multipath strategy override (nil = auto-detect → .aggregate)
    public static var multipathStrategyOverride: MultipathUploadManager.MultipathStrategy? = nil
}
```

---

## 15. WIRE PROTOCOL

```swift
public enum PR9WireProtocol {
    public static let version = "PR9/2.1"
    public static let capabilities: Set<String> = [
        "chunked-upload", "merkle-verification", "commitment-chain",
        "proof-of-possession", "erasure-coding", "multi-layer-progress",
        "byzantine-verification", "content-defined-chunking", "cdc-deduplication",
        "raptorq-fountain", "ml-bandwidth-prediction", "camara-qod",
        "multipath-upload", "http3-quic", "per-chunk-hmac", "zero-copy-io",
        "lzfse-compression", "connection-prewarming"
    ]
}
```

---

## 16. INTEGRATION POINTS WITH EXISTING CODE

### 16.1 ChunkedUploader ↔ PipelineRunner
```swift
// OLD: let assetId = try await remoteClient.upload(videoURL: videoURL)
// NEW: let uploader = ChunkedUploader(fileURL: videoURL, apiClient: apiClient, ...)
//      let assetId = try await uploader.upload()
// Do NOT modify PipelineRunner.swift — ChunkedUploader conforms to same interface.
```

### 16.2 ChunkedUploader ↔ UploadSession
Compose, don't inherit. ChunkedUploader creates and manages UploadSession instances.

### 16.3 ChunkedUploader ↔ APIContract
Use existing: `CreateUploadRequest`, `UploadChunkResponse`, `GetChunksResponse`, `CompleteUploadRequest`.

### 16.4 ChunkedUploader ↔ ImmutableBundle
StreamingMerkleTree produces root hash compatible with ImmutableBundle's MerkleTree.

### 16.5 ChunkedUploader ↔ PR5CapturePipeline
Observe via delegate or AsyncStream. **Do NOT modify PR5CapturePipeline.swift.**

### 16.6 RecordingController.pollFileSize → Chunk Trigger
When file grows by ≥ chunkSize, trigger chunk read + upload. **Do NOT modify RecordingController.swift.**

---

## 17. TESTING REQUIREMENTS

**Test conventions:**
- `@MainActor` + `async setUp/tearDown` is BROKEN on Linux (xctest #504). Use synchronous setUp or `--skip` on Linux.
- Use `--disable-swift-testing` flag if mixing XCTest with Swift Testing.
- All tests must pass on macOS. Linux tests may skip PR5-dependent and CoreML tests.

**Grand Total: 27 test files, 3,000+ assertions**

See Section 2.2 for complete test file list with per-file assertion counts.

---

## 18. DEPENDENCY GRAPH AND BUILD ORDER

```
Phase 1 (no dependencies — parallel):
  HybridIOEngine.swift           ← Pure Foundation I/O
  ChunkBufferPool.swift          ← Pure Foundation memory
  NetworkPathObserver.swift       ← NWPathMonitor / polling
  PR9CertificatePinManager.swift ← Independent cert manager

Phase 2 (depends on Phase 1):
  KalmanBandwidthPredictor.swift ← NetworkPathObserver
  ConnectionPrewarmer.swift      ← NetworkPathObserver
  ChunkIntegrityValidator.swift  ← Pure Foundation

Phase 3 (depends on Phase 2):
  StreamingMerkleTree.swift      ← Pure Foundation crypto
  ChunkCommitmentChain.swift     ← Pure Foundation crypto
  UploadCircuitBreaker.swift     ← Pure Foundation
  CIDMapper.swift                ← Pure Foundation

Phase 4 (depends on Phase 3):
  ErasureCodingEngine.swift      ← GaloisField256
  ByzantineVerifier.swift        ← StreamingMerkleTree
  ProofOfPossession.swift        ← CIDMapper

Phase 5 (depends on Phase 2):
  ContentDefinedChunker.swift    ← HybridIOEngine
  RaptorQEngine.swift            ← GaloisField256 (from ErasureCodingEngine)
  CAMARAQoDClient.swift          ← (standalone)

Phase 6 (depends on Phase 5):
  MLBandwidthPredictor.swift     ← KalmanBandwidthPredictor
  MultipathUploadManager.swift   ← NetworkPathObserver
  FusionScheduler.swift          ← KalmanBandwidthPredictor + MLBandwidthPredictor

Phase 7 (depends on ALL above):
  UnifiedResourceManager.swift   ← (standalone, but uses constants)
  MultiLayerProgressTracker.swift ← StreamingMerkleTree
  ChunkIdempotencyManager.swift  ← IdempotencyHandler
  EnhancedResumeManager.swift    ← Keychain + crypto
  UploadTelemetry.swift          ← HMAC + all layers

Phase 8 (LAST — depends on everything):
  ChunkedUploader.swift          ← ALL 25 other files

Phase 9 (constants):
  UploadConstants.swift          ← All values from Section 13

Phase 10 (tests — after all impl):
  All 27 test files
  Run: swift test --disable-swift-testing
  Target: 3,000+ assertions passing
  Verify: swift build -Xswiftc -strict-concurrency=complete — 0 warnings
```

---

## 19. ACCEPTANCE CRITERIA

### Must Have (PR9 merge blockers)
- [ ] `ChunkedUploader` can upload a 100MB file with parallel 12-stream upload
- [ ] Resume works after simulated network disconnect (3-level verification)
- [ ] Progress reports are monotonically non-decreasing
- [ ] CRC32C + SHA-256 computed in single file pass (zero-copy where possible)
- [ ] Streaming Merkle tree produces same root as ImmutableBundle's MerkleTree
- [ ] Commitment Chain detects chunk reordering
- [ ] Per-chunk HMAC-SHA256 tamper detection
- [ ] All constants updated per Section 13
- [ ] All 26 implementation files created per Section 2
- [ ] All 27 test files pass on macOS
- [ ] `swift build` succeeds on macOS and Linux
- [ ] Upload budget always returns 100% (no throttling)
- [ ] Connection prewarming starts at capture UI entry
- [ ] Atomic resume persistence (write+fsync+rename)

### Should Have (PR9 v3.0 complete)
- [ ] Kalman filter converges within 5 samples on stable network
- [ ] Byzantine verification catches simulated corrupt chunk (Fisher-Yates sampling)
- [ ] Reed-Solomon recovers from simulated 2-chunk loss in RS(20,24)
- [ ] RaptorQ encodes/decodes correctly for K=100 with 2% overhead
- [ ] Proof-of-Possession protocol completes < 50ms for 100MB file
- [ ] 4-layer progress divergence triggers safety valve
- [ ] Connection prewarmer reduces first-chunk latency vs cold start
- [ ] 12 parallel streams ramp up correctly (4 initial + 1 per 10ms)
- [ ] CDC produces identical boundaries for identical data across platforms
- [ ] ML+Kalman ensemble weight clamped to [0.3, 0.7]
- [ ] Triple watchdog detects stalled uploads (per-chunk/session/global)
- [ ] Buffer pool maintains min 2 buffers under memory pressure
- [ ] `swift build -Xswiftc -strict-concurrency=complete` — 0 warnings

### Nice to Have (future)
- [ ] Thompson Sampling CDN selection
- [ ] Full ECDH-encrypted PoP channel
- [ ] ACI ↔ CID v1 bidirectional mapping with Multicodec registration
- [ ] CoreML on-device LSTM fine-tuning
- [ ] CAMARA QoD live carrier integration

---

## FINAL NOTES

1. **Read existing code FIRST.** Every file listed in Section 1.2 must be read before writing any code.
2. **Do NOT modify existing files** except `UploadConstants.swift` (Section 13 changes only).
3. **Compose, don't inherit.** Wrap existing classes (UploadSession, ChunkManager) rather than subclassing.
4. **All new types must be `Sendable`** (value types) or `actor`/`final class` with queue synchronization.
5. **Test on macOS first.** Linux compatibility is secondary.
6. **No external dependencies.** Pure Foundation + CryptoKit/swift-crypto only.
7. **Every public API gets a `///` doc comment** with invariant documentation.
8. **Upload speed is SACRED.** Never throttle for battery/thermal/power.
9. **All security is fail-closed.** No platform-conditional `return true`.
10. **All key material as `SymmetricKey`.** Never raw bytes or hex strings in logs.
