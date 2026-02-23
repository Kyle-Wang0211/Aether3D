# SSOT Foundation v1.1

**Document Version:** 1.1  
**Created Date:** 2026-01-22  
**Status:** IMMUTABLE（一旦合并，只能追加，不能修改已有规则）  
**Scope:** Asset Trust Engine 全平台

---

## 概述

本文档是 PR#1 SSOT Foundation 的核心文档，整合所有 v1.0 和 v1.1 内容。本 PR 建立平台级"宪法"文档和 Swift 类型定义，为后续所有 PR 提供不可变的基础契约。

**核心原则**：凡是"全局契约/数学安全/跨平台一致性/审计不可变"的，进 PR#1。

PR#1 是"平台宪法常量与契约"，不是阈值仓库，不是算法实现。

---

## 不可谈判的设计约束

1. **闭集原则**：所有 enum/常量必须是闭集，unknown fields 视为非法
2. **字节级可审计**：所有 hash 输入必须有确定的字节序列
3. **跨平台一致**：iOS/Android/HarmonyOS 必须产出相同结果
4. **不可删除**：任何记录只能 invalidate，不能 delete

---

## A1-A5 Final Decisions（IMMUTABLE 方法论和常量）

### A1: 混合方法论（Layer 0-3 严格分层）

**决策摘要**：系统明确采用混合方法论，结合多种行业方法的优势，但仅通过严格分层实现。不允许任何单层混合不兼容的假设。

**采用的混合架构（最终）**：

系统不选择 A/B/C 之一，而是为每个分配专用层，单向依赖：

- **Layer 0 — Continuous Reality (B)**
  - 浮点几何
  - 原始相机位姿
  - 连续深度/颜色
  - **永远不参与身份哈希**

- **Layer 1 — Patch Evidence Layer (B + C)**
  - patchId（epoch-local，高精度）
  - 详细覆盖率/证据/L3 评估
  - 仅在单个 mesh epoch 内有效

- **Layer 2 — Geometry Identity Layer (A + C)**
  - geomId（跨 epoch 稳定）
  - 用于继承和资产连续性

- **Layer 3 — Asset Trust Layer (A)**
  - S-state, AssetGrade
  - 定价/授权/发布

**非协商约束**：
- 身份永远不依赖连续值
- 下层可能影响权重或分数，但永远不重新定义身份
- 依赖方向严格 bottom → top
- 任何反向依赖被禁止

### A2: 字节序和字符串编码（永久确定性规则）

**最终决策（锁定）**：

所有身份相关的哈希必须遵循这些规则永久有效。

**整数编码**：
- 所有整数编码为 Big-Endian
- 适用于所有平台（iOS / Android / Server）
- 理由：明确、语言无关、广泛用于网络和加密系统

**字符串编码**：
- UTF-8 only
- 长度前缀编码
- **不允许 NUL 终止符**

**规范字符串格式**：
```
uint32_be byteLength
UTF-8 encoded bytes
```

- byteLength 计数 bytes，不是 characters
- 嵌入 NUL bytes 被禁止
- 空字符串编码为 length = 0

**Hash Impact Warning（显式）**：

任何未来对以下内容的变更：
- 字节序
- 字符串终止
- 长度字段大小

将不可逆地改变：
- patchId
- geomId
- meshEpochSalt

因此：
- 这些规则是 IMMUTABLE
- 任何偏差需要新的 major foundation version

### A3: 坐标量化精度（双精度策略）

**最终决策**：

采用选项 A，明确分离职责。

| 标识符 | 精度 | 值 | 目的 |
|--------|------|-----|------|
| geomId | 粗 | 1 mm (1e-3 m) | 跨 epoch 稳定 |
| patchId | 细 | 0.1 mm (1e-4 m) | epoch 内区分 |

**量化算法（锁定）**：
```
quantized = round(value / precision)
```

- 舍入模式在 A4 中定义
- 结果是有符号 int64
- 浮点值永远不能直接哈希

**明确禁止**：
- 对两种 ID 使用相同精度
- 自适应或动态精度
- 从 mesh 密度推断精度
- 连续值泄漏到身份中

### A4: 舍入模式（确定性和跨语言安全）

**最终决策**：

ROUND_HALF_AWAY_FROM_ZERO 是强制性的。

**定义**：

对于值 x：
- 如果 |fractional part| == 0.5，向 x 的符号方向舍入
- 否则，舍入到最近的整数

**为什么选择这个**：

HALF_EVEN（银行家舍入）被明确拒绝，因为：
- 它因标准库而异
- 它导致跨平台静默分歧
- 它破坏字节级确定性

**规则状态**：
- IMMUTABLE
- 适用于所有用于哈希的量化
- 如果平台默认不同，必须手动实现

