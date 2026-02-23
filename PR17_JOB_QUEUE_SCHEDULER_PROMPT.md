# PR#17: Job Queue Scheduler — Implementation Prompt

## Contract Version: PR17-JQS-2.0 (Cloud-First)
## Phase: 3 | Estimated Time: 12h
## Branch: `pr17/job-queue-scheduler`

---

## 0. Design Philosophy

**性能极致，不做伪保护。App是用户的工具，不是用户的保姆。**

- 不做热状态门控、不做电量门控、不做性能阉割。
- 真正的保护只有一种：**保护数据不丢失**（WAL崩溃恢复 + 上传断点续传）。
- 内存管理的目的是释放空间让上传跑得更快，不是阻止任务运行。

**但要限制合理的排队数量** — 一个用户不能一口气排100个任务。
不是为了「保护设备」，是因为这不合理：100个素材占几十GB服务器存储，
最后一个可能要等很久。用户的合理使用模式是：1个正在处理 + 最多2个排队。

---

## 1. Deployment Architecture — 云端渲染，端侧调度

**核心定位：S5级别的3D重建必须在云端GPU服务器上完成。**
手机Metal GPU的算力不足以达到S5品质。云端渲染是产品目标，不是"未来选项"。

**架构模型**：
```
┌─ 手机端 (Client) ─────────┐       ┌─ 云端服务器 (Server) ──────┐
│ 1. 拍摄素材                │       │ GPU集群 (NVIDIA A100/H100)  │
│ 2. 本地排队管理             │  ──→  │ 接收素材 → 3D重建 → 返回模型 │
│ 3. 上传素材到服务器          │       │ 全局任务调度                │
│ 4. 接收渲染结果             │  ←──  │ 渲染完成 → 推送结果          │
└────────────────────────────┘       └────────────────────────────┘
```

**这意味着**：
- **手机端（本PR实现）**：本地排队 + 上传管理 + 状态同步 + 等待时间预测
- **服务器端（需另租/搭建）**：GPU渲染 + 全局调度 + 多用户队列管理
- 排队有两层：①用户本地的提交队列（1+2=3），②服务器的全局处理队列

**`SchedulerMode`** 控制当前运行模式：

```swift
/// 调度器运行模式
public enum SchedulerMode: String, Codable, Sendable {
    /// 云端渲染（主要模式）：素材上传到服务器，服务器GPU处理
    /// 手机端负责：排队管理、上传、状态轮询、结果下载
    case cloudServer

    /// 端侧处理（离线/降级模式）：当服务器不可达时，本地Metal GPU处理
    /// 品质降级：S3级别（手机算力限制）
    case onDevice
}
```

**关于服务器**：
- 是的，云端渲染**一定需要**一台有GPU的服务器（或云GPU实例）
- 推荐：AWS `g5.xlarge`（NVIDIA A10G）或 `p4d.24xlarge`（A100），
  阿里云 `ecs.gn7i`，Google Cloud `a2-highgpu`
- 服务器端的全局调度逻辑不在本PR范围内（那是服务端工程），
  但本PR定义好客户端与服务器的**接口协议**
- 本PR的核心是：**客户端排队系统 + 云端通信协议**

**全球用户，双区域部署（中国数据合规）**：

中国法律要求（网络安全法、数据安全法、个人信息保护法）：
**中国用户的个人信息必须存储在中国境内。** 数据出境需要合规路径。

因此不能用"全球一个GPU集群"的简单方案。必须**双区域**：

```
┌─ 中国区域（阿里云/腾讯云 大陆机房）──────────────────┐
│  • 中国用户数据存储（OSS）                            │
│  • GPU渲染集群（阿里云 gn7i / 腾讯云 GN10X）          │
│  • 中国区任务队列                                     │
│  • CDN下发（阿里CDN 大陆2300+节点）                   │
│  • ICP备案 + 网安等保                                 │
│                                                       │
│  中国用户 → 直连 → 阿里云 → 中国区GPU → 阿里CDN       │
└───────────────────────────────────────────────────────┘

┌─ 国际区域（AWS us-east / GCP / 阿里云海外）───────────┐
│  • 国际用户数据存储                                    │
│  • GPU渲染集群（NVIDIA A100）                         │
│  • 国际区任务队列                                     │
│  • CDN下发（CloudFront / Cloudflare）                 │
│                                                       │
│  美国/全球用户 → 边缘PoP → AWS → GPU → CDN            │
└───────────────────────────────────────────────────────┘
```

**关键合规要求**：
- 中国用户扫描数据**不出境**：上传到阿里云大陆机房，在大陆GPU渲染，结果存大陆OSS
- 国际用户数据存国际区域，不受中国法律约束
- 客户端通过 `ServerRegion` 自动路由：中国IP→中国区API，其他→国际区API
- 两个区域各自有独立的任务队列，互不干扰
- 需要 ICP备案 + 中国法人实体（WFOE 或合资）才能在中国App Store上架
- 如果扫描涉及人脸：属于**敏感个人信息**，需单独同意 + 个人信息影响评估（PIA）

**上架中国App Store的硬性要求**：
- ICP备案号（Apple 2024年起强制）
- 中国大陆服务器托管
- 中国法人实体

