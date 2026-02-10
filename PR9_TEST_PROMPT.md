# PR9 Chunked Upload V3.0 — 全面深度测试生成提示词

> **目标**: 为 PR9 的 41 个实现文件生成 **27 个测试文件**，总计 **2000+ 个测试方法**，**3000+ 个断言**。
> **测试框架**: XCTest（禁止使用 Swift Testing `@Test` 宏）
> **测试目标**: `UploadTests`（`Tests/Upload/` 目录）
> **依赖**: `@testable import Aether3DCore`
> **跨平台**: macOS + Linux（禁止 `@MainActor`、禁止 `async setUp/tearDown`）

---

## 重要规则（必须遵守）

### 并发安全规则
```
❌ 禁止: @MainActor class MyTests: XCTestCase
❌ 禁止: override func setUp() async throws
❌ 禁止: override func tearDown() async throws
✅ 正确: override func setUp() { /* 同步初始化 */ }
✅ 正确: override func tearDown() { /* 同步清理 */ }
✅ 正确: func testAsync() async throws { let result = await actor.method() }
```

### 代码风格规则
```
- 每个测试方法名 testXxx 必须描述具体场景
- 每个 XCTAssert 必须包含 message 参数说明失败原因
- 临时文件使用 UUID 命名 + defer 清理
- Actor 方法调用使用 async/await（func testXxx() async throws）
- 不使用任何 Mock 框架，纯 Foundation 手写测试替身
- 所有 hex 字符串使用小写
- 每个文件开头注释格式:
  //
  //  XxxTests.swift
  //  Aether3D
  //
  //  PR#9: Chunked Upload V3.0 - Xxx Tests
  //
```

### 文件结构规则
```
- 所有测试文件放在 Tests/Upload/ 目录
- import XCTest + @testable import Aether3DCore
- final class XxxTests: XCTestCase { ... }
- MARK 注释分隔测试分组
```

---

## 现有实现文件清单（41个，路径: Core/Upload/）

| 文件 | 行数 | 类型 | 关键API |
|------|------|------|---------|
| ChunkedUploader.swift | 466 | actor | `upload() async throws -> String` |
| HybridIOEngine.swift | 440 | actor | `readChunk(offset:length:) async throws -> IOResult` |
| BundleManifest.swift | 964 | struct | `compute(...) throws -> BundleManifest`, `verifyHash() -> Bool` |
| ImmutableBundle.swift | 546 | struct | `seal(...) async throws -> ImmutableBundle`, `verify(...) async throws -> Bool` |
| NetworkSpeedMonitor.swift | 414 | class | `recordSample(bytesTransferred:durationSeconds:)`, `getSpeedClass()` |
| KalmanBandwidthPredictor.swift | 339 | actor | `addSample(bytesTransferred:durationSeconds:)`, `predict() -> BandwidthPrediction` |
| ConnectionPrewarmer.swift | 284 | actor | `startPrewarming() async`, `getCurrentStage() -> PrewarmingStage` |
| EnhancedResumeManager.swift | 297 | actor | `persistResumeState(_:) async throws`, `resumeLevel1/2/3(...)` |
| ContentDefinedChunker.swift | 272 | actor | `chunkFile(at:) async throws -> [CDCBoundary]` |
| NetworkPathObserver.swift | 251 | actor | `startMonitoring()`, `events: AsyncStream<NetworkPathEvent>` |
| ChunkIntegrityValidator.swift | 239 | actor | `validatePreUpload(chunk:session:) -> ValidationResult` |
| ChunkCommitmentChain.swift | 242 | actor | `appendChunk(_:) -> String`, `verifyForwardChain(_:) -> Bool` |
| StreamingMerkleTree.swift | 203 | actor | `appendLeaf(_:) async`, `rootHash: Data`, `verifyProof(...)` |
| DeviceInfo.swift | 194 | struct | `BundleDeviceInfo.current()`, `validated() throws` |
| CIDMapper.swift | 178 | enum | `aciToCID(_:) -> String?`, `cidToACI(_:) -> String?` |
| ChunkBufferPool.swift | 159 | actor | `acquire() -> UnsafeMutableRawBufferPointer?`, `release(_:)` |
| CAMARAQoDClient.swift | 169 | actor | `requestHighBandwidth(duration:) async throws -> QualityGrant` |
| MLBandwidthPredictor.swift | 171 | actor | `addSample(...)`, `predict() -> BandwidthPrediction` |
| MultipathUploadManager.swift | 173 | actor | `detectPaths() async`, `assignChunkToPath(priority:) -> PathInfo?` |
| ErasureCodingEngine.swift | 197 | actor | `selectCoder(chunkCount:lossRate:)`, `encode(data:redundancy:)` |
| FusionScheduler.swift | 197 | actor | `decideChunkSize() async -> Int` |
| RaptorQEngine.swift | 170 | actor | `encode(data:redundancy:) async -> [Data]`, `decode(...)` |
| HashCalculator.swift | 220 | enum | `sha256(of:) -> String`, `timingSafeEqual(_:_:) -> Bool` |
| UploadSession.swift | 152 | class | `updateState(_:)`, `markChunkCompleted(index:)` |
| MultiLayerProgressTracker.swift | 149 | actor | `updateWireProgress(_:)`, `getProgress() -> MultiLayerProgress` |
| UploadProgressTracker.swift | 132 | class | `updateProgress()`, `forceReportProgress()` |
| UploadCircuitBreaker.swift | 127 | actor | `shouldAllowRequest() -> Bool`, `recordSuccess()`, `recordFailure()` |
| ByzantineVerifier.swift | 121 | actor | `verifyChunks(...) async -> VerificationResult` |
| UploadTelemetry.swift | 119 | actor | `recordChunk(_:)`, `getEntries() -> [TelemetryEntry]` |
| ProofOfPossession.swift | 117 | actor | `generateChallengeCount(fileSizeBytes:)`, `validateNonce(_:)` |
| ChunkManager.swift | 110 | class | `markChunkCompleted(index:...)`, `calculateRetryDelay(attempt:)` |
| ChunkIdempotencyManager.swift | 109 | actor | `generateChunkKey(...)`, `checkChunkIdempotency(key:)` |
| UnifiedResourceManager.swift | 99 | actor | `getUploadBudget() -> Double`, `shouldPauseUpload() -> Bool` |
| ACI.swift | 89 | struct | `parse(_:) throws -> ACI`, `fromSHA256Hex(_:)` |
| AdaptiveChunkSizer.swift | 79 | class | `calculateChunkSize() -> Int` |
| DualDigest.swift | 72 | struct | `compute(data:) -> DualDigest`, `verify(against:) -> Bool` |
| VerificationMode.swift | 76 | enum | `.progressive`, `.probabilistic(delta:)`, `.full` |
| BundleError.swift | 46 | enum | 12 error cases with `failClosedCode: UInt16` |
| UploadResumeManager.swift | 104 | class | `saveSession(_:)`, `loadSession(sessionId:)` |
| PR9CertificatePinManager.swift | 214 | actor | `validateCertificateChain(_:)`, `rotatePins(...)` |

---

## 关键常量（UploadConstants.swift — 所有测试必须引用这些常量）