### A5: meshEpochSalt — 输入闭集（最终，锁定）

**核心原则**：

meshEpochSalt 表示因果内容边界，不是执行指纹。

只有因果决定网格几何的输入才被允许。

**最终包含的输入**：
```
meshEpochSaltInputs = {
  rawVideoDigest,
  cameraIntrinsicsDigest,
  reconstructionParamsDigest,
  pipelineVersion
}
```

**明确排除（禁止）**：
```
forbiddenInputs = {
  deviceModelClass,
  timestampRange
}
```

原因：
- 导致无意义的身份分叉
- 破坏跨设备继承
- 引入隐私风险
- 不改变几何语义

**审计用（不在 Salt 中）**：
```
auditOnlyInputs = {
  frameDigestMerkleRoot
}
```

- 用于：争议解决、强溯源
- 永远不参与身份推导

**不变量保证**：
- 相同输入 → 相同 meshEpochSalt
- 不同几何语义 → 不同 salt
- 执行环境差异不得影响 salt

---

## B1-B3 Final Additions（强制要求）

### B1: User Explanation Catalog（强制要求）

**决策（最终）**：User Explanation Catalog **必须在 v1.1 中交付**。这是非可选的。

**理由（不可协商）**：
- 输出分数而不解释的系统会导致：用户困惑、不信任、不可恢复的 UX 债务
- 在算法存在后添加解释会导致：语义不匹配、模糊文案、跨版本不可逆的不一致性

因此，解释词汇必须在算法之前，而不是之后。

**规范**：

机器可读的解释目录必须引入：
- `docs/constitution/constants/USER_EXPLANATION_CATALOG.json`

**结构（闭集）**：

每个条目必须遵循此结构：
```json
{
  "code": "STRUCTURAL_OCCLUSION_CONFIRMED",
  "category": "coverage",
  "severity": "blocking",
  "shortLabel": "Structural occlusion detected",
  "userExplanation": "Some parts of the object were permanently blocked from view during scanning.",
  "technicalExplanation": "Confirmed structural occlusion prevents reliable surface reconstruction in affected regions.",
  "appliesTo": ["coverage", "PIZ", "S_state"],
  "actionable": true,
  "suggestedActions": [
    "Change your scanning angle",
    "Move around the object to expose hidden areas"
  ]
}
```

**硬规则**：
- code 是稳定的闭集枚举键
- 解释是：人类可读、确定性、不在运行时由 AI 生成
- 此目录：必须在 PR#6 之前存在，永远不能推断或自动生成

**治理**：
- Append-only
- 无重命名
- 无语义漂移
- 任何变更需要：RFC、版本升级、迁移说明

### B2: Guaranteed Interpretability Fields（强制要求）

**决策（最终）**：可解释性字段必须是 v1.1 中保证输出契约的一部分。

仅分数不是可接受的输出。

**新增保证字段**：

这些字段必须添加到保证输出字段契约中：

1. **primaryReasonCode**
   - `primaryReasonCode: String`
   - 必须引用 USER_EXPLANATION_CATALOG.json 中定义的 code
   - 表示影响资产状态的单一主导原因
   - 规则：exactly one，never null，deterministic

2. **nextBestActionHints**
   - `nextBestActionHints: [String]`
   - 零个或多个 hint codes
   - 每个条目必须：存在于解释目录中、是 actionable、是 user-safe
   - 顺序有意义且稳定

**契约保证**：
- 这些字段是 schema-guaranteed，不是可选的
- 它们不暗示：如何计算 reason、如何选择 hints
- 它们只定义：下游系统和 UI 可以依赖什么

**明确非目标**：
- 无评分逻辑
- 无优先级启发式
- 无本地化
- 无 UI 文案决策

本 PR 定义语义槽，不是行为。

### B3: Append-Only Enum Order Freezing（强制要求）

**决策（最终）**：所有闭集和 append-only enums 必须在 v1.1 中冻结其 case 顺序。此规则是强制性的。

**解决的问题**：

没有顺序冻结：
- case 重排序静默破坏：日志、序列化差异、审计、历史比较
- 损害是微妙的、延迟的、不可逆的

这是长期平台中的已知失败模式。

**规范**：

对于每个 append-only enum（包括但不限于）：
- EdgeCaseType
- RiskFlag
- PrimaryReasonCode
- ActionHintCode

必须强制执行以下内容：

1. **冻结顺序 Hash**
   - 每个 enum 必须定义规范 case 顺序 hash：`static let frozenCaseOrderHash: String`
   - 计算自：case names、按声明顺序、用 `\n` 连接、SHA-256 哈希
   - 存储为字符串字面量

2. **CI 强制执行**
   - 必须存在测试：从 enum 声明重新计算 hash、与 frozenCaseOrderHash 比较、如果顺序改变/case 删除/case 重命名则失败 CI