**合规分级**（按用户量，2024.3新规）：
| 中国用户量 | 合规要求 |
|-----------|---------|
| < 10万/年（非敏感数据）| **豁免**安全评估/标准合同，但需告知同意 + PIA |
| 10万-100万 | 需签标准合同（SCC）或获得认证 |
| > 100万 | 必须CAC安全评估 |
| 涉及人脸 > 1万人 | 必须安全评估（不论总量）|

```swift
/// 服务器区域路由
public enum ServerRegion: String, Codable, Sendable {
    /// 中国大陆（阿里云/腾讯云 大陆机房）
    /// 数据不出境，符合网络安全法/PIPL
    case china          // api-cn.aether3d.com

    /// 国际区域（AWS/GCP/阿里云海外）
    case international  // api.aether3d.com
}
```

---

## 2. Architecture — Client Queue + Cloud Rendering Pipeline

```
┌─ iOS/macOS App (Client) ──────────────────────────────────────┐
│                                                                │
│  ┌──────────────────────────────────────────────────────┐     │
│  │              JobScheduler (actor)                     │     │
│  │  mode: .cloudServer                                   │     │
│  │                                                       │     │
│  │  ┌──────────┐  ┌──────────────────┐  ┌───────────┐  │     │
│  │  │ FIFOQueue│  │WaitTimeEstimator │  │UploadMgr  │  │     │
│  │  │ max: 1+2 │  │(EMA + server ETA)│  │(chunked)  │  │     │
│  │  │ =3 slots │  │                  │  │           │  │     │
│  │  └──────────┘  └──────────────────┘  └───────────┘  │     │
│  │                                                       │     │
│  │  ┌────────────────┐  ┌──────────────┐                │     │
│  │  │TimeoutWatchdog │  │RecoveryManager│                │     │
│  │  │(actor)         │  │(WAL-based)   │                │     │
│  │  └────────────────┘  └──────────────┘                │     │
│  │                                                       │     │
│  │  ┌────────────────┐  ┌──────────────────┐            │     │
│  │  │MemoryOptimizer │  │CloudAPIClient    │            │     │
│  │  │(cache cleanup) │  │(server protocol) │            │     │
│  │  └────────────────┘  └──────────────────┘            │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ Existing Core/Jobs/*                                  │     │
│  │ (JobStateMachine, EventStore, CircuitBreaker,         │     │
│  │  RetryCalculator, DLQ, ProgressEstimator)             │     │
│  └──────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────┘
            │ HTTPS/WebSocket │
            ▼                 ▲
┌─ Cloud Server (NOT in this PR, but interface defined) ────────┐
│  Receives uploads → GPU render → returns 3D model             │
│  Global queue across all users                                 │
│  POST /api/v1/jobs/submit    → accept upload                  │
│  GET  /api/v1/jobs/{id}      → status + progress              │
│  GET  /api/v1/jobs/{id}/eta  → server-side wait estimate      │
│  GET  /api/v1/jobs/{id}/result → download rendered model      │
│  DELETE /api/v1/jobs/{id}    → cancel                         │
│  WS   /api/v1/jobs/{id}/stream → real-time progress push     │
└────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
1. **1 processing + 2 pending = 3 total slots per user.** Hard product limit (client-side enforcement).
2. **Cloud-first**: Primary mode is `.cloudServer` — upload scan data, server renders, download result.
3. **On-device fallback**: When server unreachable, degrade to `.onDevice` (S3 quality, local Metal).
4. **UploadManager**: Chunked upload with resume support. Scan data can be 200MB-1GB.
5. **CloudAPIClient**: Protocol-based server communication. Defines the API contract this PR expects.
6. **WaitTimeEstimator**: Merges local EMA statistics with server-reported ETA for accuracy.
7. **MemoryOptimizer**: Frees caches to speed up uploads and keep app responsive. Never blocks.

---

## 3. File Structure

```
Server/
└── queue/
    ├── JobScheduler.swift          # Main orchestrator (actor)
    ├── FIFOQueue.swift             # Thread-safe FIFO data structure
    ├── WaitTimeEstimator.swift     # EMA-based processing time prediction
    ├── TimeoutWatchdog.swift       # Timeout monitoring & kill stuck jobs
    ├── RecoveryManager.swift       # Crash recovery & WAL replay
    ├── MemoryOptimizer.swift       # Proactive cache cleanup (NOT a gate)
    ├── UploadManager.swift         # Chunked upload with resume (cloud mode)
    ├── CloudAPIClient.swift        # Server communication protocol & impl
    ├── CloudAPIProtocol.swift      # Protocol defining server API contract
    ├── SchedulerConstants.swift    # PR17-specific constants
    └── SchedulerError.swift        # PR17-specific errors
```

Add to `Package.swift`:
- New library product `Aether3DScheduler`
- New target with path `Server/queue`, dependency on `Aether3DCore`
- New test target `SchedulerTests` at `Tests/Scheduler/`

---

## 4. Key Constants

```swift
public enum SchedulerConstants {
    // ═══ Queue Slots — THE critical product decision ═══

    /// Per-user concurrent processing slots (client-side enforcement).
    /// Cloud mode: 1 job rendering on server at a time per user.
    /// Server may run N users' jobs in parallel, but each user sees "1 processing".
    public static let CONCURRENT_PROCESSING_PER_USER = 1