```swift
// 分块大小
CHUNK_SIZE_MIN_BYTES = 256 * 1024          // 256KB
CHUNK_SIZE_DEFAULT_BYTES = 2 * 1024 * 1024  // 2MB
CHUNK_SIZE_MAX_BYTES = 32 * 1024 * 1024    // 32MB
CHUNK_SIZE_STEP_BYTES = 512 * 1024          // 512KB

// 网络速度 (SI Mbps)
NETWORK_SPEED_SLOW_MBPS = 3.0
NETWORK_SPEED_NORMAL_MBPS = 30.0
NETWORK_SPEED_FAST_MBPS = 100.0
NETWORK_SPEED_ULTRAFAST_MBPS = 200.0
NETWORK_SPEED_MIN_SAMPLES = 5

// 并行
MAX_PARALLEL_CHUNK_UPLOADS = 12
PARALLEL_RAMP_UP_DELAY_MS = 10

// 重试
CHUNK_MAX_RETRIES = 7
RETRY_BASE_DELAY_SECONDS = 0.5
RETRY_MAX_DELAY_SECONDS = 15.0

// 超时
CHUNK_TIMEOUT_SECONDS = 45.0
CONNECTION_TIMEOUT_SECONDS = 8.0
WATCHDOG_SESSION_TIMEOUT = 60.0
WATCHDOG_GLOBAL_TIMEOUT = 300.0

// Kalman
KALMAN_PROCESS_NOISE_BASE = 0.01
KALMAN_MEASUREMENT_NOISE_FLOOR = 0.001
KALMAN_ANOMALY_THRESHOLD_SIGMA = 2.5
KALMAN_CONVERGENCE_THRESHOLD = 5.0
KALMAN_DYNAMIC_R_SAMPLE_COUNT = 10

// Merkle
MERKLE_SUBTREE_CHECKPOINT_INTERVAL = 16
MERKLE_LEAF_PREFIX = 0x00
MERKLE_NODE_PREFIX = 0x01

// 承诺链
COMMITMENT_CHAIN_DOMAIN = "CCv1\0"
COMMITMENT_CHAIN_JUMP_DOMAIN = "CCv1_JUMP\0"
COMMITMENT_CHAIN_GENESIS_PREFIX = "Aether3D_CC_GENESIS_"

// 断路器
CIRCUIT_BREAKER_FAILURE_THRESHOLD = 5
CIRCUIT_BREAKER_HALF_OPEN_INTERVAL = 30.0
CIRCUIT_BREAKER_SUCCESS_THRESHOLD = 2

// 纠删码
ERASURE_RS_DATA_SYMBOLS = 20
ERASURE_RAPTORQ_FALLBACK_LOSS_RATE = 0.08
RAPTORQ_CHUNK_COUNT_THRESHOLD = 256
RAPTORQ_MAX_REPAIR_RATIO = 2.0

// CDC
CDC_MIN_CHUNK_SIZE = 256 * 1024
CDC_MAX_CHUNK_SIZE = 8 * 1024 * 1024
CDC_AVG_CHUNK_SIZE = 1 * 1024 * 1024
CDC_GEAR_TABLE_VERSION = "v1"

// ML
ML_PREDICTION_HISTORY_LENGTH = 30
ML_WARMUP_SAMPLES = 10
ML_ENSEMBLE_WEIGHT_MIN = 0.3
ML_ENSEMBLE_WEIGHT_MAX = 0.7

// 缓冲池
BUFFER_POOL_MAX_BUFFERS = 12
BUFFER_POOL_MIN_BUFFERS = 2

// 拜占庭
BYZANTINE_COVERAGE_TARGET = 0.999
BYZANTINE_MAX_FAILURES = 3
```

---

## 27个测试文件详细规格

### ═══════════════════════════════════════════
### 文件 1: `HybridIOEngineTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `HybridIOEngine` (actor)
**测试分组**:

#### MARK: - I/O Method Selection (20 tests)
```
testSelectIOMethod_SmallFile_ReturnsMmap
testSelectIOMethod_LargeFile_ReturnsMmap
testSelectIOMethod_VeryLargeFile_ReturnsFileHandle
testSelectIOMethod_ZeroSize_ReturnsFileHandle
testSelectIOMethod_NegativeSize_ReturnsFileHandle
testSelectIOMethod_ExactlyMmapThreshold_ReturnsMmap
testSelectIOMethod_OneOverMmapThreshold_ReturnsFileHandle
testSelectIOMethod_ChunkSizeZero_ReturnsFileHandle
testSelectIOMethod_MaxInt64Size_ReturnsFileHandle
testSelectIOMethod_1ByteFile_ReturnsMmap
testSelectIOMethod_256KBFile_ReturnsMmap
testSelectIOMethod_64MBFile_ReturnsMmap
testSelectIOMethod_65MBFile_WindowedMmap
testSelectIOMethod_1GBFile_ReturnsFileHandle
testSelectIOMethod_10GBFile_ReturnsFileHandle
testSelectIOMethod_DefaultChunkSize_Correct
testSelectIOMethod_MinChunkSize_Correct
testSelectIOMethod_MaxChunkSize_Correct
testSelectIOMethod_ConsistentResults_SameInputs
testSelectIOMethod_IOMethodEnum_AllCasesExist
```

#### MARK: - Read Chunk (25 tests)
```
testReadChunk_SmallFile_ReturnsCorrectHash
testReadChunk_LargeFile_ReturnsCorrectHash
testReadChunk_FirstChunk_OffsetZero
testReadChunk_MiddleChunk_CorrectOffset
testReadChunk_LastChunk_CorrectLength
testReadChunk_SingleByte_Works
testReadChunk_EmptyFile_ThrowsError
testReadChunk_NegativeOffset_ThrowsError
testReadChunk_OffsetBeyondFileSize_ThrowsError
testReadChunk_ZeroLength_ThrowsError
testReadChunk_NegativeLength_ThrowsError
testReadChunk_LengthExceedsFile_ThrowsError
testReadChunk_FileNotFound_ThrowsError
testReadChunk_PermissionDenied_ThrowsError
testReadChunk_256KB_MinChunkSize
testReadChunk_32MB_MaxChunkSize
testReadChunk_ConsecutiveChunks_DifferentHashes
testReadChunk_SameChunkTwice_SameHash
testReadChunk_CRC32CNotZero_ForNonEmptyData
testReadChunk_CompressibilityRange_0to1
testReadChunk_IncompressibleData_HighCompressibility
testReadChunk_CompressibleData_LowCompressibility
testReadChunk_ByteCountMatchesLength
testReadChunk_SHA256Is64HexChars
testReadChunk_IOMethodFieldNotEmpty
```

#### MARK: - IOResult Validation (15 tests)
```
testIOResult_SHA256Hex_Is64Characters
testIOResult_SHA256Hex_IsLowercase
testIOResult_SHA256Hex_OnlyHexCharacters
testIOResult_CRC32C_NonZeroForData
testIOResult_ByteCount_MatchesInput
testIOResult_Compressibility_BetweenZeroAndOne
testIOResult_IOMethod_IsValidEnum
testIOResult_Sendable_ConformanceCompiles
testIOResult_DifferentData_DifferentHashes
testIOResult_SameData_SameHash
testIOResult_EmptyData_KnownHash
testIOResult_1MB_CorrectByteCount
testIOResult_AllZeros_SpecificCRC32C
testIOResult_AllOnes_SpecificCRC32C
testIOResult_KnownTestVector_MatchesExpected
```

#### MARK: - Triple Hash (CRC32C + SHA256 + Compressibility) (15 tests)
```
testTripleHash_EmptyData_ValidResults
testTripleHash_KnownData_SHA256Matches
testTripleHash_KnownData_CRC32CMatches
testTripleHash_Compressibility_AllZeros_Compressible
testTripleHash_Compressibility_Random_Incompressible
testTripleHash_Deterministic_SameInputSameOutput
testTripleHash_DifferentInput_DifferentOutput
testTripleHash_1Byte_ValidResults
testTripleHash_4MB_ValidResults
testTripleHash_32MB_ValidResults
testTripleHash_UTF8Text_ValidResults
testTripleHash_BinaryData_ValidResults
testTripleHash_CRC32CMatchesSoftware_WhenNoHardware
testTripleHash_SHA256MatchesHashCalculator
testTripleHash_CompressibilityNeverNegative
```

#### MARK: - TOCTOU Protection (10 tests)
```
testTOCTOU_FileChangedDuringRead_DetectsChange
testTOCTOU_FileDeletedDuringRead_ThrowsError
testTOCTOU_FileTruncatedDuringRead_ThrowsError
testTOCTOU_FileGrowsDuringRead_ThrowsError
testTOCTOU_FileLocking_PreventsConcurrentAccess
testTOCTOU_FstatPostOpen_MatchesPre
testTOCTOU_SymlinkTarget_RejectsSymlinks
testTOCTOU_HardLink_AllowsSameInode
testTOCTOU_DeviceFile_Rejects
testTOCTOU_PipeFile_Rejects
```

#### MARK: - Concurrent Access (10 tests)
```
testConcurrent_MultipleReads_SameFile_NoRace
testConcurrent_MultipleEngines_DifferentFiles
testConcurrent_ReadWhileAnotherReads_Isolated
testConcurrent_10Readers_SameFile_AllSucceed
testConcurrent_ReadAndRelease_NoLeak
testConcurrent_RapidOpenClose_NoResourceLeak
testConcurrent_ActorIsolation_PreventsMutation
testConcurrent_CancelDuringRead_Handles
testConcurrent_TimeoutDuringRead_Handles
testConcurrent_LargeFileParallelChunks_AllValid
```

#### MARK: - Memory & Resource (5 tests)
```
testMemory_MmapCleanup_AfterDeinit
testMemory_FileHandleClose_AfterDeinit
testMemory_NoLeaks_After1000Reads
testMemory_BufferAlignment_16384Boundary
testResource_FileDescriptor_ClosedAfterUse
```

---