3. **允许的变更模式**
   - 唯一允许的变更：在末尾追加新 cases
   - 其他任何内容都是破坏性变更，必须被拒绝

**序列化规则**：
- 不信任 enum raw values
- 稳定性由以下保证：显式 case 顺序、冻结 hash、append-only 纪律

---

## CE: Color Encoding Invariant（Lab Reference System）

**最终决策**：

Lab 颜色空间参考系统永久固定为：
- Illuminant / White Point: D65
- 转换路径：sRGB → XYZ (D65) → Lab
- 转换矩阵和常量：明确硬编码的 SSOT 常量
- 系统 / OS 颜色 API：严格禁止

此规则在合并后是 IMMUTABLE。

**CE 不变量摘要（不可协商）**：
- D65 永久固定
- 转换矩阵是 SSOT 常量
- 无运行时切换
- 任何未来偏差需要：
  - 新 schemaVersion
  - 新资产类别
  - 不继承旧 L3 证据

这是为长期资产信任服务的故意刚性。

---

## CL2: Cross-Platform Numerical Consistency Tolerances

**最终决策**：

以下容差被接受并锁定：

| 指标类型 | 容差 | 类型 |
|----------|------|------|
| Coverage / Ratio 值 | 相对误差 ≤ 1e-4 | Relative |
| Lab 颜色分量 | 绝对误差 ≤ 1e-3 | Absolute |

这些容差适用于跨平台等价性检查，不是算法质量。

**CL2 约束**：
- 这些容差适用于跨平台等价性检查，不是算法质量阈值
- 这是跨平台等价性契约，不是质量标准
- 保证"相同输入 ≈ 相同输出"

---

## 最终不变量（A1–A5）

- 身份是确定性的、分层的、单向的
- Hash 输入是完全闭集
- 精度选择是显式的和合理的
- 不信任平台默认行为
- 未来演进通过添加层发生，而不是改变基础

---

---

## A2.1: PolicyHashCanonicalBytesLayout_v1（PR1 v2.4 Addendum）

**表：PolicyHashCanonicalBytesLayout_v1**（用于 CapacityTier policyHash 输入）

| 字段顺序 | 字段名                         | 类型       | 编码规则       | 字节数                 | 说明                                       |
| ---- | --------------------------- | -------- | ---------- | ------------------- | ---------------------------------------- |
| 1    | tierId                      | UInt16   | Big-Endian | 2                   | 层级标识符                                    |
| 2    | schemaVersion               | UInt16   | Big-Endian | 2                   | 结构版本                                     |
| 3    | profileId                   | UInt8    | 直接         | 1                   | 配置文件ID                                   |
| 4    | policyEpoch                 | UInt32   | Big-Endian | 4                   | 策略纪元（单调）                                 |
| 5    | policyFlags                 | UInt32   | Big-Endian | 4                   | 功能开关位集                                   |
| 6    | softLimitPatchCount         | Int32    | Big-Endian | 4                   | 软限制补丁数                                   |
| 7    | hardLimitPatchCount         | Int32    | Big-Endian | 4                   | 硬限制补丁数                                   |
| 8    | eebBaseBudget               | Int64    | Big-Endian | 8                   | EEB基础预算（BudgetUnit）                      |
| 9    | softBudgetThreshold         | Int64    | Big-Endian | 8                   | 软预算阈值（BudgetUnit）                        |
| 10   | hardBudgetThreshold         | Int64    | Big-Endian | 8                   | 硬预算阈值（BudgetUnit）                        |
| 11   | budgetEpsilon               | Int64    | Big-Endian | 8                   | 预算精度（BudgetUnit）                         |
| 12   | maxSessionExtensions        | UInt8    | 直接         | 1                   | 最大会话扩展数                                  |
| 13   | extensionBudgetRatio        | Int64    | Big-Endian | 8                   | 扩展预算比率（RatioUnit）                        |
| 14   | cooldownNs                  | UInt64   | Big-Endian | 8                   | 冷却期（纳秒）                                  |
| 15   | throttleWindowNs            | UInt64   | Big-Endian | 8                   | 节流窗口（纳秒）                                 |
| 16   | throttleMaxAttempts         | UInt8    | 直接         | 1                   | 节流最大尝试数                                  |
| 17   | throttleBurstTokens         | UInt8    | 直接         | 1                   | 节流突发令牌数                                  |
| 18   | throttleRefillRateNs        | UInt64   | Big-Endian | 8                   | 节流补充速率（纳秒）                               |
| 19   | retryStormFuseThreshold     | UInt32   | Big-Endian | 4                   | 重试风暴熔断阈值                                 |
| 20   | costWindowK                 | UInt8    | 直接         | 1                   | 成本窗口大小                                   |
| 21   | minValueScore               | Int64    | Big-Endian | 8                   | 最小价值分数（BudgetUnit）                       |
| 22   | shedRateAtSaturated         | Int64    | Big-Endian | 8                   | 饱和时脱落率（RatioUnit）                        |
| 23   | shedRateAtTerminal          | Int64    | Big-Endian | 8                   | 终端时脱落率（RatioUnit）                        |
| 24   | deterministicSelectionSalt  | UInt64   | Big-Endian | 8                   | 确定性选择盐值                                  |
| 25   | hashAlgoId                  | UInt8    | 直接         | 1                   | 哈希算法ID（封闭世界）                             |
| 26   | eligibilityWindowK          | UInt8    | 直接         | 1                   | 资格窗口大小                                   |
| 27   | minGainThreshold            | Int64    | Big-Endian | 8                   | 最小增益阈值（BudgetUnit）                       |
| 28   | minDiversity                | Int64    | Big-Endian | 8                   | 最小多样性（RatioUnit）                         |
| 29   | rejectDominanceMaxShare     | Int64    | Big-Endian | 8                   | 拒绝主导最大份额（RatioUnit）                      |
| 30   | flowBucketCount             | UInt8    | 直接         | 1                   | 流桶数量（固定，例如4）                             |
| 31   | flowWeights                 | [UInt16] | Big-Endian | flowBucketCount × 2 | 流权重数组（不编码长度，精确 flowBucketCount 个 UInt16） |
| 32   | maxPerFlowExtensionsPerFlow | UInt16   | Big-Endian | 2                   | 每流最大扩展数                                  |
| 33   | limiterTickNs               | UInt64   | Big-Endian | 8                   | 限制器刻度纳秒（包含在policyHash中，影响行为）             |
| 34   | valueScoreWeightA           | Int64    | Big-Endian | 8                   | ValueScore权重A（BudgetUnit，包含在policyHash中） |
| 35   | valueScoreWeightB           | Int64    | Big-Endian | 8                   | ValueScore权重B（BudgetUnit，包含在policyHash中） |
| 36   | valueScoreWeightC           | Int64    | Big-Endian | 8                   | ValueScore权重C（BudgetUnit，包含在policyHash中） |
| 37   | valueScoreWeightD           | Int64    | Big-Endian | 8                   | ValueScore权重D（BudgetUnit，包含在policyHash中） |
| 38   | valueScoreMax               | Int64    | Big-Endian | 8                   | ValueScore最大值（BudgetUnit，包含在policyHash中） |