    /// Maximum pending (waiting) jobs per user.
    /// WHY 2: User scans Object A (uploading/processing), then scans B and C (queued).
    /// That's a natural workflow. 3 pending = user hoarding = not realistic.
    /// Each pending job holds raw scan data (~200-500MB on phone). 2 pending = 1GB max local temp storage.
    public static let MAX_PENDING_PER_USER = 2

    /// Total client-side queue capacity per user = processing + pending
    /// 1 + 2 = 3 jobs max per user at any time
    public static let TOTAL_QUEUE_CAPACITY = CONCURRENT_PROCESSING_PER_USER + MAX_PENDING_PER_USER

    // ═══ Cloud Upload ═══

    /// Upload chunk size: 5MB
    /// WHY 5MB: Balances upload resume granularity vs HTTP overhead.
    /// On failure, lose at most 5MB of progress. Mobile networks are unreliable.
    public static let UPLOAD_CHUNK_SIZE_BYTES: Int = 5 * 1024 * 1024

    /// Max concurrent upload chunks: 3
    /// WHY 3: Saturates typical LTE/5G uplink without starving other network traffic.
    public static let UPLOAD_MAX_CONCURRENT_CHUNKS = 3

    /// Upload timeout per chunk: 60 seconds
    /// WHY 60s: 5MB on a slow 1Mbps connection = 40s. Give 50% headroom.
    public static let UPLOAD_CHUNK_TIMEOUT_SECONDS: TimeInterval = 60.0

    /// Upload retry count per chunk
    public static let UPLOAD_CHUNK_MAX_RETRIES = 3

    // ═══ Timeouts ═══

    /// Server-side processing timeout: 30 minutes (client-side watchdog)
    /// WHY 30min: S5-quality reconstruction with 1000+ frames on A100 can take 20min.
    /// Client monitors server heartbeat. If no progress in 30min → mark as timed out.
    public static let PROCESSING_TIMEOUT_SECONDS: TimeInterval = 30 * 60

    /// Pending TTL: 72 hours
    /// WHY 72h: User scans Friday night, doesn't reopen app until Monday.
    /// Don't punish users for having a life. After 72h, silently expire pending (not-yet-uploaded) jobs.
    public static let PENDING_TTL_SECONDS: TimeInterval = 72 * 60 * 60

    /// Watchdog tick: 5 seconds (cloud mode checks server status)
    /// WHY 5s: Server-side polling. 3s was for on-device; server network round-trip needs margin.
    public static let WATCHDOG_TICK_INTERVAL_SECONDS: TimeInterval = 5.0

    /// Grace period after timeout: 30 seconds
    /// WHY 30s: Give server 30s to return partial results before marking failed.
    public static let TIMEOUT_GRACE_PERIOD_SECONDS: TimeInterval = 30.0

    // ═══ Server Polling / WebSocket ═══

    /// Status poll interval when WebSocket unavailable: 5 seconds
    public static let STATUS_POLL_INTERVAL_SECONDS: TimeInterval = 5.0

    /// WebSocket heartbeat interval: 15 seconds
    public static let WS_HEARTBEAT_INTERVAL_SECONDS: TimeInterval = 15.0

    /// WebSocket reconnect backoff base: 2 seconds
    public static let WS_RECONNECT_BASE_SECONDS: TimeInterval = 2.0

    /// WebSocket reconnect max delay: 60 seconds
    public static let WS_RECONNECT_MAX_SECONDS: TimeInterval = 60.0

    // ═══ Memory Optimizer (enabler, not gate) ═══

    /// Trigger cache cleanup when used memory exceeds 70%
    /// This does NOT block the job. It frees space so UPLOAD runs better.
    public static let MEMORY_CLEANUP_TRIGGER_PERCENT: Double = 0.70

    /// Aggressive cleanup at 85%: drop ALL non-essential caches
    public static let MEMORY_AGGRESSIVE_CLEANUP_PERCENT: Double = 0.85

    /// Trigger temp file cleanup when disk space below 200MB
    /// Clean old WAL files, previous scan artifacts. NOT block new scans.
    public static let DISK_CLEANUP_TRIGGER_BYTES: UInt64 = 200 * 1024 * 1024

    // ═══ Recovery ═══

    /// WAL flush interval: 2 seconds
    /// Crash loses at most 2s of state. SSD write of one JSON line is <1ms.
    public static let WAL_FLUSH_INTERVAL_SECONDS: TimeInterval = 2.0

    /// Max WAL entries before compaction
    public static let WAL_MAX_ENTRIES = 10000

    /// Stale job threshold after app restart: varies by mode
    /// On-device: 10 minutes (app died → job died).
    /// Cloud: check server — job may still be running on server.
    public static let RECOVERY_STALE_ONDEVICE_SECONDS: TimeInterval = 600.0

    // ═══ On-Device Fallback ═══

    /// On-device processing timeout (lower quality, longer per frame)
    public static let ONDEVICE_PROCESSING_TIMEOUT_SECONDS: TimeInterval = 30 * 60

    /// On-device watchdog tick: 3 seconds (local, no network)
    public static let ONDEVICE_WATCHDOG_TICK_SECONDS: TimeInterval = 3.0

    // ═══ UI ═══

