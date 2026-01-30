# PR2-5 总体实施计划（v5.0 纠错版）

**文档版本:** 5.0
**状态:** DRAFT
**创建日期:** 2026-01-29
**最后更新:** 2026-01-29
**范围:** PR2-5 端侧采集质量提升 + 云端协同架构

---

## 第零部分：架构约束（写死）

### 0.1 核心约束

```
┌─────────────────────────────────────────────────────────────────┐
│                      三大铁律（不可违反）                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 所有开源项目、所有推理、所有调试 → 手机端执行               │
│     云端只负责：训练 + 渲染 + 存储                              │
│                                                                 │
│  2. 跨平台一致性：iOS / Android / Web 用户体验必须一样          │
│     → 所有端侧代码必须考虑跨平台抽象层                          │
│                                                                 │
│  3. 所有采集到的原始帧必须有两条路径：                          │
│     • rawFrame → 训练/渲染账本（不可篡改）                      │
│     • assistFrame → 只用于匹配/pose（可增强，不记入账本）       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 0.2 产品哲学

```
用户世界里根本不存在"重拍/补拍"的概念
只有：「我现在拍的这个地方，颜色有没有变亮」

UI 永远不出现文字
用户只看到 黑 → 灰 → 白 → 本色
用户永远只做一件事：怼着拍、转、靠近、补
一切"为什么还不行"，只存在于算法里
```

---

## 第一部分：v4.0 硬伤修正

### 1.1 硬伤 #1：单调递增会"伪证据锁死"

**问题：**
```swift
// v4.0 错误写法
EvidenceScore(t+1) = max(EvidenceScore(t), f(...))
```

当场景变化或错误观测被纳入时，证据会被永久记账，后续无法纠正。

**修正：三层证据体系**

```swift
/// 三层证据变量
public struct EvidenceLayers {

    /// Layer 1: 真实账本（可回退、可纠错）
    /// - 按 patch/voxel 级别存储
    /// - 允许剔除错误观测
    var ledger: PatchEvidenceMap  // 内部使用

    /// Layer 2: 显示证据（UI 单调）
    /// - 用 EMA 平滑 ledger
    /// - 只增不减
    var display: Double  // [0, 1]，用户可见

    /// Layer 3: 增量证据（受乘性影响）
    /// - 决定"亮得快不快"
    /// - 不会归零，只会变慢
    var delta: Double  // 当前帧贡献
}

/// 核心更新逻辑
func updateEvidence(
    currentLedger: inout PatchEvidenceMap,
    currentDisplay: inout Double,
    newObservation: Observation
) {
    // Step 1: 真实账本可纠错
    let patchId = newObservation.patchId
    let quality = newObservation.quality

    // 如果新观测质量更高，替换旧的
    if quality > currentLedger[patchId] ?? 0 {
        currentLedger[patchId] = quality
    }
    // 如果检测到错误（动态物体/深度失真），可以降低
    if newObservation.isErroneous {
        currentLedger[patchId] = max(0, (currentLedger[patchId] ?? 0) - 0.2)
    }

    // Step 2: 计算账本总分
    let ledgerTotal = currentLedger.values.reduce(0, +) / Double(currentLedger.count)

    // Step 3: UI 证据只增不减（用 EMA 平滑）
    let alpha: Double = 0.1
    let smoothed = alpha * ledgerTotal + (1 - alpha) * currentDisplay
    currentDisplay = max(currentDisplay, smoothed)  // UI 单调
}
```

**效果：**
- 用户看到的永远是"越来越亮"（UI 单调）
- 系统内部可以纠错（账本可回退）
- 纠错不通过"变暗"体现，而是"亮得慢/局部黑块迟迟不亮"

### 1.2 硬伤 #2：禁止处理会伤害弱纹理场景

**问题：**
v4.0 写了"永远不做锐化/去噪"，但弱纹理场景（墙面、暗光）SfM 会匹配失败。

**修正：双帧通道**

```swift
/// 双帧通道：rawFrame + assistFrame
public struct DualFrameChannel {

    /// 原始帧：用于训练/渲染（不可篡改）
    let rawFrame: CVPixelBuffer