### ═══════════════════════════════════════════
### 文件 2: `KalmanBandwidthPredictorTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `KalmanBandwidthPredictor` (actor), `BandwidthPrediction`, `BandwidthTrend`, `PredictionSource`

#### MARK: - Initialization (10 tests)
```
testInit_WithoutObserver_Succeeds
testInit_WithObserver_Succeeds
testInit_InitialState_ZeroBandwidth
testInit_InitialState_NotReliable
testInit_InitialCovariance_Diagonal100_10_1_50
testInit_InitialProcessNoise_Base0_01
testInit_InitialMeasurementNoise_Floor0_001
testInit_Predict_BeforeSamples_ReturnsZero
testInit_Predict_BeforeSamples_NotReliable
testInit_Predict_BeforeSamples_SourceIsKalman
```

#### MARK: - Sample Processing (20 tests)
```
testAddSample_SingleSample_UpdatesState
testAddSample_ZeroDuration_Ignored
testAddSample_NegativeDuration_Ignored
testAddSample_ZeroBytes_ValidMeasurement
testAddSample_1GB_1Second_HighBandwidth
testAddSample_1Byte_10Seconds_LowBandwidth
testAddSample_MultipleSamples_StateConverges
testAddSample_5Samples_BecomesReliable
testAddSample_4Samples_StillUnreliable
testAddSample_100Samples_StaysReliable
testAddSample_ConvergesToTrue_WhenStable
testAddSample_BitsPerSecond_CorrectConversion
testAddSample_SI_Mbps_NotMibps
testAddSample_RecentSamples_MaxCount10
testAddSample_OlderSamples_EvictedFromRecent
testAddSample_AdaptsMeasurementNoise_R
testAddSample_R_NeverBelowFloor
testAddSample_LargeVariance_IncreasesR
testAddSample_SmallVariance_KeepsRAtFloor
testAddSample_ExactlyMaxRecentSamples_NoOverflow
```

#### MARK: - Prediction (20 tests)
```
testPredict_AfterStableSamples_AccurateBandwidth
testPredict_PredictedBps_NonNegative
testPredict_ConfidenceInterval_LowLessThanHigh
testPredict_ConfidenceInterval_LowNonNegative
testPredict_ConfidenceInterval_Contains95Percent
testPredict_Trend_StableSamples_Stable
testPredict_Trend_IncreasingSamples_Rising
testPredict_Trend_DecreasingSamples_Falling
testPredict_IsReliable_AfterConvergence
testPredict_IsReliable_TracePBelowThreshold
testPredict_Source_AlwaysKalman
testPredict_After100Mbps_PredictNear100Mbps
testPredict_After1Mbps_PredictNear1Mbps
testPredict_SteadyState_NarrowConfidenceInterval
testPredict_Volatile_WideConfidenceInterval
testPredict_AfterReset_NotReliable
testPredict_AfterReset_ZeroBandwidth
testPredict_GradualIncrease_TrendRising
testPredict_GradualDecrease_TrendFalling
testPredict_Oscillating_TrendStable
```

#### MARK: - Anomaly Detection (15 tests)
```
testAnomaly_NormalSample_FullWeight
testAnomaly_Outlier10x_ReducedWeight
testAnomaly_MahalanobisAbove2_5Sigma_Detected
testAnomaly_MahalanobisBelow2_5Sigma_NotDetected
testAnomaly_ExactlyAtThreshold_NotDetected
testAnomaly_Spike100xBandwidth_HandleGracefully
testAnomaly_DropTo0_HandleGracefully
testAnomaly_NegativeBandwidth_HandleGracefully
testAnomaly_AfterAnomaly_RecoverToNormal
testAnomaly_ConsecutiveAnomalies_StillConverges
testAnomaly_SingleAnomaly_DoesNotCorruptState
testAnomaly_AnomalyWeight_Is0_5
testAnomaly_StateVector_NoNaN_AfterAnomaly
testAnomaly_Covariance_NoNaN_AfterAnomaly
testAnomaly_CovariancePositiveSemiDefinite_AfterAnomaly
```

#### MARK: - Network Change Adaptation (10 tests)
```
testNetworkChange_QIncreases10x
testNetworkChange_AfterAdaptation_QIs10xBase
testNetworkChange_CovarianceExpands
testNetworkChange_ConfidenceIntervalWidens
testNetworkChange_PredictionLessReliable
testNetworkChange_RecoverAfterStableSamples
testNetworkChange_WiFiToCellular_Adapts
testNetworkChange_CellularToWiFi_Adapts
testNetworkChange_MultipleChanges_HandledCorrectly
testNetworkChange_BaseQIsProcessNoiseBase
```

#### MARK: - Kalman Mathematics (15 tests)
```
testKalman_StateTransitionMatrix_Dimensions4x4
testKalman_ObservationMatrix_First1Rest0
testKalman_PredictStep_xEquals_Fx
testKalman_PredictStep_PEquals_FPFt_Plus_Q
testKalman_UpdateStep_xConverges
testKalman_UpdateStep_PConverges
testKalman_KalmanGain_ConvergesToOptimal
testKalman_Innovation_CorrectComputation
testKalman_MatrixMultiply_IdentityPreserves
testKalman_MatrixMultiply_ZeroResultsZero
testKalman_Transpose_Correct
testKalman_DotProduct_Correct
testKalman_OuterProduct_Correct
testKalman_IdentityMatrix_Diagonal
testKalman_Covariance_SymmetricAfterUpdate
```

#### MARK: - Reset (10 tests)
```
testReset_StateVectorZero
testReset_CovarianceToInitial
testReset_SampleCountZero
testReset_PredictionZero
testReset_NotReliable
testReset_TrendStable
testReset_RecentSamplesEmpty
testReset_AfterManySamples_FullReset
testReset_CanAddSamplesAfterReset
testReset_MultiplResets_NoCorruption
```

---

### ═══════════════════════════════════════════
### 文件 3: `StreamingMerkleTreeTests.swift` (120+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `StreamingMerkleTree` (actor), `IntegrityTree` protocol

#### MARK: - Empty Tree (10 tests)
```
testEmptyTree_RootHash_IsSHA256Of0x00
testEmptyTree_RootHash_Is32Bytes
testEmptyTree_RootHash_Deterministic
testEmptyTree_GenerateProof_ReturnsNil
testEmptyTree_GenerateProof_NegativeIndex_ReturnsNil
testEmptyTree_LeafCount_Zero
testEmptyTree_MultipleRootQueries_SameResult
testEmptyTree_ProtocolConformance_IntegrityTree
testEmptyTree_ActorIsolation_Works
testEmptyTree_Sendable_Conformance
```

#### MARK: - Single Leaf (10 tests)
```
testSingleLeaf_RootEquals_LeafHash
testSingleLeaf_LeafHash_SHA256_0x00_IndexLE32_Data
testSingleLeaf_Index0_CorrectLeafHash
testSingleLeaf_DifferentData_DifferentRoot
testSingleLeaf_SameData_SameRoot
testSingleLeaf_EmptyData_ValidRoot
testSingleLeaf_LargeData_ValidRoot
testSingleLeaf_RootIs32Bytes
testSingleLeaf_ProofForIndex0_ReturnsEmptyOrNil
testSingleLeaf_ProofForIndex1_ReturnsNil
```

#### MARK: - Two Leaves (10 tests)
```
testTwoLeaves_Root_Equals_MergeOf2LeafHashes
testTwoLeaves_InternalHash_SHA256_0x01_Level_Left_Right
testTwoLeaves_RootIs32Bytes
testTwoLeaves_OrderMatters_DifferentRoots
testTwoLeaves_SameLeaves_SameRoot
testTwoLeaves_DifferentLeaves_DifferentRoot
testTwoLeaves_MergeLevel_Is0
testTwoLeaves_StackSize_Is1_AfterCarry
testTwoLeaves_ProofForLeaf0_ContainsLeaf1Hash
testTwoLeaves_VerifyProof_Leaf0_Succeeds
```

#### MARK: - Power-of-2 Trees (15 tests)
```
testTree4Leaves_RootCorrect
testTree8Leaves_RootCorrect
testTree16Leaves_RootCorrect
testTree32Leaves_RootCorrect
testTree64Leaves_RootCorrect
testTree128Leaves_RootCorrect
testTree256Leaves_RootCorrect
testTree1024Leaves_ValidRoot
testTree4Leaves_BinaryCarryMerges_Correct
testTree8Leaves_AllLevelsPresent
testTree16Leaves_CheckpointEmitted
testTree32Leaves_2Checkpoints
testTree64Leaves_4Checkpoints
testTree128Leaves_8Checkpoints
testTree256Leaves_16Checkpoints
```