    /// Min interval between status stream updates
    public static let STATUS_THROTTLE_INTERVAL_SECONDS: TimeInterval = 0.5

    // ═══ Version ═══
    public static let SCHEDULER_VERSION = "PR17-JQS-2.0"
}
```

### Queue Slot Rationale

| Scenario | Processing/User | Pending/User | Total/User | Why |
|----------|----------------|-------------|-----------|-----|
| **Cloud (primary)** | 1 (server GPU) | 2 (local queue) | 3 | Natural workflow: upload→render→scan next→scan one more |
| **On-device (fallback)** | 1 (local Metal) | 2 | 3 | Same limit, lower quality (S3 vs S5) |

**Why exactly 2 pending, not 3 or 5?**
- Local storage: each pending job holds raw scan data. 200-500MB × 2 = up to 1GB. Manageable.
- 200-500MB × 5 = 2.5GB. On a 64GB iPhone with photos/apps, that's aggressive.
- Upload bandwidth: 3 pending jobs = 1.5GB to upload. On LTE that's 30+ minutes.
- UX: 3rd pending job would wait behind 2 uploads + 2 renders. User will forget they queued it.
- If user really needs more: finish one, queue another. The limit encourages finishing work.

---

## 5. Core Implementations

### 5.1 FIFOQueue.swift (unchanged from v1 — queue logic is mode-agnostic)

```swift
/// Thread-safe FIFO queue with hard capacity limit.
/// Actor-based for Swift 6.2 Sendable compliance.
///
/// Capacity: TOTAL_QUEUE_CAPACITY (1 processing + 2 pending = 3)
/// When full: throw SchedulerError.queueFull(currentCount:maxCapacity:)
/// User sees: "你已经有2个任务在排队了，请等一个完成后再提交"
public actor FIFOQueue<Element: Sendable & Identifiable> where Element.ID: Hashable {
    private var storage: [Element] = []
    private var cancelledIds: Set<Element.ID> = []
    private var ttlMap: [Element.ID: Date] = [:]
    private let maxCapacity: Int

    public init(maxCapacity: Int = SchedulerConstants.TOTAL_QUEUE_CAPACITY) {
        self.maxCapacity = maxCapacity
    }

    /// Enqueue job. Throws if queue is at capacity.
    public func enqueue(_ element: Element, ttl: TimeInterval) throws { ... }

    /// Dequeue next non-cancelled, non-expired job. Returns nil if empty.
    public func dequeue() -> Element? { ... }

    /// Cancel by ID (O(1) via set lookup)
    public func cancel(id: Element.ID) { ... }

    /// Current count of active (non-cancelled, non-expired) jobs
    public var activeCount: Int { ... }

    /// Is queue at capacity?
    public var isFull: Bool { activeCount >= maxCapacity }
}
```

### 5.2 CloudAPIProtocol.swift & CloudAPIClient.swift

```swift
/// Protocol defining the server API contract.
/// This is the INTERFACE that PR17 depends on. Server implementation is separate.
/// Using a protocol so we can mock the server in tests.
public protocol CloudAPIProtocol: Sendable {
    /// Submit scan data for cloud rendering.
    func submitJob(_ request: CloudSubmitRequest) async throws -> CloudSubmitResponse
    /// Upload a chunk of scan data (multipart, resumable).
    func uploadChunk(jobId: String, chunkIndex: Int, data: Data) async throws -> ChunkUploadResponse
    /// Query job status from server.
    func getJobStatus(jobId: String) async throws -> CloudJobStatus
    /// Get server-side ETA estimate (accounts for global queue position).
    func getServerETA(jobId: String) async throws -> ServerETAResponse
    /// Download rendered 3D model (URL points to CDN edge, not origin).
    func downloadResult(jobId: String) async throws -> URL
    /// Cancel a job on the server.
    func cancelJob(jobId: String) async throws
    /// Open WebSocket for real-time progress stream.
    func openProgressStream(jobId: String) -> AsyncStream<CloudProgressEvent>
}

public struct CloudSubmitRequest: Sendable, Codable {
    public let clientJobId: String
    public let frameCount: Int
    public let resolution: String           // "1080p", "4K"
    public let totalBytes: UInt64           // total scan data size
    public let qualityLevel: String         // "S5" — the whole point of cloud
}

public struct CloudSubmitResponse: Sendable, Codable {
    public let serverJobId: String
    public let uploadURL: String            // region-specific upload endpoint:
                                            // China user  → cn-upload.aether3d.com (阿里云OSS大陆，数据不出境)
                                            // Global user → us-upload.aether3d.com (S3/R2 with edge acceleration)
    public let uploadRegion: String         // "cn-shanghai", "us-east", "sg" — transparency
    public let chunkSize: Int               // server-preferred chunk size
    public let estimatedQueuePosition: Int  // global position across all users
    public let estimatedWaitSeconds: TimeInterval
}

public struct CloudJobStatus: Sendable, Codable {
    public let serverJobId: String
    public let state: String                // "queued", "rendering", "packaging", "completed", "failed"
    public let progress: Double             // 0.0 - 1.0
    public let globalQueuePosition: Int?    // nil if already rendering
    public let estimatedRemainingSeconds: TimeInterval?
}