    /// 辅助帧：只用于匹配/pose（可增强）
    let assistFrame: CVPixelBuffer

    /// 生成辅助帧（只在弱纹理场景启用）
    static func createAssistFrame(
        from raw: CVPixelBuffer,
        textureStrength: Double
    ) -> CVPixelBuffer {
        // 纹理足够 → 不需要辅助
        if textureStrength > 0.4 {
            return raw
        }

        // 弱纹理 → 轻度增强（只用于特征提取）
        var assist = raw.copy()

        // 轻度锐化（只为提特征，不用于渲染）
        assist = assist.applyUnsharpMask(amount: 0.3, radius: 1.0)

        // 轻度去噪（只为稳定特征点）
        assist = assist.applyBilateralFilter(sigma: 2.0)

        return assist
    }
}

/// 使用规则
public enum FrameUsageRules {

    /// 特征提取/匹配 → 优先 assistFrame
    static func forFeatureExtraction(_ dual: DualFrameChannel) -> CVPixelBuffer {
        return dual.assistFrame
    }

    /// Pose 优化 → 可用 assistFrame
    static func forPoseOptimization(_ dual: DualFrameChannel) -> CVPixelBuffer {
        return dual.assistFrame
    }

    /// 纹理/颜色证据 → 必须 rawFrame
    static func forTextureEvidence(_ dual: DualFrameChannel) -> CVPixelBuffer {
        return dual.rawFrame
    }

    /// 训练/渲染 → 必须 rawFrame
    static func forTraining(_ dual: DualFrameChannel) -> CVPixelBuffer {
        return dual.rawFrame
    }
}
```

**效果：**
- 弱纹理场景不会变成"黑洞"
- 最终渲染质量不受影响（用原始帧）
- 辅助帧只用于"找位置"，不用于"上色"

### 1.3 硬伤 #3：边缘置信度一刀切降权

**问题：**
v4.0 对所有边缘像素做 -0.15 降权，但几何边缘恰恰是 S5 的灵魂。

**修正：边缘分类置信度**

```swift
/// 边缘类型分类
public enum EdgeType {
    case geometric    // 几何边缘（高价值）
    case specular     // 反光边缘（低价值）
    case transparent  // 透明边缘（低价值）
    case textural     // 纹理边缘（中等价值）
}

/// 边缘分类器
public struct EdgeClassifier {

    /// 分类边缘像素
    static func classify(
        depthGradient: Float,
        colorGradient: Float,
        normalGradient: Float,
        arkitConfidence: Float
    ) -> EdgeType {
        // 深度跳变大 + 法线跳变大 → 几何边缘
        if depthGradient > 0.3 && normalGradient > 0.5 {
            return .geometric
        }

        // 颜色跳变大 + 深度平滑 → 反光边缘
        if colorGradient > 0.6 && depthGradient < 0.1 {
            return .specular
        }

        // ARKit 置信度极低 → 透明边缘
        if arkitConfidence < 0.2 {
            return .transparent
        }

        return .textural
    }
}

/// 边缘类型置信度
public struct EdgeConfidence {

    static func confidenceFor(_ edgeType: EdgeType) -> Double {
        switch edgeType {
        case .geometric:   return 0.95  // 高价值，高置信
        case .textural:    return 0.70  // 中等价值
        case .specular:    return 0.25  // 低价值（可能不准）
        case .transparent: return 0.15  // 最低（几乎不用）
        }
    }
}
```

**效果：**
- 几何边缘（真正的遮挡边界）获得高置信
- 反光/透明边缘被自动降权
- S5 灵魂（遮挡边界）不会被误杀

### 1.4 调整 #4：乘性惩罚不应让增长归零

**问题：**
v4.0 的乘性函数会导致"某一项坏=全坏"，用户怎么补都不涨。

**修正：乘性作用于增量，而非绝对值**

```swift
/// 软信号增益计算（乘性作用于增量）
public struct SoftGainV5 {