#### MARK: - Non-Power-of-2 Trees (15 tests)
```
testTree3Leaves_StackStructure_Correct
testTree5Leaves_RootCorrect
testTree7Leaves_RootCorrect
testTree9Leaves_RootCorrect
testTree13Leaves_RootCorrect
testTree15Leaves_RootCorrect
testTree17Leaves_RootCorrect
testTree31Leaves_RootCorrect
testTree33Leaves_RootCorrect
testTree100Leaves_ValidRoot
testTree255Leaves_ValidRoot
testTree1000Leaves_ValidRoot
testTree3Leaves_StackHas2Elements
testTree5Leaves_StackHas2Elements
testTree7Leaves_StackHas3Elements
```

#### MARK: - Domain Separation (RFC 9162) (15 tests)
```
testDomainSeparation_LeafPrefix_0x00
testDomainSeparation_NodePrefix_0x01
testDomainSeparation_LeafHashIncludesIndexLE32
testDomainSeparation_NodeHashIncludesLevel
testDomainSeparation_Leaf0_DifferentFromNode0
testDomainSeparation_LeafAndNode_DifferentPrefixes
testDomainSeparation_SameData_LeafVsNode_DifferentHash
testDomainSeparation_IndexLE32_LittleEndian
testDomainSeparation_Index0_Bytes00000000
testDomainSeparation_Index1_Bytes01000000
testDomainSeparation_Index255_BytesFF000000
testDomainSeparation_Index256_Bytes00010000
testDomainSeparation_Level_AsUInt8
testDomainSeparation_Level0_Byte00
testDomainSeparation_Level1_Byte01
```

#### MARK: - Incremental Consistency (15 tests)
```
testIncremental_AppendDoesNotChange_PreviousRoot
testIncremental_EachAppend_ProducesNewRoot
testIncremental_Deterministic_SameSequence_SameRoots
testIncremental_10000Leaves_MemoryOLogN
testIncremental_StackNeverExceedsLogN
testIncremental_AfterNLeaves_StackSizeLeqLogN_Plus1
testIncremental_BinaryCarry_MergesCorrectly
testIncremental_CarryPropagation_MultiLevel
testIncremental_SubtreeCheckpoint_Every16Leaves
testIncremental_CheckpointCount_EqualsLeafCount_Div16
testIncremental_MonotonicallyIncreasingLeafCount
testIncremental_ConcurrentAppends_ActorSafe
testIncremental_100Appends_AllRootsDifferent
testIncremental_RootAfterN_SameAsRebuiltTree
testIncremental_PartialTree_MatchesFullComputation
```

#### MARK: - Proof Generation & Verification (20 tests)
```
testProof_InvalidIndex_ReturnsNil
testProof_NegativeIndex_ReturnsNil
testProof_IndexBeyondLeafCount_ReturnsNil
testVerifyProof_ValidProof_ReturnsTrue
testVerifyProof_InvalidProof_ReturnsFalse
testVerifyProof_WrongRoot_ReturnsFalse
testVerifyProof_WrongLeaf_ReturnsFalse
testVerifyProof_WrongIndex_ReturnsFalse
testVerifyProof_EmptyProof_ValidForSingleLeaf
testVerifyProof_SwappedSiblings_ReturnsFalse
testVerifyProof_TruncatedProof_ReturnsFalse
testVerifyProof_ExtendedProof_ReturnsFalse
testVerifyProof_LeftChild_CorrectOrder
testVerifyProof_RightChild_CorrectOrder
testVerifyProof_Leaf0In2Tree_Works
testVerifyProof_Leaf1In2Tree_Works
testVerifyProof_Leaf0In4Tree_Works
testVerifyProof_Leaf3In4Tree_Works
testVerifyProof_Leaf7In8Tree_Works
testVerifyProof_StaticMethod_NoActorNeeded
```

#### MARK: - Edge Cases (10 tests)
```
testEdge_VeryLargeLeafData_1MB
testEdge_EmptyLeafData
testEdge_UnicodeLeafData
testEdge_BinaryLeafData_AllZeros
testEdge_BinaryLeafData_AllOnes
testEdge_MaxUInt32Index_DoesNotOverflow
testEdge_10000Leaves_Completes
testEdge_HashCollision_DifferentIndexPreventsFalsePositive
testEdge_SameDataDifferentIndex_DifferentLeafHash
testEdge_RootHashConsistent_AcrossRuns
```

---

### ═══════════════════════════════════════════
### 文件 4: `ChunkCommitmentChainTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ChunkCommitmentChain` (actor)

#### MARK: - Genesis (10 tests)
```
testGenesis_SessionBound_SHA256
testGenesis_DifferentSessions_DifferentGenesis
testGenesis_SameSession_SameGenesis
testGenesis_EmptySessionId_ValidGenesis
testGenesis_LongSessionId_ValidGenesis
testGenesis_UnicodeSessionId_ValidGenesis
testGenesis_GenesisPrefix_IsAether3D_CC_GENESIS
testGenesis_LatestCommitment_IsGenesis_WhenEmpty
testGenesis_Is32Bytes_64HexChars
testGenesis_Deterministic_AcrossInstances
```

#### MARK: - Forward Chain (20 tests)
```
testForwardChain_SingleChunk_CommitmentCorrect
testForwardChain_TwoChunks_ChainedCorrectly
testForwardChain_10Chunks_AllChained
testForwardChain_CommitmentFormula_SHA256_Domain_ChunkHash_Prev
testForwardChain_DomainPrefix_CCv1Null
testForwardChain_DifferentChunkHash_DifferentCommitment
testForwardChain_SameChunkHash_DifferentPreviousCommitment
testForwardChain_LatestCommitment_UpdatesAfterAppend
testForwardChain_AppendReturns64HexString
testForwardChain_InvalidHexHash_ReturnsNil_OrFatal
testForwardChain_OddLengthHex_ReturnsNil
testForwardChain_UppercaseHex_HandledCorrectly
testForwardChain_1000Chunks_NoPerformanceDegradation
testForwardChain_OrderMatters_DifferentOrder_DifferentChain
testForwardChain_DuplicateChunks_DifferentCommitments
testForwardChain_EmptyChunkHash_ReturnsNilOrFatal
testForwardChain_NonHexChars_ReturnsNilOrFatal
testForwardChain_32ByteHash_64HexChars
testForwardChain_ChainLength_EqualsAppendCount
testForwardChain_Deterministic_SameInputs_SameChain
```

#### MARK: - Verify Forward Chain (15 tests)
```
testVerifyForward_ValidChain_ReturnsTrue
testVerifyForward_EmptyChain_EmptyHashes_ReturnsTrue
testVerifyForward_TamperedChunk_ReturnsFalse
testVerifyForward_ReorderedChunks_ReturnsFalse
testVerifyForward_MissingChunk_ReturnsFalse
testVerifyForward_ExtraChunk_ReturnsFalse
testVerifyForward_WrongHash_ReturnsFalse
testVerifyForward_WrongCount_ReturnsFalse
testVerifyForward_SingleChunk_Valid
testVerifyForward_100Chunks_Valid
testVerifyForward_FirstChunkTampered_DetectedImmediately
testVerifyForward_LastChunkTampered_Detected
testVerifyForward_MiddleChunkTampered_Detected
testVerifyForward_AllChunksTampered_Detected
testVerifyForward_EmptyHashInArray_ReturnsFalse
```

#### MARK: - Reverse Chain (15 tests)
```
testVerifyReverse_ValidChain_ReturnsNil
testVerifyReverse_TamperedAt3_Returns3
testVerifyReverse_TamperedAtFirst_Returns0
testVerifyReverse_TamperedAtLast_ReturnsLastIndex
testVerifyReverse_StartIndex0_VerifiesAll
testVerifyReverse_StartIndex5_VerifiesFrom5
testVerifyReverse_StartIndexBeyondChain_ReturnsStartIndex
testVerifyReverse_EmptyHashes_ReturnsNil
testVerifyReverse_PartialVerification_DetectsCorrectIndex
testVerifyReverse_ResumeScenario_VerifyFromCheckpoint
testVerifyReverse_MultipleTampered_ReturnsFirst
testVerifyReverse_BinarySearchCapable_FindsExact
testVerifyReverse_1000Chunks_PerformanceOK
testVerifyReverse_SingleChunk_Valid
testVerifyReverse_SingleChunk_Tampered_Returns0
```

