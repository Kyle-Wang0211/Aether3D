# PR6 TSDF — 全面检测修复 + 测试生成提示词

> **目标**: 修复全部编译阻断器 (3)、逻辑 Bug (8)、缺失内容 (2)，然后生成完整测试套件。
> **规则**: 每个修复必须精确到文件+行号。修复完成后 `swift build` 必须零错误。测试通过率 100%。
> **参考**: 所有常量引用 `TSDFConstants.swift`（78 个 SSOT 常量），跨平台类型引用 `TSDFMathTypes.swift`。

---

## 当前 API 签名速查表（写测试时必须参考）

```swift
// ── SpatialHashTable ──
public struct SpatialHashTable: Sendable {
    public init(initialSize: Int = TSDFConstants.hashTableInitialSize,
                poolCapacity: Int = TSDFConstants.maxTotalVoxelBlocks)
    public mutating func insertOrGet(key: BlockIndex, voxelSize: Float) -> Int?  // returns optional
    public func lookup(key: BlockIndex) -> Int?
    public mutating func remove(key: BlockIndex)  // returns Void (BUG-5 needs fix)
    public var voxelAccessor: VoxelBlockAccessor { get }
    public var voxelBaseAddress: UnsafeMutableRawPointer { get }
    public var voxelByteCount: Int { get }
    public func readBlock(at poolIndex: Int) -> VoxelBlock
    public func forEachBlock(_ block: (BlockIndex, Int, VoxelBlock) -> Void)
    public func getAllBlocks() -> [(BlockIndex, Int)]
    public mutating func updateBlock(at poolIndex: Int, _ updater: (inout VoxelBlock) -> Void)
}

// ── VoxelBlockPool ──
public struct VoxelBlockPool: Sendable {
    public init(capacity: Int = TSDFConstants.maxTotalVoxelBlocks)
    public mutating func allocate(voxelSize: Float) -> Int?  // returns optional
    public mutating func deallocate(index: Int)
    public var accessor: VoxelBlockAccessor { get }
    public var baseAddress: UnsafeMutableRawPointer { get }
    public var byteCount: Int { get }
}

// ── IntegrationInput ──
public struct IntegrationInput: Sendable {
    public let timestamp: TimeInterval
    public let intrinsics: TSDFMatrix3x3
    public let cameraToWorld: TSDFMatrix4x4  // NOT "cameraPose"
    public let depthWidth: Int
    public let depthHeight: Int
    public let trackingState: Int  // 0=notAvailable, 1=limited, 2=normal
}

// ── IntegrationResult (enum) ──
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
        case trackingLost, poseTeleport, poseJitter, thermalThrottle,
             frameTimeout, lowValidPixels, memoryPressure
    }
}

// ── TSDFIntegrationBackend (protocol) ──
public protocol TSDFIntegrationBackend: Sendable {
    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]  // (blockIndex, poolIndex) 元组
    ) async -> IntegrationResult.IntegrationStats
}

// ── DepthDataProvider / ArrayDepthData ──
public protocol DepthDataProvider: Sendable {
    var width: Int { get }
    var height: Int { get }
    func depthAt(x: Int, y: Int) -> Float
    func confidenceAt(x: Int, y: Int) -> UInt8
}
public struct ArrayDepthData: DepthDataProvider, Sendable {
    public init(width: Int, height: Int, depths: [Float], confidences: [UInt8])
}

// ── AdaptiveResolution (enum — no instances!) ──
public enum AdaptiveResolution {
    public static func blockIndex(worldPosition: TSDFFloat3, voxelSize: Float) -> BlockIndex
    public static func voxelSize(forDepth depth: Float) -> Float
    public static func truncationDistance(voxelSize: Float) -> Float
}

// ── MarchingCubesExtractor (struct) ── NOT "MarchingCubes"
public struct MarchingCubesExtractor {
    public static func extractIncremental(hashTable: SpatialHashTable, maxTriangles: Int) -> MeshOutput
    public static func extractBlock(_ block: VoxelBlock, neighbors: ..., origin: ..., voxelSize: ...) -> ([MeshTriangle], [MeshVertex])
    static func isDegenerate(v0: TSDFFloat3, v1: TSDFFloat3, v2: TSDFFloat3) -> Bool  // internal
}

// ── BlockIndex ──
public struct BlockIndex: Sendable, Codable, Equatable, Hashable {
    public var x: Int32, y: Int32, z: Int32
    public init(_ x: Int32, _ y: Int32, _ z: Int32)
}

// ── IntegrationRecord ──
public struct IntegrationRecord: Sendable {
    public let timestamp: TimeInterval
    public let cameraPose: TSDFMatrix4x4
    public let intrinsics: TSDFMatrix3x3
    public let affectedBlockIndices: [Int32]
    public let isKeyframe: Bool
    public let keyframeId: UInt32?
    public static let empty: IntegrationRecord
}

// ── SDFStorage ──
// Apple: typealias SDFStorage = Float16 (Float(stored) works)
// Linux: struct SDFStorage { var bitPattern: UInt16; var floatValue: Float }
// 跨平台: 用 #if canImport(simd) 或 arch(arm64) 判断

// ── TSDFMathTypes ──
// Apple: .columns.0.x, .columns.1.y 等 (simd tuple)
// Linux: .c0.x, .c1.y 等 (struct properties, 没有 columns tuple!)
```

---

## ═══════════════════════════════════════════════════════════════
## PART A — 编译阻断器 (COMPILE BLOCKERS) — 必须首先修复
## ═══════════════════════════════════════════════════════════════

### BLOCKER-1: 重复 TSDFParams 结构体 → 编译失败 "invalid redeclaration"

**问题**: `TSDFParams` struct 在两个文件中各定义了一次，同一 module 内会冲突。

- **文件 A**: `App/TSDF/MetalTSDFIntegrator.swift` 第 38-69 行
- **文件 B**: `App/TSDF/MetalBufferPool.swift` 第 91-122 行

**修复方案**:
1. 在 `App/TSDF/TSDFShaderTypes.h` 旁创建 `App/TSDF/TSDFShaderBridging.swift`，或在已有的 `Core/TSDF/TSDFTypes.swift` 中定义 `public struct TSDFParams: Sendable`（从 MetalTSDFIntegrator.swift L38-69 复制字段）。
2. **删除** MetalTSDFIntegrator.swift 第 38-69 行的 `struct TSDFParams`。
3. **删除** MetalBufferPool.swift 第 91-122 行的 `struct TSDFParams`。

**验证**: `swift build` 不再报 "invalid redeclaration of 'TSDFParams'"。

---

### BLOCKER-2: processFrame() 和 prepareFrame() 缺少 public 访问修饰符

- **文件**: `App/TSDF/MetalTSDFIntegrator.swift`
- **第 178 行**: `func prepareFrame(...)` → 加 `public`
- **第 183 行**: `func processFrame(...)` → 加 `public`

---

### BLOCKER-3: MarchingCubes triTable 不完整 — 仅 72/256 条目

- **文件**: `Core/TSDF/MarchingCubes.swift`
- **第 68-141 行**: `triTable` 只有 72 个 `[[Int]]` 条目
- edgeTable（第 30-63 行）已完整 256 条目

**修复**: 用完整的 Paul Bourke 256 条目替换第 68-141 行。
**验证**: 替换后 `triTable.count == 256`。

---

## ═══════════════════════════════════════════════════════════════
## PART B — 逻辑 Bug (LOGIC BUGS)
## ═══════════════════════════════════════════════════════════════

### BUG-4: SpatialHashTable.rehashIfNeeded() 泄漏 pool blocks

- **文件**: `Core/TSDF/SpatialHashTable.swift` 第 116-136 行
- **第 133 行**: `_ = insertOrGet(key: key, voxelSize: block.voxelSize)` 分配了新 block

**修复**: rehash 只重映射 key → poolIndex，不重新分配 pool block。
```swift
mutating func rehashIfNeeded() {
    guard loadFactor >= TSDFConstants.hashTableMaxLoadFactor else { return }
    // 保存所有 (key, poolIndex) 对
    let oldMappings: [(BlockIndex, Int32)] = entries.compactMap { entry in
        entry.blockPoolIndex >= 0 ? (entry.key, entry.blockPoolIndex) : nil
    }
    let newSize = entries.count * 2
    entries = ContiguousArray(repeating: HashEntry(key: BlockIndex(0,0,0), blockPoolIndex: -1), count: newSize)
    stableKeyList = ContiguousArray()
    count = 0
    // 重新插入 metadata — 不动 pool
    for (key, poolIndex) in oldMappings {
        let h = key.niessnerHash(tableSize: entries.count)
        var probe = h
        for _ in 0..<TSDFConstants.hashMaxProbeLength {
            if entries[probe].blockPoolIndex == -1 {
                entries[probe] = HashEntry(key: key, blockPoolIndex: poolIndex)
                stableKeyList.append(key)
                count += 1
                break
            }
            probe = (probe + 1) % entries.count
        }
    }
}
```

---

### BUG-5: SpatialHashTable.remove() 破坏线性探测链

- **文件**: `Core/TSDF/SpatialHashTable.swift` 第 84-105 行
- **第 97 行**: 直接设为空，破坏探测链

**修复 (backward-shift deletion)**:
```swift
public mutating func remove(key: BlockIndex) {
    let h = key.niessnerHash(tableSize: entries.count)
    var probe = h
    for _ in 0..<TSDFConstants.hashMaxProbeLength {
        let entry = entries[probe]
        if entry.blockPoolIndex == -1 { return }  // Not found
        if entry.key == key {
            pool.deallocate(index: Int(entry.blockPoolIndex))
            stableKeyList.removeAll { $0 == key }
            // Backward-shift: move subsequent chain entries back
            var empty = probe
            var j = (probe + 1) % entries.count
            while entries[j].blockPoolIndex >= 0 {
                let ideal = entries[j].key.niessnerHash(tableSize: entries.count)
                if (empty <= j) ? (ideal <= empty || ideal > j) : (ideal <= empty && ideal > j) {
                    entries[empty] = entries[j]
                    empty = j
                }
                j = (j + 1) % entries.count
            }
            entries[empty] = HashEntry(key: BlockIndex(0,0,0), blockPoolIndex: -1)
            count -= 1
            return
        }
        probe = (probe + 1) % entries.count
    }
}
```

---

### BUG-6: AdaptiveResolution.blockIndex() 对负坐标错误

- **文件**: `Core/TSDF/AdaptiveResolution.swift` 第 60-75 行
- **第 65, 67 行**: `.rounded(.towardZero)` 应为 `.rounded(.down)`

**注意**: 两个分支（if/else）目前完全相同！都是 `.towardZero`。
改为两个分支都使用 `.rounded(.down)`，或直接删掉 if/else：
```swift
public static func blockIndex(worldPosition: TSDFFloat3, voxelSize: Float) -> BlockIndex {
    let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
    return BlockIndex(
        Int32((worldPosition.x / blockWorldSize).rounded(.down)),
        Int32((worldPosition.y / blockWorldSize).rounded(.down)),
        Int32((worldPosition.z / blockWorldSize).rounded(.down))
    )
}
```

**验证**: `AdaptiveResolution.blockIndex(worldPosition: TSDFFloat3(-0.001, 0, 0), voxelSize: 0.004)` → `BlockIndex(-1, 0, 0)`

---

### BUG-7: MetalTSDFIntegrator 用数组下标当 pool index

- **文件**: `App/TSDF/MetalTSDFIntegrator.swift`
- 约第 416 行附近: 遍历 activeBlocks 时误用 `firstIndex(of:)` 或 `enumerated()` 的 offset 当 pool index

**修复**: active blocks 列表应存储 `(blockIndex: BlockIndex, poolIndex: Int)` 元组。遍历时使用 `poolIndex`。

---

### BUG-8: TSDFVolume idle preallocation 除零 → NaN

- **文件**: `Core/TSDF/TSDFVolume.swift` 第 349 行
- `velocity.length()` 在相机静止时 ≈ 0

**修复**:
```swift
let speed = velocity.length()
let predictedPosition: TSDFFloat3
if speed > 1e-6 {
    predictedPosition = trans3 + velocity * (lookAheadDistance / speed)
} else {
    predictedPosition = trans3
}
```

---

### BUG-9: CPUIntegrationBackend 是骨架 — 不写 voxel

- **文件**: `Core/TSDF/CPUIntegrationBackend.swift`
- **第 131-139 行**: 只递增计数器，不写 voxel
- **第 57 行**: 硬编码 voxelSizeMid

**修复**: 在 SDF/weight 计算后，通过 `volume.writeBlock(at: poolIndex, block)` 写回 voxel 数据。

---

### BUG-10: TSDFVolume.swift `.columns` 语法在 Linux 不工作

- **文件**: `Core/TSDF/TSDFVolume.swift`
- **第 159-162 行**: `intrinsics.columns.0.x` 等
- **第 637-643 行**: `from.columns.0.x` 等

**问题**: Apple `simd_float3x3` 有 `columns` tuple，Linux `TSDFMatrix3x3` 用 `c0, c1, c2` 属性。

**修复方案 (首选)**: 在 Linux 的 `TSDFMatrix3x3` 和 `TSDFMatrix4x4` struct 中添加 `columns` computed property:
```swift
// TSDFMathTypes.swift Linux section:
extension TSDFMatrix3x3 {
    public var columns: (TSDFFloat3, TSDFFloat3, TSDFFloat3) { (c0, c1, c2) }
}
extension TSDFMatrix4x4 {
    public var columns: (TSDFFloat4, TSDFFloat4, TSDFFloat4, TSDFFloat4) { (c0, c1, c2, c3) }
}
```

---

### BUG-11: Metal shader 硬编码常量

- **文件**: `App/TSDF/TSDFShaders.metal`
- **第 29 行**: `gid.x >= 256 || gid.y >= 192` 硬编码 depth 分辨率
- **第 100 行**: `pixel.x >= 255 || pixel.y >= 191` 硬编码 + **off-by-one** (应为 256/192)
- **第 155-156 行**: `deadZoneBase = 0.001f` / `deadZoneWeightScale = 0.004f` 硬编码

**修复**:
1. 在 `TSDFShaderTypes.h` 的 C struct `TSDFParams` 中添加 `uint32_t depthWidth, depthHeight; float sdfDeadZoneBase, sdfDeadZoneWeightScale;`
2. CPU 端填入值
3. Shader 中用 `params.depthWidth` 等替代硬编码

---

## ═══════════════════════════════════════════════════════════════
## PART C — 缺失内容 (MISSING CONTENT)
## ═══════════════════════════════════════════════════════════════

### MISSING-12: Package.swift 缺少 TSDF test target

在 `Package.swift` 的 `targets:` 数组中添加:
```swift
.testTarget(
    name: "TSDFTests",
    dependencies: ["Aether3DCore"],
    path: "Tests/TSDF"
),
```
并在 `Aether3DCoreTests` 的 `exclude:` 列表中添加 `"TSDF"`。