public struct CloudProgressEvent: Sendable, Codable {
    public let serverJobId: String
    public let progress: Double
    public let stage: String                // "uploading", "queued", "rendering", "packaging"
    public let message: String?             // "正在渲染第234/1000帧"
    public let estimatedRemainingSeconds: TimeInterval?
}

/// REST API endpoints the server must implement:
///   POST /api/v1/jobs/submit         → CloudSubmitResponse
///   PUT  /api/v1/jobs/{id}/chunks/{n} → ChunkUploadResponse
///   GET  /api/v1/jobs/{id}           → CloudJobStatus
///   GET  /api/v1/jobs/{id}/eta       → ServerETAResponse
///   GET  /api/v1/jobs/{id}/result    → binary download
///   DELETE /api/v1/jobs/{id}         → 204
///   WS   /api/v1/jobs/{id}/stream    → CloudProgressEvent stream

/// Concrete implementation using URLSession.
/// Initialized with a ServerRegion to determine base URL.
public actor CloudAPIClient: CloudAPIProtocol {
    private let baseURL: URL              // region-specific
    private let region: ServerRegion      // .china or .international
    private let session: URLSession
    // URLSessionWebSocketTask for progress streaming

    /// Factory: create client for the correct region based on user locale/IP
    public static func forCurrentUser() -> CloudAPIClient {
        // 1. Check device locale (zh_CN → .china)
        // 2. Optionally: call geo-IP endpoint for confirmation
        // 3. Return client with correct baseURL
    }
}

/// Region-specific API base URLs
extension ServerRegion {
    public var apiBaseURL: URL {
        switch self {
        case .china:         return URL(string: "https://api-cn.aether3d.com/api/v1")!
        case .international: return URL(string: "https://api.aether3d.com/api/v1")!
        }
    }
}
```

### 5.3 UploadManager.swift

```swift
/// Manages chunked, resumable uploads of scan data to cloud server.
/// Automatically routes to nearest edge node for upload acceleration.
///
/// Key features:
///   - Splits scan data into 5MB chunks
///   - Uploads 3 chunks concurrently (saturate uplink)
///   - Edge-aware: uploads to nearest PoP, not directly to origin
///     (e.g., China user → Hong Kong edge → backbone → US storage)
///   - Resume on failure: tracks which chunks are done via WAL
///   - Retries failed chunks 3 times with exponential backoff
///   - Reports upload progress to UI
///
/// Upload lifecycle:
///   1. resolveUploadEndpoint() → server returns nearest edge URL
///      (e.g., presigned R2/S3 URL with acceleration)
///   2. prepareUpload(jobId, scanDataURL) → split into chunks
///   3. startUpload() → concurrent chunk upload to edge endpoint
///   4. On chunk fail → retry with backoff (RetryCalculator reuse)
///   5. All chunks done → notify server "upload complete"
///   6. On app crash → WAL has chunk progress → resume where left off
///
/// The upload URL is provided by CloudAPIProtocol.submitJob() response.
/// Server decides which edge endpoint to use based on client IP geo.
public actor UploadManager {
    private let apiClient: any CloudAPIProtocol
    public let progressStream: AsyncStream<UploadProgress>

    public func prepareUpload(jobId: String, scanDataURL: URL) async throws -> UploadPlan
    public func startUpload(_ plan: UploadPlan) async throws
    public func resumeUpload(jobId: String) async throws  // after crash recovery
    public func cancelUpload(jobId: String) async
}

public struct UploadProgress: Sendable {
    public let jobId: String
    public let bytesUploaded: UInt64
    public let totalBytes: UInt64
    public let chunksCompleted: Int
    public let totalChunks: Int
    public let estimatedRemainingSeconds: TimeInterval?
    public let uploadRegion: String?     // "hk", "us-east", "sg" — for UI transparency
}
```

### 5.4 WaitTimeEstimator.swift

```swift
/// Estimates total wait = upload time + server queue time + render time.
///
/// Three components:
///   1. Upload ETA: bytes remaining / observed upload speed (EMA)
///   2. Server queue ETA: from server API (CloudAPIProtocol.getServerETA)
///   3. Render ETA: from server API + local EMA (whichever available)
///
/// Job type buckets (server-side render time with A100 GPU):
///   small:  0-200 frames,  1080p → ~1 min
///   medium: 200-500 frames, 1080p → ~3 min
///   large:  500-1000 frames, 4K  → ~8 min
///   xl:     1000+ frames, 4K     → ~15 min
///
/// Display to user (cloud mode):
///   Uploading: "正在上传 · 42% · 预计还需3分钟"
///   Queued:    "排队中(3/15) · 预计8分钟后开始渲染"  ← server global position
///   Rendering: "云端渲染中 · 65% · 预计还需5分钟"
///   Queue #1:  "等待中(1/2) · 预计20分钟后开始"

public protocol WaitTimePredictor: Sendable {
    func estimateProcessingTime(for descriptor: JobDescriptor) async -> TimeInterval
    func estimateWaitTime(queuePosition: Int, jobsAhead: [JobDescriptor], currentJob: ActiveJobInfo?) async -> WaitTimeEstimate
    func estimateUploadTime(remainingBytes: UInt64) async -> TimeInterval
    func recordCompletion(descriptor: JobDescriptor, actualDuration: TimeInterval) async
    func recordUploadSpeed(bytesPerSecond: Double) async
}