#### MARK: - Jump Chain (20 tests)
```
testJumpChain_EmptyChain_Valid
testJumpChain_1Chunk_HasJumpEntry
testJumpChain_StrideIsSqrtN
testJumpChain_JumpHash_SHA256_JumpDomain_Commitment
testJumpChain_JumpDomain_CCv1_JUMP_Null
testJumpChain_Valid_ReturnsTrue
testJumpChain_Tampered_ReturnsFalse
testJumpChain_4Chunks_Stride2
testJumpChain_9Chunks_Stride4
testJumpChain_16Chunks_Stride5
testJumpChain_100Chunks_Stride11
testJumpChain_256Chunks_Stride17
testJumpChain_VerifyOSqrtN_Complexity
testJumpChain_ConsistentWithForwardChain
testJumpChain_After1000Chunks_Valid
testJumpChain_AfterTampering_Invalid
testJumpChain_GrowsWithChain
testJumpChain_JumpEntryCount_Correct
testJumpChain_StrideUpdates_OnAppend
testJumpChain_DeterministicJumpHashes
```

#### MARK: - Session Binding (10 tests)
```
testSessionBinding_SameChunks_DifferentSession_DifferentChain
testSessionBinding_SessionIdInGenesis
testSessionBinding_CannotReplayAcrossSessions
testSessionBinding_EmptySessionId_StillBound
testSessionBinding_UUIDSessionId_Works
testSessionBinding_LongSessionId_Works
testSessionBinding_ConcurrentAccess_ActorSafe
testSessionBinding_MultipleChains_Independent
testSessionBinding_GenesisUniquePerSession
testSessionBinding_1000DifferentSessions_AllDifferent
```

#### MARK: - Hex Conversion (10 tests)
```
testHexConversion_ValidHex_Converts
testHexConversion_InvalidHex_ReturnsNil
testHexConversion_OddLength_ReturnsNil
testHexConversion_Empty_ReturnsEmptyData
testHexConversion_Uppercase_Works
testHexConversion_MixedCase_Works
testHexConversion_NonHexChars_ReturnsNil
testHexConversion_Roundtrip_DataToHexToData
testHexConversion_AllBytes_00toFF
testHexConversion_SHA256Length_64Chars
```

---

### ═══════════════════════════════════════════
### 文件 5: `UploadCircuitBreakerTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `UploadCircuitBreaker` (actor), `CircuitState`

#### MARK: - Initial State (8 tests)
```
testInitial_State_IsClosed
testInitial_ShouldAllowRequest_ReturnsTrue
testInitial_NoFailures_Recorded
testInitial_CircuitState_AllCases_Exist
testInitial_CircuitState_Closed_RawValue
testInitial_CircuitState_Open_RawValue
testInitial_CircuitState_HalfOpen_RawValue
testInitial_CircuitState_Sendable
```

#### MARK: - Closed → Open Transition (12 tests)
```
testClosed_1Failure_StillClosed
testClosed_4Failures_StillClosed
testClosed_5Failures_OpensCircuit
testClosed_ExactlyThreshold_Opens
testClosed_SuccessResetsCounter
testClosed_4Failures_1Success_ResetTo0
testClosed_4Failures_1Success_1Failure_StillClosed
testClosed_ShouldAllowRequest_AlwaysTrue
testClosed_RecordSuccess_KeepsClosed
testClosed_AlternatingFailureSuccess_NeverOpens
testClosed_5FailuresConsecutive_Opens
testClosed_FailureThreshold_Equals5
```

#### MARK: - Open State (10 tests)
```
testOpen_ShouldAllowRequest_ReturnsFalse
testOpen_ImmediatelyAfterOpen_Blocked
testOpen_RecordFailure_UpdatesTimestamp
testOpen_RecordSuccess_StaysOpen_Unexpected
testOpen_After29Seconds_StillBlocked
testOpen_After30Seconds_TransitionsToHalfOpen
testOpen_After31Seconds_AllowsRequest
testOpen_TimeBasedTransition_HalfOpenInterval30s
testOpen_MultipleFailures_ResetTimer
testOpen_State_ReportsOpen
```

#### MARK: - Half-Open State (15 tests)
```
testHalfOpen_ShouldAllowRequest_ReturnsTrue
testHalfOpen_1Success_StillHalfOpen
testHalfOpen_2Successes_CloseCircuit
testHalfOpen_ExactlySuccessThreshold_Closes
testHalfOpen_1Failure_OpensAgain
testHalfOpen_SuccessThreshold_Equals2
testHalfOpen_AfterClose_FailureCountReset
testHalfOpen_AfterClose_SuccessCountReset
testHalfOpen_1Success_1Failure_OpensAgain
testHalfOpen_Failure_SetsTimestamp
testHalfOpen_Failure_FailureCountEqualsThreshold
testHalfOpen_Success_CountIncrementsCorrectly
testHalfOpen_SuccessCountResets_OnReopen
testHalfOpen_State_ReportsHalfOpen
testHalfOpen_MultipleTransitions_Stable
```

#### MARK: - Reset (8 tests)
```
testReset_FromClosed_StaysClosed
testReset_FromOpen_GoesToClosed
testReset_FromHalfOpen_GoesToClosed
testReset_ClearsFailureCount
testReset_ClearsSuccessCount
testReset_ClearsLastFailureTime
testReset_ShouldAllowRequest_True
testReset_CanResetMultipleTimes
```

#### MARK: - Full Lifecycle (7 tests)
```
testLifecycle_ClosedToOpenToHalfOpenToClosed
testLifecycle_ClosedToOpenToHalfOpenToOpen
testLifecycle_RepeatCycling_5Times
testLifecycle_RapidTransitions_NoCorruption
testLifecycle_ConcurrentAccess_ActorSafe
testLifecycle_10ConcurrentRecordFailure_Correct
testLifecycle_MixedConcurrentOperations_NoRace
```

---

### ═══════════════════════════════════════════
### 文件 6: `ErasureCodingEngineTests.swift` (120+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ErasureCodingEngine` (actor), `RaptorQEngine` (actor), `ErasureCodingMode`, `ErasureCodingError`, `ChunkPriority`

#### MARK: - Mode Selection (20 tests)
```
testSelectCoder_10Chunks_1PercentLoss_RSgf256
testSelectCoder_10Chunks_8PercentLoss_RaptorQ
testSelectCoder_10Chunks_7_9PercentLoss_RSgf256
testSelectCoder_10Chunks_8_0PercentLoss_RaptorQ
testSelectCoder_255Chunks_1PercentLoss_RSgf256
testSelectCoder_256Chunks_1PercentLoss_RSgf65536
testSelectCoder_256Chunks_3PercentLoss_RaptorQ
testSelectCoder_256Chunks_2_9PercentLoss_RSgf65536
testSelectCoder_1000Chunks_1PercentLoss_RSgf65536
testSelectCoder_1000Chunks_5PercentLoss_RaptorQ
testSelectCoder_1Chunk_0Loss_RSgf256
testSelectCoder_0Chunks_ReturnsRSgf256
testSelectCoder_MaxInt_HighLoss_RaptorQ
testSelectCoder_ExactlyThreshold255_RSgf256
testSelectCoder_ExactlyThreshold256_RSgf65536_LowLoss
testSelectCoder_LossRate0_RSgf256_ForSmall
testSelectCoder_LossRate1_0_RaptorQ
testSelectCoder_NegativeLossRate_HandledGracefully
testSelectCoder_LossRateAbove1_HandledGracefully
testSelectCoder_BoundaryConditions_AllCorrect
```

#### MARK: - Reed-Solomon Encoding (20 tests)
```
testRSEncode_SingleBlock_10PercentRedundancy
testRSEncode_20Blocks_10PercentRedundancy_22Total
testRSEncode_20Blocks_20PercentRedundancy_24Total
testRSEncode_20Blocks_40PercentRedundancy_28Total
testRSEncode_SystematicCode_FirstKBlocksUnchanged
testRSEncode_ParityBlocksAdded
testRSEncode_EmptyData_ReturnsEmpty
testRSEncode_1Block_Minimum
testRSEncode_255Blocks_GF256Max
testRSEncode_Redundancy0_NoParityBlocks
testRSEncode_Redundancy1_0_DoubleBlocks
testRSEncode_OutputCount_EqualsK_Plus_Parity
testRSEncode_AllBlocksSameSize
testRSEncode_DeterministicOutput
testRSEncode_DifferentData_DifferentParity
testRSEncode_LargeBlocks_1MB
testRSEncode_SmallBlocks_1Byte
testRSEncode_EmptyBlocks_Handled
testRSEncode_OriginalDataPreserved
testRSEncode_GF256_Field_Selection
```