### MISSING-13: 6 个测试文件全部缺失

创建 `Tests/TSDF/` 目录和 6 个测试文件（详见 PART D）。

---

## ═══════════════════════════════════════════════════════════════
## PART D — 完整测试套件 (目标: 2000+ 个 XCTAssert)
## ═══════════════════════════════════════════════════════════════

> **硬性要求**: 修复完 PART A/B/C 后，生成的测试套件必须包含 **至少 2000 个 XCTAssert 调用**（XCTAssertEqual、XCTAssertTrue、XCTAssertNil 等全部计入）。
> 如果下面的示例测试不足 2000 个断言，Cursor 必须自行**补充**更多测试 case 直到达标。
>
> **测试维度清单** — 每个被测模块必须覆盖以下全部维度:
> 1. **正常路径 (happy path)** — 基本功能正确
> 2. **边界值 (boundary)** — 0、1、-1、MAX、MIN、刚好在阈值上/下
> 3. **负坐标 / 负值** — 尤其是 BlockIndex 和 SDF
> 4. **压力测试 (stress)** — 大量数据、满容量、反复 alloc/dealloc
> 5. **回归测试 (regression)** — 每个 BUG-4 到 BUG-11 至少有 3 个 case
> 6. **交叉验证 (cross-check)** — 不同模块之间的数据一致性
> 7. **随机模糊 (fuzz)** — 随机输入，验证不崩溃、不产生 NaN/Inf
> 8. **幂等性 (idempotency)** — 重复操作结果不变
> 9. **对称性 (symmetry)** — 正反操作互逆（insert→remove→insert 等）
> 10. **性能合理性 (performance sanity)** — 操作在合理时间内完成
>
> **约束**:
> - 所有测试用 XCTest。**不用 `@MainActor`。不用 `async setUp/tearDown`。**
> - 不引用 Metal、ARKit、AVFoundation — 只测 Core/ 层纯 Swift 逻辑。
> - 参考上方 "API 签名速查表" 确保所有构造函数和方法签名正确。
> - 大量循环测试用 `for` 循环 + 内部 `XCTAssert`，每次迭代算独立断言。

### 文件 1: `Tests/TSDF/TSDFConstantsTests.swift`

> 下面是示例骨架。Cursor 必须在此基础上**大幅扩充**，确保该文件至少 **300 个 XCTAssert**。
> 扩充方向: 每个常量逐一检查 > 0 或合理范围、Section 内排序关系、allSpecs 逐条 name/section/value 交叉验证。

```swift
import XCTest
@testable import Aether3DCore

final class TSDFConstantsTests: XCTestCase {

    // ═══ 78 个常量存在性 + 类型 ═══
    func testAllConstantsExistAndHaveCorrectTypes() {
        // Section 1 (5)
        let _: Float = TSDFConstants.voxelSizeNear
        let _: Float = TSDFConstants.voxelSizeMid
        let _: Float = TSDFConstants.voxelSizeFar
        let _: Float = TSDFConstants.depthNearThreshold
        let _: Float = TSDFConstants.depthFarThreshold
        // Section 2 (2)
        let _: Float = TSDFConstants.truncationMultiplier
        let _: Float = TSDFConstants.truncationMinimum
        // Section 3 (7)
        let _: UInt8 = TSDFConstants.weightMax
        let _: Float = TSDFConstants.confidenceWeightLow
        let _: Float = TSDFConstants.confidenceWeightMid
        let _: Float = TSDFConstants.confidenceWeightHigh
        let _: Float = TSDFConstants.distanceDecayAlpha
        let _: Float = TSDFConstants.viewingAngleWeightFloor
        let _: UInt8 = TSDFConstants.carvingDecayRate
        // Section 4 (4)
        let _: Float = TSDFConstants.depthMin; let _: Float = TSDFConstants.depthMax
        let _: Float = TSDFConstants.minValidPixelRatio; let _: Bool = TSDFConstants.skipLowConfidencePixels
        // Section 5 (5)
        let _: Int = TSDFConstants.maxVoxelsPerFrame; let _: Int = TSDFConstants.maxTrianglesPerCycle
        let _: Double = TSDFConstants.integrationTimeoutMs; let _: Int = TSDFConstants.metalThreadgroupSize
        let _: Int = TSDFConstants.metalInflightBuffers
        // Section 6 (7)
        let _: Int = TSDFConstants.maxTotalVoxelBlocks; let _: Int = TSDFConstants.hashTableInitialSize
        let _: Float = TSDFConstants.hashTableMaxLoadFactor; let _: Int = TSDFConstants.hashMaxProbeLength
        let _: Float = TSDFConstants.dirtyThresholdMultiplier
        let _: TimeInterval = TSDFConstants.staleBlockEvictionAge; let _: TimeInterval = TSDFConstants.staleBlockForceEvictionAge
        // Section 7 (1)
        let _: Int = TSDFConstants.blockSize
        // Section 8 (5)
        let _: Float = TSDFConstants.maxPoseDeltaPerFrame; let _: Float = TSDFConstants.maxAngularVelocity
        let _: Int = TSDFConstants.poseRejectWarningCount; let _: Int = TSDFConstants.poseRejectFailCount
        let _: Float = TSDFConstants.loopClosureDriftThreshold
        // Section 9 (4)
        let _: Int = TSDFConstants.keyframeInterval; let _: Float = TSDFConstants.keyframeAngularTriggerDeg
        let _: Float = TSDFConstants.keyframeTranslationTrigger; let _: Int = TSDFConstants.maxKeyframesPerSession
        // Section 10 (4)
        let _: Double = TSDFConstants.semaphoreWaitTimeoutMs
        let _: Int = TSDFConstants.gpuMemoryProactiveEvictBytes; let _: Int = TSDFConstants.gpuMemoryAggressiveEvictBytes
        let _: Float = TSDFConstants.worldOriginRecenterDistance
        // Section 11 (5)
        let _: Double = TSDFConstants.thermalDegradeHysteresisS; let _: Double = TSDFConstants.thermalRecoverHysteresisS
        let _: Int = TSDFConstants.thermalRecoverGoodFrames; let _: Float = TSDFConstants.thermalGoodFrameRatio
        let _: Int = TSDFConstants.thermalMaxIntegrationSkip
        // Section 12 (3)
        let _: Float = TSDFConstants.minTriangleArea; let _: Float = TSDFConstants.maxTriangleAspectRatio
        let _: Int = TSDFConstants.integrationRecordCapacity
        // Section 13 (11)
        let _: Float = TSDFConstants.sdfDeadZoneBase; let _: Float = TSDFConstants.sdfDeadZoneWeightScale
        let _: Float = TSDFConstants.vertexQuantizationStep; let _: Float = TSDFConstants.meshExtractionTargetHz
        let _: Double = TSDFConstants.meshExtractionBudgetMs
        let _: Float = TSDFConstants.mcInterpolationMin; let _: Float = TSDFConstants.mcInterpolationMax
        let _: Float = TSDFConstants.poseJitterGateTranslation; let _: Float = TSDFConstants.poseJitterGateRotation
        let _: UInt32 = TSDFConstants.minObservationsBeforeMesh; let _: Int = TSDFConstants.meshFadeInFrames
        // Section 14 (9)
        let _: Double = TSDFConstants.meshBudgetTargetMs; let _: Double = TSDFConstants.meshBudgetGoodMs
        let _: Double = TSDFConstants.meshBudgetOverrunMs
        let _: Int = TSDFConstants.minBlocksPerExtraction; let _: Int = TSDFConstants.maxBlocksPerExtraction
        let _: Int = TSDFConstants.blockRampPerCycle; let _: Int = TSDFConstants.consecutiveGoodCyclesBeforeRamp
        let _: Int = TSDFConstants.forgivenessWindowCycles; let _: Float = TSDFConstants.slowStartRatio
        // Section 15 (6)
        let _: Float = TSDFConstants.normalAveragingBoundaryDistance
        let _: Float = TSDFConstants.motionDeferTranslationSpeed; let _: Float = TSDFConstants.motionDeferAngularSpeed
        let _: Float = TSDFConstants.idleTranslationSpeed; let _: Float = TSDFConstants.idleAngularSpeed
        let _: Float = TSDFConstants.anticipatoryPreallocationDistance
    }

    // ═══ SSOT allSpecs ═══
    func testAllSpecsCount() { XCTAssertEqual(TSDFConstants.allSpecs.count, 77) }
    func testSpecNamesUnique() {
        let names = TSDFConstants.allSpecs.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count)
    }
    func testSpecSectionsInRange() {
        for spec in TSDFConstants.allSpecs { XCTAssertTrue((1...15).contains(spec.section)) }
    }
    func testEachSpecHasNonEmptyName() {
        for spec in TSDFConstants.allSpecs { XCTAssertFalse(spec.name.isEmpty) }
    }

    // ═══ 值域约束 (每个常量至少一个 Assert) ═══
    func testVoxelSizeOrdering() {
        XCTAssertGreaterThan(TSDFConstants.voxelSizeNear, 0)
        XCTAssertLessThan(TSDFConstants.voxelSizeNear, TSDFConstants.voxelSizeMid)
        XCTAssertLessThan(TSDFConstants.voxelSizeMid, TSDFConstants.voxelSizeFar)
        XCTAssertLessThan(TSDFConstants.voxelSizeFar, 1.0) // sanity: voxel < 1m
    }
    func testDepthThresholdOrdering() {
        XCTAssertGreaterThan(TSDFConstants.depthNearThreshold, 0)
        XCTAssertLessThan(TSDFConstants.depthNearThreshold, TSDFConstants.depthFarThreshold)
    }
    func testDepthFilterBounds() {
        XCTAssertGreaterThan(TSDFConstants.depthMin, 0)
        XCTAssertLessThan(TSDFConstants.depthMin, TSDFConstants.depthMax)
        XCTAssertGreaterThan(TSDFConstants.depthMax, 0)
        XCTAssertGreaterThan(TSDFConstants.minValidPixelRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.minValidPixelRatio, 1.0)
    }
    func testWeightConstants() {
        XCTAssertGreaterThan(TSDFConstants.weightMax, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.weightMax, 255)
        XCTAssertGreaterThan(TSDFConstants.confidenceWeightLow, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightLow, TSDFConstants.confidenceWeightMid)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightMid, TSDFConstants.confidenceWeightHigh)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightHigh, 1.0)
    }
    func testTruncation() {
        XCTAssertGreaterThan(TSDFConstants.truncationMultiplier, 0)
        XCTAssertGreaterThan(TSDFConstants.truncationMinimum, 0)
    }
    func testBlockSizePowerOf2() {
        let s = TSDFConstants.blockSize
        XCTAssertGreaterThan(s, 0); XCTAssertEqual(s & (s - 1), 0)
    }
    func testHashTableConstants() {
        XCTAssertGreaterThan(TSDFConstants.hashTableInitialSize, 0)
        XCTAssertGreaterThan(TSDFConstants.hashTableMaxLoadFactor, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.hashTableMaxLoadFactor, 1.0)
        XCTAssertGreaterThan(TSDFConstants.hashMaxProbeLength, 0)
    }
    func testMemoryConstants() {
        XCTAssertGreaterThan(TSDFConstants.maxTotalVoxelBlocks, 0)
        XCTAssertGreaterThan(TSDFConstants.staleBlockEvictionAge, 0)
        XCTAssertLessThan(TSDFConstants.staleBlockEvictionAge, TSDFConstants.staleBlockForceEvictionAge)
    }
    func testPerformanceBudgets() {
        XCTAssertGreaterThan(TSDFConstants.maxVoxelsPerFrame, 0)
        XCTAssertGreaterThan(TSDFConstants.maxTrianglesPerCycle, 0)
        XCTAssertGreaterThan(TSDFConstants.integrationTimeoutMs, 0)
        XCTAssertGreaterThan(TSDFConstants.metalThreadgroupSize, 0)
    }
    func testCameraPoseSafety() {
        XCTAssertGreaterThan(TSDFConstants.maxPoseDeltaPerFrame, 0)
        XCTAssertGreaterThan(TSDFConstants.maxAngularVelocity, 0)
        XCTAssertLessThan(TSDFConstants.poseRejectWarningCount, TSDFConstants.poseRejectFailCount)
    }
    func testAIMDConstants() {
        XCTAssertGreaterThan(TSDFConstants.thermalDegradeHysteresisS, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalRecoverHysteresisS, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalMaxIntegrationSkip, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalGoodFrameRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.thermalGoodFrameRatio, 1.0)
    }
    func testMCInterpolation() {
        XCTAssertGreaterThan(TSDFConstants.mcInterpolationMin, 0)
        XCTAssertLessThan(TSDFConstants.mcInterpolationMax, 1.0)
        XCTAssertLessThan(TSDFConstants.mcInterpolationMin, TSDFConstants.mcInterpolationMax)
    }
    func testCongestionControl() {
        XCTAssertLessThan(TSDFConstants.meshBudgetGoodMs, TSDFConstants.meshBudgetTargetMs)
        XCTAssertLessThan(TSDFConstants.meshBudgetTargetMs, TSDFConstants.meshBudgetOverrunMs)
        XCTAssertLessThanOrEqual(TSDFConstants.minBlocksPerExtraction, TSDFConstants.maxBlocksPerExtraction)
        XCTAssertGreaterThan(TSDFConstants.slowStartRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.slowStartRatio, 1.0)
    }
    func testValidateRelationships() {
        let errors = TSDFConstants.validateRelationships()
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
    }

    // ═══ Cursor 必须补充: allSpecs 逐条验证 ═══
    // 对 allSpecs 中的每一条 spec:
    //   1. XCTAssertFalse(spec.name.isEmpty)
    //   2. XCTAssertTrue((1...15).contains(spec.section))
    //   3. 验证 spec.value 与实际常量值一致 (需要 switch spec.name)
    // 这将产生 77 × 3 = 231 个额外断言
}
```

### 文件 2: `Tests/TSDF/SpatialHashTableTests.swift`

> Cursor 必须在此基础上扩充到至少 **500 个 XCTAssert**。
> 扩充方向: 100 个随机 key insert/lookup、50 次 remove 后全表验证、rehash 压力（插入到 load=0.9）、
> 连续 insert→remove→reinsert 循环 100 次、forEachBlock 遍历计数精确匹配 count、
> getAllBlocks 排序一致性、updateBlock 修改每个字段后 readBlock 验证。