    /// 计算增量增益
    static func computeDeltaGain(
        baseGain: Double,           // 基础增益（0.0 - 1.0）
        qualityFactors: [Double]    // 各项质量因子（0.0 - 1.0）
    ) -> Double {
        // 乘性因子（但有下限）
        let multiplier = qualityFactors.reduce(1.0) { acc, factor in
            acc * max(0.1, factor)  // 下限 0.1，不会完全归零
        }

        // 最终增量 = 基础增益 × 乘性因子
        // 即使 qualityFactors 都很低，也有 baseGain * 0.1^n 的增长
        return baseGain * multiplier
    }

    /// 示例：深度 + 拓扑 乘性
    static func depthTopologyGain(
        depthConsistency: Double,   // 0.0 - 1.0
        occlusionSharpness: Double, // 0.0 - 1.0
        holeRatio: Double           // 0.0 - 1.0 (越低越好)
    ) -> Double {
        let depthFactor = sigmoid((0.06 - depthConsistency) / 0.015)
        let sharpFactor = sigmoid((occlusionSharpness - 0.82) / 0.05)
        let holeFactor = sigmoid((0.025 - holeRatio) / 0.01)

        // 乘性，但有下限
        return computeDeltaGain(
            baseGain: 0.5,
            qualityFactors: [depthFactor, sharpFactor, holeFactor]
        )
    }
}
```

### 1.5 调整 #5：动态权重（前期偏 Gate，后期偏 Soft）

**问题：**
v4.0 固定 0.55/0.45 权重会导致后期 Gate 饱和后推不动。

**修正：动态权重插值**

```swift
/// 动态权重计算
public struct DynamicWeights {

    /// 根据当前进度调整 Gate/Soft 权重
    static func weights(currentTotal: Double) -> (gate: Double, soft: Double) {
        // 前期（< 0.5）：偏 Gate，让它快亮
        // 后期（> 0.5）：偏 Soft，让登峰由 Soft 决定

        let t = smoothstep(0.45, 0.75, currentTotal)
        let gateWeight = lerp(0.65, 0.35, t)
        let softWeight = 1.0 - gateWeight

        return (gateWeight, softWeight)
    }

    /// smoothstep 插值
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// 线性插值
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }
}
```

### 1.6 调整 #6：抖动指标加时间窗

**问题：**
depthEdgeAlign、occlusionSharpness 容易单帧抖动，把用户"罚停"。

**修正：时间窗平滑**

```swift
/// 时间窗平滑器
public class MetricSmoother {

    private var history: [Double] = []
    private let windowSize: Int

    init(windowSize: Int = 5) {
        self.windowSize = windowSize
    }

    /// 添加新值并返回平滑后的值
    func addAndSmooth(_ value: Double) -> Double {
        history.append(value)
        if history.count > windowSize {
            history.removeFirst()
        }

        // 使用中位数（比均值更抗噪）
        return history.sorted()[history.count / 2]
    }
}

/// 在 Soft 计算中使用
public class SoftEvidenceCalculator {

    private let depthEdgeSmoother = MetricSmoother(windowSize: 5)
    private let occlusionSmoother = MetricSmoother(windowSize: 5)

    func computeSoftEvidence(
        rawDepthEdgeAlign: Double,
        rawOcclusionSharpness: Double,
        /* other metrics */
    ) -> Double {
        // 对易抖动指标做时间窗平滑
        let smoothedEdgeAlign = depthEdgeSmoother.addAndSmooth(rawDepthEdgeAlign)
        let smoothedOcclusion = occlusionSmoother.addAndSmooth(rawOcclusionSharpness)

        // 使用平滑后的值计算
        let depthBonus = sigmoid((1.8 - smoothedEdgeAlign) / 0.4)
        let sharpBonus = sigmoid((smoothedOcclusion - 0.82) / 0.05)

        // ...
    }
}
```

### 1.7 调整 #7：Soft 里 geomSoftBonus 降权

**问题：**
Soft 里加了 geomSoftBonus 0.20 权重，但 Soft 灵魂应该是 depth + topology。

**修正：geom 在 Soft 里降为 cap 角色**

```swift
/// Soft 内部权重（v5.0）
public enum SoftWeightsV5 {
    // 灵魂：depth + topology
    public static let depthWeight: Double = 0.30   // 提升
    public static let topoWeight: Double = 0.35    // 提升