**关键规则**：

- **policyHash 字段本身不包含在用于计算 policyHash 的字节中**（避免递归）
- flowWeights：**不编码长度**，编码恰好 flowBucketCount 个 UInt16（大端序）
- 如果 flowWeights 长度与 flowBucketCount 不匹配 => 失败关闭
- 所有整数固定宽度大端序
- 无字符串、无 JSON、无变长编码（除非明确定义）

**预期字节长度公式**：

```
fixedFieldsLength = 2 + 2 + 1 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 1 + 8 + 8 + 8 + 1 + 1 + 8 + 4 + 1 + 8 + 8 + 8 + 8 + 8 + 1 + 1 + 8 + 8 + 8 + 1 + 2 + 8 + 8 + 8 + 8 + 8 + 8 = 210
flowWeightsLength = flowBucketCount * 2
expectedLength = fixedFieldsLength + flowWeightsLength
```

---

## A2.2: CandidateStableIdOpaqueBytesLayout_v1（PR1 v2.4 Addendum）

**表：CandidateStableIdOpaqueBytesLayout_v1**（用于 candidateStableId 推导）

| 字段顺序 | 字段名                       | 类型       | 编码规则       | 字节数 | 说明                                                 |
| ---- | ------------------------- | -------- | ---------- | --- | -------------------------------------------------- |
| 1    | layoutVersion             | UInt8    | 直接         | 1   | 布局版本（固定为1）                                         |
| 2    | sessionStableIdSourceUuid | UUID     | RFC4122网络序 | 16  | 捕获会话UUID字节，不可变                                     |
| 3    | candidateId               | UUID     | RFC4122网络序 | 16  | 候选UUID字节，不可变                                       |
| 4    | policyHash                | UInt64   | Big-Endian | 8   | 绑定稳定ID到策略，防止跨策略冲突                                  |
| 5    | candidateKind             | UInt8    | 直接         | 1   | 封闭世界枚举（0=patchCandidate,1=frameCandidate），如未使用则编码0 |
| 6    | reserved                  | UInt8[3] | 直接         | 3   | 固定填充，必须为{0,0,0}                                    |

**明确排除**：