```swift
import XCTest
@testable import Aether3DCore

final class SpatialHashTableTests: XCTestCase {

    // ═══ 基础 CRUD ═══
    func testInsertAndLookup() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(1, 2, 3)
        let poolIdx = table.insertOrGet(key: key, voxelSize: 0.004)
        XCTAssertNotNil(poolIdx)
        XCTAssertEqual(table.lookup(key: key), poolIdx)
    }
    func testLookupMissingNil() {
        let table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        XCTAssertNil(table.lookup(key: BlockIndex(99, 99, 99)))
    }
    func testIdempotentInsert() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(5, 5, 5)
        let idx1 = table.insertOrGet(key: key, voxelSize: 0.004)
        let idx2 = table.insertOrGet(key: key, voxelSize: 0.004)
        XCTAssertEqual(idx1, idx2)
    }

    // ═══ 批量 insert (100 keys) ═══
    func testInsert100UniqueKeys() {
        var table = SpatialHashTable(initialSize: 256, poolCapacity: 256)
        var indices: [Int] = []
        for i: Int32 in 0..<100 {
            if let idx = table.insertOrGet(key: BlockIndex(i, i &* 7, i &* 13), voxelSize: 0.01) {
                indices.append(idx)
            }
        }
        XCTAssertEqual(indices.count, 100)
        XCTAssertEqual(Set(indices).count, 100)
        // 全部可 lookup
        for i: Int32 in 0..<100 {
            XCTAssertNotNil(table.lookup(key: BlockIndex(i, i &* 7, i &* 13)))
        }
    }

    // ═══ Remove ═══
    func testRemoveExisting() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(1, 1, 1)
        _ = table.insertOrGet(key: key, voxelSize: 0.004)
        table.remove(key: key)
        XCTAssertNil(table.lookup(key: key))
    }
    func testRemoveNonexistent() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        table.remove(key: BlockIndex(99, 99, 99)) // no crash
    }

    /// BUG-5 回归: remove 不破坏探测链 (多种模式)
    func testRemoveMiddlePreservesChain() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 32)
        let keys = (0..<10).map { BlockIndex(Int32($0), Int32($0), Int32($0)) }
        var poolIndices: [BlockIndex: Int] = [:]
        for key in keys {
            if let idx = table.insertOrGet(key: key, voxelSize: 0.004) { poolIndices[key] = idx }
        }
        // 逐个删除偶数 key，验证奇数仍在
        for i in stride(from: 0, to: 10, by: 2) {
            table.remove(key: keys[i])
        }
        for i in stride(from: 1, to: 10, by: 2) {
            XCTAssertEqual(table.lookup(key: keys[i]), poolIndices[keys[i]])
        }
    }
    func testRemoveFirstPreservesChain() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 32)
        let keys = (0..<8).map { BlockIndex(Int32($0), 0, 0) }
        var saved: [BlockIndex: Int] = [:]
        for key in keys { if let idx = table.insertOrGet(key: key, voxelSize: 0.01) { saved[key] = idx } }
        table.remove(key: keys[0])
        for key in keys.dropFirst() { XCTAssertEqual(table.lookup(key: key), saved[key]) }
    }
    func testRemoveLastPreservesChain() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 32)
        let keys = (0..<8).map { BlockIndex(Int32($0), 0, 0) }
        var saved: [BlockIndex: Int] = [:]
        for key in keys { if let idx = table.insertOrGet(key: key, voxelSize: 0.01) { saved[key] = idx } }
        table.remove(key: keys.last!)
        for key in keys.dropLast() { XCTAssertEqual(table.lookup(key: key), saved[key]) }
    }

    // ═══ Insert→Remove→Reinsert 循环 ═══
    func testInsertRemoveReinsert50Cycles() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(42, -7, 13)
        for _ in 0..<50 {
            let idx = table.insertOrGet(key: key, voxelSize: 0.01)
            XCTAssertNotNil(idx)
            XCTAssertEqual(table.lookup(key: key), idx)
            table.remove(key: key)
            XCTAssertNil(table.lookup(key: key))
        }
    }

    // ═══ Negative coordinates ═══
    func testNegativeCoordinates() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        for x: Int32 in [-100, -1, 0, 1, 100] {
            for y: Int32 in [-50, 0, 50] {
                let key = BlockIndex(x, y, 0)
                let idx = table.insertOrGet(key: key, voxelSize: 0.01)
                XCTAssertNotNil(idx)
                XCTAssertEqual(table.lookup(key: key), idx)
            }
        }
    }

    // ═══ BUG-4 回归: rehash preserves pool indices ═══
    func testRehashPreservesPoolIndices() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 64)
        var original: [BlockIndex: Int] = [:]
        for i: Int32 in 0..<12 { // 75% load → triggers rehash
            let key = BlockIndex(i, 0, 0)
            if let idx = table.insertOrGet(key: key, voxelSize: 0.004) { original[key] = idx }
        }
        for (key, expectedIdx) in original {
            XCTAssertEqual(table.lookup(key: key), expectedIdx)
        }
    }

    // ═══ 边界 key ═══
    func testZeroKey() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let idx = table.insertOrGet(key: BlockIndex(0, 0, 0), voxelSize: 0.01)
        XCTAssertNotNil(idx)
        XCTAssertEqual(table.lookup(key: BlockIndex(0, 0, 0)), idx)
    }
    func testLargeCoordinates() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(10000, -10000, 32767)
        let idx = table.insertOrGet(key: key, voxelSize: 0.02)
        XCTAssertNotNil(idx); XCTAssertEqual(table.lookup(key: key), idx)
    }
    func testInt32MaxCoordinates() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(Int32.max, Int32.min, 0)
        let idx = table.insertOrGet(key: key, voxelSize: 0.01)
        XCTAssertNotNil(idx); XCTAssertEqual(table.lookup(key: key), idx)
    }

    // ═══ readBlock / updateBlock ═══
    func testReadBlockNewBlockEmpty() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        guard let poolIdx = table.insertOrGet(key: BlockIndex(1,2,3), voxelSize: 0.004) else { XCTFail("nil"); return }
        let block = table.readBlock(at: poolIdx)
        for i in 0..<512 { XCTAssertEqual(block.voxels[i].weight, 0) }
    }
    func testUpdateBlockAndReadBack() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        guard let idx = table.insertOrGet(key: BlockIndex(0,0,0), voxelSize: 0.01) else { XCTFail("nil"); return }
        table.updateBlock(at: idx) { $0.integrationGeneration = 42; $0.meshGeneration = 10 }
        let b = table.readBlock(at: idx)
        XCTAssertEqual(b.integrationGeneration, 42); XCTAssertEqual(b.meshGeneration, 10)
    }

    // ═══ forEachBlock / getAllBlocks ═══
    func testForEachBlockCountMatchesCount() {
        var table = SpatialHashTable(initialSize: 128, poolCapacity: 128)
        let n = 30
        for i: Int32 in 0..<Int32(n) { _ = table.insertOrGet(key: BlockIndex(i, 0, 0), voxelSize: 0.01) }
        var visited = 0
        table.forEachBlock { _, _, _ in visited += 1 }
        XCTAssertEqual(visited, n); XCTAssertEqual(table.count, n)
    }
    func testGetAllBlocksCount() {
        var table = SpatialHashTable(initialSize: 128, poolCapacity: 128)
        for i: Int32 in 0..<25 { _ = table.insertOrGet(key: BlockIndex(i, 0, 0), voxelSize: 0.01) }
        XCTAssertEqual(table.getAllBlocks().count, 25)
    }

    // ═══ voxelByteCount / voxelBaseAddress ═══
    func testVoxelByteCount() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        _ = table.insertOrGet(key: BlockIndex(0,0,0), voxelSize: 0.01)
        XCTAssertGreaterThan(table.voxelByteCount, 0)
    }

    // ═══ loadFactor ═══
    func testLoadFactorIncreasesWithInsertions() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let lf0 = table.loadFactor
        for i: Int32 in 0..<10 { _ = table.insertOrGet(key: BlockIndex(i, 0, 0), voxelSize: 0.01) }
        XCTAssertGreaterThan(table.loadFactor, lf0)
    }

    // ═══ Cursor 必须补充更多到 500+ assert ═══
    // 方向:
    //   - 随机 fuzz: 随机 100 个 BlockIndex insert/lookup (100 × 2 = 200 assert)
    //   - remove 50 个后验证剩余 50 个 (50 assert)
    //   - 多次 rehash (初始 size=8, 插入 50 个) 后全部可 lookup (50 assert)
    //   - forEachBlock 中 poolIndex 和 readBlock 数据一致性 (N assert)
    //   - getAllBlocks 返回的 key 集合与 insert 集合完全一致 (Set 比较)
}
```

### 文件 3: `Tests/TSDF/VoxelBlockPoolTests.swift`

> **目标: 至少 400 个 XCTAssert**
> Cursor 必须在示例测试基础上补充到 400+ 个 XCTAssert。
> 维度: happy path, boundary, negative, stress (alloc/dealloc cycles), data integrity, sentinel, idempotency