    // 辅助：view + geom + semantic
    public static let viewWeight: Double = 0.15    // 不变
    public static let geomWeight: Double = 0.10    // 降低（从 0.20）
    public static let semanticWeight: Double = 0.10 // 不变

    // geomSoftBonus 改为 cap 模式
    // 只影响最后 10%，不与 depth/topo 争主权
}
```

---

## 第二部分：跨平台架构设计

### 2.1 三平台分工

```
┌─────────────────────────────────────────────────────────────────┐
│                      跨平台架构                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │     iOS      │  │   Android    │  │     Web      │          │
│  │              │  │              │  │              │          │
│  │ Swift/Metal  │  │ Kotlin/NNAPI │  │ TS/WebGPU    │          │
│  │ ARKit        │  │ ARCore       │  │ WebXR        │          │
│  │ CoreML       │  │ TFLite       │  │ ONNX.js      │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           ▼                                     │
│              ┌─────────────────────┐                            │
│              │    统一协议层        │                            │
│              │                     │                            │
│              │ • EvidenceProtocol  │                            │
│              │ • FrameProtocol     │                            │
│              │ • DepthProtocol     │                            │
│              │ • UploadProtocol    │                            │
│              └─────────────────────┘                            │
│                           │                                     │
│                           ▼                                     │
│              ┌─────────────────────┐                            │
│              │       云端          │                            │
│              │                     │                            │
│              │ • SfM 重建          │                            │
│              │ • 高斯训练          │                            │
│              │ • 渲染服务          │                            │
│              └─────────────────────┘                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 统一协议定义

```swift
/// 证据协议（所有平台必须实现）
public protocol EvidenceProtocol {
    /// 三层证据
    var ledger: PatchEvidenceMap { get }
    var display: Double { get }
    var delta: Double { get }

    /// 更新证据
    func update(observation: Observation)

    /// 颜色映射
    func colorForPatch(_ patchId: String) -> ColorState
}

/// 帧协议（所有平台必须实现）
public protocol FrameProtocol {
    /// 双帧通道
    var rawFrame: PixelBuffer { get }
    var assistFrame: PixelBuffer { get }

    /// 元数据
    var timestamp: Double { get }
    var pose: CameraPose { get }
    var intrinsics: CameraIntrinsics { get }
}

/// 深度协议（所有平台必须实现）
public protocol DepthProtocol {
    /// 融合深度
    var fusedDepth: DepthMap { get }

    /// 置信度（含边缘分类）
    var confidence: ConfidenceMap { get }

    /// 边缘类型
    func edgeTypeAt(_ x: Int, _ y: Int) -> EdgeType
}

/// 上传协议（所有平台必须实现）
public protocol UploadProtocol {
    /// 上传帧包
    func uploadFrameBundle(_ bundle: FrameBundle) async throws

    /// 上传进度
    var uploadProgress: Double { get }
}
```

### 2.3 平台适配层示例

```swift
// iOS 实现
class iOSEvidenceEngine: EvidenceProtocol {
    // 使用 Metal 加速证据计算
    private let metalCompute: MTLComputePipelineState
    // ...
}

// Android 实现（Kotlin）
class AndroidEvidenceEngine : EvidenceProtocol {
    // 使用 Vulkan/NNAPI 加速
    private val vulkanCompute: VkPipeline
    // ...
}

// Web 实现（TypeScript）
class WebEvidenceEngine implements EvidenceProtocol {
    // 使用 WebGPU 加速
    private computePipeline: GPUComputePipeline;
    // ...
}
```

---

## 第三部分：PR2-5 分支计划

### 3.1 总览

```
PR2: 证据系统基础
     ↓
PR3: Gate 可达系统
     ↓
PR4: Soft 极限系统
     ↓
PR5: 采集优化 + 端到端测试
```

### 3.2 PR2 - 证据系统基础（Week 1-2）

**目标：** 实现三层证据体系 + 颜色映射