- ❌ 无时间戳
- ❌ 无 patchCount
- ❌ 无 eebRemaining
- ❌ 无 buildMode
- ❌ 无 degradationLevel
- ❌ 无可选字段

**稳定ID推导规则**：

- `sessionStableId = blake3_64(sessionUuidBytes || policyHashBytes)`
- `candidateStableId = blake3_64(CandidateStableIdOpaqueBytesLayout_v1 bytes)`

**变更规则**：

- 任何未来变更 => 递增 layoutVersion
- 必须提升 schemaVersion 或 policyEpoch

**预期字节长度**：

```
expectedLength = 1 + 16 + 16 + 8 + 1 + 3 = 45 bytes
```

---

## A2.3: ExtensionRequestIdempotencySnapshotBytesLayout_v1（PR1 v2.4 Addendum）

**表：ExtensionRequestIdempotencySnapshotBytesLayout_v1**（用于 ExtensionResultSnapshot 幂等性）

| 字段顺序 | 字段名                | 类型       | 编码规则       | 字节数 | 说明                                           |
| ---- | ------------------ | -------- | ---------- | --- | -------------------------------------------- |
| 1    | layoutVersion      | UInt8    | 直接         | 1   | 布局版本（固定为1）                                   |
| 2    | extensionRequestId | UUID     | RFC4122网络序 | 16  | 扩展请求ID                                       |
| 3    | trigger            | UInt8    | 直接         | 1   | 触发枚举值                                        |
| 4    | tierId             | UInt16   | Big-Endian | 2   | 层级ID                                         |
| 5    | schemaVersion      | UInt16   | Big-Endian | 2   | 结构版本                                         |
| 6    | policyHash         | UInt64   | Big-Endian | 8   | 策略哈希                                         |
| 7    | extensionCount     | UInt8    | 直接         | 1   | 扩展计数                                         |
| 8    | resultTag          | UInt8    | 直接         | 1   | 结果标签（0=extended,1=denied,2=alreadyProcessed） |
| 9    | denialReasonTag    | UInt8    | 直接         | 1   | 拒绝原因存在标签（0=absent,1=present）                 |
| 10   | denialReason       | UInt8    | 直接         | 0或1 | 拒绝原因（仅当denialReasonTag==1时存在）                |
| 11   | eebCeiling         | Int64    | Big-Endian | 8   | EEB上限（BudgetUnit）                            |
| 12   | eebAdded           | Int64    | Big-Endian | 8   | EEB添加量（BudgetUnit）                           |
| 13   | newEebRemaining    | Int64    | Big-Endian | 8   | 新EEB剩余（BudgetUnit，仅当extended时有意义；否则编码0）      |
| 14   | reserved           | UInt8[4] | 直接         | 4   | 固定填充，必须为{0,0,0,0}                            |

**明确排除**：

- ❌ 无墙钟时间
- ❌ 无处理时间
- ❌ 字节在重放下稳定

**预期字节长度公式**：

```
baseLength = 1 + 16 + 1 + 2 + 2 + 8 + 1 + 1 + 1 + 8 + 8 + 8 + 4 = 61
denialReasonLength = (denialReasonTag == 1) ? 1 : 0
expectedLength = baseLength + denialReasonLength
```

---

## A2.4: DecisionHashInputBytesLayout_v1（PR1 v2.4 Addendum）

**表：DecisionHashInputBytesLayout_v1**（用于 CapacityMetrics decisionHash 输入）