public struct WaitTimeEstimate: Sendable, Codable {
    public let uploadSeconds: TimeInterval?       // nil if already uploaded
    public let serverQueueSeconds: TimeInterval?  // from server API
    public let renderSeconds: TimeInterval
    public let totalSeconds: TimeInterval
    public let confidenceRange: ClosedRange<TimeInterval>
    public let queuePosition: Int        // 0 = processing, 1 = next, 2 = after
    public let serverPosition: Int?      // global server queue position
    public let displayText: String       // localized
}

public struct JobDescriptor: Sendable, Codable, Hashable {
    public let frameCount: Int
    public let resolution: String        // "1080p", "4K"
    public let qualityLevel: String      // "S3" (on-device) or "S5" (cloud)
    public let scanDataBytes: UInt64     // for upload time estimation
}

/// EMA-based predictor. Merges local stats with server-reported ETA.
public actor StatisticalWaitTimePredictor: WaitTimePredictor {
    // Per-bucket EMA for render times
    // Per-network EMA for upload speeds (WiFi vs Cellular)
    // When server provides ETA: weighted average (server 70%, local 30%)
}
```

### 5.5 MemoryOptimizer.swift

```swift
/// Frees caches before upload/download to maximize network + memory headroom.
/// NEVER blocks a job. This is a pit crew, not a traffic cop.
///
/// What it clears and why:
/// ┌──────────────────────────┬────────────┬──────────────────────────────────┐
/// │ Cache Type               │ Typical MB │ Why clear                        │
/// ├──────────────────────────┼────────────┼──────────────────────────────────┤
/// │ URLCache (API responses) │ 50-200     │ Not needed during upload/render  │
/// │ Image thumbnails         │ 100-500    │ User not browsing list           │
/// │ Previous scan temp frames│ 200-1000   │ Garbage from last job            │
/// │ Metal texture cache      │ 50-300     │ No GPU work during cloud render  │
/// └──────────────────────────┴────────────┴──────────────────────────────────┘
/// Total recoverable: up to ~2GB
///
/// When:
///   prepareForUpload()  → before upload starts (free RAM for buffer pools)
///   handlePressure()    → on DidReceiveMemoryWarningNotification (iOS)
///   finalizeJob()       → after result downloaded, clean scan temp files
public actor MemoryOptimizer {
    public func prepareForUpload() async -> CleanupReport
    public func handleMemoryPressure() async
    public func finalizeJob(jobId: String) async
}

public struct CleanupReport: Sendable, Codable {
    public let bytesFreed: UInt64
    public let cachesPurged: Int
    public let tempFilesDeleted: Int
}
```

### 5.6 TimeoutWatchdog.swift

```swift
/// Monitors job health across the full pipeline: upload → server queue → render → download.
///
/// Cloud mode:
/// - Ticks every 5s (polls server status or listens on WebSocket)
/// - Upload phase: monitors upload progress; stuck upload → retry/fail
/// - Server phase: monitors server heartbeat; no progress in 30min → timeout
/// - Progress-aware: if server reported progress in last 60s, it's alive
/// - On genuine timeout (30min, no server progress):
///   1. Warning → UI shows "服务器处理可能卡住了"
///   2. 30s grace → query server one more time
///   3. Mark failed → .failed(.processingTimeout)
///
/// On-device fallback: same logic, ticks every 3s, kills stuck Metal jobs
public actor TimeoutWatchdog {
    // watchedJobs: [String: WatchEntry]
    // struct WatchEntry { startTime, lastHeartbeat, lastProgress, deadline, phase }
    // phase: .uploading | .serverQueued | .serverRendering | .downloading | .localProcessing
}
```

### 5.7 RecoveryManager.swift

```swift
/// WAL-based crash recovery. THE real protection users need.
///
/// Cloud mode advantage: server jobs SURVIVE app crashes.
/// The server doesn't care if the client app died. The render continues.
///
/// When user relaunches:
///   1. Read WAL
///   2. Pending jobs (not yet uploaded): raw data on disk → re-enqueue
///   3. Uploading job: check WAL for chunk progress → resume from last chunk
///   4. Server-side job: query server!
///      Server alive + job alive → reconnect progress stream
///      Server alive + job done → download result
///      Server alive + job failed → mark failed, user can retry
///      Server unreachable → mark "unknown", retry query with backoff
///   5. Compact WAL
///
/// WAL format: JSON Lines in Application Support directory
/// Entry: { action, jobId, timestamp, state, progress, serverJobId?, chunkProgress? }
/// Flush every 2s. Crash loses at most 2s of CLIENT state.
public actor RecoveryManager {
    public func recoverOnLaunch(apiClient: any CloudAPIProtocol) async -> RecoveryResult
}