| 任务 | 描述 | 优先级 | 跨平台 |
|------|------|--------|--------|
| EvidenceLayers 结构 | ledger + display + delta | P0 | ✓ |
| PatchEvidenceMap | 按 patch 存储证据 | P0 | ✓ |
| 颜色映射 | E_display → 黑灰白本色 | P0 | ✓ |
| 动态权重 | Gate/Soft 权重随进度变化 | P0 | ✓ |
| 时间窗平滑 | 抖动指标平滑器 | P1 | ✓ |
| 单元测试 | 证据更新逻辑测试 | P0 | ✓ |

**交付物：**
- `Core/Evidence/EvidenceLayers.swift`
- `Core/Evidence/PatchEvidenceMap.swift`
- `Core/Evidence/ColorMapping.swift`
- `Core/Evidence/DynamicWeights.swift`
- `Core/Evidence/MetricSmoother.swift`

### 3.3 PR3 - Gate 可达系统（Week 2-3）

**目标：** 实现 HardGates v1.3 + Gate 增益曲线

| 任务 | 描述 | 优先级 | 跨平台 |
|------|------|--------|--------|
| HardGates 常量 | v1.3 可达版数值 | P0 | ✓ |
| viewGateGain | 视角覆盖增益 | P0 | ✓ |
| geomGateGain | 几何精度增益 | P0 | ✓ |
| basicGateGain | 基础质量增益 | P0 | ✓ |
| 视角追踪 | L2/L3 视角计数 | P0 | ✓ |
| 单元测试 | Gate 增益曲线测试 | P0 | ✓ |

**交付物：**
- `Core/Constants/HardGatesV13.swift`
- `Core/Evidence/GateGainFunctions.swift`
- `Core/Tracking/ViewAngleTracker.swift`

### 3.4 PR4 - Soft 极限系统（Week 3-5）

**目标：** 实现 SoftSignals v1.3 + 深度融合 + 边缘分类

| 任务 | 描述 | 优先级 | 跨平台 |
|------|------|--------|--------|
| SoftSignals 常量 | v1.3 极限版数值 | P0 | ✓ |
| 乘性增益（v5）| 作用于增量，有下限 | P0 | ✓ |
| DualFrameChannel | rawFrame + assistFrame | P0 | ✓ |
| EdgeClassifier | 边缘类型分类 | P0 | ✓ |
| 深度融合 | Small + Large + ARKit | P0 | iOS |
| 深度置信度 | 含边缘分类置信 | P0 | ✓ |
| 拓扑评估 | 孔洞 + 遮挡边界 | P0 | ✓ |
| 单元测试 | Soft 增益曲线测试 | P0 | ✓ |

**交付物：**
- `Core/Constants/SoftSignalsV13.swift`
- `Core/Evidence/SoftGainV5.swift`
- `Core/Frame/DualFrameChannel.swift`
- `Core/Edge/EdgeClassifier.swift`
- `Core/Depth/DepthFusion.swift`
- `Core/Depth/DepthConfidenceV5.swift`
- `Core/Topology/TopologyEvaluator.swift`

### 3.5 PR5 - 采集优化（Week 5-6）

**目标：** 实现采集时控制 + 端到端测试

| 任务 | 描述 | 优先级 | 跨平台 |
|------|------|--------|--------|
| 曝光控制 | 锁定基准 + 暗光补灯 | P0 | iOS |
| 帧质量决策 | 丢弃 vs 保留 | P0 | ✓ |
| 纹理检测 | 决定是否需要 assistFrame | P0 | ✓ |
| 信息增益 | 选帧依据 | P1 | ✓ |
| 端到端测试 | 证据曲线验证 | P0 | ✓ |
| 性能测试 | 帧率/内存/电量 | P0 | iOS |

**交付物：**
- `Core/Capture/ExposureController.swift`
- `Core/Capture/FrameQualityDetector.swift`
- `Core/Capture/TextureStrengthAnalyzer.swift`
- `Core/Selection/InformationGain.swift`
- `Tests/E2E/EvidenceCurveTests.swift`

---

## 第四部分：关键常量汇总（v5.0）

### 4.1 HardGates v1.3（可达版）