| 字段顺序 | 字段名                      | 类型       | 编码规则       | 字节数                 | 说明                                                                 |
| ---- | ------------------------ | -------- | ---------- | ------------------- | ------------------------------------------------------------------ |
| 1    | layoutVersion            | UInt8    | 直接         | 1                   | 布局版本（固定为1）                                                         |
| 2    | decisionSchemaVersion    | UInt16   | Big-Endian | 2                   | 决策模式区分符（固定为0x0001用于v1，这不是全局schemaVersion）                        |
| 3    | policyHash               | UInt64   | Big-Endian | 8                   | 策略哈希                                                               |
| 4    | sessionStableId          | UInt64   | Big-Endian | 8                   | 会话稳定ID（blake3_64）                                                  |
| 5    | candidateStableId        | UInt64   | Big-Endian | 8                   | 候选稳定ID（blake3_64）                                                  |
| 6    | classification           | UInt8    | 直接         | 1                   | 分类枚举值                                                              |
| 7    | rejectReasonTag          | UInt8    | 直接         | 1                   | 拒绝原因存在标签（0=absent,1=present）                                       |
| 8    | rejectReason             | UInt8    | 直接         | 0或1                 | 拒绝原因（仅当rejectReasonTag==1时存在）                                      |
| 9    | shedDecisionTag          | UInt8    | 直接         | 1                   | 脱落决策存在标签（0=absent,1=present）                                       |
| 10   | shedDecision             | UInt8    | 直接         | 0或1                 | 脱落决策（仅当shedDecisionTag==1时存在）                                      |
| 11   | shedReasonTag            | UInt8    | 直接         | 1                   | 脱落原因存在标签（0=absent,1=present）                                       |
| 12   | shedReason               | UInt8    | 直接         | 0或1                 | 脱落原因（仅当shedReasonTag==1时存在）                                        |
| 13   | degradationLevel         | UInt8    | 直接         | 1                   | 降级级别枚举值                                                            |
| 14   | degradationReasonCodeTag | UInt8    | 直接         | 1                   | 降级原因代码存在标签（0=absent,1=present，v2.4+当degradationLevel!=NORMAL时强制为1） |
| 15   | degradationReasonCode    | UInt8    | 直接         | 0或1                 | 降级原因代码（仅当degradationReasonCodeTag==1时存在）                           |
| 16   | valueScore               | Int64    | Big-Endian | 8                   | 价值分数（BudgetUnit）                                                   |
| 17   | flowBucketCount          | UInt8    | 直接         | 1                   | 流桶数量（自描述，编码在 perFlowCounters 之前）                               |
| 18   | perFlowCounters          | [UInt16] | Big-Endian | flowBucketCount × 2 | 每流计数器数组（不编码长度，精确flowBucketCount个UInt16）                            |
| 19   | throttleStatsTag         | UInt8    | 直接         | 1                   | 节流统计存在标签（0=absent,1=present）                                       |
| 20   | windowStartTick          | UInt64   | Big-Endian | 0或8                 | 窗口起始刻度（仅当throttleStatsTag==1时存在）                                   |
| 21   | windowDurationTicks     | UInt32   | Big-Endian | 0或4                 | 窗口持续时间（刻度数，仅当throttleStatsTag==1时存在）                               |
| 22   | attemptsInWindow        | UInt32   | Big-Endian | 0或4                 | 窗口内尝试数（仅当throttleStatsTag==1时存在）                                   |

**预期字节长度公式（v2.4+ 强制执行）**：

```
baseLength = 1 + 2 + 8 + 8 + 8 + 1 + 1 + 1 + 1 + 1 + 1 + 8 + 1 + 1 = 48
// Note: shedDecision 和 shedReason 在 absent 时不写入 payload 字节（presenceTag 规则）
rejectReasonLength = (rejectReasonTag == 1) ? 1 : 0
degradationReasonCodeLength = (degradationReasonCodeTag == 1) ? 1 : 0
perFlowCountersLength = flowBucketCount * 2
throttleStatsLength = (throttleStatsTag == 1) ? (8 + 4 + 4) : 0

expectedLength = baseLength + rejectReasonLength + degradationReasonCodeLength + 
                perFlowCountersLength + throttleStatsLength
```

**关键规则**：

- **decisionSchemaVersion**: 固定值 0x0001 用于 v1。这不是全局 schemaVersion；它是哈希输入模式区分符，用于未来证明。
- **layoutVersion 和 decisionSchemaVersion 验证**: v2.4+ 必须验证 layoutVersion==1 AND decisionSchemaVersion==0x0001，否则失败关闭。
- **flowBucketCount 自描述**: 编码在 perFlowCounters 之前，用于确定数组大小。
- **长度不变量**: v2.4+ 必须验证实际长度匹配预期长度公式，不匹配 => FailClosedError.canonicalLengthMismatch。
- **重放稳定性**: 输入字段必须仅从确定性事件输入派生，禁止墙钟、Date()、进程运行时间、随机、指针地址、线程时序。

---

## A2.5: policyEpoch 治理规则（PR1 v2.4 Addendum）

**schemaVersion 变更规则**：

- schemaVersion 仅在**结构布局变更**时更改
- 例如：添加/删除字段、改变字段类型、改变字段顺序、改变字段在规范字节中的位置

**policyEpoch 变更规则**：

- policyEpoch 仅在**数值/阈值表变更**时递增
- 必须按 tierId **单调**（同一 tierId 的 policyEpoch 只能递增）
- 禁止重用已使用的 policyEpoch 值
- 示例：如果 STANDARD tier (tierId=1) 的阈值从 8000 改为 10000，则 policyEpoch 必须递增

**解码器验证规则**（P0，v2.4+强制）：

- 如果解码器看到 policyEpoch 回退（对于声明的 v2.4+ 会话）=> **失败关闭**
- 实现：在解码 CapacityTier 时，检查 policyEpoch >= 之前见过的同一 tierId 的最大 policyEpoch
- 使用进程本地注册表（不跨应用安装持久化）
- 使用 actor PolicyEpochRegistry 实现并发安全（单写者语义）

**PolicyEpochRegistry 实现规则**：

