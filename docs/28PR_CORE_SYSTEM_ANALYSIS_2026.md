# 28 PR 核心层/系统层划分与执行分析

**日期**: 2026-02-11  
**状态**: 对照当前代码与 CURSOR_MEGA_PROMPT_V2 边界的冷静审查

---

## 1. 核心层 vs 系统层 — 边界定义（来自 CURSOR_MEGA_PROMPT_V2）

> 详见 `../CURSOR_MEGA_PROMPT_V2.md`（唯一核心文档，位于项目父目录）第 1 节。

### 可进入 C++ Core（纯逻辑、跨平台、可验证）：
- Evidence：D-S 融合、状态机、维度评分、账簿
- MerkleTree / Hash chain
- TimeAnchoring **规则**（验证逻辑、区间融合，不含网络 I/O）
- Quality/Gate **决策逻辑**：评分、阈值、fail-fast 原因码（**不含像素分析**）
- **PerformanceTier / Degradation**：evaluate(thermal, battery)→DegradationTier；THERMAL_THROTTLE_THRESHOLD、LOW_BATTERY_GRACE_LEVEL；与 TIER_FULL/REDUCED/MINIMAL 对齐（**仅接收系统层传入的 thermal_state、battery_level**）
- Constants / SSOT
- TSDF 纯算法：SpatialHashTable、MarchingCubes、体素融合
- 确定性 JSON 编码、 canonical 哈希、replay 引擎

### 禁止进入 C++ Core（平台 SDK、I/O、生命周期）：
- Metal / Vulkan / GPU
- ARKit / ARCore
- 数据库实现（Core 只定义格式）
- 网络栈、HTTP、推送、后台任务
- UI / SwiftUI
- **图像像素分析**（blur、曝光等 — 留在平台层，**仅结果传入 Core**）
- **热量/电量传感器采样**（thermal_state、battery_level — 平台层调用 ProcessInfo/BatteryManager，**仅结果传入 Core**）
- 系统时间采样（Core 接收时间戳，不直接调用系统时钟）

---

## 2. 28 PR 按层分类

| PR | 名称 | 层 | 说明 |
|----|------|-----|------|
| **PR1** | SSOT Constants & Error Codes | **核心** | 常量、错误码，已大部分在 Core/Constants |
| **PR2** | Job State Machine | 系统层（契约） | 状态机逻辑在 Core/Jobs，契约需 Swift↔Python 同步 |
| **PR3** | API Contract | 系统层 | 端点、schema、idempotency，Core 只定义契约常量 |
| **PR4** | Capture Recording | 系统层 | AVFoundation、中断、热控，纯平台 |
| **PR5** | Quality Pre-check | **混合** | 像素分析在平台，**阈值与决策逻辑在 Core** |
| **PR6** | Evidence Grid | **核心** | S0–S4、L1/L2/L3、PatchGrid、CoverageEstimator |
| **PR7** | Scan Guidance UI | 系统层 | 渲染、提示、覆盖可视化 |
| **PR8** | Bundle Format | 核心/系统边界 | Manifest、Hash、DeviceInfo 为纯逻辑，可迁入 Core |
| **PR9** | Chunked Upload | 系统层 | 网络、断点续传、进度，平台 I/O |
| **PR10** | Server Upload Reception | 系统层 | Python 端，I/O + 验证 |
| **PR11** | Video Decode + Sampling | 系统层 | **采样规则**可提炼为 Core 契约，解码在 Server |
| **PR12** | Depth Estimation | 系统层 | 模型推理，纯 Server |
| **PR13** | SfM Pipeline | 系统层 | **失败分类规则**可与 Core 同步，算法在 Server |
| **PR14** | 3DGS Training | 系统层 | Splatfacto、Checkpoint |
| **PR15** | Quality Check | **混合** | PSNR/配准评分 **公式与阈值**在 Core |
| **PR16** | Artifact Package | 系统层 | TTL、Cleanup 策略 |
| **PR17** | Job Queue | 系统层 | FIFO、超时、恢复，Server |
| **PR18** | iOS Delivery | 系统层 | 轮询、Range 下载、完整性 |
| **PR19** | Local Library | 系统层 | 索引、存储、事务 |
| **PR20** | iOS Viewer | 系统层 | Metal、手势、SafeLoader |
| **PR21** | Evidence Mode | 系统层 | S0–S4 可视化、PIZ、置信度 overlay |
| **PR22** | Cancel Strategy | 系统层 | 取消流程、清理 |
| **PR23** | Failure Strategy | **混合** | 失败分类、用户消息，**分类规则**可 Core |
| **PR24** | E2E Testing | 系统层 | 基准、回归、压力 |
| **PR25** | Performance Monitor | 系统层 | GPU、OOM、健康检查 |
| **PR26** | Audit Trail | 系统层 | 日志、哈希链、签名 |
| **PR27** | Honesty Rules | **核心** | EvidenceChain、SelfProof、确定性策略 |
| **PR28** | Release Candidate | 文档 | 限制、假设、信任边界、失败手册 |