#### MARK: - Reed-Solomon Decoding (20 tests)
```
testRSDecode_NoErasures_RecoversOriginal
testRSDecode_1Erasure_Recovers
testRSDecode_2Erasures_Recovers
testRSDecode_MaxErasures_Recovers
testRSDecode_TooManyErasures_Throws
testRSDecode_AllNil_ThrowsDecodingFailed
testRSDecode_EmptyBlocks_ThrowsError
testRSDecode_OriginalCount0_HandlesGracefully
testRSDecode_OriginalCountGreaterThanBlocks_Throws
testRSDecode_SystematicDecoding_FirstKBlocks
testRSDecode_RecoveredData_MatchesOriginal
testRSDecode_NilInParityPosition_StillDecodes
testRSDecode_NilInDataPosition_Recovers
testRSDecode_ConsecutiveErasures_Recovers
testRSDecode_RandomErasures_Recovers
testRSDecode_SingleBlock_NoErasure
testRSDecode_255Blocks_MaxGF256
testRSDecode_InsufficientBlocks_ThrowsError
testRSDecode_DeterministicRecovery
testRSDecode_Roundtrip_EncodeDecodeLossless
```

#### MARK: - RaptorQ (20 tests)
```
testRaptorQ_Encode_AddsRepairSymbols
testRaptorQ_Encode_SystematicOutput
testRaptorQ_Encode_RepairCountCorrect
testRaptorQ_Encode_OverheadTargetMet
testRaptorQ_Decode_NoLoss_Recovers
testRaptorQ_Decode_2PercentLoss_Recovers
testRaptorQ_Decode_10PercentLoss_Recovers
testRaptorQ_Decode_TooMuchLoss_ThrowsError
testRaptorQ_MaxRepairRatio_2x_Respected
testRaptorQ_SymbolAlignment_64Bytes
testRaptorQ_LDPCDensity_001
testRaptorQ_PreCoding_LDPCandHDPC
testRaptorQ_GaussianElimination_Correct
testRaptorQ_InactivationDecoding_ThresholdMet
testRaptorQ_FountainProperty_RatelessGeneration
testRaptorQ_LargeData_256Chunks
testRaptorQ_SmallData_1Chunk
testRaptorQ_Roundtrip_EncodeDecode
testRaptorQ_DeterministicOutput
testRaptorQ_DifferentRedundancy_DifferentRepair
```

#### MARK: - Unequal Error Protection (10 tests)
```
testUEP_Priority0_3xRedundancy
testUEP_Priority1_2_5xRedundancy
testUEP_Priority2_1_5xRedundancy
testUEP_Priority3_1xRedundancy
testUEP_CriticalChunks_MostProtected
testUEP_LowPriorityChunks_LeastProtected
testUEP_ChunkPriority_AllCases_Exist
testUEP_ChunkPriority_RawValues_Sequential
testUEP_ChunkPriority_Critical_Is0
testUEP_ChunkPriority_Low_Is3
```

#### MARK: - Error Types (10 tests)
```
testError_DecodingFailed_IsError
testError_InsufficientBlocks_IsError
testError_InvalidRedundancy_IsError
testError_DecodingFailed_Sendable
testError_InsufficientBlocks_Sendable
testError_InvalidRedundancy_Sendable
testError_AllCases_Distinct
testError_EquatableConformance
testError_Description_NotEmpty
testError_CanBeCaughtAndRethrown
```

#### MARK: - Adaptive Fallback (10 tests)
```
testFallback_RSFails_FallsToRaptorQ
testFallback_LargeChunkCount_AutoSelectsRaptorQ
testFallback_HighLossRate_AutoSelectsRaptorQ
testFallback_LowChunkCount_LowLoss_UsesRS
testFallback_RaptorQEngineCreatedLazily
testFallback_RaptorQEngineReused
testFallback_ConcurrentEncoding_ActorSafe
testFallback_ConcurrentDecoding_ActorSafe
testFallback_EncodeDecodeMixedBlocks
testFallback_Roundtrip_WithFallback
```

#### MARK: - Edge Cases & Performance (10 tests)
```
testEdge_MaxUInt16Blocks_Handles
testEdge_1ByteBlocks_Handles
testEdge_MixedSizeBlocks_Handles
testEdge_ZeroRedundancy_NoExtraBlocks
testEdge_100PercentRedundancy_DoubleBlocks
testEdge_NegativeRedundancy_HandledGracefully
testEdge_VeryLargeData_10MB_PerBlock
testPerformance_RS_20Blocks_Under10ms
testPerformance_RaptorQ_256Blocks_Under100ms
testPerformance_1000Encodes_NoMemoryLeak
```

---

### ═══════════════════════════════════════════
### 文件 7: `FusionSchedulerTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `FusionScheduler` (actor)

#### MARK: - Initialization & Default (10 tests)
#### MARK: - MPC Controller (10 tests)
#### MARK: - ABR Controller (15 tests)
#### MARK: - EWMA Controller (10 tests)
#### MARK: - Kalman Controller (10 tests)
#### MARK: - ML Controller (10 tests)
#### MARK: - Weighted Trimmed Mean Fusion (15 tests)
#### MARK: - Lyapunov Safety Valve (10 tests)
#### MARK: - Page Alignment & Clamping (10 tests)

重点测试:
- `decideChunkSize()` 输出始终在 [CHUNK_SIZE_MIN, CHUNK_SIZE_MAX] 范围
- 输出始终对齐到 16KB (16384) 边界
- ABR: 队列<1MB→最大块, <10MB→默认, ≥10MB→最小
- EWMA: α=0.3, 目标3秒传输时间
- Kalman: rising→增加STEP, falling→减少STEP, stable→保持
- 加权截尾均值: 去掉最高最低, 按权重平均
- 空candidates→返回DEFAULT
- 2个candidate→不截尾, 取第一个
- 5个controller都参与(有ML时)
- 4个controller参与(无ML时)

---

### ═══════════════════════════════════════════
### 文件 8: `ContentDefinedChunkerTests.swift` (180+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ContentDefinedChunker` (actor), `CDCBoundary`, `CDCDedupRequest/Response`

#### MARK: - Gear Table (20 tests)
- gear table 有 256 个条目
- deterministic: 每次生成相同
- version = "v1"
- 每个条目是 UInt64

#### MARK: - Boundary Detection (30 tests)
- 最小块 >= CDC_MIN_CHUNK_SIZE (256KB)
- 最大块 <= CDC_MAX_CHUNK_SIZE (8MB)
- 平均块 ≈ CDC_AVG_CHUNK_SIZE (1MB) ± 30%
- normalization level = 1
- 空文件→空boundary数组
- 1字节文件→单个boundary
- 小于min的文件→单个boundary
- 大于max的→强制切割
- 连续相同数据→regular boundaries
- 随机数据→分布均匀

#### MARK: - Hash Correctness (20 tests)
- SHA-256 per boundary matches HashCalculator
- CRC32C per boundary matches independent calculation
- offset + size 覆盖整个文件
- 无间隙无重叠

#### MARK: - Deduplication Protocol (20 tests)
- CDCDedupRequest 编码/解码
- CDCDedupResponse 编码/解码
- existingChunks + missingChunks = total
- savedBytes >= 0
- dedupRatio 0-1

#### MARK: - Determinism (20 tests)
- 同一文件→相同boundaries
- 不同文件→不同boundaries (除非相同内容)
- 跨平台: 同内容同结果

#### MARK: - Normalization (15 tests)
- normalization减少variance ~30%
- normalization不改变总数据量

#### MARK: - Performance (10 tests)
- 10MB文件 < 100ms
- 100MB文件 < 1s
- 1GB文件 < 10s

#### MARK: - Edge Cases (25 tests)
- 空数据、极大文件、全0数据、全1数据
- Unicode文件名、特殊字符文件名
- 只读文件、符号链接
- 文件大小刚好等于min/max

#### MARK: - Concurrent Access (20 tests)
- 10个并发chunker同时处理不同文件
- actor隔离正确

---

### ═══════════════════════════════════════════
### 文件 9: `MultiLayerProgressTrackerTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `MultiLayerProgressTracker` (actor), `MultiLayerProgress`, `ETAEstimate`

#### MARK: - 4-Layer Progress (25 tests)
- Wire (A) → ACK (B) → Merkle (C) → ServerReconstructed (D)
- 每层 0.0-1.0
- Wire >= ACK >= Merkle >= ServerReconstructed
- 每次update都是单调递增

#### MARK: - Monotonic Guarantee (20 tests)
- displayProgress 永不减小
- max(lastDisplayed, computed)
- 即使某层回退, display不回退