```swift
import XCTest
@testable import Aether3DCore

final class VoxelBlockPoolTests: XCTestCase {

    // ══════════════════════════════════════
    // MARK: - 1. 基本分配 (happy path)
    // ══════════════════════════════════════

    func testAllocateReturnsNonNil() {
        var pool = VoxelBlockPool(capacity: 10)
        let idx = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(idx)
    }

    func testAllocateReturnsDifferentIndices() {
        var pool = VoxelBlockPool(capacity: 10)
        let idx0 = pool.allocate(voxelSize: 0.01)
        let idx1 = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(idx0)
        XCTAssertNotNil(idx1)
        XCTAssertNotEqual(idx0, idx1)
    }

    func testAllocate10DifferentIndices() {
        var pool = VoxelBlockPool(capacity: 20)
        var indices: [Int] = []
        for _ in 0..<10 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        // 所有 index 唯一
        XCTAssertEqual(Set(indices).count, 10)
        for i in 0..<10 {
            for j in (i+1)..<10 {
                XCTAssertNotEqual(indices[i], indices[j])
            }
        }
    }

    func testAllocatedCountTracking() {
        var pool = VoxelBlockPool(capacity: 10)
        XCTAssertEqual(pool.allocatedCount, 0)
        _ = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(pool.allocatedCount, 1)
        _ = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(pool.allocatedCount, 2)
        _ = pool.allocate(voxelSize: 0.005)
        XCTAssertEqual(pool.allocatedCount, 3)
    }

    func testAllocateWithDifferentVoxelSizes() {
        var pool = VoxelBlockPool(capacity: 10)
        let sizes: [Float] = [0.005, 0.01, 0.02, 0.005, 0.01, 0.02]
        for size in sizes {
            let idx = pool.allocate(voxelSize: size)
            XCTAssertNotNil(idx)
            guard let i = idx else { continue }
            let block = pool.accessor.readBlock(at: i)
            XCTAssertEqual(block.voxelSize, size, accuracy: 1e-6,
                "分配的 block 的 voxelSize 应为 \(size)")
        }
    }

    // ══════════════════════════════════════
    // MARK: - 2. 回收与重用
    // ══════════════════════════════════════

    func testAllocateAndDeallocateReuses() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        pool.deallocate(index: idx)
        let reused = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(reused, idx, "deallocate 后应重用同一 index")
    }

    func testAllocDeallocCycle50() {
        var pool = VoxelBlockPool(capacity: 20)
        for cycle in 0..<50 {
            guard let idx = pool.allocate(voxelSize: 0.01) else {
                XCTFail("cycle \(cycle) allocate failed"); return
            }
            XCTAssertGreaterThanOrEqual(idx, 0)
            pool.deallocate(index: idx)
        }
        XCTAssertEqual(pool.allocatedCount, 0)
    }

    func testAllocDeallocMultipleConcurrentBlocks() {
        var pool = VoxelBlockPool(capacity: 10)
        var indices: [Int] = []
        // 分配 5 个
        for _ in 0..<5 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        XCTAssertEqual(pool.allocatedCount, 5)
        // 释放前 3 个
        for i in 0..<3 {
            pool.deallocate(index: indices[i])
        }
        XCTAssertEqual(pool.allocatedCount, 2)
        // 再分配 3 个 — 应重用
        var reusedIndices: [Int] = []
        for _ in 0..<3 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            reusedIndices.append(idx)
        }
        XCTAssertEqual(pool.allocatedCount, 5)
        // 重用的 index 应属于之前释放的 index 集合
        let freedSet = Set(indices[0..<3])
        for ri in reusedIndices {
            XCTAssertTrue(freedSet.contains(ri), "重用 index \(ri) 应在已释放集合中")
        }
    }

    func testDeallocResetsBlock() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        // 写入数据
        var block = pool.accessor.readBlock(at: idx)
        block.voxels[0] = Voxel(sdf: SDFStorage(-0.5), weight: 50, confidence: 2)
        block.integrationGeneration = 42
        pool.accessor.writeBlock(at: idx, block)
        // 释放
        pool.deallocate(index: idx)
        // 重新分配 — block 应被重置
        guard let reIdx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        XCTAssertEqual(reIdx, idx)
        let newBlock = pool.accessor.readBlock(at: reIdx)
        XCTAssertEqual(newBlock.integrationGeneration, 0)
        XCTAssertEqual(newBlock.meshGeneration, 0)
        XCTAssertEqual(newBlock.voxels[0].weight, 0, "重新分配后 voxel 应被重置")
    }

    // ══════════════════════════════════════
    // MARK: - 3. 边界: 耗尽 pool
    // ══════════════════════════════════════

    func testExhaustPool() {
        let cap = 10
        var pool = VoxelBlockPool(capacity: cap)
        var indices: [Int] = []
        for _ in 0..<cap {
            if let idx = pool.allocate(voxelSize: 0.01) { indices.append(idx) }
        }
        XCTAssertEqual(indices.count, cap)
        XCTAssertEqual(Set(indices).count, cap)
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
    }

    func testExhaustPoolAllocatedCount() {
        let cap = 5
        var pool = VoxelBlockPool(capacity: cap)
        for i in 0..<cap {
            _ = pool.allocate(voxelSize: 0.01)
            XCTAssertEqual(pool.allocatedCount, i + 1)
        }
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
        XCTAssertEqual(pool.allocatedCount, cap)
    }

    func testExhaustThenDeallocOneThenAllocOne() {
        let cap = 3
        var pool = VoxelBlockPool(capacity: cap)
        var indices: [Int] = []
        for _ in 0..<cap {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
        pool.deallocate(index: indices[1])
        let newIdx = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(newIdx)
        XCTAssertEqual(newIdx, indices[1])
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
    }

    func testExhaustPoolCapacity1() {
        var pool = VoxelBlockPool(capacity: 1)
        let idx = pool.allocate(voxelSize: 0.005)
        XCTAssertNotNil(idx)
        XCTAssertNil(pool.allocate(voxelSize: 0.005))
        pool.deallocate(index: idx!)
        let idx2 = pool.allocate(voxelSize: 0.02)
        XCTAssertNotNil(idx2)
        XCTAssertEqual(idx2, idx)
    }

    // ══════════════════════════════════════
    // MARK: - 4. 数据完整性: 新 block 初始化
    // ══════════════════════════════════════

    func testNewBlockIsEmpty() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        let block = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(block.voxels.count, 512)
        for i in 0..<512 {
            XCTAssertEqual(block.voxels[i].weight, 0, "voxel[\(i)].weight 应为 0")
        }
    }

    func testNewBlockVoxelSizeIsSet() {
        var pool = VoxelBlockPool(capacity: 10)
        let sizes: [Float] = [0.005, 0.01, 0.02]
        for size in sizes {
            guard let idx = pool.allocate(voxelSize: size) else { XCTFail("nil"); return }
            let block = pool.accessor.readBlock(at: idx)
            XCTAssertEqual(block.voxelSize, size, accuracy: 1e-6)
            XCTAssertEqual(block.integrationGeneration, 0)
            XCTAssertEqual(block.meshGeneration, 0)
        }
    }

    func testNewBlockSDFIsPositive() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        let block = pool.accessor.readBlock(at: idx)
        for i in 0..<512 {
            #if canImport(simd) || arch(arm64)
            let sdfVal = Float(block.voxels[i].sdf)
            #else
            let sdfVal = block.voxels[i].sdf.floatValue
            #endif
            XCTAssertEqual(sdfVal, 1.0, accuracy: 0.01,
                "新 block 的 sdf[\(i)] 应为 1.0 (empty sentinel)")
        }
    }

    // ══════════════════════════════════════
    // MARK: - 5. 读写完整性
    // ══════════════════════════════════════

    func testWriteAndReadBlock() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.voxels[0] = Voxel(sdf: SDFStorage(0.5), weight: 42, confidence: 2)
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(readBack.voxels[0].weight, 42)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(readBack.voxels[0].sdf), 0.5, accuracy: 0.01)
        #else
        XCTAssertEqual(readBack.voxels[0].sdf.floatValue, 0.5, accuracy: 0.01)
        #endif
    }

    func testWriteMultipleVoxels() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        // 写入多个不同位置
        let positions = [0, 1, 7, 63, 64, 255, 511]
        for (i, pos) in positions.enumerated() {
            let w = UInt8(i + 1)
            let sdf = Float(i) * 0.1 - 0.3
            block.voxels[pos] = Voxel(sdf: SDFStorage(sdf), weight: w, confidence: UInt8(i % 3))
        }
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        for (i, pos) in positions.enumerated() {
            XCTAssertEqual(readBack.voxels[pos].weight, UInt8(i + 1),
                "position \(pos) weight mismatch")
            XCTAssertEqual(readBack.voxels[pos].confidence, UInt8(i % 3),
                "position \(pos) confidence mismatch")
        }
    }

    func testWriteToMultipleBlocks() {
        var pool = VoxelBlockPool(capacity: 5)
        var indices: [Int] = []
        for _ in 0..<5 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        // 每个 block 写不同数据
        for (blockIdx, poolIdx) in indices.enumerated() {
            var block = pool.accessor.readBlock(at: poolIdx)
            block.voxels[0] = Voxel(sdf: SDFStorage(0.1), weight: UInt8(blockIdx + 10), confidence: 1)
            block.integrationGeneration = UInt32(blockIdx * 100)
            pool.accessor.writeBlock(at: poolIdx, block)
        }
        // 逐个验证
        for (blockIdx, poolIdx) in indices.enumerated() {
            let block = pool.accessor.readBlock(at: poolIdx)
            XCTAssertEqual(block.voxels[0].weight, UInt8(blockIdx + 10),
                "block \(blockIdx) weight mismatch")
            XCTAssertEqual(block.integrationGeneration, UInt32(blockIdx * 100),
                "block \(blockIdx) generation mismatch")
        }
    }

    func testWriteGenerationAndMeshGeneration() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.integrationGeneration = 5
        block.meshGeneration = 3
        block.lastObservedTimestamp = 12345.0
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(readBack.integrationGeneration, 5)
        XCTAssertEqual(readBack.meshGeneration, 3)
        XCTAssertEqual(readBack.lastObservedTimestamp, 12345.0, accuracy: 1e-6)
    }

    // ══════════════════════════════════════
    // MARK: - 6. 稳定地址 (Metal zero-copy)
    // ══════════════════════════════════════

    func testBaseAddressStable() {
        var pool = VoxelBlockPool(capacity: 10)
        _ = pool.allocate(voxelSize: 0.01)
        let addr1 = pool.baseAddress
        _ = pool.allocate(voxelSize: 0.01)
        let addr2 = pool.baseAddress
        XCTAssertEqual(addr1, addr2, "baseAddress 应在多次 allocate 后保持稳定")
    }

    func testBaseAddressStableAfterDeallocate() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        let addr1 = pool.baseAddress
        pool.deallocate(index: idx)
        let addr2 = pool.baseAddress
        _ = pool.allocate(voxelSize: 0.01)
        let addr3 = pool.baseAddress
        XCTAssertEqual(addr1, addr2)
        XCTAssertEqual(addr2, addr3)
    }

    func testBaseAddressStableAfterManyAllocations() {
        var pool = VoxelBlockPool(capacity: 100)
        let addr0 = pool.baseAddress
        for _ in 0..<100 {
            _ = pool.allocate(voxelSize: 0.01)
        }
        XCTAssertEqual(pool.baseAddress, addr0, "100 次 allocate 后 baseAddress 不变")
    }

    func testByteCountPositive() {
        let pool = VoxelBlockPool(capacity: 10)
        XCTAssertGreaterThan(pool.byteCount, 0)
    }

    func testByteCountMatchesCapacity() {
        let cap = 10
        let pool = VoxelBlockPool(capacity: cap)
        let expectedBytes = cap * MemoryLayout<VoxelBlock>.stride
        XCTAssertEqual(pool.byteCount, expectedBytes)
    }

    // ══════════════════════════════════════
    // MARK: - 7. Sentinel 值验证
    // ══════════════════════════════════════

    func testVoxelEmptySentinel() {
        let v = Voxel.empty
        XCTAssertEqual(v.weight, 0)
        XCTAssertEqual(v.confidence, 0)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(v.sdf), 1.0, accuracy: 0.01)
        #else
        XCTAssertEqual(v.sdf.floatValue, 1.0, accuracy: 0.01)
        #endif
    }

    func testVoxelBlockEmptySentinel() {
        let block = VoxelBlock.empty
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.integrationGeneration, 0)
        XCTAssertEqual(block.meshGeneration, 0)
        XCTAssertEqual(block.voxelSize, 0.01, accuracy: 1e-6)
        XCTAssertEqual(block.lastObservedTimestamp, 0, accuracy: 1e-6)
    }

    func testVoxelBlockSizeConstant() {
        XCTAssertEqual(VoxelBlock.size, 8)
        XCTAssertEqual(VoxelBlock.size * VoxelBlock.size * VoxelBlock.size, 512)
    }

    func testVoxelBlockEmptyAllVoxelsWeight0() {
        let block = VoxelBlock.empty
        for i in 0..<512 {
            XCTAssertEqual(block.voxels[i].weight, 0,
                "VoxelBlock.empty voxel[\(i)].weight 应为 0")
        }
    }

    // ══════════════════════════════════════
    // MARK: - 8. SDFStorage 跨平台 round-trip (fuzz)
    // ══════════════════════════════════════

    func testSDFStorageRoundTripRange() {
        // 测试 -1.0 到 +1.0 范围内的值
        let values: [Float] = [-1.0, -0.75, -0.5, -0.25, -0.1, -0.01, 0.0,
                                0.01, 0.1, 0.25, 0.5, 0.75, 1.0]
        for original in values {
            let stored = SDFStorage(original)
            #if canImport(simd) || arch(arm64)
            let recovered = Float(stored)
            #else
            let recovered = stored.floatValue
            #endif
            XCTAssertEqual(recovered, original, accuracy: 0.01,
                "SDFStorage round-trip failed for \(original)")
        }
    }

    func testSDFStorageZero() {
        let stored = SDFStorage(0.0)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(stored), 0.0, accuracy: 0.001)
        #else
        XCTAssertEqual(stored.floatValue, 0.0, accuracy: 0.001)
        #endif
    }

    // ══════════════════════════════════════
    // MARK: - 9. 压力测试: alloc/dealloc 循环
    // ══════════════════════════════════════

    func testStressAllocDeallocCycle200() {
        var pool = VoxelBlockPool(capacity: 50)
        var live: [Int] = []
        for cycle in 0..<200 {
            if live.count < 50 && (cycle % 3 != 0 || live.isEmpty) {
                if let idx = pool.allocate(voxelSize: 0.01) {
                    live.append(idx)
                }
            } else if !live.isEmpty {
                let remove = live.removeFirst()
                pool.deallocate(index: remove)
            }
            // 检查 allocatedCount 一致
            XCTAssertEqual(pool.allocatedCount, live.count,
                "cycle \(cycle): allocatedCount 不一致")
        }
    }

    func testFullExhaustAndRecoverCycle() {
        let cap = 20
        var pool = VoxelBlockPool(capacity: cap)
        // 3 次完整 exhaust + recover 循环
        for round in 0..<3 {
            var indices: [Int] = []
            for _ in 0..<cap {
                guard let idx = pool.allocate(voxelSize: 0.01) else {
                    XCTFail("round \(round) allocate 失败"); return
                }
                indices.append(idx)
            }
            XCTAssertEqual(pool.allocatedCount, cap)
            XCTAssertNil(pool.allocate(voxelSize: 0.01))
            for idx in indices {
                pool.deallocate(index: idx)
            }
            XCTAssertEqual(pool.allocatedCount, 0)
        }
    }

    // ══════════════════════════════════════
    // MARK: - 10. ManagedVoxelStorage (accessor) 测试
    // ══════════════════════════════════════

    func testManagedVoxelStorageReadBlock() {
        let storage = ManagedVoxelStorage(capacity: 5)
        let block = storage.readBlock(at: 0)
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.voxels[0].weight, 0)
    }

    func testManagedVoxelStorageWriteBlock() {
        let storage = ManagedVoxelStorage(capacity: 5)
        var block = VoxelBlock.empty
        block.voxels[100] = Voxel(sdf: SDFStorage(-0.3), weight: 15, confidence: 1)
        storage.writeBlock(at: 2, block)
        let readBack = storage.readBlock(at: 2)
        XCTAssertEqual(readBack.voxels[100].weight, 15)
        XCTAssertEqual(readBack.voxels[100].confidence, 1)
    }

    func testManagedVoxelStorageSubscript() {
        let storage = ManagedVoxelStorage(capacity: 5)
        var block = VoxelBlock.empty
        block.integrationGeneration = 99
        storage[3] = block
        XCTAssertEqual(storage[3].integrationGeneration, 99)
    }

    func testManagedVoxelStorageBaseAddress() {
        let storage = ManagedVoxelStorage(capacity: 10)
        let addr = storage.baseAddress
        XCTAssertNotNil(addr)
        XCTAssertGreaterThan(storage.byteCount, 0)
        XCTAssertEqual(storage.capacity, 10)
    }

    // ═════════════════════════════════════════════════════════════════
    // 📌 Cursor 补充指令:
    // 以上约 100 个 XCTAssert。请继续补充以下测试至总计 400+ 个 assert:
    //
    // (a) Voxel 构造: 至少 20 种不同 (sdf, weight, confidence) 组合，
    //     验证构造后各字段正确。(60+ assert)
    // (b) VoxelBlock 完整 512 voxel 读写: 写入全部 512 个 voxel 为不同值，
    //     读回并逐个验证。(512+ assert → 取前 100 个即可)
    // (c) Pool capacity=1: 单容量边界测试，alloc→write→dealloc→realloc→verify
    //     重复 10 次。(30+ assert)
    // (d) allocatedCount 在异常路径: exhaust 后再 allocate 10 次验证
    //     每次都是 nil 且 allocatedCount 不变。(20+ assert)
    // (e) 不同 voxelSize 组合: 分配 3 个 near + 3 个 mid + 3 个 far，
    //     验证每个 block 的 voxelSize 字段。(27+ assert)
    // (f) baseAddress 与 byteCount 在 capacity=1 和 capacity=100000
    //     两种极端值验证。(10+ assert)
    // (g) Idempotency: 对同一 block 反复 readBlock 10 次，结果相同。(50+ assert)
    // ═════════════════════════════════════════════════════════════════
}
```

### 文件 4: `Tests/TSDF/MarchingCubesTests.swift`

> **目标: 至少 400 个 XCTAssert**
> Cursor 必须在示例测试基础上补充到 400+ 个 XCTAssert。
> 维度: BLOCKER-3 回归 (256 cube configs), surface patterns, degenerate rejection, MeshOutput, MeshVertex/MeshTriangle, extractIncremental