---

## 3. 需迁入核心层或与核心对齐的逻辑（谨慎）

### 3.1 不应从系统层迁入核心层（保持系统层）

以下为**系统层职责**，按 CURSOR_MEGA_PROMPT 不应迁入 C++ Core：
- BlurDetector、ExposureAnalyzer、TextureAnalyzer 的**像素计算实现**（卷积、特征提取）— 应留在平台
- Capture Recording、Chunked Upload、Job Queue、Delivery、Viewer — 均为 I/O / 平台
- Server 端视频解码、深度、SfM、训练 — 均为 Server 流水线

### 3.2 可提炼为 Core 契约 / 常量（非迁移实现）

| 来源 | 内容 | 操作 |
|------|------|------|
| PR5 | LAPLACIAN_THRESHOLD、MIN_FEATURES、LOW_LIGHT_BRIGHTNESS | 已在 QualityThresholds / QualityPreCheckConstants，**保持** |
| PR11 | 采样规则（KEYFRAME_ANGLE、MOTION_THRESHOLD_HIGH/LOW） | 新建 `SamplingConstants.swift` 或补充 `SamplingConstants`，Server 与 Core 共用契约 |
| PR13 | SfM 失败分类（REGISTRATION_MIN、SPARSE_POINTS_MIN 等） | 与 QualityThresholds、HardGatesV13 对齐，确保 Swift↔Python 一致 |
| PR15 | PSNR_MIN、QUALITY_REJECT、QUALITY_LOW | 已在 QualityThresholds，**保持** |
| PR23 | 15 种失败类型定义 | 与 Core/Jobs/FailureReason 对齐，用户消息留在 App |

### 3.3 当前 BlurDetector 问题（PR5）

- `BlurDetector.calculateLaplacianVariance` 为**占位实现**：直接返回 `QualityThresholds.laplacianBlurThreshold`，未做真实 Laplacian 计算
- **建议**：实现真实 Laplacian 方差计算，或将其移动到平台层（如 Sources/PR5Capture），由平台提供 `BlurResult` 给 Core

---

## 4. 算法、数值与防护可优化点

### 4.1 已集中在 Core 的常量（无需迁移）

- `CapacityLimitConstants`：SOFT_LIMIT=5000、HARD_LIMIT=8000、EEB_* 等
- `QualityThresholds`：sfmRegistrationMinRatio、psnrMin8BitDb、laplacianBlurThreshold 等
- `EvidenceConstants`、`HardGatesV13`、`PIZThresholds`

### 4.2 可优化防护

| 模块 | 现状 | 建议 |
|------|------|------|
| DSMassFusion | 39 处数值使用 | 核查是否全部引用 SSOT 常量，消除内联魔数 |
| EvidenceStateMachine | 内联 0.75、coverage 阈值 | 引用 EvidenceConstants.s5MinSoftEvidence、ScanGuidanceConstants |
| PIZDetector | 14 处数值 | 确保引用 PIZThresholds、PIZConstants |
| TSDFConstants | 103 处 | 已集中，继续用 TSDF 专用常量 |