#### MARK: - Safety Valves (15 tests)
- Wire-ACK 差值 > 8% → 异常
- ACK-Merkle 差值 > 0 → 异常

#### MARK: - ETA Estimation (15 tests)
- minSeconds <= bestEstimate <= maxSeconds
- 进度0→ETA为无穷大或NaN
- 进度100%→ETA为0

#### MARK: - Smoothing (10 tests)
- Savitzky-Golay smoothing
- 平滑不改变最终值

#### MARK: - Edge Cases (15 tests)
- 0 totalBytes
- 负数bytes
- 超过totalBytes
- 并发更新

---

### ═══════════════════════════════════════════
### 文件 10: `EnhancedResumeManagerTests.swift` (120+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `EnhancedResumeManager` (actor), `ResumeState`, `FileFingerprint`, `ResumeLevel`, `ResumeError`

#### MARK: - FileFingerprint (20 tests)
- 计算正确: fileSize, sha256Hex, createdAt, modifiedAt
- 同一文件→相同fingerprint
- 修改后→不同fingerprint
- 重命名→相同fingerprint (内容不变)

#### MARK: - 3-Level Resume (30 tests)
- Level 1: 本地 fingerprint 匹配
- Level 2: + 服务器 chunk 验证
- Level 3: + Merkle root + commitment tip 全完整性
- 每级失败→降级

#### MARK: - AES-GCM Encryption (20 tests)
- persist加密→load解密→内容一致
- 错误密钥→解密失败
- 密钥派生: HKDF-SHA256
- 版本v2→AES-GCM

#### MARK: - Atomic Persistence (15 tests)
- write→fsync→rename
- 崩溃中途→不损坏
- 并发persist→actor安全

#### MARK: - Error Handling (15 tests)
- encryptionFailed
- decryptionFailed
- persistenceFailed
- fingerprintMismatch
- invalidState

#### MARK: - Edge Cases (20 tests)

---

### ═══════════════════════════════════════════
### 文件 11: `ChunkIntegrityValidatorTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ChunkIntegrityValidator` (actor)

#### MARK: - Pre-Upload Validation (25 tests)
- hash校验: SHA-256匹配
- index范围: 0 to totalChunks-1
- size范围: MIN to MAX
- monotonic counter: 递增
- nonce freshness: 120秒窗口
- nonce不可重用 (LRU)

#### MARK: - Post-ACK Validation (15 tests)
- 服务器响应hash匹配
- chunkIndex匹配
- receivedSize匹配

#### MARK: - Nonce Validation (25 tests)
- 有效nonce→true
- 过期nonce→false
- 重用nonce→false
- LRU eviction, max 8000
- 120秒窗口

#### MARK: - Commitment Chain Validation (15 tests)
- 有效chain→success
- 断链→failure

#### MARK: - Edge Cases (20 tests)

---

### ═══════════════════════════════════════════
### 文件 12: `NetworkPathObserverTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `NetworkPathObserver` (actor), `NetworkPathEvent`, `InterfaceType`, `ChangeType`

#### MARK: - Event Types (15 tests)
#### MARK: - AsyncStream (15 tests)
#### MARK: - Path Change Detection (15 tests)
#### MARK: - Cross-Platform (15 tests)

---

### ═══════════════════════════════════════════
### 文件 13: `ChunkIdempotencyManagerTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ChunkIdempotencyManager` (actor)

#### MARK: - Key Generation (15 tests)
- sessionId + chunkIndex + chunkHash → 唯一key
- 相同输入→相同key
- 不同输入→不同key

#### MARK: - Cache Operations (20 tests)
- store→check→hit
- miss→store→hit
- 过期→miss

#### MARK: - Replay Detection (15 tests)
- 重复上传→返回缓存
- 不同chunk→新请求

#### MARK: - Cleanup (10 tests)
- 过期条目自动清理

---

### ═══════════════════════════════════════════
### 文件 14: `CIDMapperTests.swift` (40+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `CIDMapper` (enum)

#### MARK: - ACI → CID (15 tests)
- 有效ACI→CID v1
- 无效ACI→nil
- Multicodec编码正确

#### MARK: - CID → ACI (15 tests)
- 有效CID→ACI
- 无效CID→nil
- Base32解码正确

#### MARK: - Roundtrip (10 tests)
- ACI→CID→ACI 一致
- CID→ACI→CID 一致

---

### ═══════════════════════════════════════════
### 文件 15: `ConnectionPrewarmerTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ConnectionPrewarmer` (actor), `PrewarmingStage`

#### MARK: - Stage Progression (20 tests)
- notStarted → dnsResolved → tcpConnected → tlsHandshaked → http2Ready → ready
- 每个stage正确

#### MARK: - DNS Pre-Resolution (10 tests)
#### MARK: - Prewarmed Session (15 tests)
#### MARK: - QUIC Probe (15 tests)

---

### ═══════════════════════════════════════════
### 文件 16: `UploadTelemetryTests.swift` (40+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `UploadTelemetry` (actor), `TelemetryEntry`, `LayerTimings`

#### MARK: - HMAC Signing (15 tests)
- 每条entry有HMAC签名
- 不同entry→不同HMAC
- 同entry同key→同HMAC
- 篡改entry→HMAC不匹配

#### MARK: - Differential Privacy (15 tests)
- ε=1.0 Laplace noise
- hash前缀只取前8字符

#### MARK: - Entry Management (10 tests)

---

### ═══════════════════════════════════════════
### 文件 17: `UnifiedResourceManagerTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `UnifiedResourceManager` (actor)

#### MARK: - Upload Budget (20 tests)
```
testGetUploadBudget_Always1_0
testGetUploadBudget_NeverBelow1_0
testGetUploadBudget_NeverAbove1_0
testShouldPauseUpload_AlwaysFalse
testShouldPauseUpload_NeverTrue
testShouldPauseUpload_EvenUnderMemoryPressure_False
testShouldPauseUpload_EvenLowBattery_False
testShouldPauseUpload_EvenCriticalThermal_False
(12 more tests for "upload speed is sacred" principle)
```

#### MARK: - Memory Strategy (20 tests)
- full: 12 buffers
- reduced: 8 buffers
- minimal: 4 buffers
- emergency: 2 buffers
- NEVER below 2

#### MARK: - Thermal Budget (10 tests)
- 始终返回 unrestricted 或不影响upload

#### MARK: - Edge Cases (10 tests)

---

### ═══════════════════════════════════════════
### 文件 18: `ProofOfPossessionTests.swift` (80+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ProofOfPossession` (actor), `ChallengeRequest`, `ChallengeResponse`, `ChallengeType`

#### MARK: - Challenge Generation (20 tests)
- 文件大小→challenge数量
- 大文件→更多challenges
- challenge类型: fullHash, partialHash, merkleProof

#### MARK: - Nonce Validation (20 tests)
- UUID v7 格式
- 15秒过期
- 重放→拒绝
- 过期nonce→拒绝

#### MARK: - Challenge Types (15 tests)
#### MARK: - Anti-Replay (15 tests)
#### MARK: - Edge Cases (10 tests)

---

### ═══════════════════════════════════════════
### 文件 19: `ByzantineVerifierTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ByzantineVerifier` (actor), `VerificationResult`

#### MARK: - Sample Calculation (15 tests)
- Fisher-Yates shuffle
- 样本数量计算正确
- coverage target 0.999

#### MARK: - Verification (20 tests)
- 所有valid→success
- 部分invalid→failed + 列表
- coverage计算正确

#### MARK: - Edge Cases (15 tests)
#### MARK: - Reset (10 tests)

---

### ═══════════════════════════════════════════
### 文件 20: `ChunkBufferPoolTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `ChunkBufferPool` (actor)

#### MARK: - Allocation (15 tests)
- acquire返回对齐到16KB的buffer
- release后可重新acquire
- 池空→返回nil

#### MARK: - Memory Pressure (15 tests)
- adjustForMemoryPressure→减少buffer
- NEVER below 2 buffers
- 恢复后→增加buffer

#### MARK: - Zero-Alloc Loop (15 tests)
- acquire→use→release循环不分配新内存
- 100次循环→0次分配

#### MARK: - Buffer Zeroing (15 tests)
- release时buffer被zeroed (memset_s)
- deinit时所有buffer被zeroed并释放

---

### ═══════════════════════════════════════════
### 文件 21: `MLBandwidthPredictorTests.swift` (120+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `MLBandwidthPredictor` (actor)

#### MARK: - Kalman Fallback (25 tests)
- 没有CoreML→完全使用Kalman
- warmup期间(< 10 samples)→纯Kalman
- Linux→总是Kalman

