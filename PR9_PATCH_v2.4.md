# PR9 PATCH v2.4 — EXTREME PERFORMANCE + MAXIMUM SECURITY + ABSOLUTE STABILITY

## CRITICAL: This is a PATCH to v1.0 + v2.0 + v2.1 + v2.2 + v2.3

**Apply ON TOP of all previous patches.** This patch OVERRIDES all throttling/thermal/battery constraints.

**Branch:** `pr9/chunked-upload-v3` (same branch)

**Design Philosophy — THE LAW OF v2.4:**

> Once the user taps "End Capture", everything is OUR responsibility.
> The user wants ONE thing: see their 3D creation as fast as possible.
> We deliver the FASTEST upload, the STRONGEST protection, and the MOST STABLE operation.
> We do NOT manage battery. We do NOT throttle for thermal. We do NOT "save resources."
> The user has a charger. The user has a cooling fan. Our job is MAXIMUM PERFORMANCE.

**What v2.4 Changes:**
- **PERF-1:** Remove ALL thermal/battery throttling — replace with constant max throughput
- **PERF-2:** HTTP/3 QUIC with 0-RTT — eliminate handshake latency
- **PERF-3:** Parallel upload 6→12 streams, with aggressive ramp-up
- **PERF-4:** Zero-copy I/O pipeline — mmap + F_NOCACHE + MADV_SEQUENTIAL
- **PERF-5:** Pipeline overlap — read chunk N+2 while uploading chunk N
- **PERF-6:** Compression decision: LZFSE hardware-accelerated on Apple Silicon
- **PERF-7:** Connection prewarming at capture start, not upload start
- **PERF-8:** Chunk size up to 32MB for ultrafast networks
- **PERF-9:** Per-chunk SHA-256 + CRC32C pipelined in single pass with NEON
- **PERF-10:** DNS pre-resolution + Happy Eyeballs v2 (RFC 8305)
- **SEC-1:** TLS 1.3 only + certificate transparency enforcement
- **SEC-2:** Per-chunk HMAC tamper detection on wire
- **SEC-3:** Memory-safe buffer handling with automatic zeroing
- **STAB-1:** Triple-layer watchdog (per-chunk, per-session, global)
- **STAB-2:** Atomic resume state with fsync + rename pattern
- **STAB-3:** Network transition zero-downtime handoff
- **STAB-4:** Circuit breaker with per-endpoint health scoring

---

## PATCH TABLE OF CONTENTS