- PolicyEpochRegistry 作为 actor（单写者语义）
- 进程本地（不跨应用安装持久化）
- 并发安全（actor 保证单写者）
- 错误映射到 FailClosedError 0x2405 (POLICY_EPOCH_ROLLBACK)

---

## A2.6: UUID RFC4122 规范字节编码规则（PR1 v2.4 Addendum）

**UUID RFC4122 网络序编码规则**：

- UUID 必须编码为 RFC4122 网络序的 16 字节
- 使用显式字段级 RFC4122 网络序（不依赖内存顺序假设）
- 在 Swift 中：从 UUID 的 uuid_t 提取字段并按 RFC4122 顺序排列：
  - time_low (4 bytes, BE)
  - time_mid (2 bytes, BE)
  - time_hi_and_version (2 bytes, BE)
  - clock_seq_hi_and_reserved (1 byte)
  - clock_seq_low (1 byte)
  - node (6 bytes)
- ❌ 禁止使用 uuidString 或任何字符串表示用于哈希/幂等性

**实现要求**：

- 实现 `uuidRFC4122Bytes(_ uuid: UUID) -> [UInt8;16]` 方法
- 使用显式字段提取和重新排列，不依赖内存布局
- 错误映射到 FailClosedError 0x2404 (UUID_CANONICALIZATION_ERROR)

---

## A2.7: 可选字段编码跨字段约束表（PR1 v2.4 Addendum）

**可选字段编码跨字段约束（v2.4+ 强制）**：

| 约束                       | 规则                                                                                                    | 违规处理       |
| ------------------------ | ----------------------------------------------------------------------------------------------------- | ---------- |
| rejectReasonTag          | tag==0 => rejectReason 缺失；tag==1 => rejectReason 存在                                                   | v2.4+ 失败关闭 |
| shedDecisionTag          | tag==0 => shedDecision 缺失（不写入 payload 字节）；tag==1 => shedDecision 存在                               | v2.4+ 失败关闭 |
| shedReasonTag            | tag==0 => shedReason 缺失（不写入 payload 字节）；tag==1 => shedReason 存在且 shedDecision 存在且为 true               | v2.4+ 失败关闭 |
| throttleStatsTag         | tag==0 => 三个字段缺失；tag==1 => 三个字段全部存在                                                                   | v2.4+ 失败关闭 |
| degradationReasonCodeTag | degradationLevel==NORMAL => tag==0 且 reasonCode 缺失；degradationLevel!=NORMAL => tag==1 且 reasonCode 存在 | v2.4+ 失败关闭 |

**PresenceTag 编码规则**：

- 任何可为 nil 的字段必须编码为：`presenceTag: UInt8` (0 = absent, 1 = present)
- 如果 tag==0（absent），**不写入 payload 字节**
- 如果 tag==1（present），写入 payload 字节
- ❌ 禁止依赖 Codable 可选编码
- ❌ 禁止在 absent 时写入零值或占位符字节

**违规处理**：

- 所有违规 => FailClosedError.internalContractViolation(code: FailClosedErrorCode.presenceTagViolation.rawValue, context: ...)
- v2.4+ 强制执行，v2.3 及之前允许放宽约束

---

## A2.8: AdmissionDecisionBytesLayout_v1（PR1 v2.4 Addendum）

**表：AdmissionDecisionBytesLayout_v1**（用于 AdmissionController 输出记录）

| 字段顺序 | 字段名                | 类型       | 编码规则       | 字节数 | 说明                                           |
| ---- | ------------------ | -------- | ---------- | --- | -------------------------------------------- |
| 1    | layoutVersion      | UInt8    | 直接         | 1   | 布局版本（固定为1）                                   |
| 2    | schemaVersion      | UInt16   | Big-Endian | 2   | 结构版本                                         |
| 3    | policyHash         | UInt64   | Big-Endian | 8   | 策略哈希                                         |
| 4    | sessionStableId    | UInt64   | Big-Endian | 8   | 会话稳定ID（blake3_64）                            |
| 5    | candidateStableId  | UInt64   | Big-Endian | 8   | 候选稳定ID（blake3_64）                            |
| 6    | decisionHashAlgoId | UInt8    | 直接         | 1   | 哈希算法ID（封闭世界，BLAKE3_256=1）                    |
| 7    | decisionHash       | [UInt8;32] | 直接         | 32  | DecisionHash（32字节，BLAKE3-256摘要）                |
| 8    | classification     | UInt8    | 直接         | 1   | 分类枚举值                                        |
| 9    | rejectReasonTag    | UInt8    | 直接         | 1   | 拒绝原因存在标签（0=absent,1=present）                 |
| 10   | rejectReason       | UInt8    | 直接         | 0或1 | 拒绝原因（仅当rejectReasonTag==1时存在）                |
| 11   | shedDecisionTag    | UInt8    | 直接         | 1   | 脱落决策存在标签（0=absent,1=present）                 |
| 12   | shedDecision       | UInt8    | 直接         | 0或1 | 脱落决策（仅当shedDecisionTag==1时存在）                |
| 13   | shedReasonTag      | UInt8    | 直接         | 1   | 脱落原因存在标签（0=absent,1=present）                 |
| 14   | shedReason         | UInt8    | 直接         | 0或1 | 脱落原因（仅当shedReasonTag==1时存在）                  |
| 15   | degradationLevel   | UInt8    | 直接         | 1   | 降级级别枚举值                                     |
| 16   | degradationReasonCodeTag | UInt8 | 直接 | 1   | 降级原因代码存在标签（0=absent,1=present）            |
| 17   | degradationReasonCode | UInt8 | 直接 | 0或1 | 降级原因代码（仅当degradationReasonCodeTag==1时存在）   |
| 18   | valueScore         | Int64    | Big-Endian | 8   | 价值分数（BudgetUnit）                            |
| 19   | reserved           | UInt8[4] | 直接         | 4   | 固定填充，必须为{0,0,0,0}                            |