```swift
public enum HardGatesV13 {
    // Coverage (reachable)
    public static let minThetaSpanDeg: Double = 26.0
    public static let minL2PlusCount: Int = 13
    public static let minL3Count: Int = 5

    // Geometry (reachable)
    public static let maxReprojRmsPx: Double = 0.48
    public static let maxEdgeRmsPx: Double = 0.23

    // Basic quality (reachable)
    public static let minSharpness: Double = 85.0
    public static let maxOverexposureRatio: Double = 0.28
    public static let maxUnderexposureRatio: Double = 0.38
}
```

### 4.2 SoftSignals v1.3（极限版）

```swift
public enum SoftSignalsV13 {
    // Depth (extreme)
    public static let depthConsistencyThreshold: Double = 0.06
    public static let depthEdgeAlignmentPx: Double = 1.8
    public static let minConfidenceForMetrics: Double = 0.65
    public static let edgeBandWidthPx: Int = 2

    // Topology (extreme)
    public static let occlusionBoundarySharpness: Double = 0.82
    public static let maxHoleRatio: Double = 0.025
    public static let enableHoleConnectivityPenalty: Bool = true

    // Semantics (cap, not hard)
    public static let semanticConsistencyRatio: Double = 0.94
}
```

### 4.3 证据权重（v5.0 动态版）

```swift
public enum EvidenceWeightsV5 {
    // 动态 Gate/Soft 权重（见 DynamicWeights）
    // 前期 Gate 0.65, 后期 Gate 0.35

    // Gate 内部权重
    public static let gateViewWeight: Double = 0.40
    public static let gateGeomWeight: Double = 0.45
    public static let gateBasicWeight: Double = 0.15

    // Soft 内部权重（v5.0 调整）
    public static let softViewWeight: Double = 0.15
    public static let softGeomWeight: Double = 0.10   // 降低
    public static let softDepthWeight: Double = 0.30  // 提升
    public static let softTopoWeight: Double = 0.35   // 提升
    public static let softSemanticWeight: Double = 0.10
}
```

### 4.4 边缘分类置信度

```swift
public enum EdgeTypeConfidence {
    public static let geometric: Double = 0.95
    public static let textural: Double = 0.70
    public static let specular: Double = 0.25
    public static let transparent: Double = 0.15
}
```

### 4.5 颜色映射阈值

```swift
public enum ColorMappingV5 {
    public static let blackThreshold: Double = 0.20
    public static let darkGrayThreshold: Double = 0.45
    public static let lightGrayThreshold: Double = 0.70
    public static let whiteThreshold: Double = 0.88
    public static let originalColorMinSoftEvidence: Double = 0.75
}
```

---

## 第五部分：风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 深度模型延迟过高 | 中 | 高 | Small 模型每帧，Large 每5帧 |
| 边缘分类不准确 | 中 | 中 | 渐进式上线，先用保守阈值 |
| 跨平台一致性难保证 | 高 | 高 | 定义统一协议 + 自动化测试 |
| 弱纹理场景 assistFrame 不够 | 低 | 中 | 可调节增强强度 |
| 动态物体检测漏报 | 中 | 中 | 结合 ARKit scene understanding |

---

## 总结

### v5.0 相对 v4.0 的核心改进

| 维度 | v4.0 | v5.0 |
|------|------|------|
| **证据体系** | 全局单调 max | 三层分离（ledger 可纠错，display 单调）|
| **帧处理** | 绝对禁止处理 | 双通道（raw 用于渲染，assist 用于匹配）|
| **边缘置信** | 一刀切降权 | 分类置信（几何边缘高权重）|
| **乘性惩罚** | 可能归零 | 作用于增量 + 下限 0.1 |
| **权重分配** | 固定 0.55/0.45 | 动态权重（前期偏 Gate，后期偏 Soft）|
| **Soft 内部** | geom 0.20 | geom 降为 0.10（cap 角色）|
| **跨平台** | 未明确 | 统一协议层 + 三平台适配 |

---

**状态:** DRAFT v5.0
**作者:** Claude Code
**最后更新:** 2026-01-29