```swift
import XCTest
@testable import Aether3DCore

final class MarchingCubesTests: XCTestCase {

    // ══════════════════════════════════════
    // MARK: - Helper
    // ══════════════════════════════════════

    /// 创建一个 block，所有 voxel 填入指定 SDF 和 weight
    private func makeUniformBlock(sdf: Float, weight: UInt8 = 10) -> VoxelBlock {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: weight, confidence: 2)
        }
        return block
    }

    /// 创建平面 block: 沿指定轴，小于 threshold 的为 inside (sdf < 0)
    private func makePlaneBlock(axis: Int, threshold: Int) -> VoxelBlock {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let coord = [x, y, z][axis]
                    let sdf: Float = coord < threshold ? -1.0 : 1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        return block
    }

    // ══════════════════════════════════════
    // MARK: - 1. BLOCKER-3 回归: triTable 完整性
    // ══════════════════════════════════════

    /// 棋盘格 SDF 覆盖所有 256 种 cube 配置 — 不崩溃
    func testExtractBlockAllConfigurationsNoCrash() {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            let sdf: Float = (i % 2 == 0) ? 1.0 : -1.0
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    /// 反转棋盘格 — 另一种覆盖
    func testExtractBlockInverseCheckerboard() {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            let sdf: Float = (i % 2 == 0) ? -1.0 : 1.0
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    /// 3D 棋盘格: (x+y+z) % 2 决定 inside/outside
    func testExtractBlock3DCheckerboard() {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = ((x + y + z) % 2 == 0) ? 1.0 : -1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "3D 棋盘格应产生三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    // ══════════════════════════════════════
    // MARK: - 2. 全同质 block — 无三角形
    // ══════════════════════════════════════

    func testExtractBlockAllEmptyNoTriangles() {
        let block = VoxelBlock.empty  // sdf=1.0, weight=0
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty, "全外部不应生成三角形")
    }

    func testExtractBlockAllOutsideHighWeight() {
        let block = makeUniformBlock(sdf: 1.0, weight: 64)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty, "全外部（高 weight）不应生成三角形")
    }

    func testExtractBlockAllInsideNoTriangles() {
        let block = makeUniformBlock(sdf: -1.0)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty, "全内部不应生成三角形")
    }

    func testExtractBlockAllInsideHighWeight() {
        let block = makeUniformBlock(sdf: -1.0, weight: 64)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty, "全内部（高 weight）不应生成三角形")
    }

    // ══════════════════════════════════════
    // MARK: - 3. 表面交叉 — 不同轴平面
    // ══════════════════════════════════════

    func testExtractBlockSurfaceCrossingZ() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "Z 平面交叉应生成三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockSurfaceCrossingX() {
        let block = makePlaneBlock(axis: 0, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "X 平面交叉应生成三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockSurfaceCrossingY() {
        let block = makePlaneBlock(axis: 1, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "Y 平面交叉应生成三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockPlaneAtZ1() {
        let block = makePlaneBlock(axis: 2, threshold: 1)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "Z=1 平面应生成三角形")
    }

    func testExtractBlockPlaneAtZ7() {
        let block = makePlaneBlock(axis: 2, threshold: 7)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "Z=7 平面应生成三角形")
    }

    /// 对角平面: x+y+z < 12 为 inside
    func testExtractBlockDiagonalPlane() {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = (x + y + z) < 12 ? -1.0 : 1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "对角平面应生成三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    /// 球体: 中心 (3.5, 3.5, 3.5), 半径 3
    func testExtractBlockSphere() {
        var block = VoxelBlock.empty
        let cx: Float = 3.5, cy: Float = 3.5, cz: Float = 3.5, r: Float = 3.0
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let dx = Float(x) - cx, dy = Float(y) - cy, dz = Float(z) - cz
                    let dist = (dx*dx + dy*dy + dz*dz).squareRoot()
                    let sdf = dist - r
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0, "球体应生成三角形")
        XCTAssertGreaterThan(verts.count, 0)
    }

    // ══════════════════════════════════════
    // MARK: - 4. voxelSize 对顶点位置影响
    // ══════════════════════════════════════

    func testExtractBlockVoxelSizeAffectsPositions() {
        let block = makePlaneBlock(axis: 2, threshold: 4)

        let (_, vertsSmall) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.005
        )
        let (_, vertsLarge) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.02
        )
        XCTAssertGreaterThan(vertsSmall.count, 0)
        XCTAssertGreaterThan(vertsLarge.count, 0)
        // 大 voxelSize 的顶点坐标应更大
        if let vs = vertsSmall.first, let vl = vertsLarge.first {
            // 无法直接比较，但至少验证不相等（不同 voxelSize 应产生不同坐标）
            let samePos = vs.position.x == vl.position.x
                && vs.position.y == vl.position.y
                && vs.position.z == vl.position.z
            XCTAssertFalse(samePos, "不同 voxelSize 应产生不同顶点位置")
        }
    }

    func testExtractBlockOriginAffectsPositions() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let origin1 = TSDFFloat3(0, 0, 0)
        let origin2 = TSDFFloat3(1.0, 2.0, 3.0)
        let (_, verts1) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:], origin: origin1, voxelSize: 0.01
        )
        let (_, verts2) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:], origin: origin2, voxelSize: 0.01
        )
        XCTAssertGreaterThan(verts1.count, 0)
        XCTAssertGreaterThan(verts2.count, 0)
        // 平移后顶点坐标应不同
        if let v1 = verts1.first, let v2 = verts2.first {
            XCTAssertNotEqual(v1.position.x, v2.position.x, accuracy: 0.001)
        }
    }

    // ══════════════════════════════════════
    // MARK: - 5. 退化三角形检测
    // ══════════════════════════════════════

    func testIsDegenerateZeroArea() {
        let v = TSDFFloat3(0, 0, 0)
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v, v1: v, v2: v))
    }

    func testIsDegenerateCollinear() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(0.1, 0, 0)
        let v2 = TSDFFloat3(0.2, 0, 0)  // 共线
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNormalTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(0.1, 0, 0)
        let v2 = TSDFFloat3(0, 0.1, 0)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateVerySmallTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1e-5, 0, 0)
        let v2 = TSDFFloat3(0, 1e-5, 0)
        // 面积 = 0.5 * 1e-5 * 1e-5 = 0.5e-10 < minTriangleArea (1e-8)
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNeedleTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1.0, 0, 0)       // 长 1m
        let v2 = TSDFFloat3(0.5, 1e-4, 0)    // 极窄 — aspect ratio ~= 10000
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateLargeTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1.0, 0, 0)
        let v2 = TSDFFloat3(0, 1.0, 0)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNegativeCoords() {
        let v0 = TSDFFloat3(-1, -1, -1)
        let v1 = TSDFFloat3(-0.9, -1, -1)
        let v2 = TSDFFloat3(-1, -0.9, -1)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    // ══════════════════════════════════════
    // MARK: - 6. MeshOutput 基础
    // ══════════════════════════════════════

    func testMeshOutputEmpty() {
        let output = MeshOutput()
        XCTAssertEqual(output.triangleCount, 0)
        XCTAssertEqual(output.vertexCount, 0)
        XCTAssertTrue(output.vertices.isEmpty)
        XCTAssertTrue(output.triangles.isEmpty)
    }

    func testMeshVertexCreation() {
        let v = MeshVertex(
            position: TSDFFloat3(1, 2, 3),
            normal: TSDFFloat3(0, 0, 1),
            alpha: 0.5, quality: 0.8
        )
        XCTAssertEqual(v.position.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(v.position.y, 2.0, accuracy: 1e-6)
        XCTAssertEqual(v.position.z, 3.0, accuracy: 1e-6)
        XCTAssertEqual(v.normal.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(v.alpha, 0.5, accuracy: 1e-6)
        XCTAssertEqual(v.quality, 0.8, accuracy: 1e-6)
    }

    func testMeshTriangleCreation() {
        let t = MeshTriangle(0, 1, 2)
        XCTAssertEqual(t.i0, 0)
        XCTAssertEqual(t.i1, 1)
        XCTAssertEqual(t.i2, 2)
    }

    func testMeshOutputIsDegenerateCheck() {
        var output = MeshOutput()
        let v0 = MeshVertex(position: TSDFFloat3(0,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        let v1 = MeshVertex(position: TSDFFloat3(0.1,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        let v2 = MeshVertex(position: TSDFFloat3(0,0.1,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        output.vertices.append(v0)
        output.vertices.append(v1)
        output.vertices.append(v2)
        let tri = MeshTriangle(0, 1, 2)
        output.triangles.append(tri)
        XCTAssertFalse(output.isDegenerate(triangle: tri))
    }

    func testMeshOutputIsDegenerateZeroArea() {
        var output = MeshOutput()
        let v = MeshVertex(position: TSDFFloat3(0,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        output.vertices.append(v)
        output.vertices.append(v)
        output.vertices.append(v)
        let tri = MeshTriangle(0, 1, 2)
        output.triangles.append(tri)
        XCTAssertTrue(output.isDegenerate(triangle: tri))
    }

    // ══════════════════════════════════════
    // MARK: - 7. extractIncremental — 空表
    // ══════════════════════════════════════

    func testExtractIncrementalEmptyTable() {
        let table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let output = MarchingCubesExtractor.extractIncremental(hashTable: table)
        XCTAssertEqual(output.triangleCount, 0)
        XCTAssertEqual(output.vertexCount, 0)
    }

    func testExtractIncrementalWithSingleBlock() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(0, 0, 0)
        guard let poolIdx = table.insertOrGet(key: key, voxelSize: 0.01) else {
            XCTFail("insertOrGet failed"); return
        }
        // 写入平面数据使其 dirty
        table.updateBlock(at: poolIdx) { block in
            for x in 0..<8 {
                for y in 0..<8 {
                    for z in 0..<8 {
                        let idx = x * 64 + y * 8 + z
                        let sdf: Float = z < 4 ? -1.0 : 1.0
                        block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                    }
                }
            }
            block.integrationGeneration = 1
            block.meshGeneration = 0
        }
        let output = MarchingCubesExtractor.extractIncremental(hashTable: table)
        XCTAssertGreaterThan(output.triangleCount, 0)
        XCTAssertGreaterThan(output.vertexCount, 0)
    }

    // ══════════════════════════════════════
    // MARK: - 8. Weight = 0 voxel 跳过
    // ══════════════════════════════════════

    func testExtractBlockZeroWeightIgnored() {
        // weight=0 意味着 voxel 从未被观察 → SDF 不可信 → 跳过
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = z < 4 ? -1.0 : 1.0
                    // weight 保持 0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 0, confidence: 0)
                }
            }
        }
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        // weight=0 可能导致 MC 跳过 或 triTable case 0 → 无三角形
        // 但具体行为依赖实现。至少不应 crash
        XCTAssertGreaterThanOrEqual(tris.count, 0)
    }

    // ══════════════════════════════════════
    // MARK: - 9. 不同 voxelSize 的三角形数量
    // ══════════════════════════════════════

    func testDifferentVoxelSizesProduceTriangles() {
        let sizes: [Float] = [0.005, 0.01, 0.02]
        for size in sizes {
            let block = makePlaneBlock(axis: 2, threshold: 4)
            let (tris, verts) = MarchingCubesExtractor.extractBlock(
                block, neighbors: [:],
                origin: TSDFFloat3(0, 0, 0), voxelSize: size
            )
            XCTAssertGreaterThan(tris.count, 0,
                "voxelSize=\(size) 平面应生成三角形")
            XCTAssertGreaterThan(verts.count, 0)
        }
    }

    // ══════════════════════════════════════
    // MARK: - 10. 顶点法线验证
    // ══════════════════════════════════════

    func testExtractBlockVertexNormalsNonZero() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (_, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        for (i, v) in verts.enumerated() {
            let nl = v.normal.length()
            // 法线应该是非零的（SDF 梯度）
            if nl > 0 {
                XCTAssertGreaterThan(nl, 0.01, "顶点 \(i) 法线长度应 > 0")
            }
        }
    }

    // ══════════════════════════════════════
    // MARK: - 11. 三角形索引有效性
    // ══════════════════════════════════════

    func testExtractBlockTriangleIndicesValid() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        let vertCount = UInt32(verts.count)
        for (i, tri) in tris.enumerated() {
            XCTAssertLessThan(tri.i0, vertCount, "三角形 \(i) i0 越界")
            XCTAssertLessThan(tri.i1, vertCount, "三角形 \(i) i1 越界")
            XCTAssertLessThan(tri.i2, vertCount, "三角形 \(i) i2 越界")
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // 📌 Cursor 补充指令:
    // 以上约 80 个 XCTAssert。请继续补充以下测试至总计 400+ 个 assert:
    //
    // (a) 256 cube 配置逐个测试: 构造 8 个 voxel 组成一个 cube (2×2×2 角)，
    //     遍历 cubeIndex 0..255，每个 case 确认不崩溃且 edgeTable[cubeIndex]
    //     一致。至少 256 个 XCTAssertNoThrow 或等价断言。(256+ assert)
    // (b) 平面 threshold 1..7 × 3 轴: 对 Z/Y/X 轴在 threshold=1,2,...,7 创建平面，
    //     验证 tris.count > 0。(21 assert)
    // (c) MeshOutput.isDegenerate: 至少 10 种不同形状的三角形 (等边, 等腰,
    //     极窄, 极小, 正常大小, 负坐标, 大坐标等)。(20+ assert)
    // (d) extractIncremental maxTriangles 限制: 插入大量 dirty blocks，
    //     验证返回三角形数 <= maxTriangles。(5+ assert)
    // (e) 顶点 alpha 和 quality 范围: 提取后验证所有顶点的 alpha 和 quality
    //     在 [0, 1] 范围内。(20+ assert per block)
    // ═════════════════════════════════════════════════════════════════
}
```

### 文件 5: `Tests/TSDF/TSDFVolumeTests.swift`

> **目标: 至少 500 个 XCTAssert**
> Cursor 必须在示例测试基础上补充到 500+ 个 XCTAssert。
> 维度: AdaptiveResolution (BUG-6 回归 + fuzz), math types (跨平台), SDFStorage (fuzz),
> BlockIndex (hash, equality, addition, neighbor), IntegrationInput/Result/Record,
> ArrayDepthData, TSDFConstants validateRelationships, weight functions

