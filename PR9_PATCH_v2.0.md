# PR9 PATCH v2.0 — Post-Audit Comprehensive Upgrade

## CRITICAL: This is a PATCH to `PR9_CURSOR_PROMPT.md` (v1.0)

**Apply these changes ON TOP of the original prompt.** Where this patch specifies new values, they OVERRIDE the v1.0 values. Where this patch adds new sections, they are ADDITIVE.

**Branch:** `pr9/chunked-upload-v3` (same branch)

---

## PATCH TABLE OF CONTENTS

1. [Architecture Self-Consistency Fixes](#1-architecture-self-consistency-fixes)
2. [Constants Precision Refinement (23 additional tunings)](#2-constants-precision-refinement)
3. [Security Hardening Upgrade (31 new items → total 89)](#3-security-hardening-upgrade)
4. [New File: `Core/Upload/ChunkIntegrityValidator.swift`](#4-new-file-chunkintegrityvalidator)
5. [New File: `Core/Upload/NetworkPathObserver.swift`](#5-new-file-networkpathobserver)
6. [New File: `Core/Upload/UploadCircuitBreaker.swift`](#6-new-file-uploadcircuitbreaker)
7. [Layer-by-Layer Precision Fixes](#7-layer-by-layer-precision-fixes)
8. [Testing Hardening (2000+ checks framework)](#8-testing-hardening)
9. [Future-Proofing Architecture](#9-future-proofing-architecture)
10. [PR5↔PR9 Fusion Tightening](#10-pr5pr9-fusion-tightening)
11. [Guardrails and Safety Valves](#11-guardrails-and-safety-valves)
12. [Competitive Edge Differentiators](#12-competitive-edge-differentiators)

---

## 1. ARCHITECTURE SELF-CONSISTENCY FIXES

### 1.1 Mbps Calculation Bug in NetworkSpeedMonitor

**CRITICAL BUG in existing code:** `NetworkSpeedMonitor.swift` line 108:
```swift
// CURRENT (WRONG):
public var speedMbps: Double {
    return (speedBps * 8.0) / (1024.0 * 1024.0)  // This is Mibps, NOT Mbps
}
```

**FIX:** Mbps (megabits per second) uses SI units (1,000,000), not binary (1,048,576).
All ISPs, speed tests, and networking standards use SI Mbps.

```swift
// PR9 MUST use in KalmanBandwidthPredictor and everywhere:
public var speedMbps: Double {
    return (speedBps * 8.0) / 1_000_000.0  // SI Mbps (correct)
}
```

**Impact:** At 100 Mbps actual, old code reports 95.37 Mbps → wrong speed class assignment. This cascades into wrong chunk size decisions.

### 1.2 UploadSession Thread Safety Gap

**BUG:** `UploadSession.progress` reads `uploadedBytes` and `fileSize` WITHOUT queue synchronization:
```swift
// CURRENT (RACE CONDITION):
public var progress: Double {
    guard fileSize > 0 else { return 0 }
    return Double(uploadedBytes) / Double(fileSize)  // reads uploadedBytes outside queue
}
```

**PR9 ChunkedUploader MUST wrap this call** in the existing session queue, or use its own synchronized accessor.

### 1.3 UploadResumeManager Plaintext Vulnerability

**BUG:** `SessionSnapshot` stored as plaintext JSON in UserDefaults. Contains `sessionId`, `fileName`, `fileSize`, all `chunks` with offsets.

**PR9 EnhancedResumeManager** already addresses this, but the patch must explicitly state:
- Old SessionSnapshot data MUST be migrated (decrypt-on-read, encrypt-on-write)
- Migration path: detect unencrypted data → encrypt in place → delete plaintext key
- Add `snapshotVersion: UInt8` field (v1=plaintext, v2=AES-GCM)

### 1.4 ReplayAttackPreventer Critical Vulnerability Confirmation

**CONFIRMED BUG (line 62-64):**
```swift
if usedNonces.count > 10000 {
    usedNonces.removeAll()  // DELETES ALL NONCES → replay window opens
}
```

**PR9 MUST create a parallel nonce validator** (do not modify PR5 file). In `ChunkIntegrityValidator.swift`:
- LRU eviction: remove oldest 20% when count > 8000 (NOT removeAll)
- Each nonce entry stores `(nonce: String, timestamp: Date)`
- Eviction: sort by timestamp, remove oldest 20%
- Window: 120 seconds (not 300s — shorter is safer)
- Add monotonic counter per session (chunks must arrive with non-decreasing counter)

### 1.5 DataAtRestEncryption Key Loss

**BUG:** `encryptionKey` generated fresh on every `init()`. If actor is re-created, all previously encrypted data is unrecoverable.

**PR9 EnhancedResumeManager** must:
- Store encryption key in Keychain (Apple) or file with 0600 permissions (Linux)
- Use HKDF to derive per-session keys from a master key
- Master key: `SecRandomCopyBytes` 32 bytes, stored once
- Session key: `HKDF-SHA256(masterKey, info: "PR9-resume-" + sessionId, salt: random_16_bytes)`

### 1.6 APIClient Creates New URLSession Per Request

**BUG:** `executeWithCertificatePinning()` creates a NEW URLSession for every request. This:
- Prevents HTTP/2 connection reuse
- Defeats connection pooling
- Wastes TLS handshake effort
- ConnectionPrewarmer's work is thrown away

**PR9 ChunkedUploader** must create ONE URLSession at init and reuse it:
```swift
// In ChunkedUploader.init():
let config = URLSessionConfiguration.default
config.httpMaximumConnectionsPerHost = 6
config.timeoutIntervalForRequest = 30.0
config.timeoutIntervalForResource = 3600.0
config.multipathServiceType = .handover
config.waitsForConnectivity = true
config.requestCachePolicy = .reloadIgnoringLocalCacheData
config.urlCache = nil  // No disk caching of chunk data

// Reuse this session for ALL chunk uploads
self.uploadSession = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
```

### 1.7 Missing Sendable Conformances

Several existing types used by PR9 lack `Sendable`:
- `ChunkStatus` is a struct but has `var` properties → not automatically Sendable
- `UploadProgressEvent` is Equatable but not Sendable
- `SpeedSample` is Codable but not explicitly Sendable

**PR9 must add `@unchecked Sendable`** where needed, or use copies across isolation boundaries.

---

## 2. CONSTANTS PRECISION REFINEMENT

### 2.1 Additional Constants to Add to UploadConstants.swift

Beyond the 56 changes in v1.0, add these 23 NEW constants:

```swift
// =========================================================================
// MARK: - PR9 Kalman Filter Configuration
// =========================================================================

/// Kalman filter process noise base (Q matrix diagonal)
/// - Lower = trust model more, Higher = trust measurement more
/// - 0.01 optimal for WiFi stability, multiplied 10x on network change
public static let KALMAN_PROCESS_NOISE_BASE: Double = 0.01

/// Kalman measurement noise base (R)
/// - Computed dynamically from last N samples' variance
/// - This is the minimum floor to prevent division by zero
public static let KALMAN_MEASUREMENT_NOISE_FLOOR: Double = 0.001

/// Kalman anomaly threshold (Mahalanobis distance in sigma units)
/// - 2.5σ = 98.76% confidence interval
/// - Samples beyond this are weighted down, not discarded
public static let KALMAN_ANOMALY_THRESHOLD_SIGMA: Double = 2.5

/// Kalman convergence threshold (trace of P matrix)
/// - Below this → mark estimate as "reliable"
/// - Empirically: converges in 5-8 samples on stable networks
public static let KALMAN_CONVERGENCE_THRESHOLD: Double = 5.0

/// Number of recent samples for dynamic R calculation
public static let KALMAN_DYNAMIC_R_SAMPLE_COUNT: Int = 10

// =========================================================================
// MARK: - PR9 Merkle Tree Configuration
// =========================================================================

/// Subtree checkpoint interval (in leaves)
/// - Also checkpoints on every carry merge
/// - 16 leaves ≈ one checkpoint per 32-256MB depending on chunk size
public static let MERKLE_SUBTREE_CHECKPOINT_INTERVAL: Int = 16

/// Maximum Merkle tree depth (safety valve)
/// - log2(20GB / 512KB) ≈ 15.25, cap at 24 for safety
/// - Prevents stack overflow in recursive verification
public static let MERKLE_MAX_TREE_DEPTH: Int = 24

/// Merkle leaf domain separator byte
public static let MERKLE_LEAF_PREFIX: UInt8 = 0x00

/// Merkle internal node domain separator byte
public static let MERKLE_NODE_PREFIX: UInt8 = 0x01

// =========================================================================
// MARK: - PR9 Commitment Chain Configuration
// =========================================================================

/// Commitment chain domain tag (NUL-terminated)
public static let COMMITMENT_CHAIN_DOMAIN: String = "CCv1\0"

/// Jump chain domain tag (NUL-terminated)
public static let COMMITMENT_CHAIN_JUMP_DOMAIN: String = "CCv1_JUMP\0"

/// Genesis derivation prefix
public static let COMMITMENT_CHAIN_GENESIS_PREFIX: String = "Aether3D_CC_GENESIS_"

// =========================================================================
// MARK: - PR9 Byzantine Verification
// =========================================================================

/// Byzantine verification initiation delay after ACK (ms)
/// - Must be < chunk upload time to overlap with next chunk
public static let BYZANTINE_VERIFY_DELAY_MS: Int = 100

/// Byzantine verification timeout (ms)
public static let BYZANTINE_VERIFY_TIMEOUT_MS: Int = 500

/// Byzantine max consecutive failures before endpoint switch
public static let BYZANTINE_MAX_FAILURES: Int = 3

/// Byzantine coverage target (probability)
public static let BYZANTINE_COVERAGE_TARGET: Double = 0.999

// =========================================================================
// MARK: - PR9 Circuit Breaker Configuration
// =========================================================================

/// Circuit breaker failure threshold to open circuit
public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD: Int = 5

/// Circuit breaker half-open test interval (seconds)
public static let CIRCUIT_BREAKER_HALF_OPEN_INTERVAL: TimeInterval = 30.0

/// Circuit breaker success threshold to close from half-open
public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD: Int = 2

/// Circuit breaker window for counting failures (seconds)
public static let CIRCUIT_BREAKER_WINDOW_SECONDS: TimeInterval = 60.0

// =========================================================================
// MARK: - PR9 Erasure Coding
// =========================================================================

/// RS code data symbols (k) for standard encoding
public static let ERASURE_RS_DATA_SYMBOLS: Int = 20

/// Loss rate threshold for RaptorQ fallback
public static let ERASURE_RAPTORQ_FALLBACK_LOSS_RATE: Double = 0.08

/// Maximum FEC overhead percentage (cap total redundancy)
public static let ERASURE_MAX_OVERHEAD_PERCENT: Double = 50.0
```

### 2.2 Corrections to v1.0 Constants

| Constant | v1.0 Value | v2.0 Value | Reason |
|----------|-----------|-----------|--------|
| `CHUNK_SIZE_MIN_BYTES` | 512KB | 256KB (256 * 1024) | Alibaba Cloud OSS uses 256KB min for extreme weak networks; AWS S3 allows 5MB but we need sub-1Mbps support for emerging markets |
| `NETWORK_SPEED_WINDOW_SECONDS` | 45.0 | 60.0 | Full 5G NR carrier aggregation oscillation cycle is 45-55s; 60s captures complete cycle with margin |
| `STALL_MIN_PROGRESS_RATE_BPS` | 2048 | 4096 | At 2KB/s, a 2MB chunk takes 17 minutes. At 4KB/s, it's 8.5 minutes — still generous but prevents zombie connections |
| `PROGRESS_THROTTLE_INTERVAL` | 0.066 | 0.05 | 20fps aligns with both 60Hz and 120Hz ProMotion displays (LCM). 15fps (0.066) causes visible judder on 120Hz |
| `MAX_FILE_SIZE_BYTES` | 20GB | 50GB | High-res 3DGS with LOD can exceed 20GB; Polycam Pro supports 40GB+; futureproof for 8K multi-view |
| `SESSION_MAX_CONCURRENT` | 5 | 3 | Revert: 5 concurrent sessions × 6 parallel chunks = 30 connections. URLSession performance degrades >20 |

### 2.3 Compile-Time Validation Additions

Add to `UploadConstantsValidation`:
```swift
// PR9 additions
assert(UploadConstants.KALMAN_ANOMALY_THRESHOLD_SIGMA > 1.0 &&
       UploadConstants.KALMAN_ANOMALY_THRESHOLD_SIGMA < 5.0,
       "Kalman anomaly threshold must be between 1σ and 5σ")

assert(UploadConstants.MERKLE_MAX_TREE_DEPTH >= 16 &&
       UploadConstants.MERKLE_MAX_TREE_DEPTH <= 32,
       "Merkle tree depth must be 16-32 (covers 32KB to 2PB)")

assert(UploadConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD >= 3,
       "Circuit breaker needs ≥3 failures to avoid false positives")

assert(UploadConstants.BYZANTINE_COVERAGE_TARGET >= 0.99,
       "Byzantine coverage must be ≥99%")

assert(UploadConstants.ERASURE_MAX_OVERHEAD_PERCENT <= 100.0,
       "FEC overhead cannot exceed 100%")

assert(UploadConstants.CHUNK_SIZE_MIN_BYTES >= 256 * 1024,
       "Minimum chunk below 256KB has excessive HTTP overhead")

assert(UploadConstants.MAX_FILE_SIZE_BYTES <= 50 * Int64(1024 * 1024 * 1024),
       "Max file size capped at 50GB for mobile feasibility")
```

---

## 3. SECURITY HARDENING UPGRADE

### 3.1 New Transport Security Items (S-13 to S-20)

- **S-13: HTTP/2 SETTINGS frame validation** — Validate server's SETTINGS frame values (SETTINGS_MAX_CONCURRENT_STREAMS, SETTINGS_INITIAL_WINDOW_SIZE). Reject if MAX_CONCURRENT_STREAMS < 2 or INITIAL_WINDOW_SIZE < 65535.

- **S-14: Request smuggling prevention** — Always use `Content-Length` header (never chunked Transfer-Encoding for upload body). Validate server echoes exact content length in response.

- **S-15: Connection coalescing guard** — Verify that HTTP/2 connection coalescing only happens for same-origin requests. Different upload endpoints must use separate connections if certificates differ.

- **S-16: TLS session ticket rotation** — Force new TLS session ticket every 3600 seconds (1 hour). Prevents long-lived session tickets from being compromised.

- **S-17: ALPN negotiation verification** — Verify ALPN returns "h2" for HTTP/2. If server downgrades to HTTP/1.1, log warning and reduce parallelism to 2 (no multiplexing).

- **S-18: SNI leak prevention** — Ensure SNI (Server Name Indication) matches the expected hostname. Detect if a proxy/middlebox is modifying SNI.

- **S-19: Certificate Transparency (CT) log verification** — Verify server certificate has valid Signed Certificate Timestamps (SCTs) from at least 2 independent CT logs.

- **S-20: OCSP stapling enforcement** — Prefer OCSP stapled responses. If no staple, perform OCSP check with 5s timeout. On failure, allow but log "soft-fail" (don't block upload for OCSP failures).

### 3.2 New Data Security Items (D-09 to D-15)

- **D-09: Chunk buffer zeroing** — After each chunk is uploaded and ACK received, zero the buffer memory with `memset_s()` (not `memset` — compiler cannot optimize away `memset_s`). For Swift: use `withUnsafeMutableBytes { ptr in memset_s(ptr.baseAddress, ptr.count, 0, ptr.count) }`.

- **D-10: URLSession ephemeral configuration** — Use `URLSessionConfiguration.ephemeral` instead of `.default` for chunk uploads. This prevents:
  - Cookie storage on disk
  - URL cache on disk
  - Credential persistence
  - HTTP pipelining data leaks

- **D-11: Temporary file cleanup** — Any temporary files created during chunk splitting MUST be deleted with secure overwrite (zero before delete) on: upload complete, upload cancel, app terminate, and crash recovery.

- **D-12: Memory-mapped file access pattern** — When using mmap, set `madvise(addr, len, MADV_SEQUENTIAL)` for sequential read (hash computation) and `madvise(addr, len, MADV_DONTNEED)` after read to release pages immediately.

- **D-13: Sensitive struct auto-zeroing** — All structs containing cryptographic material (keys, nonces, intermediate hashes) should implement `deinit` (via class wrapper) or explicit `.wipe()` method. Swift value types are copied — ensure no dangling copies contain sensitive data.

- **D-14: Keychain access control** — When storing master encryption key in Keychain, use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. This:
  - Survives device lock (needed for background upload)
  - Does NOT migrate to backups
  - Is device-specific

- **D-15: Binary data path sanitization** — Never log raw chunk data or hash bytes. All debug logging must use `String(prefix: 8)` for hashes, `"<\(data.count) bytes>"` for data.

### 3.3 New Integrity Items (I-08 to I-14)

- **I-08: Chunk index overflow protection** — Validate `chunkIndex` fits in UInt32 before encoding in Merkle leaf. At max file 50GB / min chunk 256KB = 200,000 chunks, well within UInt32. Add assert.

- **I-09: Total chunk count commitment** — At session creation, client sends `expected_total_chunks` to server. Server rejects `CompleteUploadRequest` if `received_chunks != expected_total_chunks`. This prevents truncation attacks.

- **I-10: Merkle root binding** — The final `CompleteUploadRequest` MUST include the client-computed Merkle root. Server independently computes its Merkle root from received chunks and compares. Mismatch = data integrity failure.

- **I-11: Timestamp monotonicity** — Each chunk's upload timestamp must be strictly greater than the previous chunk's. This prevents replay of old chunks. Enforced in `ChunkCommitmentChain`.

- **I-12: Double-hash for dedup safety** — For Proof-of-Possession, the client proves possession of the DATA, not just the hash. A hash-only check allows an attacker who knows the hash to claim ownership. The partial-chunk challenge in v1.0 already handles this — this item explicitly documents why.

- **I-13: Session binding enforcement** — All chunk uploads in a session MUST include the `sessionId` in the HTTP header. Server must reject chunks with mismatched `sessionId`. Prevents cross-session chunk injection.

- **I-14: Nonce freshness guarantee** — All nonces used in Proof-of-Possession MUST be UUID v7 (time-ordered). Server rejects nonces with embedded timestamps > 15 seconds old. This provides both uniqueness and freshness without a nonce database.

### 3.4 New Availability Items (A-10 to A-16)

- **A-10: Circuit breaker pattern** — Implement circuit breaker for upload endpoint. After 5 consecutive failures within 60s, open circuit → wait 30s → half-open (try 1 request) → if 2 successes, close circuit. See new file `UploadCircuitBreaker.swift`.

- **A-11: Graceful degradation cascade** — When resources are constrained:
  ```
  Level 0 (normal):   All features active
  Level 1 (moderate): Disable Byzantine verification, reduce Kalman to 2D
  Level 2 (severe):   Disable erasure coding, use simple retry only
  Level 3 (critical): Single chunk upload, no parallelism, minimal memory
  Level 4 (emergency): Pause upload, save resume point, release all resources
  ```

- **A-12: Watchdog timer** — Global watchdog: if no upload progress for 120 seconds despite active session, force-trigger stall recovery. Prevents silent hangs from undetected network issues.

- **A-13: Upload deadline** — Optional deadline parameter. If upload cannot complete by deadline, switch to: (a) compress remaining chunks, (b) reduce quality, (c) notify user. For capture-upload pipeline, deadline = battery life estimate.

- **A-14: DNS failover** — If primary DNS resolution fails, retry with:
  1. System DNS resolver (default)
  2. DoH via Cloudflare (1.1.1.1)
  3. DoH via Google (8.8.8.8)
  4. Hardcoded fallback IP (last resort, log warning)

- **A-15: Chunk retry budget** — Global retry budget per session: `max_total_retries = chunk_count * 2`. Once exhausted, fail the upload instead of retrying forever. Prevents infinite loop on persistent server errors.

- **A-16: Background upload resilience** — On iOS, when app enters background:
  1. Save resume point immediately
  2. Create `URLSessionConfiguration.background` session
  3. Transfer pending chunks to background session
  4. App can be killed; iOS continues upload
  5. On next launch, check background session for results

### 3.5 New Privacy Items (P-11 to P-15)

- **P-11: Metadata stripping** — Before upload, strip EXIF/XMP metadata from images (GPS coordinates, camera serial, lens info). For video, strip GPS track. Only keep: resolution, duration, frame rate (needed for processing).

- **P-12: Upload telemetry anonymization** — All telemetry data uses k-anonymity (k≥5). Device model generalized (e.g., "iPhone15,2" → "iPhone 15 Pro"). Network type generalized (e.g., "AT&T 5G NR SA" → "5G").

- **P-13: Server-side log redaction** — Client includes `X-Privacy-Level` header:
  - `strict`: Server must not log file hashes, sizes, or session IDs
  - `standard` (default): Server may log anonymized metrics
  - `permissive`: Full logging for debugging (user opt-in)

- **P-14: Right to deletion** — Implement `deleteAllUploadData()` that:
  1. Deletes all resume snapshots (Keychain + UserDefaults)
  2. Zeros and deletes all temporary chunk files
  3. Clears all in-memory caches (nonces, hashes, telemetry)
  4. Sends `DELETE /api/v1/uploads/{sessionId}` for all known sessions

- **P-15: Consent-based telemetry** — Telemetry collection requires explicit user opt-in. Default is OFF. Respect `ProcessInfo.processInfo.isLowPowerModeEnabled` — disable all non-essential telemetry in Low Power Mode.

---

## 4. NEW FILE: `Core/Upload/ChunkIntegrityValidator.swift`

**Purpose:** Central validation hub for all chunk integrity checks. Replaces scattered validation logic with a single, auditable validator.

```
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-INTEGRITY-1.0
// Module: Upload Infrastructure - Chunk Integrity Validator
// Cross-Platform: macOS + Linux (pure Foundation)
```

**Actor-based** for thread safety.

**Responsibilities:**
1. Validate chunk hash matches expected (CRC32C fast check + SHA-256 definitive)
2. Validate chunk index within expected range [0, totalChunks)
3. Validate chunk size within [CHUNK_SIZE_MIN, CHUNK_SIZE_MAX] (last chunk can be smaller)
4. Validate monotonic counter (non-decreasing per session)
5. Validate nonce freshness (UUID v7 timestamp within window) — replaces ReplayAttackPreventer bug
6. Validate commitment chain continuity (current commit depends on previous)
7. Coordinate with ByzantineVerifier for server-side checks

**Key methods:**
```swift
public actor ChunkIntegrityValidator {
    /// Validate chunk before upload
    func validatePreUpload(chunk: ChunkData, session: UploadSessionContext) -> ValidationResult

    /// Validate chunk after server ACK
    func validatePostACK(chunkIndex: Int, serverResponse: UploadChunkResponse,
                         expectedHash: String) -> ValidationResult

    /// Validate nonce freshness (replaces ReplayAttackPreventer.removeAll bug)
    func validateNonce(_ nonce: String, timestamp: Date) -> Bool

    /// Full session integrity check (all chains, all hashes)
    func validateSessionIntegrity(session: UploadSessionContext) -> SessionIntegrityReport
}
```

**Nonce management (fixing ReplayAttackPreventer bug):**
```swift
private var nonceCache: [(nonce: String, timestamp: Date)] = []
private let maxNonces = 10000
private let nonceWindow: TimeInterval = 120  // 2 minutes

func validateNonce(_ nonce: String, timestamp: Date) -> Bool {
    let now = Date()
    // Check timestamp freshness
    guard now.timeIntervalSince(timestamp) <= nonceWindow else { return false }
    // Check uniqueness
    guard !nonceCache.contains(where: { $0.nonce == nonce }) else { return false }
    // Record
    nonceCache.append((nonce: nonce, timestamp: now))
    // LRU eviction (NOT removeAll!)
    if nonceCache.count > maxNonces {
        // Sort by timestamp, remove oldest 20%
        nonceCache.sort { $0.timestamp < $1.timestamp }
        nonceCache.removeFirst(maxNonces / 5)
    }
    return true
}
```

---

## 5. NEW FILE: `Core/Upload/NetworkPathObserver.swift`

**Purpose:** Monitor network path changes using `NWPathMonitor` (Apple) or polling (Linux). Feeds events to KalmanBandwidthPredictor for process noise adaptation.

```
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-NETWORK-1.0
// Module: Upload Infrastructure - Network Path Observer
// Cross-Platform: macOS + Linux (pure Foundation, optional Network framework)
```

**Key features:**
1. Detects WiFi → Cellular handover (triggers Kalman Q 10x increase)
2. Detects Cellular → WiFi upgrade (triggers connection prewarming)
3. Monitors `isConstrained` (Low Data Mode) and `isExpensive` (cellular) flags
4. Tracks interface type changes (WiFi, cellular, wiredEthernet, loopback)
5. Publishes events via AsyncStream for all consumers

```swift
#if canImport(Network)
import Network

public actor NetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let pathStream: AsyncStream<NetworkPathEvent>
    private let pathContinuation: AsyncStream<NetworkPathEvent>.Continuation

    public struct NetworkPathEvent: Sendable {
        public let timestamp: Date
        public let interfaceType: InterfaceType
        public let isConstrained: Bool   // Low Data Mode
        public let isExpensive: Bool     // Cellular
        public let hasIPv4: Bool
        public let hasIPv6: Bool
        public let changeType: ChangeType
    }

    public enum ChangeType: Sendable {
        case initial
        case interfaceChanged(from: InterfaceType, to: InterfaceType)
        case constraintChanged
        case pathUnavailable
        case pathRestored
    }

    public enum InterfaceType: String, Sendable {
        case wifi, cellular, wiredEthernet, loopback, other, unknown
    }
}
#else
// Linux fallback: periodic /proc/net/dev polling
public actor NetworkPathObserver {
    // Poll /proc/net/dev every 5 seconds for interface changes
    // Detect interface up/down events
    // No constrained/expensive metadata available on Linux
}
#endif
```

**Integration points:**
- KalmanBandwidthPredictor subscribes to `pathStream` → adjust Q matrix on change
- ConnectionPrewarmer subscribes → prewarm new connection on interface upgrade
- UnifiedResourceManager subscribes → adjust battery strategy on cellular/WiFi

---

## 6. NEW FILE: `Core/Upload/UploadCircuitBreaker.swift`

**Purpose:** Circuit breaker pattern preventing cascade failures when server is unhealthy.

```
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-RESILIENCE-1.0
// Module: Upload Infrastructure - Circuit Breaker
// Cross-Platform: macOS + Linux (pure Foundation)
```

**States:** Closed (normal) → Open (failing) → Half-Open (testing)

```swift
public actor UploadCircuitBreaker {
    public enum State: Sendable {
        case closed      // Normal operation
        case open        // Blocking requests
        case halfOpen    // Testing with single request
    }

    private var state: State = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    private var failures: [(timestamp: Date, error: String)] = []

    /// Check if request is allowed
    public func canExecute() -> Bool {
        switch state {
        case .closed: return true
        case .open:
            // Check if enough time has passed to try half-open
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= UploadConstants.CIRCUIT_BREAKER_HALF_OPEN_INTERVAL {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true  // Allow single test request
        }
    }

    /// Record success
    public func recordSuccess() {
        switch state {
        case .halfOpen:
            successCount += 1
            if successCount >= UploadConstants.CIRCUIT_BREAKER_SUCCESS_THRESHOLD {
                state = .closed
                failureCount = 0
                successCount = 0
                failures.removeAll()
            }
        case .closed:
            // Reset consecutive failures on success
            failureCount = 0
        case .open:
            break
        }
    }

    /// Record failure
    public func recordFailure(error: String) {
        let now = Date()
        failures.append((timestamp: now, error: error))
        lastFailureTime = now

        // Remove old failures outside window
        failures = failures.filter {
            now.timeIntervalSince($0.timestamp) <= UploadConstants.CIRCUIT_BREAKER_WINDOW_SECONDS
        }

        failureCount = failures.count

        switch state {
        case .closed:
            if failureCount >= UploadConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD {
                state = .open
            }
        case .halfOpen:
            state = .open
            successCount = 0
        case .open:
            break
        }
    }

    /// Get circuit breaker status for telemetry
    public func getStatus() -> CircuitBreakerStatus {
        CircuitBreakerStatus(
            state: state,
            failureCount: failureCount,
            lastFailureTime: lastFailureTime
        )
    }
}
```

---

## 7. LAYER-BY-LAYER PRECISION FIXES

### 7.1 Layer 1: HybridIOEngine Additions

**Add: Compressibility detection refinement**
```
Current v1.0: Sample 32KB every 5MB → try LZFSE
Fix: Sample 32KB every 5MB → try BOTH LZ4 AND zstd level 1
- If LZ4 ratio < 0.75 AND zstd ratio < 0.60 → mark "highly compressible"
- If LZ4 ratio 0.75-0.95 → mark "moderately compressible"
- If LZ4 ratio > 0.95 → mark "incompressible"
- This dual-sampling costs <0.5ms extra per sample (LZ4 is ~4GB/s)
```

**Add: Read-ahead hint for sequential I/O**
```swift
// After open():
#if os(macOS) || os(iOS)
    fcntl(fd, F_RDAHEAD, 1)   // Enable read-ahead (macOS/iOS kernel hint)
    fcntl(fd, F_NOCACHE, 0)    // Allow caching (we DO want cache for re-reads)
#endif
```

**Add: File integrity check before each chunk read**
```swift
// Before reading chunk at offset:
var currentStat = stat()
fstat(fd, &currentStat)
guard currentStat.st_ino == initialStat.st_ino &&
      currentStat.st_dev == initialStat.st_dev &&
      currentStat.st_size == initialStat.st_size &&
      currentStat.st_mtimespec == initialStat.st_mtimespec else {
    throw IOError.fileModifiedDuringRead
}
```

### 7.2 Layer 2: KalmanBandwidthPredictor Additions

**Add: 2D fallback mode for constrained devices**
```
When UnifiedResourceManager reports Level 2+ degradation:
- Switch from 4D state [bw, d_bw, d2_bw, var] to 2D state [bw, d_bw]
- Reduces matrix operations from 4x4 to 2x2 (16x fewer multiplications)
- Still provides trend detection (rising/falling)
- Convergence is faster (3 samples vs 5)
```

**Add: Exponential Moving Average crosscheck**
```
Run simple EMA (alpha=0.3) in parallel with Kalman
If |kalman_estimate - ema_estimate| > 3 * ema_stddev:
    → Kalman may have diverged → reset P matrix to P0
    → Log anomaly for telemetry
This catches Kalman divergence from numerical instability
```

### 7.3 Layer 3: CIDMapper Additions

**Add: Content-defined chunking (CDC) preparation**
- While PR9 v1.0 uses fixed-boundary chunking, prepare the CIDMapper for future CDC:
- Add `ChunkBoundaryType` enum: `.fixed`, `.contentDefined(algorithm: .fastCDC)`
- Add `chunkFingerprint: UInt64` field to chunk metadata (for future dedup)
- The fingerprint is computed but NOT used for boundary decisions in v1.0
- This allows PR16 to enable CDC without modifying PR9's structure

### 7.4 Layer 4: StreamingMerkleTree Additions

**Add: Concurrent verification support**
```swift
/// Generate inclusion proof for a specific leaf
/// Used by ByzantineVerifier to prove chunk membership
public func generateInclusionProof(leafIndex: Int) -> InclusionProof? {
    // Returns sibling hashes from leaf to root
    // Proof size: O(log n) hashes
    // Verification: O(log n) hash computations
}

/// Verify an inclusion proof (static, stateless)
public static func verifyInclusionProof(
    proof: InclusionProof,
    leafHash: Data,
    rootHash: Data,
    totalLeaves: Int
) -> Bool {
    // Recompute root from leaf + proof
    // Compare with expected root (timing-safe)
}
```

**Add: Incremental root update notification**
```swift
/// AsyncStream of root hash updates
/// Emits new root after every carry merge
public var rootUpdates: AsyncStream<MerkleRootUpdate>

public struct MerkleRootUpdate: Sendable {
    public let leafCount: Int
    public let currentRoot: Data
    public let timestamp: Date
    public let isCheckpoint: Bool  // true if at checkpoint interval
}
```

### 7.5 Layer 5: ErasureCodingEngine Additions

**Add: Adaptive overhead calculation**
```
Instead of fixed RS parameters, calculate dynamically:
  n = k + ceil(k * loss_rate * safety_factor)
  where safety_factor = 2.0 (100% margin over measured loss rate)

  But cap: n <= k + ceil(k * MAX_OVERHEAD_PERCENT / 100)
  And floor: n >= k + 1 (always at least 1 parity symbol)
```

**Add: GF(2^8) lookup table initialization**
```swift
/// Pre-compute GF(2^8) multiplication tables at init
/// Uses AES-friendly irreducible polynomial: x^8 + x^4 + x^3 + x + 1 (0x11B)
/// Table size: 256 * 256 = 64KB (fits in L1 cache)
private let gfMulTable: [[UInt8]]  // gfMulTable[a][b] = a * b in GF(2^8)
private let gfExpTable: [UInt8]    // gfExpTable[i] = alpha^i
private let gfLogTable: [UInt8]    // gfLogTable[x] = log_alpha(x)
```

### 7.6 Layer 6: FusionScheduler Additions

**Add: Warmup phase (first 10 chunks)**
```
During warmup (first 10 chunks):
- Use ONLY EWMA controller (most stable, least data needed)
- Weight: EWMA=1.0, others=0.0
- Gradually introduce: chunk 5 → add Kalman, chunk 8 → add ABR, chunk 10 → add MPC
- This prevents MPC from making wild predictions with insufficient data
```

**Add: Hysteresis on chunk size changes**
```
Don't change chunk size for single-sample fluctuations:
- Must have ≥3 consecutive recommendations in same direction
- OR: new size differs by >30% from current (strong signal)
- Debounce interval: 2 seconds minimum between size changes
```

---

## 8. TESTING HARDENING

### 8.1 Test Coverage Requirements (2000+ checks)

Each test file must achieve minimum assertion counts:

| Test File | Min Assertions | Key Scenarios |
|-----------|---------------|---------------|
| ChunkedUploaderTests | 200 | Full lifecycle × 5 network conditions × 4 file sizes × 3 interrupt points = 60 scenarios, ~3 asserts each |
| HybridIOEngineTests | 150 | IO method selection × 3 platforms × 4 file sizes = 12, plus CRC32C correctness (50 vectors), SHA-256 (50 vectors), compressibility (20) |
| KalmanBandwidthPredictorTests | 120 | Convergence (20), anomaly detection (20), network switch (20), 2D fallback (20), edge cases (40) |
| StreamingMerkleTreeTests | 200 | Binary carry correctness (50 chunk counts), inclusion proofs (30), checkpoint (20), RFC 9162 (50 vectors), edge cases (50) |
| ChunkCommitmentChainTests | 100 | Forward chain (20), reverse verification (20), jump chain (20), tampering detection (20), session binding (20) |
| MultiLayerProgressTrackerTests | 150 | 4-layer consistency (40), monotonic (30), safety valves (30), smoothing (30), edge cases (20) |
| EnhancedResumeManagerTests | 120 | FileFingerprint (30), encryption round-trip (20), 3-level resume (30), migration (20), corruption (20) |
| FusionSchedulerTests | 150 | 4-theory fusion (40), Lyapunov stability (30), warmup phase (20), hysteresis (20), weight adaptation (40) |
| ErasureCodingEngineTests | 180 | RS encode/decode (50 block configs), GF arithmetic (50), RaptorQ fallback (20), UEP (30), SIMD correctness (30) |
| ProofOfPossessionTests | 100 | Challenge-response (30), anti-replay (20), partial chunk (20), timeout (10), edge cases (20) |
| ChunkIntegrityValidatorTests | 100 | Pre-upload validation (25), post-ACK (25), nonce (25), session integrity (25) |
| UploadCircuitBreakerTests | 80 | State transitions (30), timing (20), concurrent access (15), reset (15) |
| NetworkPathObserverTests | 50 | Path changes (20), event stream (15), graceful degradation on Linux (15) |

**Total: 1,700+ explicit assertions minimum, targeting 2,000+**

### 8.2 Fuzz Testing Requirements

```swift
// Add to each test file:
func testFuzz_randomInputs() {
    for _ in 0..<1000 {
        let randomData = Data((0..<Int.random(in: 1...10000)).map { _ in UInt8.random(in: 0...255) })
        // Feed to component, verify no crash
        // All errors must be caught, no force-unwraps
    }
}
```

### 8.3 Deterministic Test Seeds

All random-dependent tests must use `SeededRandomNumberGenerator`:
```swift
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
// Use: var rng = SeededRNG(state: 42) → reproducible results
```

### 8.4 Performance Benchmarks (XCTest Metrics)

```swift
func testPerformance_chunkedUpload100MB() {
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
        // Upload 100MB file in chunks
        // Assert: < 35 seconds on fast network simulation
        // Assert: peak memory < 50MB
        // Assert: CPU usage < 30% average
    }
}

func testPerformance_merkleTreeBuilding() {
    measure {
        // Build Merkle tree for 1000 chunks
        // Assert: < 100ms
    }
}

func testPerformance_kalmanConvergence() {
    measure {
        // Feed 100 samples, measure convergence time
        // Assert: reliable within 5 samples on stable input
    }
}
```

---

## 9. FUTURE-PROOFING ARCHITECTURE

### 9.1 Protocol Abstraction Layer

Create protocol interfaces that allow future replacement:

```swift
/// Protocol for bandwidth estimation (allows swapping Kalman for RL in future)
public protocol BandwidthEstimator: Sendable {
    func addSample(bytesTransferred: Int64, durationSeconds: TimeInterval)
    func predict() -> BandwidthPrediction
    func reset()
}

/// Protocol for integrity verification (allows swapping Merkle for Verkle in future)
public protocol IntegrityTree: Sendable {
    func appendLeaf(_ data: Data) async
    var rootHash: Data { get async }
    func generateProof(leafIndex: Int) async -> [Data]?
    static func verifyProof(leaf: Data, proof: [Data], root: Data, index: Int, totalLeaves: Int) -> Bool
}

/// Protocol for erasure coding (allows swapping RS for fountain codes in future)
public protocol ErasureCoder: Sendable {
    func encode(data: [Data], redundancy: Double) -> [Data]
    func decode(blocks: [Data?], originalCount: Int) throws -> [Data]
}

/// Protocol for resource management (allows platform-specific implementations)
public protocol ResourceManager: Sendable {
    func getThermalBudget() -> ThermalBudget
    func getMemoryAvailable() -> UInt64
    func getBatteryLevel() -> Double?
    func shouldPauseUpload() -> Bool
}
```

### 9.2 Feature Flags for Gradual Rollout

```swift
public enum PR9FeatureFlags {
    /// Use Kalman bandwidth prediction (vs simple EWMA)
    public static var useKalmanPredictor: Bool = true

    /// Enable Byzantine verification
    public static var enableByzantineVerification: Bool = true

    /// Enable erasure coding
    public static var enableErasureCoding: Bool = false  // Off by default in v1.0

    /// Enable Proof-of-Possession (instant upload)
    public static var enableProofOfPossession: Bool = false  // Off by default

    /// Enable 4-theory fusion scheduler (vs EWMA-only)
    public static var enableFusionScheduler: Bool = true

    /// Enable circuit breaker
    public static var enableCircuitBreaker: Bool = true

    /// Enable content-defined chunking preparation
    public static var enableCDCPreparation: Bool = false  // Future PR16

    /// Maximum degradation level (0-4)
    public static var maxDegradationLevel: Int = 4
}
```

### 9.3 Versioned Wire Protocol

```swift
public enum PR9WireProtocol {
    /// Current protocol version sent in X-Upload-Protocol header
    public static let version = "PR9/2.0"

    /// Minimum server protocol version for full features
    public static let minServerVersion = "PR9/1.0"

    /// Feature negotiation: client sends capabilities, server responds with supported subset
    public static let capabilities: Set<String> = [
        "chunked-upload",
        "merkle-verification",
        "commitment-chain",
        "proof-of-possession",
        "erasure-coding",
        "multi-layer-progress",
        "byzantine-verification"
    ]
}
```

### 9.4 WebTransport Ready

Prepare architecture for future WebTransport migration:
- All transport calls go through `TransportLayer` protocol
- Current implementation: URLSession (HTTP/2)
- Future: WebTransport (HTTP/3 + QUIC) — drop-in replacement
- Key benefit: 0-RTT, connection migration, no head-of-line blocking

```swift
public protocol TransportLayer: Sendable {
    func sendChunk(data: Data, metadata: ChunkMetadata) async throws -> ChunkACK
    func openStream() async throws -> UploadStream
    func closeStream() async throws
    var isConnected: Bool { get }
}
```

### 9.5 Post-Quantum Cryptography Preparation

- SHA-256 is quantum-resistant for hashing (Grover's provides only 2^128 → still secure)
- HMAC-SHA-256 is quantum-resistant for authentication
- **Future concern:** If using ECDH for PoP encrypted channel, need hybrid approach
- **Preparation:** Add `CryptoSuite` enum that allows future algorithm upgrades:

```swift
public enum CryptoSuite: String, Sendable {
    case v1_classical = "v1"   // SHA-256 + AES-GCM + ECDH (current)
    case v2_hybrid = "v2"      // SHA-256 + AES-GCM + X25519Kyber768 (future)
}
```

---

## 10. PR5↔PR9 FUSION TIGHTENING

### 10.1 Quality Gate Refinement

Expand quality gate mapping with explicit thresholds:

```
PR5 Quality Score | PR9 Priority | RS Redundancy | Upload Timing
-----------------|-------------|---------------|---------------
> 0.95 (exceptional) | 0 (CRITICAL) | 3.0x | Immediate (preempt)
0.85 - 0.95 (high) | 1 (HIGH) | 2.5x | Next available slot
0.60 - 0.85 (normal) | 2 (NORMAL) | 1.5x | Normal queue
0.30 - 0.60 (low) | 3 (LOW) | 1.0x | Deferred (after all normal)
< 0.30 (rejected) | 5 (DEFERRED) | 0.5x | Background WiFi only
```

### 10.2 Frame Dependency Graph

Upload order should respect frame dependencies for incremental rendering:
```
1. First: camera intrinsics + IMU calibration (required for ANY reconstruction)
2. Then: keyframes with highest quality scores (sparse SfM input)
3. Then: keyframes in temporal order (dense MVS)
4. Then: non-keyframes in temporal order (refinement)
5. Last: rejected/low-quality frames (gap-filling)
```

### 10.3 Backpressure Mechanism

When upload queue is full (>50 chunks pending):
1. Signal PR5CapturePipeline to reduce frame acceptance rate
2. Lower quality threshold from 0.6 to 0.8 (only accept high-quality frames)
3. This prevents OOM from unbounded queue growth during capture

When upload queue drains below 10 chunks:
4. Restore normal quality threshold
5. Process any deferred frames from backpressure period

### 10.4 Upload-Triggered Render Notifications

Add structured notifications for server-side rendering:
```swift
public enum RenderTriggerEvent: Sendable {
    case sparseSfMReady(keyFrameCount: Int, intrinsicsReceived: Bool, imuSegments: Int)
    case denseMVSReady(keyFramePercentage: Double, coverageEstimate: Double)
    case refinementReady(totalFrames: Int, merkleRootVerified: Bool)
    case incrementalUpdate(newChunksVerified: Int, totalVerified: Int)
}
```

---

## 11. GUARDRAILS AND SAFETY VALVES

### 11.1 Resource Consumption Limits

```swift
/// Hard limits to prevent any single upload from consuming excessive resources
public enum PR9ResourceLimits {
    /// Maximum memory for upload buffers (excludes OS overhead)
    static let maxUploadMemoryMB: Int = 128  // On 4GB device, leaves 3.9GB

    /// Maximum CPU usage target for upload (percentage)
    static let maxUploadCPUPercent: Int = 25  // Leaves 75% for capture + render

    /// Maximum disk space for temporary files (resume snapshots + partial chunks)
    static let maxTempDiskMB: Int = 512

    /// Maximum number of in-flight chunks (across all sessions)
    static let maxInFlightChunks: Int = 24  // 6 parallel × 4 sessions max

    /// Maximum telemetry buffer entries (before auto-flush)
    static let maxTelemetryEntries: Int = 1000

    /// Maximum nonce cache entries (before LRU eviction)
    static let maxNonceCacheEntries: Int = 10000
}
```

### 11.2 Automatic Degradation Triggers

| Metric | Level 1 Trigger | Level 2 Trigger | Level 3 Trigger | Level 4 Trigger |
|--------|----------------|----------------|----------------|----------------|
| Available Memory | < 200MB | < 100MB | < 50MB | < 30MB |
| Thermal State | .fair | .serious | .critical | .critical + rising |
| Battery Level | < 30% | < 15% | < 5% | < 3% |
| Upload Failures | 3 in 60s | 5 in 60s | Circuit open | Circuit open + retry budget exhausted |
| Network Speed | < 1 Mbps | < 500 Kbps | < 100 Kbps | No connectivity |

### 11.3 Recovery Protocol

After degradation, recovery requires ALL of:
1. Triggering metric improved by at least 20% above threshold (hysteresis)
2. Stability: metric stayed improved for 30 seconds
3. No new triggers firing

---

## 12. COMPETITIVE EDGE DIFFERENTIATORS

### 12.1 What We Do That Nobody Else Does

| Feature | Aether3D PR9 | Polycam | Luma AI | Apple Object Capture | tus.io |
|---------|-------------|---------|---------|---------------------|--------|
| 6-Layer Architecture | ✅ | ❌ | ❌ | ❌ | ❌ |
| 4-Theory Fusion Scheduling | ✅ | ❌ | ❌ | ❌ | ❌ |
| Kalman Bandwidth Prediction | ✅ | ❌ | ❌ | ❌ | ❌ |
| Streaming Merkle Verification | ✅ | ❌ | ❌ | ❌ | ❌ |
| Commitment Chain | ✅ | ❌ | ❌ | ❌ | ❌ |
| Byzantine Server Verification | ✅ | ❌ | ❌ | ❌ | ❌ |
| Erasure Coding with UEP | ✅ | ❌ | ❌ | ❌ | ❌ |
| Proof-of-Possession | ✅ | ❌ | ❌ | ❌ | ❌ |
| Circuit Breaker Pattern | ✅ | ❌ | ❌ | ❌ | ❌ |
| Unified Thermal/Battery/Memory | ✅ | Partial | ❌ | Partial | ❌ |
| Capture→Upload→Render Fusion | ✅ | ❌ | Partial | ❌ | ❌ |
| 4-Layer Progress Model | ✅ | ❌ | ❌ | ❌ | ❌ |
| 89 Security Hardening Items | ✅ | Unknown | Unknown | Apple-managed | ❌ |
| Content-Defined Chunking Prep | ✅ | ❌ | ❌ | ❌ | ❌ |
| Post-Quantum Ready | ✅ | ❌ | ❌ | ❌ | ❌ |

### 12.2 Benchmarks vs. Industry

| Metric | Industry Average | Best in Class (tus.io) | Aether3D PR9 Target |
|--------|-----------------|----------------------|-------------------|
| First byte latency | 2-5s | 500ms | 150ms (prewarming) |
| Resume recovery time | 5-30s | 2s | <2s (3-level resume) |
| Progress accuracy | ±10-15% | ±5% | ±1% (4-layer Kalman) |
| Disconnect recovery | Restart/manual | Resume from last chunk | Auto <2s + verify chain |
| Security measures | 5-10 | 15-20 | 89 items |
| Attack surface coverage | 20-40% | 60% | 98%+ |
| Weak network (3G) support | Often fails | Retry-based | Adaptive + FEC + CDC-ready |

---

## IMPLEMENTATION ORDER FOR THIS PATCH

1. **First:** Apply Constants changes (Section 2) to UploadConstants.swift
2. **Second:** Create ChunkIntegrityValidator.swift (Section 4)
3. **Third:** Create NetworkPathObserver.swift (Section 5)
4. **Fourth:** Create UploadCircuitBreaker.swift (Section 6)
5. **Fifth:** Apply Layer fixes (Section 7) to all 12 existing PR9 files
6. **Sixth:** Add protocol abstractions (Section 9.1) to ChunkedUploader.swift
7. **Seventh:** Add feature flags (Section 9.2)
8. **Eighth:** Apply PR5 fusion tightening (Section 10)
9. **Ninth:** Add guardrails (Section 11)
10. **Last:** Write all tests (Section 8) — 2000+ assertions

**Total new files: 3 (ChunkIntegrityValidator, NetworkPathObserver, UploadCircuitBreaker)**
**Total files from v1.0: 16**
**Grand total PR9 files: 19**

---

## FINAL VERIFICATION CHECKLIST

Before considering PR9 complete, verify:

- [ ] All 89 security items addressed (58 from v1.0 + 31 from this patch)
- [ ] All 79 constants correctly set (56 from v1.0 + 23 from this patch, with 6 corrections)
- [ ] All 19 files compile without warnings
- [ ] All 13 test files pass with 2000+ assertions
- [ ] `swift build` succeeds on macOS and Linux
- [ ] No force-unwraps (`!`) outside of FATAL_OK-annotated lines
- [ ] No `print()` calls (use structured logging only)
- [ ] All public APIs have `///` doc comments
- [ ] All actor types are actually needed (don't use actor for stateless computation)
- [ ] Feature flags allow disabling any PR9 feature without breaking compilation
- [ ] Protocol abstractions are implemented for all swappable components
- [ ] Compile-time validations cover all constant relationships
- [ ] Memory usage stays under PR9ResourceLimits.maxUploadMemoryMB
- [ ] ReplayAttackPreventer bug is NOT present in any PR9 code (LRU, never removeAll)
- [ ] URLSession is created ONCE and reused (not per-request)
- [ ] Mbps calculation uses SI (1,000,000), not binary (1,048,576)