#### MARK: - Ensemble Weighting (25 tests)
- weight在[0.3, 0.7]范围
- accuracy高→weight高
- accuracy低→weight低

#### MARK: - Prediction (25 tests)
- source标记正确(.ml, .kalman, .ensemble)
- predictedBps非负
- confidenceInterval正确

#### MARK: - History & Warmup (25 tests)
- 历史保持最近30个sample
- 10个sample前→kalman only

#### MARK: - Edge Cases (20 tests)

---

### ═══════════════════════════════════════════
### 文件 22: `CAMARAQoDClientTests.swift` (80+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `CAMARAQoDClient` (actor), `QualityGrant`, `QoDError`, `QoSProfile`

#### MARK: - QoS Profile (10 tests)
#### MARK: - OAuth2 Flow (20 tests)
#### MARK: - Session Lifecycle (20 tests)
#### MARK: - Error Handling (15 tests)
#### MARK: - Token Management (15 tests)

---

### ═══════════════════════════════════════════
### 文件 23: `MultipathUploadManagerTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `MultipathUploadManager` (actor), `MultipathStrategy`, `PathInfo`, `NetworkInterface`

#### MARK: - Strategy (20 tests)
- 默认策略: .aggregate
- WiFiOnly, handover, interactive, aggregate

#### MARK: - Path Assignment (25 tests)
- critical priority→最佳路径
- chunk分配到正确路径

#### MARK: - Dual-Radio (20 tests)
#### MARK: - Path Detection (20 tests)
#### MARK: - Edge Cases (15 tests)

---

### ═══════════════════════════════════════════
### 文件 24: `RaptorQEngineTests.swift` (200+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `RaptorQEngine` (actor)

#### MARK: - Systematic Encoding (30 tests)
#### MARK: - Repair Symbol Generation (30 tests)
#### MARK: - Pre-Coding (LDPC + HDPC) (25 tests)
#### MARK: - Gaussian Elimination (25 tests)
#### MARK: - Inactivation Decoding (20 tests)
#### MARK: - Roundtrip (20 tests)
#### MARK: - GF(256) Arithmetic (25 tests)
#### MARK: - Edge Cases (25 tests)

---

### ═══════════════════════════════════════════
### 文件 25: `PR9CertificatePinManagerTests.swift` (60+ 测试)
### ═══════════════════════════════════════════

**测试对象**: `PR9CertificatePinManager` (actor)

#### MARK: - Pin Management (20 tests)
- activePins 可变
- backupPins 可变
- 72h rotation overlap

#### MARK: - Pin Rotation (15 tests)
- rotatePins→旧pin进入backup
- backup超过72h→清除

#### MARK: - Validation (15 tests)
#### MARK: - Error Handling (10 tests)

---

### ═══════════════════════════════════════════
### 文件 26: `PR9PerformanceTests.swift` (100+ 测试)
### ═══════════════════════════════════════════

#### MARK: - Zero-Copy I/O Throughput (15 tests)
#### MARK: - Hash Computation Speed (15 tests)
#### MARK: - Merkle Tree Memory Efficiency (15 tests)
#### MARK: - Buffer Pool Zero-Alloc (15 tests)
#### MARK: - Kalman Convergence Speed (15 tests)
#### MARK: - CDC Throughput (15 tests)
#### MARK: - Circuit Breaker Latency (10 tests)

---

### ═══════════════════════════════════════════
### 文件 27: `PR9SecurityTests.swift` (65+ 测试)
### ═══════════════════════════════════════════

#### MARK: - TLS 1.3 Enforcement (10 tests)
#### MARK: - Per-Chunk HMAC-SHA256 (10 tests)
#### MARK: - Buffer Zeroing (10 tests)
#### MARK: - Nonce Freshness (10 tests)
#### MARK: - Fail-Closed Verification (10 tests)
#### MARK: - Log Truncation (8 tests)
#### MARK: - AES-GCM Encryption (7 tests)

---

### ═══════════════════════════════════════════
### 已有测试文件（保留不动，不要修改）
### ═══════════════════════════════════════════

以下 10 个文件已存在于 `Tests/Upload/`，**不要修改、删除或重复**：

1. `BundleManifestTests.swift` (684 lines)
2. `ImmutableBundleTests.swift` (727 lines)
3. `HashCalculatorTests.swift` (325 lines)
4. `BundleConstantsTests.swift` (175 lines)
5. `DeviceInfoTests.swift` (214 lines)
6. `NetworkSpeedMonitorTests.swift` (184 lines)
7. `AdaptiveChunkSizerTests.swift` (59 lines)
8. `ChunkManagerTests.swift` (66 lines)
9. `UploadSessionTests.swift` (70 lines)
10. `UploadResumeManagerTests.swift` (66 lines)

---

## 执行计划

### Phase 1: 基础层测试（5个文件，先创建这些）
1. `HybridIOEngineTests.swift` — 100 tests
2. `ChunkBufferPoolTests.swift` — 60 tests
3. `ChunkIntegrityValidatorTests.swift` — 100 tests
4. `UnifiedResourceManagerTests.swift` — 60 tests
5. `UploadCircuitBreakerTests.swift` — 60 tests

### Phase 2: 算法层测试（5个文件）
6. `KalmanBandwidthPredictorTests.swift` — 100 tests
7. `StreamingMerkleTreeTests.swift` — 120 tests
8. `ChunkCommitmentChainTests.swift` — 100 tests
9. `ContentDefinedChunkerTests.swift` — 180 tests
10. `ErasureCodingEngineTests.swift` — 120 tests

### Phase 3: 高级算法测试（5个文件）
11. `FusionSchedulerTests.swift` — 100 tests
12. `RaptorQEngineTests.swift` — 200 tests
13. `MLBandwidthPredictorTests.swift` — 120 tests
14. `MultiLayerProgressTrackerTests.swift` — 100 tests
15. `EnhancedResumeManagerTests.swift` — 120 tests

### Phase 4: 集成与辅助测试（7个文件）
16. `ProofOfPossessionTests.swift` — 80 tests
17. `ByzantineVerifierTests.swift` — 60 tests
18. `CIDMapperTests.swift` — 40 tests
19. `ConnectionPrewarmerTests.swift` — 60 tests
20. `UploadTelemetryTests.swift` — 40 tests
21. `ChunkIdempotencyManagerTests.swift` — 60 tests
22. `NetworkPathObserverTests.swift` — 60 tests

### Phase 5: 安全与性能测试（3个文件）
23. `MultipathUploadManagerTests.swift` — 100 tests
24. `CAMARAQoDClientTests.swift` — 80 tests
25. `PR9CertificatePinManagerTests.swift` — 60 tests

### Phase 6: 顶层测试（2个文件）
26. `PR9PerformanceTests.swift` — 100 tests
27. `PR9SecurityTests.swift` — 65 tests

---

## 关键质量要求

### 每个测试方法必须:
1. 有描述性的名字 (test + 场景 + 预期结果)
2. 有明确的 Arrange → Act → Assert 结构
3. XCTAssert 包含 message 参数
4. 测试单一行为（一个测试一个断言或紧密相关的一组断言）
5. 不依赖其他测试的执行顺序
6. 清理临时资源（defer 模式）

### 每个测试文件必须:
1. 编译通过（`swift build --build-tests`）
2. 所有测试通过（`swift test --filter XxxTests`）
3. 覆盖正常路径 + 错误路径 + 边界条件 + 并发安全
4. Actor 测试使用 `func testXxx() async throws` 模式
5. 不使用 `@MainActor`、不使用 `async setUp/tearDown`

### 断言分布要求:
- 正常路径 (happy path): 40%
- 错误路径 (error path): 25%
- 边界条件 (boundary): 20%
- 并发安全 (concurrency): 10%
- 性能验证 (performance): 5%

---

## 总计目标

| 指标 | 目标 |
|------|------|
| 新测试文件 | 27 |
| 总测试方法 | 2000+ |
| 总断言数 | 3000+ |
| 总代码行数 | ~15000 |
| 代码覆盖率 | 41个实现文件全覆盖 |
| 跨平台 | macOS + Linux 均通过 |

---

## 开始吧！

请从 **Phase 1** 开始，按照上面的执行计划，一个文件一个文件地创建。每完成一个文件后，立刻编译测试确保通过，然后继续下一个文件。

**每个文件完成后运行**:
```bash
swift build --build-tests 2>&1 | tail -20
swift test --filter XxxTests --disable-swift-testing 2>&1 | tail -30
```

现在开始创建 Phase 1 的第一个文件: `HybridIOEngineTests.swift`