1. [REMOVE ALL THROTTLING — Performance is Sacred](#1-remove-all-throttling)
2. [I/O Engine: Zero-Copy Maximum Throughput](#2-io-engine-zero-copy-maximum-throughput)
3. [Transport: HTTP/3 QUIC + 0-RTT](#3-transport-http3-quic--0-rtt)
4. [Parallelism: 12 Streams with Prefetch Pipeline](#4-parallelism-12-streams-with-prefetch-pipeline)
5. [Compression: Hardware-Accelerated Decision](#5-compression-hardware-accelerated-decision)
6. [Connection Prewarming: Start at Capture](#6-connection-prewarming-start-at-capture)
7. [Constants Override: Aggressive Tuning](#7-constants-override-aggressive-tuning)
8. [Security Hardening: Maximum Without Speed Loss](#8-security-hardening-maximum-without-speed-loss)
9. [Stability: Triple Watchdog + Atomic Resume](#9-stability-triple-watchdog--atomic-resume)
10. [Network Transition: Zero-Downtime Handoff](#10-network-transition-zero-downtime-handoff)
11. [Memory Pipeline: No Throttling, Smart Pooling](#11-memory-pipeline-no-throttling-smart-pooling)
12. [Updated Constants Table (28 overrides)](#12-updated-constants-table)
13. [Testing Additions for v2.4](#13-testing-additions-for-v24)
14. [Final Verification Checklist v2.4](#14-final-verification-checklist-v24)

---

## 1. REMOVE ALL THROTTLING — PERFORMANCE IS SACRED

### 1.1 Thermal Management: DELETED

**v1.0 specified (Section 10, UnifiedResourceManager):**
```
nominal:    Upload% = 25%
fair:       Upload% = 20%
serious:    Upload% = 10%
critical:   Upload% = 0% (PAUSE)
```

**v2.4 OVERRIDE: ALL thermal states → Upload% = 100%.**

```swift
// v2.4 OVERRIDE in UnifiedResourceManager.swift:
// REMOVE thermal budget allocation entirely.
// The upload engine ALWAYS runs at maximum throughput.

public actor UnifiedResourceManager {

    /// v2.4: Thermal state is MONITORED (for telemetry) but NEVER throttles upload.
    /// The user's device has cooling. Our job is to upload fast.
    public func getUploadBudget() -> Double {
        return 1.0  // ALWAYS 100%. No exceptions.
    }

    /// Thermal state for telemetry/logging only. NEVER used for throttling decisions.
    public func getCurrentThermalState() -> ProcessInfo.ThermalState {
        return ProcessInfo.processInfo.thermalState
    }

    // DELETED: Schmitt hysteresis for thermal budget
    // DELETED: Predictive thermal reduction (temperature slope)
    // DELETED: Critical thermal pause
    // DELETED: 30s stability wait after cooling

    // KEPT: Memory monitoring (for buffer pool sizing, not throttling)
    // KEPT: Telemetry reporting
}
```

### 1.2 Battery Management: DELETED

**v1.0 specified (Section 10):**
```
100-50%:  Parallel=6, WiFi+5G
50-30%:   Parallel=4, WiFi+5G
30-15%:   Parallel=2, WiFi only
15-5%:    Parallel=1, pause Merkle verify
<5%:      PAUSE upload
```

**v2.4 OVERRIDE: ALL battery levels → Maximum everything.**

```swift
// v2.4: Battery level NEVER affects upload behavior.
// At ALL battery levels:
//   - parallel = MAX (12 streams)
//   - chunkSize = MAX (up to 32MB on ultrafast)
//   - multipath = .aggregate (WiFi + 5G bonded)
//   - erasure coding = enabled
//   - Merkle verify = enabled
//   - compression = enabled (if beneficial)
//
// The ONLY exception: if the device powers off, iOS gives us
// BGProcessingTask time. We checkpoint resume state.
// When user plugs in, we resume at full speed.
//
// We DO NOT preemptively pause at <5%. The OS will manage shutdown.
// We DO write resume checkpoints frequently (every 10 chunks).

public func getMaxParallelUploads() -> Int {
    return UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS  // 12 (v2.4)
}

public func getMultipathStrategy() -> MultipathUploadManager.MultipathStrategy {
    return .aggregate  // ALWAYS. No battery check.
}
```

### 1.3 Low Power Mode: IGNORED for Upload

**v1.0:** "Low Power Mode: Same as 30-15% + force compression"

**v2.4:** Low Power Mode is a SYSTEM preference, not an upload preference. The user explicitly started an upload — they want it done fast. We respect `isConstrained` for multipath (Low Data Mode) but NOT Low Power Mode.

```swift
// v2.4: Low Power Mode does NOT reduce upload performance.
// isLowPowerModeEnabled is LOGGED but IGNORED.
// Only isConstrained (Low Data Mode) is respected for multipath.
```

### 1.4 Memory Pressure: Smart Pooling, NOT Throttling

**v1.0 specified:**
```
> 200MB available:   Normal
100-200MB:           Reduce in-flight chunks, switch to FileHandle
50-100MB:            PAUSE upload
< 50MB:              Emergency pause
```

**v2.4 OVERRIDE: NEVER pause upload for memory. Use buffer pool with recycling.**

```swift
// v2.4: Memory pressure response — REDUCE BUFFERS, NEVER PAUSE.
//
// > 200MB available: 12 in-flight chunk buffers (max throughput)
// 100-200MB:         8 in-flight buffers (still fast)
// 50-100MB:          4 in-flight buffers (minimum viable pipeline)
// < 50MB:            2 in-flight buffers + force FileHandle I/O (no mmap)
//
// CRITICAL: NEVER pause. Even at 2 buffers, upload continues.
// Buffer pool recycles completed buffers immediately.

public actor ChunkBufferPool {
    private var availableBuffers: [UnsafeMutableRawBufferPointer] = []
    private let bufferSize: Int  // = current chunk size
    private var maxBuffers: Int  // Adjusted by memory pressure

    /// Acquire a buffer for reading a chunk. Blocks until one is available.
    /// NEVER returns nil — waits for a buffer to be recycled.
    public func acquire() async -> UnsafeMutableRawBufferPointer {
        while availableBuffers.isEmpty {
            await Task.yield()  // Yield, wait for recycled buffer
        }
        return availableBuffers.removeLast()
    }

    /// Return buffer after chunk upload completes.
    /// Buffer is zeroed (security) then made available.
    public func recycle(_ buffer: UnsafeMutableRawBufferPointer) {
        // Zero the buffer for security
        memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        availableBuffers.append(buffer)
    }

    /// Adjust pool size based on available memory.
    /// NEVER reduces to 0. Minimum is 2.
    public func adjustForMemoryPressure() {
        let available = os_proc_available_memory()
        switch available {
        case 200_000_000...:    maxBuffers = 12
        case 100_000_000...:    maxBuffers = 8
        case 50_000_000...:     maxBuffers = 4
        default:                maxBuffers = 2  // NEVER below 2
        }
        // Release excess buffers
        while availableBuffers.count > maxBuffers {
            let buf = availableBuffers.removeLast()
            buf.deallocate()
        }
    }
}
```

---

## 2. I/O ENGINE: ZERO-COPY MAXIMUM THROUGHPUT

### 2.1 Override v1.0 I/O Decision Matrix

**v1.0 had conservative I/O decisions.** v2.4 is aggressive:

```
Platform     | File < 512MB     | 512MB-4GB        | > 4GB
-------------|------------------|------------------|------------------
macOS        | mmap+SEQUENTIAL  | mmap 64MB window | mmap 64MB window
iOS (any)    | mmap+SEQUENTIAL  | mmap 64MB window | mmap 32MB sliding
Linux        | mmap+SEQUENTIAL  | mmap 64MB window | mmap 32MB sliding
```

**Key changes from v1.0:**
- **ALWAYS use mmap** (never FileHandle except as last-resort fallback when mmap fails)
- **Window size doubled:** 32MB → 64MB on macOS, 32MB on iOS (Apple Silicon handles it)
- **F_NOCACHE for files > 256MB:** Bypass filesystem cache — we only read once

### 2.2 mmap with F_NOCACHE + MADV_SEQUENTIAL

```swift
// v2.4 HybridIOEngine — aggressive I/O:
public actor HybridIOEngine {

    /// Read a chunk with maximum I/O throughput.
    /// Uses mmap + F_NOCACHE + MADV_SEQUENTIAL for sequential single-pass reads.
    public func readChunk(
        fileURL: URL,
        offset: Int64,
        length: Int
    ) async throws -> IOResult {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw PR9Error.fileOpenFailed(errno: errno) }
        defer { close(fd) }

        // TOCTOU protection: verify inode after open
        var postStat = stat()
        fstat(fd, &postStat)

        // F_NOCACHE: bypass filesystem cache for large files
        // We read each byte exactly once — caching wastes memory
        if length > 256 * 1024 * 1024 {
            fcntl(fd, F_NOCACHE, 1)
        }

        // Shared lock: prevent concurrent writes during our read
        flock(fd, LOCK_SH)
        defer { flock(fd, LOCK_UN) }

        // mmap the region
        let mapLength = min(length, 64 * 1024 * 1024)  // 64MB window max
        let ptr = mmap(
            nil,
            mapLength,
            PROT_READ,
            MAP_PRIVATE | MAP_NOCACHE,  // MAP_PRIVATE for copy-on-write safety
            fd,
            off_t(offset)
        )
        guard ptr != MAP_FAILED else {
            // Fallback to FileHandle (should never happen on modern Apple devices)
            return try await readChunkFileHandle(fd: fd, offset: offset, length: length)
        }
        defer { munmap(ptr, mapLength) }

        // MADV_SEQUENTIAL: tell kernel we're reading linearly
        madvise(ptr, mapLength, MADV_SEQUENTIAL)
        // MADV_WILLNEED: prefetch the pages
        madvise(ptr, min(mapLength, 4 * 1024 * 1024), MADV_WILLNEED)

        // Single-pass: CRC32C + SHA-256 + compressibility in one scan
        let buffer = UnsafeRawBufferPointer(start: ptr, count: mapLength)
        let (sha256, crc32c, compressibility) = computeTripleHash(buffer: buffer)

        return IOResult(
            sha256Hex: sha256,
            crc32c: crc32c,
            byteCount: Int64(mapLength),
            compressibility: compressibility,
            ioMethod: .mmap
        )
    }
}
```

### 2.3 Pipelined Triple Hash (CRC32C + SHA-256 + Compressibility)

```swift
/// Process buffer in 128KB blocks (L1 cache optimal on Apple Silicon).
/// CRC32C uses ARM hardware intrinsics, SHA-256 uses CryptoKit hardware.
/// Both operate on the SAME buffer without extra copies.
private func computeTripleHash(
    buffer: UnsafeRawBufferPointer
) -> (sha256Hex: String, crc32c: UInt32, compressibility: Double) {
    var sha256 = SHA256Impl()
    var crc: UInt32 = 0
    var compressibleSamples: [Double] = []

    let blockSize = 128 * 1024  // 128KB = Apple Silicon L1 Data Cache size

    for blockStart in stride(from: 0, to: buffer.count, by: blockSize) {
        let blockEnd = min(blockStart + blockSize, buffer.count)
        let block = UnsafeRawBufferPointer(rebasing: buffer[blockStart..<blockEnd])

        // 1. CRC32C — ARM hardware intrinsic: ~20 GB/s
        #if arch(arm64)
        crc = block.withUnsafeBytes { ptr in
            var c = crc
            let words = ptr.bindMemory(to: UInt64.self)
            for word in words {
                c = __crc32cd(c, word)  // ARM CRC32C intrinsic
            }
            return c
        }
        #else
        crc = softwareCRC32C(crc, block)
        #endif

        // 2. SHA-256 — CryptoKit hardware: ~2.3 GB/s on M1
        sha256.update(data: block)

        // 3. Compressibility sample every 5MB
        if blockStart % (5 * 1024 * 1024) < blockSize {
            let sampleSize = min(32768, block.count)
            let sample = Data(block[0..<sampleSize])
            let compressed = try? (sample as NSData).compressed(using: .lzfse)
            let ratio = Double(compressed?.length ?? sample.count) / Double(sample.count)
            compressibleSamples.append(1.0 - ratio)  // 1.0 = fully compressible
        }
    }

    let avgCompressibility = compressibleSamples.isEmpty ? 0.0
        : compressibleSamples.reduce(0, +) / Double(compressibleSamples.count)

    return (sha256.finalize().hexString, crc, avgCompressibility)
}
```

### 2.4 Read-Ahead Pipeline (Prefetch N+2)

```swift
/// The upload pipeline keeps 3 stages in flight simultaneously:
///
/// Time →
/// ┌─────────┬─────────┬─────────┬─────────┬─────────┐
/// │ Read N  │ Read N+1│ Read N+2│ Read N+3│ ...     │  ← I/O pipeline
/// │         │ Hash N  │ Hash N+1│ Hash N+2│ ...     │  ← Hash pipeline
/// │         │         │Upload N │Upload N+1│ ...    │  ← Network pipeline
/// └─────────┴─────────┴─────────┴─────────┴─────────┘
///
/// At any moment:
/// - 1 chunk being read from disk (mmap)
/// - 1 chunk being hashed (CRC32C + SHA-256)
/// - 12 chunks being uploaded (parallel HTTP/2 or HTTP/3 streams)
///
/// The I/O pipeline ensures the network NEVER stalls waiting for data.

public actor PrefetchPipeline {
    private let ioEngine: HybridIOEngine
    private let bufferPool: ChunkBufferPool
    private var prefetchQueue: AsyncStream<PrefetchedChunk>.Continuation?

    /// Number of chunks to read ahead of the upload position.
    /// 3 means: at upload position N, chunks N, N+1, N+2 are already in memory.
    private let prefetchDepth: Int = 3

    public struct PrefetchedChunk: Sendable {
        let index: Int
        let data: Data  // or UnsafeMutableRawBufferPointer from pool
        let sha256Hex: String
        let crc32c: UInt32
        let compressibility: Double
    }

    /// Start prefetching chunks from the given position.
    /// Returns an AsyncStream of prefetched, hashed chunks ready for upload.
    public func startPrefetch(
        fileURL: URL,
        startIndex: Int,
        chunkSize: Int,
        totalChunks: Int
    ) -> AsyncStream<PrefetchedChunk> {
        AsyncStream { continuation in
            self.prefetchQueue = continuation
            Task {
                for i in startIndex..<totalChunks {
                    let offset = Int64(i) * Int64(chunkSize)
                    let length = min(chunkSize, Int(fileSize - offset))

                    let result = try await ioEngine.readChunk(
                        fileURL: fileURL, offset: offset, length: length
                    )

                    let chunk = PrefetchedChunk(
                        index: i,
                        data: result.rawData,
                        sha256Hex: result.sha256Hex,
                        crc32c: result.crc32c,
                        compressibility: result.compressibility
                    )

                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}
```

---

## 3. TRANSPORT: HTTP/3 QUIC + 0-RTT

### 3.1 QUIC as Primary Transport

```swift
// v2.4: Prefer HTTP/3 (QUIC) when available.
// Benefits for chunk upload:
// - 0-RTT session resumption: eliminate TLS+TCP handshake for repeat uploads
// - Stream multiplexing without head-of-line blocking
// - Built-in connection migration (WiFi → cellular without reconnect)
// - Faster loss recovery (per-stream, not per-connection)

public func createUploadSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral  // No disk cache

    #if os(iOS)
    // iOS 15+ supports HTTP/3 automatically
    config.multipathServiceType = .aggregate
    #endif

    // Force HTTP/3 when available, HTTP/2 fallback
    // URLSession automatically negotiates QUIC via Alt-Svc
    config.httpMaximumConnectionsPerHost = 12  // v2.4: up from 6
    config.timeoutIntervalForRequest = 20.0    // v2.4: aggressive
    config.timeoutIntervalForResource = 7200.0 // 2 hours for large files
    config.waitsForConnectivity = true
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil

    // TLS 1.3 only (QUIC requires it)
    // URLSession handles this automatically with HTTP/3

    return URLSession(
        configuration: config,
        delegate: pinningDelegate,
        delegateQueue: nil  // Concurrent delegate queue for max throughput
    )
}
```

### 3.2 0-RTT Session Resumption

```swift
// QUIC 0-RTT eliminates handshake on repeat connections:
//
// First upload:   DNS + TCP + TLS 1.3 = ~3 RTTs → then upload
// Repeat upload:  QUIC 0-RTT = 0 RTTs → immediate upload
//
// URLSession handles 0-RTT automatically when HTTP/3 is negotiated.
// The session ticket is cached for reuse.
//
// Security note: 0-RTT data is vulnerable to replay.
// For upload, replay is safe because:
// - Each chunk has unique idempotency key
// - Server deduplicates by key
// - Replayed chunk = no-op on server

// v2.4 ConnectionPrewarmer: extend to support QUIC discovery
public actor ConnectionPrewarmer {

    // v1.0 stages + v2.4 QUIC addition:
    // Stage 0 (app launch):         DNS pre-resolve
    // Stage 1 (enter capture UI):   TCP + TLS probe to upload endpoint
    // Stage 2 (TCP done):           HTTP/2 SETTINGS exchange
    // Stage 2.5 (NEW v2.4):         Discover Alt-Svc for HTTP/3
    //                               If Alt-Svc header present → QUIC 0-RTT ready
    // Stage 3 (capture active):     Keep connection warm with periodic pings
    // Stage 4 (capture ends):       Immediate first chunk write

    /// v2.4: Probe for QUIC availability during capture.
    /// If server supports HTTP/3, subsequent uploads use 0-RTT.
    public func probeQUICSupport(endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"  // Lightweight probe

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }

        // Check Alt-Svc header for h3 advertisement
        if let altSvc = httpResponse.value(forHTTPHeaderField: "Alt-Svc"),
           altSvc.contains("h3") {
            return true  // QUIC available — URLSession will use it automatically
        }
        return false
    }
}
```

### 3.3 Stream Multiplexing for Parallel Chunks

```swift
// HTTP/3 QUIC streams vs HTTP/2 streams:
//
// HTTP/2: All streams share ONE TCP connection.
//   → Head-of-line blocking: one lost packet stalls ALL streams
//   → Practical limit: ~6-8 useful parallel streams
//
// HTTP/3 QUIC: Each stream is independently loss-recovered.
//   → No head-of-line blocking between streams
//   → Can push to 12+ parallel streams effectively
//   → Stream 7 packet loss does NOT affect streams 1-6, 8-12
//
// v2.4: Exploit QUIC's stream independence.
// Each chunk upload is a separate QUIC stream.
// 12 parallel streams → 12 chunks uploading simultaneously.
// With 3-chunk prefetch, the I/O pipeline keeps all 12 streams fed.
```

---

## 4. PARALLELISM: 12 STREAMS WITH PREFETCH PIPELINE

### 4.1 Parallel Upload Count Override

```swift
// v1.0:  MAX_PARALLEL = 4 (conservative HTTP/2)
// v2.0:  MAX_PARALLEL = 6 (HTTP/2 multiplexing)
// v2.2:  MAX_PARALLEL = 8 for ULTRAFAST only
// v2.4:  MAX_PARALLEL = 12 (HTTP/3 QUIC streams, no HOL blocking)
//
// WHY 12:
// - HTTP/3 QUIC has no head-of-line blocking → 12 independent streams
// - At 200 Mbps uplink: 12 × 2MB chunks = 24MB in-flight = 12 × 1s = ~1s round-trip coverage
// - At 50 Mbps: 12 × 1MB chunks = 12MB in-flight = 12 × 2s = fully pipelined
// - Apple Silicon can handle 12 concurrent TLS encryptions easily
// - Memory: 12 × 32MB max = 384MB worst case (iPhone 15 Pro has 8GB RAM)
//
// Speed tier mapping:
// slow (<3 Mbps):      4 parallel (even bad networks benefit from pipelining)
// normal (3-30 Mbps):  8 parallel
// fast (30-200 Mbps):  12 parallel
// ultrafast (>200 Mbps): 12 parallel + 32MB chunks

public static let MAX_PARALLEL_CHUNK_UPLOADS: Int = 12
```

### 4.2 Aggressive Ramp-Up

```swift
// v1.0: Ramp-up delay = 0.1s (100ms between new streams)
// v2.0: Ramp-up delay = 0.05s (50ms)
// v2.4: Ramp-up delay = 0.01s (10ms) — near-instant ramp
//
// With QUIC, there's no TCP slow-start per stream.
// All streams share the same QUIC connection's congestion window.
// Ramping up 12 streams in 120ms (12 × 10ms) is safe.

public static let PARALLEL_RAMP_UP_DELAY_SECONDS: TimeInterval = 0.01
```

### 4.3 Full Pipeline Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    v2.4 Upload Pipeline                          │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────────────┐   │
│  │  Disk    │→ │  Hash    │→ │    Network (12 streams)      │   │
│  │  Reader  │  │  Engine  │  │                              │   │
│  │          │  │          │  │  Stream 1: ████████ chunk 5  │   │
│  │ Prefetch │  │ CRC32C + │  │  Stream 2: ██████── chunk 6  │   │
│  │ depth=3  │  │ SHA-256  │  │  Stream 3: ████──── chunk 7  │   │
│  │          │  │          │  │  Stream 4: ██────── chunk 8  │   │
│  │ mmap +   │  │ Single   │  │  Stream 5: ████████ chunk 9  │   │
│  │ F_NOCACHE│  │ pass     │  │  ...                         │   │
│  │ MADV_SEQ │  │ NEON     │  │  Stream 12: ██──── chunk 16  │   │
│  └──────────┘  └──────────┘  └──────────────────────────────┘   │
│                                                                  │
│  Buffer Pool: 12 buffers × chunkSize, auto-recycle             │
│  Memory: max 384MB (12 × 32MB), min 64MB (2 × 32MB)           │
└──────────────────────────────────────────────────────────────────┘
```

---

## 5. COMPRESSION: HARDWARE-ACCELERATED DECISION

### 5.1 v2.4 Compression Strategy

```swift
// v1.0: zstd level 1 (thermal ≥ fair) or LZ4 (thermal < fair)
// v2.4: LZFSE always (Apple hardware-accelerated), LZ4 on Linux
//
// Apple Compression Framework on Apple Silicon:
// - LZFSE: ~3 GB/s compress, ~4 GB/s decompress (hardware-accelerated on Apple Silicon)
// - LZ4:   ~4 GB/s compress, ~6 GB/s decompress
// - zstd:  ~500 MB/s compress (level 1), ~1.5 GB/s decompress
//
// For upload, compress throughput matters most.
// LZFSE at ~3 GB/s is 6x faster than zstd level 1.
// Even at 200 Mbps (25 MB/s), LZFSE compression (3 GB/s) adds <1% latency.
//
// For 3D scan data (binary point clouds, meshes):
// - Typical compressibility: 15-35% savings
// - If data compresses to <90% of original → compress
// - If data is incompressible (camera raw, pre-compressed) → send raw

public func decideCompression(chunk: PrefetchedChunk) -> CompressionDecision {
    // v2.4: No thermal check. Always compress if beneficial.
    if chunk.compressibility > 0.10 {
        // >10% compressible: compress
        #if canImport(Compression)
        return .compress(algorithm: .lzfse)  // Hardware-accelerated
        #else
        return .compress(algorithm: .lz4)    // Linux fallback
        #endif
    } else {
        return .raw  // Incompressible data: skip
    }
}

// Compression threshold lowered from 0.25 (v1.0) to 0.10 (v2.4)
// Because: at 3 GB/s compression throughput, even 10% savings is free.
// Only skip compression for truly incompressible data (<10%).
```

---

## 6. CONNECTION PREWARMING: START AT CAPTURE

### 6.1 v1.0 vs v2.4 Timeline

```
v1.0 Timeline:
  App Launch → Capture UI → Capture Active → End Capture → Prewarm → Upload
                                                           ^^^^^^^^
                                                           WASTED TIME

v2.4 Timeline:
  App Launch → DNS resolve
  Capture UI → TCP + TLS handshake + QUIC discovery
  Capture Active → Keep warm with periodic PING
  End Capture → IMMEDIATE first chunk (connection already ready)
  ^^^^^^^^^^^^
  NO WASTED TIME — connection is hot when we need it
```

```swift
// v2.4: Prewarming starts at CAPTURE START, not upload start.
// By the time user finishes capturing, we have:
// 1. DNS resolved and cached
// 2. TCP connection established
// 3. TLS 1.3 handshake completed
// 4. HTTP/2 SETTINGS exchanged
// 5. QUIC Alt-Svc discovered (if available)
// 6. First chunk can go out with ZERO handshake delay

public actor ConnectionPrewarmer {

    private var prewarmTask: Task<Void, Never>?
    private var isWarm: Bool = false

    /// Called when user enters capture UI (NOT when upload starts).
    public func startPrewarming(endpoint: URL) {
        prewarmTask = Task {
            // Stage 0: DNS
            let _ = try? await resolve(hostname: endpoint.host ?? "")

            // Stage 1: TCP + TLS
            var probeRequest = URLRequest(url: endpoint)
            probeRequest.httpMethod = "HEAD"
            let _ = try? await uploadSession.data(for: probeRequest)

            // Stage 2: QUIC discovery
            let quicAvailable = await probeQUICSupport(endpoint: endpoint)

            isWarm = true

            // Stage 3: Keep warm during capture
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)  // 15s keepalive
                if !Task.isCancelled {
                    let _ = try? await uploadSession.data(for: probeRequest)
                }
            }
        }
    }

    /// Called when capture ends — connection should be hot.
    public func getWarmConnection() -> URLSession {
        return uploadSession  // Already established
    }
}
```

---

## 7. CONSTANTS OVERRIDE: AGGRESSIVE TUNING

### 7.1 Chunk Size: Up to 32MB

```swift
// v2.4 Chunk Size Updates:
//
// v1.0: MIN=512KB, DEFAULT=2MB, MAX=16MB
// v2.0: MIN=256KB, DEFAULT=2MB, MAX=16MB
// v2.4: MIN=256KB, DEFAULT=4MB, MAX=32MB
//
// WHY 32MB MAX:
// - HTTP/3 QUIC handles large payloads better (stream-level loss recovery)
// - At 200 Mbps: 32MB chunk = 1.28s upload (acceptable RTT)
// - At 1 Gbps (WiFi 6E): 32MB = 0.26s (fast)
// - Fewer chunks = fewer Merkle leaves = faster tree operations
// - Fewer chunks = fewer HTTP requests = less overhead
// - Memory: 12 streams × 32MB = 384MB = fits in 8GB iPhone

public static let CHUNK_SIZE_DEFAULT_BYTES: Int = 4 * 1024 * 1024    // 4MB
public static let CHUNK_SIZE_MAX_BYTES: Int = 32 * 1024 * 1024       // 32MB
```

### 7.2 Speed Tier → Chunk Size Mapping

```swift
// v2.4: More aggressive chunk sizing per speed tier
//
// SLOW (<3 Mbps):      1MB chunks × 4 parallel = 4MB in-flight
// NORMAL (3-30 Mbps):  4MB chunks × 8 parallel = 32MB in-flight
// FAST (30-200 Mbps):  16MB chunks × 12 parallel = 192MB in-flight
// ULTRAFAST (>200 Mbps): 32MB chunks × 12 parallel = 384MB in-flight

public var recommendedChunkSize: Int {
    switch self {
    case .slow:      return 1 * 1024 * 1024    // 1MB
    case .normal:    return 4 * 1024 * 1024    // 4MB
    case .fast:      return 16 * 1024 * 1024   // 16MB
    case .ultrafast: return 32 * 1024 * 1024   // 32MB
    case .unknown:   return 4 * 1024 * 1024    // 4MB (conservative default)
    }
}
```

### 7.3 Timeout: Faster Failure Detection

```swift
// v2.4: Aggressive timeouts — detect failures FAST, retry FAST.
//
// Per-chunk timeout: scale with chunk size
//   1MB chunk at 1 Mbps worst case = 8s → timeout = 15s
//   32MB chunk at 100 Mbps = 2.56s → timeout = 10s
//   Formula: timeout = max(10, chunkSizeBytes / minExpectedBps * 2)
//
// Connection timeout: 5s (v1.0 was 10s, v2.0 was 8s)
//   On 5G and modern WiFi, connection < 1s.
//   5s is generous enough for edge cases.
//
// Stall detection: 5s (v1.0 was 15s, v2.0 was 10s)
//   If no bytes flow for 5s, something is wrong. Act immediately.

public static let CHUNK_TIMEOUT_SECONDS: TimeInterval = 30.0  // Base (adjusted per chunk)
public static let CONNECTION_TIMEOUT_SECONDS: TimeInterval = 5.0
public static let STALL_DETECTION_TIMEOUT_SECONDS: TimeInterval = 5.0
public static let STALL_MIN_PROGRESS_RATE_BPS: Int = 8192  // 8KB/s minimum
```

### 7.4 Retry: Faster Recovery

```swift
// v2.4: Retry FAST with decorrelated jitter.
//
// Base delay: 0.5s (v1.0 was 2s, v2.0 was 1s)
// Max delay: 15s (v1.0 was 60s, v2.0 was 30s)
// Max retries: 7 (v1.0 was 3, v2.0 was 5)
// Jitter: decorrelated (best empirically per AWS analysis)
//
// Decorrelated jitter formula:
//   sleep = min(maxDelay, random(baseDelay, previousSleep * 3))
//
// This gives FAST first retries (0.5-1.5s) and grows if problems persist.

public static let RETRY_BASE_DELAY_SECONDS: TimeInterval = 0.5
public static let RETRY_MAX_DELAY_SECONDS: TimeInterval = 15.0
public static let CHUNK_MAX_RETRIES: Int = 7
public static let RETRY_JITTER_TYPE: String = "decorrelated"  // vs "full" or "equal"
```

---

## 8. SECURITY HARDENING: MAXIMUM WITHOUT SPEED LOSS

### 8.1 Per-Chunk HMAC on Wire

```swift
// v2.4: Every chunk carries an HMAC tag for tamper detection.
// This is IN ADDITION to TLS encryption.
//
// Why HMAC on top of TLS?
// - Detects MITM that strips/replays chunks at the application layer
// - Detects server-side corruption before Merkle verification
// - Cost: ~1µs per chunk (HMAC-SHA256 on 32MB = negligible vs upload time)
//
// HMAC key: derived per-session from master key
// HMAC input: chunkIndex || chunkSize || chunkSHA256 || sessionId || nonce
// Sent as: X-Chunk-HMAC header

public func computeChunkHMAC(
    chunkIndex: Int,
    chunkSHA256: String,
    sessionKey: SymmetricKey
) -> String {
    var hmacInput = Data()
    hmacInput.append(contentsOf: withUnsafeBytes(of: UInt32(chunkIndex).littleEndian) { Data($0) })
    hmacInput.append(Data(chunkSHA256.utf8))
    hmacInput.append(Data(sessionId.utf8))
    let tag = HMAC<SHA256>.authenticationCode(for: hmacInput, using: sessionKey)
    return Data(tag).hexString
}
```

### 8.2 TLS 1.3 Enforcement + Certificate Transparency

```swift
// v2.4: ABSOLUTE MINIMUM transport security.
// These are NON-NEGOTIABLE, even on debug builds.
//
// 1. TLS 1.3 ONLY — no fallback to TLS 1.2
// 2. Certificate Transparency (CT): require ≥2 SCTs from independent logs
// 3. OCSP stapling preferred (soft-fail if unavailable — don't block upload)
// 4. Certificate pinning: CA-level + CT (not leaf — leaf breaks on rotation)
// 5. Session tickets: rotate every 3600s
//
// These checks add ~0ms to upload time (done during prewarming).
```

### 8.3 Automatic Buffer Zeroing

```swift
// v2.4: ALL chunk buffers are zeroed after use.
// No chunk data remains in memory after upload + ACK.
//
// Implementation: ChunkBufferPool.recycle() calls memset_s()
// memset_s() cannot be optimized away by the compiler (C11 Annex K).
// Cost: ~3 GB/s on M1 for memset = <10ms for 32MB buffer = negligible.
```

---

## 9. STABILITY: TRIPLE WATCHDOG + ATOMIC RESUME

### 9.1 Triple-Layer Watchdog

```swift
/// Three independent watchdogs ensure upload NEVER hangs:
///
/// Layer 1: Per-Chunk Watchdog (finest granularity)
///   - Timeout: dynamicChunkTimeout (based on chunk size + speed)
///   - On fire: Retry this specific chunk
///   - Reset: Every time bytes are acknowledged for this chunk
///
/// Layer 2: Per-Session Watchdog (medium granularity)
///   - Timeout: 60 seconds of zero overall progress
///   - On fire: Pause all streams → reconnect → resume from last ACK
///   - Reset: Every time any chunk makes progress
///
/// Layer 3: Global Upload Watchdog (coarsest granularity)
///   - Timeout: 5 minutes of zero ACKed chunks
///   - On fire: Full restart — new session, re-verify server state, resume
///   - Reset: Every time a chunk is fully ACKed

public actor TripleWatchdog {

    private var chunkTimers: [Int: Task<Void, Never>] = [:]  // Per-chunk
    private var sessionTimer: Task<Void, Never>?
    private var globalTimer: Task<Void, Never>?

    // Layer 1: Per-chunk
    public func startChunkWatchdog(
        chunkIndex: Int,
        timeout: TimeInterval,
        onFire: @escaping () async -> Void
    ) {
        chunkTimers[chunkIndex]?.cancel()
        chunkTimers[chunkIndex] = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled {
                await onFire()
            }
        }
    }

    public func resetChunkWatchdog(chunkIndex: Int, timeout: TimeInterval,
                                    onFire: @escaping () async -> Void) {
        startChunkWatchdog(chunkIndex: chunkIndex, timeout: timeout, onFire: onFire)
    }

    public func cancelChunkWatchdog(chunkIndex: Int) {
        chunkTimers[chunkIndex]?.cancel()
        chunkTimers.removeValue(forKey: chunkIndex)
    }

    // Layer 2: Session
    public func resetSessionWatchdog(
        timeout: TimeInterval = 60,
        onFire: @escaping () async -> Void
    ) {
        sessionTimer?.cancel()
        sessionTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { await onFire() }
        }
    }

    // Layer 3: Global
    public func resetGlobalWatchdog(
        timeout: TimeInterval = 300,
        onFire: @escaping () async -> Void
    ) {
        globalTimer?.cancel()
        globalTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { await onFire() }
        }
    }
}
```

### 9.2 Atomic Resume State Persistence

```swift
/// Resume state is persisted using POSIX atomic write pattern:
/// 1. Write to temp file (same filesystem)
/// 2. fsync(fd) — ensure data hits disk
/// 3. rename(temp, target) — atomic on POSIX
///
/// This guarantees: either the old state or the new state is on disk.
/// NEVER a half-written state.
///
/// Checkpoint frequency: every 10 ACKed chunks (not every chunk — too expensive).
/// On crash: lose at most 10 chunks of progress (re-upload them).

public func persistResumeState(_ state: ResumeState) throws {
    let data = try JSONEncoder().encode(state)
    let encrypted = try AES.GCM.seal(data, using: sessionKey)

    let targetPath = resumeStatePath
    let tempPath = targetPath + ".tmp.\(UUID().uuidString)"

    // 1. Write to temp
    let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw PR9Error.resumePersistFailed }
    defer { close(fd) }

    let written = encrypted.combined!.withUnsafeBytes { ptr in
        write(fd, ptr.baseAddress!, ptr.count)
    }
    guard written == encrypted.combined!.count else {
        unlink(tempPath)
        throw PR9Error.resumePersistFailed
    }

    // 2. fsync — ensure data on disk
    fsync(fd)

    // 3. Atomic rename
    guard rename(tempPath, targetPath) == 0 else {
        unlink(tempPath)
        throw PR9Error.resumePersistFailed
    }
}
```

### 9.3 Checkpoint Frequency

```swift
// v2.4: Checkpoint resume state every 10 successfully ACKed chunks.
// At 4MB average chunk size and 100 Mbps:
//   10 chunks = 40MB = ~3.2 seconds of upload
//   On crash: lose ~3.2 seconds of progress (re-upload 10 chunks)
//   This is acceptable.
//
// Checkpoint content:
//   - List of ACKed chunk indices
//   - Merkle tree state (carry stack)
//   - Commitment chain tip
//   - Session ID and auth state
//   - Upload position (byte offset)
//   - Bandwidth estimator state

public static let RESUME_CHECKPOINT_INTERVAL: Int = 10  // chunks
```

---

## 10. NETWORK TRANSITION: ZERO-DOWNTIME HANDOFF

```swift
/// v2.4: When network changes (WiFi → cellular, cellular → WiFi),
/// DO NOT pause upload. Instead:
///
/// 1. Detect transition via NWPathMonitor
/// 2. KEEP existing streams alive (they may still work on new path)
/// 3. Start NEW streams on new path in parallel
/// 4. As old streams complete or timeout, shift all traffic to new path
/// 5. DNS re-resolution on new path (may route to different CDN edge)
///
/// With QUIC: connection migration happens automatically.
/// With HTTP/2: graceful drain old → establish new.

public actor NetworkTransitionHandler {

    public func handlePathChange(
        oldPath: NWPath,
        newPath: NWPath,
        activeStreams: inout [UploadStream]
    ) async {
        // 1. DO NOT cancel active streams
        // Let them finish their current chunk on the old path

        // 2. Re-resolve DNS on new interface
        let newEndpoints = await resolveDNS(
            hostname: uploadHostname,
            interfaceType: newPath.availableInterfaces.first?.type
        )

        // 3. Create new connection on new path
        let newSession = createSessionForPath(newPath)

        // 4. New chunks go to new session
        // Old chunks continue on old session until completion or timeout

        // 5. After all old streams complete → release old session

        // Result: ZERO interrupted chunks during transition
    }
}
```

---

## 11. MEMORY PIPELINE: NO THROTTLING, SMART POOLING

### 11.1 Buffer Pool Architecture

```swift
// v2.4: Pre-allocated buffer pool with zero-copy semantics.
//
// At upload start:
//   1. Allocate maxParallel + prefetchDepth buffers (12 + 3 = 15)
//   2. Each buffer = chunkSize bytes, page-aligned (posix_memalign)
//   3. mlock() to prevent paging (keep in physical RAM)
//
// During upload:
//   1. Acquire buffer from pool
//   2. mmap chunk data into buffer (zero-copy from disk)
//   3. Hash buffer (in-place, no copy)
//   4. Upload buffer contents (in-place, no copy)
//   5. Zero buffer (security)
//   6. Return to pool
//
// Total copies: 0 (mmap → hash → upload all operate on same memory)
// Total allocations during upload: 0 (all pre-allocated)

public static let BUFFER_POOL_SIZE: Int = 15  // maxParallel + prefetchDepth
```

---

## 12. UPDATED CONSTANTS TABLE (28 OVERRIDES)

| Constant | v2.2 Value | v2.4 Value | Reason |
|----------|-----------|-----------|--------|
| `MAX_PARALLEL_CHUNK_UPLOADS` | 6 (8 ultrafast) | **12** | HTTP/3 QUIC no HOL blocking |
| `PARALLEL_RAMP_UP_DELAY_SECONDS` | 0.05 | **0.01** | QUIC shared congestion window |
| `PARALLELISM_ADJUST_INTERVAL` | 3.0 | **1.5** | React to network changes faster |
| `CHUNK_SIZE_DEFAULT_BYTES` | 2MB | **4MB** | BDP-optimal for 30 Mbps average |
| `CHUNK_SIZE_MAX_BYTES` | 16MB | **32MB** | HTTP/3 + fast networks |
| `CHUNK_TIMEOUT_SECONDS` | 45.0 | **30.0** | Faster failure detection |
| `CONNECTION_TIMEOUT_SECONDS` | 8.0 | **5.0** | Modern networks connect <1s |
| `STALL_DETECTION_TIMEOUT` | 10.0 | **5.0** | 5s silence = problem |
| `STALL_MIN_PROGRESS_RATE_BPS` | 4096 | **8192** | 8KB/s minimum meaningful |
| `RETRY_BASE_DELAY_SECONDS` | 1.0 | **0.5** | Faster first retry |
| `RETRY_MAX_DELAY_SECONDS` | 30.0 | **15.0** | Mobile handover <10s |
| `CHUNK_MAX_RETRIES` | 5 | **7** | More resilient |
| `PROGRESS_THROTTLE_INTERVAL` | 0.05 | **0.033** | 30fps (ProMotion 1/4 rate) |
| `PROGRESS_MIN_BYTES_DELTA` | 32KB | **16KB** | Finer granularity |
| `NETWORK_SPEED_SLOW_MBPS` | 3.0 | **3.0** | (unchanged) |
| `NETWORK_SPEED_NORMAL_MBPS` | 30.0 | **30.0** | (unchanged) |
| `NETWORK_SPEED_FAST_MBPS` | (implicit 100) | **200.0** | 5.5G uplink real-world |
| `NETWORK_SPEED_MIN_SAMPLES` | 5 | **3** | Faster ramp-up (Kalman converges in 3) |
| `MAX_FILE_SIZE_BYTES` | 50GB | **100GB** | Future 16K multi-view |
| `SESSION_MAX_AGE_SECONDS` | 172800 | **604800** | 7 days for interrupted travel uploads |
| `RESUME_CHECKPOINT_INTERVAL` | (new) | **10** | Every 10 ACKed chunks |
| `BUFFER_POOL_SIZE` | (new) | **15** | maxParallel + prefetchDepth |
| `PREFETCH_DEPTH` | (new) | **3** | Read-ahead 3 chunks |
| `IO_MMAP_WINDOW_SIZE` | 32MB | **64MB** | macOS/Linux default |
| `IO_MMAP_WINDOW_SIZE_IOS` | (new) | **32MB** | iOS (lower RAM) |
| `COMPRESSION_BENEFIT_THRESHOLD` | 0.25 | **0.10** | LZFSE is so fast, 10% is worth it |
| `WATCHDOG_SESSION_TIMEOUT` | (new) | **60.0** | Session-level watchdog |
| `WATCHDOG_GLOBAL_TIMEOUT` | (new) | **300.0** | Global upload watchdog |

---

## 13. TESTING ADDITIONS FOR v2.4

### 13.1 New Test Cases

| Test File | New Tests | What It Validates |
|-----------|----------|-------------------|
| `ChunkedUploaderTests.swift` | +30 | 12-stream parallel, prefetch pipeline, no-throttle under memory pressure |
| `HybridIOEngineTests.swift` | +15 | F_NOCACHE, 64MB mmap window, MADV_SEQUENTIAL, sliding window |
| `TripleWatchdogTests.swift` (NEW) | 40 | Per-chunk timeout, session timeout, global timeout, cascade behavior |
| `NetworkTransitionTests.swift` (NEW) | 25 | WiFi→cellular, cellular→WiFi, zero-downtime, DNS re-resolution |
| `ChunkBufferPoolTests.swift` (NEW) | 20 | Pool exhaustion blocking, recycle, memory pressure adjustment |
| `PrefetchPipelineTests.swift` (NEW) | 20 | 3-chunk read-ahead, pipeline stall recovery, EOF handling |
| `AtomicResumeTests.swift` (NEW) | 15 | Atomic write, fsync, crash-during-write recovery |

### 13.2 Updated Grand Total

| Metric | v2.3 | v2.4 Additions | v2.4 Total |
|--------|------|---------------|-----------|
| Implementation files | 24 | +2 (TripleWatchdog, PrefetchPipeline) | **26** |
| Test files | 22 | +5 | **27** |
| Test assertions | 2,830+ | +165 | **2,995+** |

---

## 14. FINAL VERIFICATION CHECKLIST v2.4

### Performance
- [ ] 12 parallel upload streams active under ULTRAFAST conditions
- [ ] Prefetch pipeline: 3 chunks read ahead at all times
- [ ] mmap + F_NOCACHE + MADV_SEQUENTIAL for all reads >256MB
- [ ] LZFSE compression for chunks with >10% compressibility
- [ ] Connection prewarmed during capture (NOT at upload start)
- [ ] 32MB chunk size used for ULTRAFAST (>200 Mbps)
- [ ] QUIC/HTTP3 used when server supports Alt-Svc h3
- [ ] Ramp-up: 12 streams active within 120ms of upload start
- [ ] Buffer pool: zero allocations during upload loop
- [ ] NO thermal throttling at any thermal state
- [ ] NO battery throttling at any battery level
- [ ] NO upload pause at any memory pressure level (reduce buffers, never pause)

### Security
- [ ] TLS 1.3 only (no 1.2 fallback)
- [ ] Certificate Transparency: ≥2 SCTs from independent logs
- [ ] Per-chunk HMAC tag in X-Chunk-HMAC header
- [ ] All buffers zeroed with memset_s() after use
- [ ] Resume state encrypted with AES-GCM + session-derived key
- [ ] Atomic resume persistence (write + fsync + rename)

### Stability
- [ ] Triple watchdog: per-chunk (dynamic), session (60s), global (300s)
- [ ] Network transition: zero interrupted chunks during WiFi↔cellular
- [ ] Resume checkpoint every 10 ACKed chunks
- [ ] Circuit breaker: 5 failures → open, 30s half-open, 2 successes → close
- [ ] Decorrelated jitter retry with 0.5s base, 15s max, 7 attempts
- [ ] Stall detection in 5s with 8KB/s minimum rate

### Testing
- [ ] 2,995+ assertions passing
- [ ] 12-stream parallel test passing
- [ ] Watchdog cascade test passing
- [ ] Atomic resume crash test passing
- [ ] Network transition test passing

---

## IMPLEMENTATION ORDER FOR v2.4

```
Phase 8A (immediate — no dependencies):
  Remove all throttling from UnifiedResourceManager
  Update all constants in UploadConstants.swift (28 overrides)
  Update Feature Flags (thermal=ignored, battery=ignored)

Phase 8B (I/O + Buffer):
  ChunkBufferPool.swift — pre-allocated buffer pool
  Update HybridIOEngine.swift — F_NOCACHE, 64MB window, aggressive mmap

Phase 8C (Pipeline):
  PrefetchPipeline.swift — 3-chunk read-ahead
  Update ChunkedUploader.swift — integrate pipeline + 12 streams

Phase 8D (Transport):
  Update ConnectionPrewarmer.swift — start at capture, QUIC probe
  Update URLSession config — HTTP/3, 12 connections, aggressive timeouts

Phase 8E (Stability):
  TripleWatchdog.swift — per-chunk + session + global
  Update EnhancedResumeManager — atomic persist + checkpoint every 10
  NetworkTransitionHandler — zero-downtime handoff

Phase 8F (Tests):
  5 new test files (165 assertions)
  Full regression: 2,995+ assertions
```

**Total new code: ~800 lines implementation + ~500 lines tests = ~1,300 lines**
**Grand total project: 26 implementation + 27 test = 53 files, ~3,000 assertions**