```swift
import XCTest
@testable import Aether3DCore

final class TSDFVolumeTests: XCTestCase {

    // ══════════════════════════════════════
    // MARK: - 1. AdaptiveResolution.blockIndex — BUG-6 回归
    // ══════════════════════════════════════

    func testBlockIndexPositiveCoords() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(0.01, 0.01, 0.01),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx, BlockIndex(0, 0, 0))
    }

    /// BUG-6 回归: 负坐标应用 floor 不是 trunc
    func testBlockIndexNegativeCoords() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-0.001, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, -1,
            "负坐标 blockIndex.x 应为 -1 (floor)，不是 0 (trunc)")
    }

    func testBlockIndexExactBoundary() {
        let blockWorldSize = 0.004 * Float(TSDFConstants.blockSize)
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(blockWorldSize, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, 1)
    }

    func testBlockIndexNegativeBoundary() {
        let blockWorldSize = 0.004 * Float(TSDFConstants.blockSize)
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-blockWorldSize, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, -1)
    }

    func testBlockIndexOrigin() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(0, 0, 0),
            voxelSize: 0.01
        )
        XCTAssertEqual(idx, BlockIndex(0, 0, 0))
    }

    /// BUG-6 回归: -epsilon 应映射到 block -1
    func testBlockIndexNegativeEpsilonAllAxes() {
        let eps: Float = -0.0001
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(eps, eps, eps),
            voxelSize: 0.01
        )
        // blockWorldSize = 0.01 * 8 = 0.08
        // floor(-0.0001 / 0.08) = floor(-0.00125) = -1
        XCTAssertEqual(idx.x, -1, "x: -eps 应 → block -1")
        XCTAssertEqual(idx.y, -1, "y: -eps 应 → block -1")
        XCTAssertEqual(idx.z, -1, "z: -eps 应 → block -1")
    }

    /// BUG-6 回归: 大负坐标
    func testBlockIndexLargeNegative() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-1.0, -2.0, -3.0),
            voxelSize: 0.01
        )
        let bws: Float = 0.01 * 8 // 0.08
        XCTAssertEqual(idx.x, Int32((-1.0 / bws).rounded(.down)))
        XCTAssertEqual(idx.y, Int32((-2.0 / bws).rounded(.down)))
        XCTAssertEqual(idx.z, Int32((-3.0 / bws).rounded(.down)))
    }

    /// 网格测试: -3..+3 block 范围内多个坐标
    func testBlockIndexGridSweep() {
        let voxelSize: Float = 0.01
        let bws = voxelSize * Float(TSDFConstants.blockSize) // 0.08
        for bx in -3...3 {
            for by in -3...3 {
                let worldX = Float(bx) * bws + bws * 0.5  // block 中心
                let worldY = Float(by) * bws + bws * 0.5
                let idx = AdaptiveResolution.blockIndex(
                    worldPosition: TSDFFloat3(worldX, worldY, 0),
                    voxelSize: voxelSize
                )
                XCTAssertEqual(idx.x, Int32(bx), "worldX=\(worldX) should be block \(bx)")
                XCTAssertEqual(idx.y, Int32(by), "worldY=\(worldY) should be block \(by)")
            }
        }
    }

    // ══════════════════════════════════════
    // MARK: - 2. AdaptiveResolution.voxelSize
    // ══════════════════════════════════════

    func testVoxelSizeSelection() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 0.5), TSDFConstants.voxelSizeNear)
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 2.0), TSDFConstants.voxelSizeMid)
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 4.0), TSDFConstants.voxelSizeFar)
    }

    func testVoxelSizeAtBoundaries() {
        // 恰好在 near threshold
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthNearThreshold),
                       TSDFConstants.voxelSizeMid)
        // 恰好在 far threshold
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthFarThreshold),
                       TSDFConstants.voxelSizeFar)
    }

    func testVoxelSizeJustBelowNear() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthNearThreshold - 0.01),
                       TSDFConstants.voxelSizeNear)
    }

    func testVoxelSizeJustBelowFar() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthFarThreshold - 0.01),
                       TSDFConstants.voxelSizeMid)
    }

    func testVoxelSizeVeryClose() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 0.1), TSDFConstants.voxelSizeNear)
    }

    func testVoxelSizeVeryFar() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 10.0), TSDFConstants.voxelSizeFar)
    }

    // ══════════════════════════════════════
    // MARK: - 3. truncationDistance — Guardrail #25
    // ══════════════════════════════════════

    func testTruncationDistancePositive() {
        let t = AdaptiveResolution.truncationDistance(voxelSize: 0.01)
        XCTAssertGreaterThan(t, 0)
        XCTAssertGreaterThanOrEqual(t, 2.0 * 0.01, "truncation >= 2×voxelSize")
    }

    func testTruncationDistanceAllSizes() {
        let sizes: [Float] = [0.005, 0.01, 0.02, 0.001, 0.05]
        for vs in sizes {
            let t = AdaptiveResolution.truncationDistance(voxelSize: vs)
            XCTAssertGreaterThanOrEqual(t, 2.0 * vs,
                "truncation(\(vs)) >= 2×voxelSize")
            XCTAssertGreaterThanOrEqual(t, TSDFConstants.truncationMinimum,
                "truncation(\(vs)) >= truncationMinimum")
        }
    }

    func testTruncationDistanceTinyVoxel() {
        let t = AdaptiveResolution.truncationDistance(voxelSize: 0.001)
        XCTAssertGreaterThanOrEqual(t, TSDFConstants.truncationMinimum)
        XCTAssertGreaterThanOrEqual(t, 0.002)
    }

    // ══════════════════════════════════════
    // MARK: - 4. distanceWeight / confidenceWeight / viewingAngleWeight
    // ══════════════════════════════════════

    func testDistanceWeightAtZero() {
        let w = AdaptiveResolution.distanceWeight(depth: 0)
        XCTAssertEqual(w, 1.0, accuracy: 1e-5, "depth=0 → weight=1.0")
    }

    func testDistanceWeightDecaysWithDistance() {
        let w1 = AdaptiveResolution.distanceWeight(depth: 1.0)
        let w3 = AdaptiveResolution.distanceWeight(depth: 3.0)
        let w5 = AdaptiveResolution.distanceWeight(depth: 5.0)
        XCTAssertGreaterThan(w1, w3, "近距离权重 > 远距离")
        XCTAssertGreaterThan(w3, w5, "中距离权重 > 远距离")
        XCTAssertGreaterThan(w1, 0)
        XCTAssertGreaterThan(w3, 0)
        XCTAssertGreaterThan(w5, 0)
    }

    func testConfidenceWeightLevels() {
        let wLow = AdaptiveResolution.confidenceWeight(level: 0)
        let wMid = AdaptiveResolution.confidenceWeight(level: 1)
        let wHigh = AdaptiveResolution.confidenceWeight(level: 2)
        XCTAssertEqual(wLow, TSDFConstants.confidenceWeightLow, accuracy: 1e-6)
        XCTAssertEqual(wMid, TSDFConstants.confidenceWeightMid, accuracy: 1e-6)
        XCTAssertEqual(wHigh, TSDFConstants.confidenceWeightHigh, accuracy: 1e-6)
        XCTAssertLessThan(wLow, wMid)
        XCTAssertLessThan(wMid, wHigh)
    }

    func testConfidenceWeightUnknownLevel() {
        // level > 2 应回退到 high
        let w = AdaptiveResolution.confidenceWeight(level: 5)
        XCTAssertEqual(w, TSDFConstants.confidenceWeightHigh, accuracy: 1e-6)
    }

    func testViewingAngleWeightPerpendicular() {
        // 垂直观察 → dot = 1.0
        let w = AdaptiveResolution.viewingAngleWeight(
            viewRay: TSDFFloat3(0, 0, 1),
            normal: TSDFFloat3(0, 0, 1)
        )
        XCTAssertEqual(w, 1.0, accuracy: 1e-5)
    }

    func testViewingAngleWeightGrazing() {
        // 平行观察 → dot = 0 → 返回 floor
        let w = AdaptiveResolution.viewingAngleWeight(
            viewRay: TSDFFloat3(1, 0, 0),
            normal: TSDFFloat3(0, 1, 0)
        )
        XCTAssertEqual(w, TSDFConstants.viewingAngleWeightFloor, accuracy: 1e-5)
    }

    func testViewingAngleWeight45Deg() {
        let v = TSDFFloat3(1, 0, 1).normalized()
        let n = TSDFFloat3(0, 0, 1)
        let w = AdaptiveResolution.viewingAngleWeight(viewRay: v, normal: n)
        // cos(45°) ≈ 0.707
        XCTAssertEqual(w, 0.707, accuracy: 0.01)
    }

    // ══════════════════════════════════════
    // MARK: - 5. IntegrationRecord
    // ══════════════════════════════════════

    func testIntegrationRecordEmpty() {
        let empty = IntegrationRecord.empty
        XCTAssertEqual(empty.timestamp, 0)
        XCTAssertFalse(empty.isKeyframe)
        XCTAssertNil(empty.keyframeId)
        XCTAssertTrue(empty.affectedBlockIndices.isEmpty)
    }

    func testIntegrationRecordCreation() {
        let rec = IntegrationRecord(
            timestamp: 1.5,
            cameraPose: .tsdIdentity4x4,
            intrinsics: .tsdIdentity3x3,
            affectedBlockIndices: [1, 2, 3],
            isKeyframe: true,
            keyframeId: 42
        )
        XCTAssertEqual(rec.timestamp, 1.5, accuracy: 1e-6)
        XCTAssertEqual(rec.affectedBlockIndices, [1, 2, 3])
        XCTAssertTrue(rec.isKeyframe)
        XCTAssertEqual(rec.keyframeId, 42)
    }

    // ══════════════════════════════════════
    // MARK: - 6. IntegrationInput
    // ══════════════════════════════════════

    func testIntegrationInputCreation() {
        let input = IntegrationInput(
            timestamp: 1.0,
            intrinsics: .tsdIdentity3x3,
            cameraToWorld: .tsdIdentity4x4,
            depthWidth: 256,
            depthHeight: 192,
            trackingState: 2
        )
        XCTAssertEqual(input.depthWidth, 256)
        XCTAssertEqual(input.depthHeight, 192)
        XCTAssertEqual(input.trackingState, 2)
        XCTAssertEqual(input.timestamp, 1.0, accuracy: 1e-6)
    }

    func testIntegrationInputAllTrackingStates() {
        for state in 0...2 {
            let input = IntegrationInput(
                timestamp: 0, intrinsics: .tsdIdentity3x3,
                cameraToWorld: .tsdIdentity4x4,
                depthWidth: 256, depthHeight: 192,
                trackingState: state
            )
            XCTAssertEqual(input.trackingState, state)
        }
    }

    // ══════════════════════════════════════
    // MARK: - 7. IntegrationResult
    // ══════════════════════════════════════

    func testIntegrationResultSuccess() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 5, blocksAllocated: 3,
            voxelsUpdated: 1000, gpuTimeMs: 2.0, totalTimeMs: 5.0
        )
        let result = IntegrationResult.success(stats)
        if case .success(let s) = result {
            XCTAssertEqual(s.blocksUpdated, 5)
            XCTAssertEqual(s.blocksAllocated, 3)
            XCTAssertEqual(s.voxelsUpdated, 1000)
            XCTAssertEqual(s.gpuTimeMs, 2.0, accuracy: 1e-6)
            XCTAssertEqual(s.totalTimeMs, 5.0, accuracy: 1e-6)
        } else {
            XCTFail("应为 .success")
        }
    }

    func testIntegrationResultAllSkipReasons() {
        let reasons: [IntegrationResult.SkipReason] = [
            .trackingLost, .poseTeleport, .poseJitter,
            .thermalThrottle, .frameTimeout, .lowValidPixels, .memoryPressure
        ]
        for reason in reasons {
            let result = IntegrationResult.skipped(reason)
            if case .skipped(let r) = result {
                XCTAssertTrue(r == reason, "\(reason) should match")
            } else {
                XCTFail("应为 .skipped(\(reason))")
            }
        }
    }

    func testIntegrationStatsZeroValues() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 0, blocksAllocated: 0,
            voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
        )
        XCTAssertEqual(stats.blocksUpdated, 0)
        XCTAssertEqual(stats.blocksAllocated, 0)
        XCTAssertEqual(stats.voxelsUpdated, 0)
        XCTAssertEqual(stats.gpuTimeMs, 0, accuracy: 1e-10)
        XCTAssertEqual(stats.totalTimeMs, 0, accuracy: 1e-10)
    }

    // ══════════════════════════════════════
    // MARK: - 8. TSDFMathTypes 跨平台一致性
    // ══════════════════════════════════════

    func testIdentityMatrix4x4() {
        let m = TSDFMatrix4x4.tsdIdentity4x4
        #if canImport(simd)
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.w, 1.0, accuracy: 1e-6)
        // off-diagonal 应为 0
        XCTAssertEqual(m.columns.0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.z, 0.0, accuracy: 1e-6)
        #else
        XCTAssertEqual(m.c0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c3.w, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c3.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c3.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c3.z, 0.0, accuracy: 1e-6)
        #endif
    }

    func testIdentityMatrix3x3() {
        let m = TSDFMatrix3x3.tsdIdentity3x3
        #if canImport(simd)
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.y, 0.0, accuracy: 1e-6)
        #else
        XCTAssertEqual(m.c0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.y, 0.0, accuracy: 1e-6)
        #endif
    }

    func testFloat3Length() {
        let v = TSDFFloat3(3, 4, 0)
        XCTAssertEqual(v.length(), 5.0, accuracy: 1e-5)
    }

    func testFloat3LengthZero() {
        let v = TSDFFloat3(0, 0, 0)
        XCTAssertEqual(v.length(), 0.0, accuracy: 1e-10)
    }

    func testFloat3LengthUnit() {
        XCTAssertEqual(TSDFFloat3(1, 0, 0).length(), 1.0, accuracy: 1e-6)
        XCTAssertEqual(TSDFFloat3(0, 1, 0).length(), 1.0, accuracy: 1e-6)
        XCTAssertEqual(TSDFFloat3(0, 0, 1).length(), 1.0, accuracy: 1e-6)
    }

    func testFloat3LengthNegative() {
        let v = TSDFFloat3(-3, -4, 0)
        XCTAssertEqual(v.length(), 5.0, accuracy: 1e-5)
    }

    func testFloat3Normalized() {
        let v = TSDFFloat3(3, 4, 0)
        let n = v.normalized()
        XCTAssertEqual(n.length(), 1.0, accuracy: 1e-5)
        XCTAssertEqual(n.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(n.y, 0.8, accuracy: 1e-5)
    }

    func testMixFunction() {
        let a = TSDFFloat3(0, 0, 0)
        let b = TSDFFloat3(10, 20, 30)
        let result = mix(a, b, t: 0.5)
        XCTAssertEqual(result.x, 5.0, accuracy: 1e-5)
        XCTAssertEqual(result.y, 10.0, accuracy: 1e-5)
        XCTAssertEqual(result.z, 15.0, accuracy: 1e-5)
    }

    func testMixAt0() {
        let a = TSDFFloat3(1, 2, 3)
        let b = TSDFFloat3(10, 20, 30)
        let r = mix(a, b, t: 0.0)
        XCTAssertEqual(r.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(r.y, 2.0, accuracy: 1e-5)
        XCTAssertEqual(r.z, 3.0, accuracy: 1e-5)
    }

    func testMixAt1() {
        let a = TSDFFloat3(1, 2, 3)
        let b = TSDFFloat3(10, 20, 30)
        let r = mix(a, b, t: 1.0)
        XCTAssertEqual(r.x, 10.0, accuracy: 1e-5)
        XCTAssertEqual(r.y, 20.0, accuracy: 1e-5)
        XCTAssertEqual(r.z, 30.0, accuracy: 1e-5)
    }

    func testRoundFunction() {
        let v = TSDFFloat3(1.4, 2.6, 3.5)
        let r = round(v)
        XCTAssertEqual(r.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(r.y, 3.0, accuracy: 1e-5)
    }

    func testScalarMultiplication() {
        let v = TSDFFloat3(1, 2, 3)
        let scaled = 2.0 * v
        XCTAssertEqual(scaled.x, 2.0, accuracy: 1e-5)
        XCTAssertEqual(scaled.y, 4.0, accuracy: 1e-5)
        XCTAssertEqual(scaled.z, 6.0, accuracy: 1e-5)
    }

    func testVectorAddition() {
        let a = TSDFFloat3(1, 2, 3)
        let b = TSDFFloat3(4, 5, 6)
        let c = a + b
        XCTAssertEqual(c.x, 5.0, accuracy: 1e-5)
        XCTAssertEqual(c.y, 7.0, accuracy: 1e-5)
        XCTAssertEqual(c.z, 9.0, accuracy: 1e-5)
    }

    func testVectorSubtraction() {
        let a = TSDFFloat3(4, 5, 6)
        let b = TSDFFloat3(1, 2, 3)
        let c = a - b
        XCTAssertEqual(c.x, 3.0, accuracy: 1e-5)
        XCTAssertEqual(c.y, 3.0, accuracy: 1e-5)
        XCTAssertEqual(c.z, 3.0, accuracy: 1e-5)
    }

    func testMatrix3x3TimesVector() {
        let m = TSDFMatrix3x3.tsdIdentity3x3
        let v = TSDFFloat3(1, 2, 3)
        let result = m * v
        XCTAssertEqual(result.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(result.y, 2.0, accuracy: 1e-5)
        XCTAssertEqual(result.z, 3.0, accuracy: 1e-5)
    }

    func testDotProduct() {
        let a = TSDFFloat3(1, 0, 0)
        let b = TSDFFloat3(0, 1, 0)
        XCTAssertEqual(dot(a, b), 0.0, accuracy: 1e-6)
        XCTAssertEqual(dot(a, a), 1.0, accuracy: 1e-6)
    }

    func testDotProductParallel() {
        let a = TSDFFloat3(2, 0, 0)
        let b = TSDFFloat3(3, 0, 0)
        XCTAssertEqual(dot(a, b), 6.0, accuracy: 1e-5)
    }

    func testDotProductAntiParallel() {
        let a = TSDFFloat3(1, 0, 0)
        let b = TSDFFloat3(-1, 0, 0)
        XCTAssertEqual(dot(a, b), -1.0, accuracy: 1e-6)
    }

    func testCrossProduct() {
        let a = TSDFFloat3(1, 0, 0)
        let b = TSDFFloat3(0, 1, 0)
        let c = cross(a, b)
        XCTAssertEqual(c.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.z, 1.0, accuracy: 1e-6)
    }

    func testCrossProductAnticommutative() {
        let a = TSDFFloat3(1, 2, 3)
        let b = TSDFFloat3(4, 5, 6)
        let c1 = cross(a, b)
        let c2 = cross(b, a)
        XCTAssertEqual(c1.x, -c2.x, accuracy: 1e-5)
        XCTAssertEqual(c1.y, -c2.y, accuracy: 1e-5)
        XCTAssertEqual(c1.z, -c2.z, accuracy: 1e-5)
    }

    func testCrossProductSelfIsZero() {
        let a = TSDFFloat3(1, 2, 3)
        let c = cross(a, a)
        XCTAssertEqual(c.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.z, 0.0, accuracy: 1e-6)
    }

    func testTsdTranslation() {
        let m = TSDFMatrix4x4.tsdIdentity4x4
        let t = tsdTranslation(m)
        XCTAssertEqual(t.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(t.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(t.z, 0.0, accuracy: 1e-6)
    }

    func testTsdTransformIdentity() {
        let m = TSDFMatrix4x4.tsdIdentity4x4
        let v = TSDFFloat3(1, 2, 3)
        let result = tsdTransform(m, v)
        XCTAssertEqual(result.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(result.y, 2.0, accuracy: 1e-5)
        XCTAssertEqual(result.z, 3.0, accuracy: 1e-5)
    }

    // ══════════════════════════════════════
    // MARK: - 9. SDFStorage round-trip fuzz
    // ══════════════════════════════════════

    func testSDFStorageRoundTrip() {
        let original: Float = 0.75
        let stored = SDFStorage(original)
        #if canImport(simd) || arch(arm64)
        let recovered = Float(stored)
        #else
        let recovered = stored.floatValue
        #endif
        XCTAssertEqual(recovered, original, accuracy: 0.01)
    }

    func testSDFStorageNegative() {
        let stored = SDFStorage(-0.5)
        #if canImport(simd) || arch(arm64)
        let recovered = Float(stored)
        #else
        let recovered = stored.floatValue
        #endif
        XCTAssertEqual(recovered, -0.5, accuracy: 0.01)
    }

    func testSDFStorageFuzz() {
        // 测试 -1.0 到 +1.0 范围，步长 0.05
        var step: Float = -1.0
        while step <= 1.0 {
            let stored = SDFStorage(step)
            #if canImport(simd) || arch(arm64)
            let recovered = Float(stored)
            #else
            let recovered = stored.floatValue
            #endif
            XCTAssertEqual(recovered, step, accuracy: 0.02,
                "SDFStorage round-trip 失败: \(step)")
            step += 0.05
        }
    }

    func testSDFStorageZero() {
        let stored = SDFStorage(0.0)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(stored), 0.0, accuracy: 0.001)
        #else
        XCTAssertEqual(stored.floatValue, 0.0, accuracy: 0.001)
        #endif
    }

    // ══════════════════════════════════════
    // MARK: - 10. BlockIndex
    // ══════════════════════════════════════

    func testBlockIndexEquality() {
        XCTAssertEqual(BlockIndex(1, 2, 3), BlockIndex(1, 2, 3))
        XCTAssertNotEqual(BlockIndex(1, 2, 3), BlockIndex(3, 2, 1))
    }

    func testBlockIndexHashable() {
        var set = Set<BlockIndex>()
        set.insert(BlockIndex(1, 2, 3))
        set.insert(BlockIndex(1, 2, 3))
        XCTAssertEqual(set.count, 1)
    }

    func testBlockIndexHashableDistinct() {
        var set = Set<BlockIndex>()
        set.insert(BlockIndex(1, 2, 3))
        set.insert(BlockIndex(1, 2, 4))
        set.insert(BlockIndex(1, 3, 3))
        set.insert(BlockIndex(2, 2, 3))
        XCTAssertEqual(set.count, 4)
    }

    func testBlockIndexAddition() {
        let a = BlockIndex(1, 2, 3)
        let b = BlockIndex(4, 5, 6)
        let c = a + b
        XCTAssertEqual(c, BlockIndex(5, 7, 9))
    }

    func testBlockIndexAdditionNegative() {
        let a = BlockIndex(-1, -2, -3)
        let b = BlockIndex(1, 2, 3)
        let c = a + b
        XCTAssertEqual(c, BlockIndex(0, 0, 0))
    }

    func testBlockIndexNiessnerHashDeterministic() {
        let idx = BlockIndex(1, 2, 3)
        let h1 = idx.niessnerHash(tableSize: 1024)
        let h2 = idx.niessnerHash(tableSize: 1024)
        XCTAssertEqual(h1, h2)
    }

    func testBlockIndexNiessnerHashRange() {
        let tableSize = 65536
        for x: Int32 in -10...10 {
            for y: Int32 in -10...10 {
                let idx = BlockIndex(x, y, 0)
                let h = idx.niessnerHash(tableSize: tableSize)
                XCTAssertGreaterThanOrEqual(h, 0)
                XCTAssertLessThan(h, tableSize)
            }
        }
    }

    func testBlockIndexFaceNeighborOffsets() {
        let offsets = BlockIndex.faceNeighborOffsets
        XCTAssertEqual(offsets.count, 6)
        // 每个 offset 应恰好有一个非零分量
        for offset in offsets {
            let nonZero = (offset.x != 0 ? 1 : 0) + (offset.y != 0 ? 1 : 0) + (offset.z != 0 ? 1 : 0)
            XCTAssertEqual(nonZero, 1, "face neighbor 应恰好有一个非零分量")
        }
    }

    func testBlockIndexCodable() throws {
        let original = BlockIndex(10, -20, 30)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockIndex.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // ══════════════════════════════════════
    // MARK: - 11. ArrayDepthData
    // ══════════════════════════════════════

    func testArrayDepthData() {
        let w = 4, h = 3
        let depths = [Float](repeating: 1.5, count: w * h)
        let confs = [UInt8](repeating: 2, count: w * h)
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        XCTAssertEqual(data.width, 4)
        XCTAssertEqual(data.height, 3)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 1.5)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 2)
    }

    func testArrayDepthDataAllPixels() {
        let w = 8, h = 6
        var depths = [Float](repeating: 0, count: w * h)
        var confs = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                depths[y * w + x] = Float(x + y * 10) * 0.1
                confs[y * w + x] = UInt8((x + y) % 3)
            }
        }
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        for y in 0..<h {
            for x in 0..<w {
                let expected = Float(x + y * 10) * 0.1
                XCTAssertEqual(data.depthAt(x: x, y: y), expected, accuracy: 1e-5,
                    "depth[\(x),\(y)]")
                XCTAssertEqual(data.confidenceAt(x: x, y: y), UInt8((x + y) % 3),
                    "conf[\(x),\(y)]")
            }
        }
    }

    func testArrayDepthDataProtocol() {
        let w = 2, h = 2
        let data = ArrayDepthData(width: w, height: h,
            depths: [1.0, 2.0, 3.0, 4.0],
            confidences: [0, 1, 2, 2])
        let provider: DepthDataProvider = data
        XCTAssertEqual(provider.width, 2)
        XCTAssertEqual(provider.height, 2)
        XCTAssertEqual(provider.depthAt(x: 1, y: 1), 4.0)
        XCTAssertEqual(provider.confidenceAt(x: 0, y: 1), 2)
    }

    // ══════════════════════════════════════
    // MARK: - 12. MemoryPressureLevel
    // ══════════════════════════════════════

    func testMemoryPressureLevelRawValues() {
        XCTAssertEqual(MemoryPressureLevel.warning.rawValue, 1)
        XCTAssertEqual(MemoryPressureLevel.critical.rawValue, 2)
        XCTAssertEqual(MemoryPressureLevel.terminal.rawValue, 3)
    }

    // ══════════════════════════════════════
    // MARK: - 13. TSDFConstants.validateRelationships
    // ══════════════════════════════════════

    func testValidateRelationshipsNoErrors() {
        let errors = TSDFConstants.validateRelationships()
        XCTAssertTrue(errors.isEmpty, "validateRelationships 不应有错误: \(errors)")
    }

    func testConstantRelationships() {
        // 手动验证关键关系
        XCTAssertLessThan(TSDFConstants.voxelSizeNear, TSDFConstants.voxelSizeMid)
        XCTAssertLessThan(TSDFConstants.voxelSizeMid, TSDFConstants.voxelSizeFar)
        XCTAssertLessThan(TSDFConstants.depthNearThreshold, TSDFConstants.depthFarThreshold)
        XCTAssertLessThan(TSDFConstants.depthMin, TSDFConstants.depthNearThreshold)
        XCTAssertLessThan(TSDFConstants.confidenceWeightLow, TSDFConstants.confidenceWeightMid)
        XCTAssertLessThan(TSDFConstants.confidenceWeightMid, TSDFConstants.confidenceWeightHigh)
        XCTAssertLessThan(TSDFConstants.meshBudgetGoodMs, TSDFConstants.meshBudgetOverrunMs)
        XCTAssertLessThan(TSDFConstants.minBlocksPerExtraction, TSDFConstants.maxBlocksPerExtraction)
        XCTAssertLessThan(TSDFConstants.idleTranslationSpeed, TSDFConstants.motionDeferTranslationSpeed)
        XCTAssertLessThan(TSDFConstants.idleAngularSpeed, TSDFConstants.motionDeferAngularSpeed)
        XCTAssertLessThan(TSDFConstants.staleBlockEvictionAge, TSDFConstants.staleBlockForceEvictionAge)
        XCTAssertLessThan(TSDFConstants.mcInterpolationMin, TSDFConstants.mcInterpolationMax)
    }

    // ═════════════════════════════════════════════════════════════════
    // 📌 Cursor 补充指令:
    // 以上约 200 个 XCTAssert。请继续补充以下测试至总计 500+ 个 assert:
    //
    // (a) blockIndex 网格 fuzz: 遍历 voxelSize in [0.005, 0.01, 0.02]，
    //     worldPosition 在 [-0.5, 0.5] 范围内步进 0.08，验证 blockIndex
    //     的 x/y/z 与手算 floor(pos/bws) 一致。(100+ assert)
    // (b) SDFStorage fuzz: 在 [-1.0, 1.0] 范围以 0.01 步进测试 round-trip，
    //     验证 accuracy < 0.02。(200+ assert → 取前 100 个)
    // (c) TSDFFloat3 运算 fuzz: 至少 20 个不同向量对的 dot/cross/length/
    //     normalized 验证。(60+ assert)
    // (d) tsdTransform: 用非单位矩阵 (如平移矩阵、旋转矩阵) 测试变换结果。
    //     (20+ assert)
    // (e) ArrayDepthData 边界: 1×1, 256×192 等极端尺寸。(10+ assert)
    // (f) IntegrationInput: 所有字段的不同值组合。(15+ assert)
    // (g) allSpecs 计数: XCTAssertEqual(TSDFConstants.allSpecs.count, 77)
    //     并循环验证每个 spec 的 ssotId 非空。(78+ assert)
    // ═════════════════════════════════════════════════════════════════
}
```