**关键规则**：

- **AdmissionController 输出合约**：必须产生 admissionRecordBytes（规范字节）和结构化输出（现有 API）
- **decisionHashHexLower**：用于日志/审计格式化，始终小写 hex，无 "0x" 前缀，恰好 64 字符
- **PresenceTag 约束**：重用 DecisionHashInputBytesLayout_v1 相同约束规则
- **黄金固定装置**：必须比较 admissionRecordBytes hex + decisionHash hex（不仅 JSON 字段）

**预期字节长度公式**：

```
baseLength = 1 + 2 + 8 + 8 + 8 + 1 + 32 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 8 + 4 = 79
rejectReasonLength = (rejectReasonTag == 1) ? 1 : 0
shedDecisionLength = (shedDecisionTag == 1) ? 1 : 0
shedReasonLength = (shedReasonTag == 1) ? 1 : 0
degradationReasonCodeLength = (degradationReasonCodeTag == 1) ? 1 : 0

expectedLength = baseLength + rejectReasonLength + shedDecisionLength + 
                shedReasonLength + degradationReasonCodeLength
```

---

## A2.x: Hash 算法封闭世界 + BLAKE3-256 长度（PR1 v2.4 Addendum）

**HashAlgoId 封闭世界规则**：

- HashAlgoId 是 UInt8 封闭世界枚举
- BLAKE3_256 = 1（固定用于 v2.4 DecisionHash V1）
- 未知值 => 失败关闭
- 所有 policyHash、sessionStableId、candidateStableId、decisionHash 必须使用相同的底层 BLAKE3 实现（Blake3Facade）

**BLAKE3-256 输出长度**：

- decisionHash 长度 = 32 字节（完整 BLAKE3-256 摘要，不截断）
- decisionHashHex = 64 小写十六进制字符（无 "0x" 前缀）

**运行时自测**：

- 启动时或首次使用时验证已知测试向量（输入 "abc" => 预期 BLAKE3-256 摘要）
- 如果不匹配 => FailClosedError.cryptoImplementationMismatch

---

## A2.x: 规范字节长度不变量（PR1 v2.4 Addendum）

**规则**：

- 每个规范布局必须定义确定性预期字节长度公式
- 所有 canonicalBytesForX() 方法必须调用 CanonicalLayoutLengthValidator 验证长度
- **任何不匹配 => 失败关闭（v2.4+）**: FailClosedError.canonicalLengthMismatch

**适用布局**：

- PolicyHashCanonicalBytesLayout_v1
- CandidateStableIdOpaqueBytesLayout_v1
- ExtensionRequestIdempotencySnapshotBytesLayout_v1
- DecisionHashInputBytesLayout_v1

---

## A2.x: Pre-v2.4 语义（PR1 v2.4 Addendum）

**选择 A（已选择）**: schemaVersion < 0x0204 => decisionHash MUST be absent/nil and never computed

**规则**：

- v2.4 前：decisionHash 可以为 nil，不计算 decisionHash
- v2.4+：decisionHash 必须计算，长度验证强制执行，presence-tag 约束强制执行，PolicyEpochRegistry 强制执行

**测试要求**：

- 测试必须覆盖 v2.3 和 v2.4 行为差异
- v2.3：允许 decisionHash = nil，允许放宽约束
- v2.4+：强制 decisionHash != nil，强制严格验证

---

**状态：** APPROVED FOR PR#1 v1.1  
**变更策略：** Append-only；现有规则 immutable  
**受众：** 编译器级工程师、平台架构师、审计审查员