public struct RecoveryResult: Sendable {
    public let restoredPending: [ScheduledJob]       // re-enqueued
    public let resumedUploads: [String]              // partial uploads to resume
    public let reconnectedServer: [String]           // still alive on server
    public let markedFailed: [String]                // dead jobs
}
```

### 5.8 JobScheduler.swift (Main Orchestrator)

```swift
/// Single entry point for job scheduling. Cloud-first, on-device fallback.
///
/// Cloud mode submit flow:
///   1. Check capacity: activeCount < TOTAL_QUEUE_CAPACITY?
///      YES → enqueue
///      NO  → throw .queueFull → UI: "你已经有2个任务在排队了"
///   2. MemoryOptimizer.prepareForUpload()
///   3. Dequeue → UploadManager.startUpload() → register with Watchdog
///   4. Upload complete → server starts rendering
///   5. Poll/WebSocket for server progress → forward to UI
///   6. Render complete → download result → Watchdog.unregister
///      → MemoryOptimizer.finalize → dequeue next if pending
///   7. On fail → RetryCalculator.shouldRetry? → re-enqueue or DLQ
///
/// On-device fallback: skip upload/download, run local Metal pipeline.
///
/// Integration with existing Core/Jobs:
/// - ALL state transitions via JobStateMachine.transition()
/// - Retry delays via RetryCalculator.calculateDelay()
/// - Failure routing via FailureReason.isRetryable
/// - Dead letter via DLQEntry
/// - Compensation via JobSagaOrchestrator
/// - Progress via ProgressEstimator
/// - Circuit breaking via CircuitBreakerActor (logs, does NOT block)
public actor JobScheduler {
    private let mode: SchedulerMode           // .cloudServer (primary)
    private let queue: FIFOQueue<ScheduledJob>
    private let waitTimeEstimator: any WaitTimePredictor
    private let memoryOptimizer: MemoryOptimizer
    private let watchdog: TimeoutWatchdog
    private let recovery: RecoveryManager
    private let uploadManager: UploadManager  // cloud mode
    private let apiClient: any CloudAPIProtocol
    private let circuitBreaker: CircuitBreakerActor
    private let stateMachine: JobStateMachine

    public let statusStream: AsyncStream<SchedulerStatus>

    public func submit(_ job: ScheduledJob) async throws -> SubmitResult
    public func cancel(jobId: String) async throws
    public func status() async -> SchedulerStatus
    public func switchMode(_ newMode: SchedulerMode) async
}

public struct SubmitResult: Sendable {
    public let jobId: String
    public let queuePosition: Int
    public let estimatedWait: WaitTimeEstimate
}

public struct SchedulerStatus: Sendable {
    public let mode: SchedulerMode
    public let processingJob: ActiveJobInfo?
    public let pendingJobs: [PendingJobInfo]     // 0, 1, or 2
    public let canSubmitMore: Bool
    public let slotsAvailable: Int
    public let serverReachable: Bool
}

public struct ActiveJobInfo: Sendable {
    public let jobId: String
    public let phase: JobPhase
    public let progress: Double              // within current phase
    public let overallProgress: Double       // across all phases
    public let estimatedRemaining: TimeInterval?
    public let serverQueuePosition: Int?
}

public enum JobPhase: String, Sendable, Codable {
    case uploading          // sending scan data to server
    case serverQueued       // waiting in server's global queue
    case rendering          // GPU processing on server
    case packaging          // server packaging the result
    case downloading        // pulling rendered model back to device
    case localProcessing    // on-device fallback mode
}
```

---

## 6. Cross-Platform

### iOS/macOS (primary client)
- URLSession for upload/download to cloud server
- URLSessionWebSocketTask for real-time progress
- `ProcessInfo.processInfo.physicalMemory` for memory stats
- `os_proc_available_memory()` (iOS 13+) for live available memory
- WAL path: `FileManager.default.urls(for: .applicationSupportDirectory, ...)`
- On-device fallback: Metal GPU for S3 quality reconstruction

### Linux (CI/testing)
- Memory: parse `/proc/meminfo`
- CloudAPIClient works on Linux (Foundation URLSession)
- On-device fallback: no Metal, CPU-only (hypothetical)
- WAL path: `XDG_DATA_HOME` or `$HOME/.aether3d/`

### Android / HarmonyOS (future)
- `PlatformBridge` protocol abstracts memory queries + cache cleanup + network
- Business logic (queue, upload, watchdog, recovery) is 100% platform-agnostic
- CloudAPIProtocol is pure Swift — any HTTP client can implement it

### Swift 6.2
- All actors, all Sendable
- No `@MainActor` on tests (Linux XCTest crash)
- No `async setUp/tearDown` (Linux deadlock)
- `AsyncStream` for status updates (Sendable-safe)
- `any CloudAPIProtocol` existential for dependency injection

---

## 7. Integration with Existing Code

| Existing Component | PR17 Usage |
|---|---|
| `JobStateMachine.transition()` | ALL state changes go through JSM |
| `ContractConstants.PROCESSING_HEARTBEAT_*` | Watchdog heartbeat-aware timeout |
| `CircuitBreakerActor` | Failure rate monitoring (log only, no blocking) |
| `RetryCalculator.calculateDelay()` | Retry backoff for re-enqueue + upload chunk retry |
| `RetryCalculator.shouldRetry()` | Is failure reason retryable? |
| `JobEventStore.append()` | Persist scheduler events |
| `DLQEntry` | Route exhausted jobs to dead letter |
| `FailureReason.processingTimeout` | Server-side watchdog timeout |
| `FailureReason.stalledProcessing` | Recovery stale detection |
| `FailureReason.networkError` | Upload failure / server unreachable |
| `ProgressEstimator` | Feed into WaitTimeEstimator |
| `JobSagaOrchestrator` | Compensation on scheduler-initiated failures |

---

## 8. Test Plan

Create `Tests/Scheduler/` with:

1. **FIFOQueueTests.swift** — FIFO ordering, TTL expiry, cancel, **capacity limit (3 max)**, reject when full
2. **CloudAPIClientTests.swift** — Mock server protocol, submit/status/cancel, error handling, WebSocket mock
3. **UploadManagerTests.swift** — Chunked upload, resume after interrupt, concurrent chunks, progress reporting
4. **WaitTimeEstimatorTests.swift** — EMA convergence, upload speed EMA, server ETA merge, display text
5. **MemoryOptimizerTests.swift** — Cleanup triggers, bytesFreed, mock platform bridge
6. **TimeoutWatchdogTests.swift** — 30min timeout, heartbeat extends, progress-aware, grace period, per-phase
7. **RecoveryManagerTests.swift** — WAL write/read, crash recovery with server reconnect, upload resume, compaction
8. **JobSchedulerTests.swift** — Full cloud flow, **queue full rejection**, auto-start next, retry, DLQ, mode switch
9. **CrossPlatformTests.swift** — `#if os(Linux)` / `#if canImport(Darwin)`