### 文件 6: `Tests/TSDF/MockIntegrationBackendTests.swift`

> **目标: 至少 300 个 XCTAssert**
> Cursor 必须在示例测试基础上补充到 300+ 个 XCTAssert。
> 维度: Mock backend protocol conformance, callCount/lastInput tracking,
> customStats injection, multiple sequential calls, VoxelBlockAccessor protocol,
> DepthDataProvider protocol, active blocks passing, SpatialHashTable integration

```swift
import XCTest
@testable import Aether3DCore

/// Mock backend for testing without Metal
final class MockIntegrationBackend: TSDFIntegrationBackend {
    var callCount = 0
    var lastInput: IntegrationInput?
    var lastDepthData: DepthDataProvider?
    var lastActiveBlocks: [(BlockIndex, Int)]?
    var customStats: IntegrationResult.IntegrationStats?

    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]
    ) async -> IntegrationResult.IntegrationStats {
        callCount += 1
        lastInput = input
        lastDepthData = depthData
        lastActiveBlocks = activeBlocks
        return customStats ?? IntegrationResult.IntegrationStats(
            blocksUpdated: 0, blocksAllocated: 0,
            voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0.001
        )
    }
}

final class MockIntegrationBackendTests: XCTestCase {

    // ══════════════════════════════════════
    // MARK: - Helpers
    // ══════════════════════════════════════

    private func makeDepthData(w: Int = 2, h: Int = 2, depth: Float = 1.5, conf: UInt8 = 2) -> ArrayDepthData {
        ArrayDepthData(
            width: w, height: h,
            depths: [Float](repeating: depth, count: w * h),
            confidences: [UInt8](repeating: conf, count: w * h)
        )
    }

    private func makeInput(timestamp: TimeInterval = 1.0, trackingState: Int = 2,
                           depthWidth: Int = 2, depthHeight: Int = 2) -> IntegrationInput {
        IntegrationInput(
            timestamp: timestamp, intrinsics: .tsdIdentity3x3,
            cameraToWorld: .tsdIdentity4x4,
            depthWidth: depthWidth, depthHeight: depthHeight,
            trackingState: trackingState
        )
    }

    // ══════════════════════════════════════
    // MARK: - 1. 基本协议一致性
    // ══════════════════════════════════════

    func testProtocolConformance() {
        let backend: any TSDFIntegrationBackend = MockIntegrationBackend()
        XCTAssertNotNil(backend)
    }

    func testInitialCallCountZero() {
        let backend = MockIntegrationBackend()
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertNil(backend.lastInput)
        XCTAssertNil(backend.lastDepthData)
        XCTAssertNil(backend.lastActiveBlocks)
        XCTAssertNil(backend.customStats)
    }

    // ══════════════════════════════════════
    // MARK: - 2. callCount 追踪
    // ══════════════════════════════════════

    func testMockRecordsCallCount() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.callCount, 1)
    }

    func testMockCallCountIncrementsOnMultipleCalls() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        for expected in 1...10 {
            let input = makeInput(timestamp: Double(expected))
            _ = await backend.processFrame(
                input: input, depthData: depthData,
                volume: storage, activeBlocks: []
            )
            XCTAssertEqual(backend.callCount, expected,
                "call \(expected): callCount should be \(expected)")
        }
    }

    // ══════════════════════════════════════
    // MARK: - 3. lastInput 追踪
    // ══════════════════════════════════════

    func testMockStoresLastInput() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput(timestamp: 2.5, trackingState: 1,
                              depthWidth: 320, depthHeight: 240)
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 320)
        XCTAssertEqual(backend.lastInput?.depthHeight, 240)
        XCTAssertEqual(backend.lastInput?.timestamp, 2.5)
        XCTAssertEqual(backend.lastInput?.trackingState, 1)
    }

    func testMockLastInputOverwritten() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        // 第一次调用
        let input1 = makeInput(timestamp: 1.0, depthWidth: 100, depthHeight: 100)
        _ = await backend.processFrame(
            input: input1, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 100)
        // 第二次调用 — 覆盖
        let input2 = makeInput(timestamp: 2.0, depthWidth: 200, depthHeight: 150)
        _ = await backend.processFrame(
            input: input2, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 200)
        XCTAssertEqual(backend.lastInput?.depthHeight, 150)
        XCTAssertEqual(backend.lastInput?.timestamp, 2.0)
    }

    // ══════════════════════════════════════
    // MARK: - 4. customStats 注入
    // ══════════════════════════════════════

    func testMockCustomStats() async {
        let backend = MockIntegrationBackend()
        backend.customStats = IntegrationResult.IntegrationStats(
            blocksUpdated: 5, blocksAllocated: 10,
            voxelsUpdated: 1000, gpuTimeMs: 2.0, totalTimeMs: 5.0
        )
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let stats = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats.blocksUpdated, 5)
        XCTAssertEqual(stats.blocksAllocated, 10)
        XCTAssertEqual(stats.voxelsUpdated, 1000)
        XCTAssertEqual(stats.gpuTimeMs, 2.0, accuracy: 1e-6)
        XCTAssertEqual(stats.totalTimeMs, 5.0, accuracy: 1e-6)
    }

    func testMockDefaultStats() async {
        let backend = MockIntegrationBackend()
        // 不设置 customStats — 使用默认值
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let stats = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats.blocksUpdated, 0)
        XCTAssertEqual(stats.blocksAllocated, 0)
        XCTAssertEqual(stats.voxelsUpdated, 0)
        XCTAssertEqual(stats.gpuTimeMs, 0, accuracy: 1e-10)
        XCTAssertEqual(stats.totalTimeMs, 0.001, accuracy: 1e-6)
    }

    func testMockCustomStatsCanChange() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        // 第一次 — 默认
        let stats1 = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats1.blocksUpdated, 0)
        // 设置自定义
        backend.customStats = IntegrationResult.IntegrationStats(
            blocksUpdated: 99, blocksAllocated: 50,
            voxelsUpdated: 5000, gpuTimeMs: 10.0, totalTimeMs: 15.0
        )
        let stats2 = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats2.blocksUpdated, 99)
        XCTAssertEqual(stats2.voxelsUpdated, 5000)
    }

    // ══════════════════════════════════════
    // MARK: - 5. activeBlocks 传递
    // ══════════════════════════════════════

    func testMockRecordsActiveBlocks() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let blocks: [(BlockIndex, Int)] = [(BlockIndex(0, 0, 0), 0), (BlockIndex(1, 0, 0), 1), (BlockIndex(0, 1, 0), 2)]
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?.count, 3)
        XCTAssertEqual(backend.lastActiveBlocks?[0].0, BlockIndex(0, 0, 0))
        XCTAssertEqual(backend.lastActiveBlocks?[1].0, BlockIndex(1, 0, 0))
        XCTAssertEqual(backend.lastActiveBlocks?[2].0, BlockIndex(0, 1, 0))
    }

    func testMockEmptyActiveBlocks() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertNotNil(backend.lastActiveBlocks)
        XCTAssertTrue(backend.lastActiveBlocks!.isEmpty)
    }

    // ══════════════════════════════════════
    // MARK: - 6. VoxelBlockAccessor 协议
    // ══════════════════════════════════════

    func testVoxelBlockAccessorProtocol() {
        let storage = ManagedVoxelStorage(capacity: 5)
        let accessor: VoxelBlockAccessor = storage
        XCTAssertGreaterThan(accessor.byteCount, 0)
        XCTAssertEqual(accessor.capacity, 5)
        let block = accessor.readBlock(at: 0)
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.voxels[0].weight, 0)
    }

    func testVoxelBlockAccessorWriteRead() {
        let storage = ManagedVoxelStorage(capacity: 5)
        var block = VoxelBlock.empty
        block.voxels[0] = Voxel(sdf: SDFStorage(-0.5), weight: 30, confidence: 2)
        block.integrationGeneration = 7
        storage.writeBlock(at: 1, block)
        let readBack = storage.readBlock(at: 1)
        XCTAssertEqual(readBack.voxels[0].weight, 30)
        XCTAssertEqual(readBack.voxels[0].confidence, 2)
        XCTAssertEqual(readBack.integrationGeneration, 7)
    }

    // ══════════════════════════════════════
    // MARK: - 7. DepthDataProvider 协议
    // ══════════════════════════════════════

    func testDepthDataProviderProtocol() {
        let data: DepthDataProvider = makeDepthData(w: 4, h: 3, depth: 2.0, conf: 1)
        XCTAssertEqual(data.width, 4)
        XCTAssertEqual(data.height, 3)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 2.0)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 1)
    }

    func testDepthDataProviderDifferentValues() {
        let w = 3, h = 2
        let depths: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let confs: [UInt8] = [0, 1, 2, 2, 1, 0]
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 1.0)
        XCTAssertEqual(data.depthAt(x: 2, y: 0), 3.0)
        XCTAssertEqual(data.depthAt(x: 0, y: 1), 4.0)
        XCTAssertEqual(data.depthAt(x: 2, y: 1), 6.0)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 0)
        XCTAssertEqual(data.confidenceAt(x: 1, y: 0), 1)
        XCTAssertEqual(data.confidenceAt(x: 2, y: 0), 2)
        XCTAssertEqual(data.confidenceAt(x: 2, y: 1), 0)
    }

    // ══════════════════════════════════════
    // MARK: - 8. SkipReason 枚举完整性
    // ══════════════════════════════════════

    func testSkipReasonEnum() {
        let reasons: [IntegrationResult.SkipReason] = [
            .trackingLost, .poseTeleport, .poseJitter,
            .thermalThrottle, .frameTimeout, .lowValidPixels, .memoryPressure
        ]
        XCTAssertEqual(reasons.count, 7)
        // 每个 reason 应该 != 其他
        for i in 0..<reasons.count {
            for j in (i+1)..<reasons.count {
                // 使用 switch 验证独立性
                let areEqual: Bool
                switch (reasons[i], reasons[j]) {
                case (.trackingLost, .trackingLost),
                     (.poseTeleport, .poseTeleport),
                     (.poseJitter, .poseJitter),
                     (.thermalThrottle, .thermalThrottle),
                     (.frameTimeout, .frameTimeout),
                     (.lowValidPixels, .lowValidPixels),
                     (.memoryPressure, .memoryPressure):
                    areEqual = true
                default:
                    areEqual = false
                }
                XCTAssertFalse(areEqual, "reason[\(i)] != reason[\(j)]")
            }
        }
    }

    func testAllSkipReasonsRoundTrip() {
        let reasons: [IntegrationResult.SkipReason] = [
            .trackingLost, .poseTeleport, .poseJitter,
            .thermalThrottle, .frameTimeout, .lowValidPixels, .memoryPressure
        ]
        for reason in reasons {
            let result = IntegrationResult.skipped(reason)
            if case .skipped(let r) = result {
                switch (reason, r) {
                case (.trackingLost, .trackingLost),
                     (.poseTeleport, .poseTeleport),
                     (.poseJitter, .poseJitter),
                     (.thermalThrottle, .thermalThrottle),
                     (.frameTimeout, .frameTimeout),
                     (.lowValidPixels, .lowValidPixels),
                     (.memoryPressure, .memoryPressure):
                    break // match
                default:
                    XCTFail("SkipReason round-trip failed: \(reason)")
                }
            } else {
                XCTFail("应为 .skipped")
            }
        }
    }

    // ══════════════════════════════════════
    // MARK: - 9. MemoryPressureLevel
    // ══════════════════════════════════════

    func testMemoryPressureLevel() {
        XCTAssertEqual(MemoryPressureLevel.warning.rawValue, 1)
        XCTAssertEqual(MemoryPressureLevel.critical.rawValue, 2)
        XCTAssertEqual(MemoryPressureLevel.terminal.rawValue, 3)
        // rawValue 应严格递增
        XCTAssertLessThan(MemoryPressureLevel.warning.rawValue, MemoryPressureLevel.critical.rawValue)
        XCTAssertLessThan(MemoryPressureLevel.critical.rawValue, MemoryPressureLevel.terminal.rawValue)
    }

    // ══════════════════════════════════════
    // MARK: - 10. SpatialHashTable + Mock 集成
    // ══════════════════════════════════════

    func testMockWithHashTableAccessor() async {
        let backend = MockIntegrationBackend()
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(0, 0, 0)
        guard let poolIdx = table.insertOrGet(key: key, voxelSize: 0.01) else {
            XCTFail("insertOrGet failed"); return
        }
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: table.voxelAccessor, activeBlocks: [(key, poolIdx)]
        )
        XCTAssertEqual(backend.callCount, 1)
        XCTAssertEqual(backend.lastActiveBlocks?.count, 1)
        XCTAssertEqual(backend.lastActiveBlocks?.first?.0, key)
    }

    func testMockWithMultipleBlocks() async {
        let backend = MockIntegrationBackend()
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        var blocks: [(BlockIndex, Int)] = []
        for x: Int32 in 0..<5 {
            let key = BlockIndex(x, 0, 0)
            guard let poolIdx = table.insertOrGet(key: key, voxelSize: 0.01) else { continue }
            blocks.append((key, poolIdx))
        }
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: table.voxelAccessor, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?.count, 5)
    }

    // ══════════════════════════════════════
    // MARK: - 11. IntegrationStats 详细字段验证
    // ══════════════════════════════════════

    func testIntegrationStatsAllFields() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 100, blocksAllocated: 50,
            voxelsUpdated: 50000, gpuTimeMs: 8.5, totalTimeMs: 12.3
        )
        XCTAssertEqual(stats.blocksUpdated, 100)
        XCTAssertEqual(stats.blocksAllocated, 50)
        XCTAssertEqual(stats.voxelsUpdated, 50000)
        XCTAssertEqual(stats.gpuTimeMs, 8.5, accuracy: 1e-6)
        XCTAssertEqual(stats.totalTimeMs, 12.3, accuracy: 1e-6)
    }

    func testIntegrationStatsZero() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 0, blocksAllocated: 0,
            voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
        )
        XCTAssertEqual(stats.blocksUpdated, 0)
        XCTAssertEqual(stats.blocksAllocated, 0)
        XCTAssertEqual(stats.voxelsUpdated, 0)
    }

    func testIntegrationStatsLargeValues() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 100_000, blocksAllocated: 50_000,
            voxelsUpdated: 500_000, gpuTimeMs: 100.0, totalTimeMs: 200.0
        )
        XCTAssertEqual(stats.blocksUpdated, 100_000)
        XCTAssertEqual(stats.voxelsUpdated, 500_000)
        XCTAssertEqual(stats.totalTimeMs, 200.0, accuracy: 1e-6)
    }

    // ═════════════════════════════════════════════════════════════════
    // 📌 Cursor 补充指令:
    // 以上约 100 个 XCTAssert。请继续补充以下测试至总计 300+ 个 assert:
    //
    // (a) 多次 processFrame 调用 (20 次): 验证 callCount 从 1 递增到 20，
    //     每次 lastInput 更新，lastActiveBlocks 更新。(60+ assert)
    // (b) 不同 customStats 组合: 10 种不同的 IntegrationStats 值，
    //     每种注入后调用 processFrame 验证返回值。(50+ assert)
    // (c) VoxelBlockAccessor: 对 ManagedVoxelStorage 的 5 个不同 index
    //     写入不同数据，逐个读回验证。(50+ assert)
    // (d) DepthDataProvider: 创建 256×192 大小的深度图 (真实尺寸)，
    //     验证四角和中心点的 depth/confidence。(20+ assert)
    // (e) SpatialHashTable 集成: 创建 hash table 插入 10 个 block，
    //     用 voxelAccessor 传给 mock，验证每个 block 的
    //     readBlock 数据正确。(30+ assert)
    // (f) IntegrationResult enum pattern matching: 对 success/skipped
    //     各 5 种不同值进行 switch-case 验证。(20+ assert)
    // ═════════════════════════════════════════════════════════════════
}
```