### 4.3 数值稳定性

- `PRMath/StableLogistic`、`QuantizerQ01` 已为 C++ 移植准备（V2.5 #0）
- `SafeRatio`、`MathSafetyConstants` 已存在，建议在热路径统一使用

---

## 5. PR 规格与当前代码的 drift（来自 DRIFT_REGISTRY）

| 常量 | PR 规格 | 当前 SSOT | 分类 | 处理 |
|------|---------|-----------|------|------|
| maxFrames | 2000 | 5000 | RELAXED | 已在 DRIFT_REGISTRY，保持 5000 |
| sfmRegistrationMinRatio | 0.60 | 0.75 | STRICTER | 保持 |
| psnrMinDb | 20.0 | 28.0 (psnrMin8BitDb) | STRICTER | 保持 |
| laplacianBlurThreshold | 100 | 双源 | — | 见下方说明 |

**Blur 阈值双源 → 已统一（2026-02-11）**：
- 新增 `CoreBlurThresholds.swift` 作为 SSOT：
  - `frameRejection = 200`：帧级拒收，不送入 SfM
  - `guidanceHaptic = 120`：引导/触觉，早于拒收触发
- `FrameQualityConstants`、`QualityThresholds.laplacianBlurThreshold`、`ScanGuidanceConstants.hapticBlurThreshold` 均引用上述两常量

---

## 6. 28 PR 执行建议

### 6.1 可直接继续执行的 PR（无结构变更）

- PR2、PR3、PR4、PR7、PR9、PR10、PR16、PR17、PR18、PR19、PR20、PR21、PR22、PR24、PR25、PR26、PR28

### 6.2 需小幅调整后执行

| PR | 调整 |
|----|------|
| **PR1** | 核对 `grep` 魔数检查范围；确认 `MAX_FRAMES=5000` 等与 DRIFT_REGISTRY 一致；版本号与 SSOT 文档同步 |
| **PR5** | 实现真实 Laplacian 计算或迁到平台；统一 laplacianBlurThreshold 与 DRIFT_REGISTRY (D009) |
| **PR6** | 确认 S0–S4、Coverage、PIZ 与 CURSOR_MEGA_PROMPT 移植清单一致 |
| **PR8** | Manifest、Hash、DeviceInfo 保持纯逻辑，便于未来迁入 C++ Core |
| **PR11** | 新建 `SamplingConstants`（或扩展已有）定义采样规则；Server 采样逻辑与 Core 契约对齐 |
| **PR13** | SfM 失败分类与 QualityThresholds、HardGatesV13 保持一致 |
| **PR15** | 质量公式与 QualityThresholds 对齐，Gate 行为与 Core 契约一致 |
| **PR23** | FailureReason 与 FailureClassifier 统一；用户消息保留在 App |
| **PR27** | EvidenceChain、SelfProof 与 HONESTY_POLICY 文档一致 |

### 6.3 PR11 当前状态

- Server 中**尚无** `decode/`、`adaptive_sampler`、`keyframe_protector` 等模块
- PR11 为**待实现**，建议：先建立 Core/Constants 或契约文档中的采样规则，再实现 Server 端采样逻辑

---

## 7. 结论

1. **核心层边界**：按 CURSOR_MEGA_PROMPT 严格划分，**不将系统层职责迁入核心**。
2. **可迁入核心**：仅限纯逻辑（Evidence、TSDF、Merkle、质量决策、常量、确定性 JSON）。像素分析、I/O、网络、UI 均保留在系统层。
3. **28 PR**：多数可继续执行；PR1、PR5、PR6、PR8、PR11、PR13、PR15、PR23、PR27 需按上表做小幅对齐或补充。
4. **优化**：DSMassFusion、EvidenceStateMachine、PIZDetector 等处逐步消除内联魔数，统一引用 SSOT 常量。
5. **BlurDetector**：需实现真实 Laplacian 或迁出 Core，避免占位实现影响质量判断。