All tests: XCTestCase, no @MainActor, no async setUp/tearDown.
Use `MockCloudAPIClient` (in-memory, no network) for all cloud tests.

---

## 9. Acceptance Criteria

### Cloud Pipeline (Primary)
- [ ] **Cloud submit flow**: submit → upload → server queue → render → download → complete
- [ ] **Region routing**: `ServerRegion.china` vs `.international` auto-detected by locale/IP
- [ ] **China data compliance**: 中国用户数据上传到大陆服务器，不出境
- [ ] **Chunked upload**: 5MB chunks, 3 concurrent, resume after crash
- [ ] **Server progress**: WebSocket real-time OR 5s polling fallback
- [ ] **Server ETA merge**: combine server-reported ETA with local EMA
- [ ] **Upload progress display**: "正在上传 · 42% · 预计还需3分钟"
- [ ] **Server queue display**: "排队中(3/15) · 预计8分钟后开始渲染" (global position)
- [ ] **Render progress display**: "云端渲染中 · 65% · 预计还需5分钟"
- [ ] **CloudAPIProtocol**: fully defined, mockable, with REST endpoint contract
- [ ] **Download result**: pull rendered 3D model back to device on completion

### Queue Management (Both Modes)
- [ ] **Queue limit**: 1 processing + 2 pending max. 4th submit throws `.queueFull`
- [ ] **User feedback on full**: "你已经有2个任务在排队了，请等一个完成后再提交"
- [ ] **Auto-advance**: when processing job completes, next pending starts automatically
- [ ] **FIFO ordering**: pending jobs process in submission order

### Reliability
- [ ] **WAL recovery**: app crash → relaunch → pending restored, uploading resumed, server jobs reconnected
- [ ] **Timeout kills STUCK**: 30min + 30s grace → `.failed(.processingTimeout)`
- [ ] **Timeout spares ACTIVE**: 90% progress + recent heartbeat = never killed
- [ ] **Retry**: retryable failures re-enqueue with backoff (upload chunks + job-level)
- [ ] **DLQ**: exhausted retries → dead letter queue

### Constraints
- [ ] **No thermal gate / no battery gate / no performance throttling**
- [ ] **Memory optimizer**: frees caches before upload, never blocks
- [ ] **On-device fallback**: server unreachable → degrade to S3 local Metal
- [ ] **Mode switch**: `switchMode(.onDevice)` / `switchMode(.cloudServer)`
- [ ] **Cross-platform**: macOS + Linux build
- [ ] **Swift 6.2**: no Sendable warnings

---

## 10. What PR17 Does and Does NOT Do

### DOES
- **Cloud rendering pipeline**: upload scan data → server GPU → download S5 model
- **Dual-region compliance**: 中国用户→大陆服务器（数据不出境），国际用户→海外服务器
- **ServerRegion routing**: 自动检测用户区域，路由到合规服务器
- **CloudAPIProtocol**: defines the complete server API contract (REST + WebSocket)
- **Chunked resumable upload**: 5MB chunks, 3 concurrent, crash-recoverable
- **1+2 queue limit**: prevents unreasonable hoarding on client side
- **Auto-advance**: seamless pipeline, user scans while previous job uploads/renders
- **WAL recovery**: no job data lost on crash; server jobs survive app death
- **Smart watchdog**: monitors all phases (upload, server queue, render, download)
- **Memory optimizer**: clears caches to maximize upload speed, never blocks
- **Wait time display**: upload ETA + server queue position + render ETA
- **On-device fallback**: when server unreachable, degrade to S3 local Metal
- **Mode switch**: seamless `.cloudServer` ↔ `.onDevice` transition

### Does NOT Do
- ~~Thermal gate~~ — user's decision
- ~~Battery gate~~ — user's decision
- ~~Memory blocking~~ — we free memory, not block work
- ~~AI/ML scheduling~~ — EMA sufficient now; `WaitTimePredictor` protocol ready for future ML
- **Server-side implementation** — this PR defines the CLIENT side. Server code is separate.
- Modify existing `Core/Jobs/*` files
- Change `ContractConstants`
- Change existing Package.swift products