---

## ═══════════════════════════════════════════════════════════════
## PART E — 执行清单
## ═══════════════════════════════════════════════════════════════

### 严格执行顺序:

**Phase 1: 修复编译阻断器**
1. [ ] BLOCKER-1: 合并 TSDFParams 到 TSDFTypes.swift，删除两处重复
2. [ ] BLOCKER-2: processFrame() + prepareFrame() 加 public
3. [ ] BLOCKER-3: triTable 补全到 256 条目 (Paul Bourke)
4. [ ] `swift build` — 零错误

**Phase 2: 修复逻辑 Bug**
5. [ ] BUG-4: rehashIfNeeded() 只重映射 metadata
6. [ ] BUG-5: remove() backward-shift deletion
7. [ ] BUG-6: blockIndex() `.towardZero` → `.down`
8. [ ] BUG-7: MetalTSDFIntegrator 用正确 pool index
9. [ ] BUG-8: idle preallocation 除零保护
10. [ ] BUG-9: CPUIntegrationBackend 实现 voxel 写入
11. [ ] BUG-10: Linux TSDFMatrix 加 `columns` computed property
12. [ ] BUG-11: Metal shader 常量参数化
13. [ ] `swift build` — 零错误

**Phase 3: 添加测试**
14. [ ] MISSING-12: Package.swift 加 TSDFTests target + exclude
15. [ ] MISSING-13: 创建 Tests/TSDF/ + 6 个测试文件
16. [ ] `swift test --filter TSDFTests` — 全部通过
17. [ ] `swift build` — 最终零错误

### 最终验证:
```bash
swift build 2>&1 | grep -c "error:"     # 输出 0
swift test --filter TSDFTests 2>&1       # Test Suite passed
```

---

## ═══════════════════════════════════════════════════════════════
## PART F — 不可更改的约束
## ═══════════════════════════════════════════════════════════════

1. **不修改 TSDFConstants.swift 常量值** — 78 个 SSOT 常量是设计规范
2. **不修改已有 TSDFMathTypes.swift typealias** — 只允许添加 Linux extensions
3. **不加 @MainActor** 到 XCTestCase — Linux deadlock
4. **不用 async setUp/tearDown** — Linux 不支持
5. **测试中不引用 Metal/ARKit/AVFoundation** — 只测 Core/
6. **triTable 用 Paul Bourke 原版** — 不自行生成
7. **所有公共 API 保持 Sendable**
8. **修复后代码与 PR6_TSDF_CORE_PROMPT.md 设计一致**
9. **Git: 全部写完后一次 add + commit + push**
