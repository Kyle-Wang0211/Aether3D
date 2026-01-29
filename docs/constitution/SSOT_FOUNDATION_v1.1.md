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

**状态：** APPROVED FOR PR#1 v1.1  
**变更策略：** Append-only；现有规则 immutable  
**受众：** 编译器级工程师、平台架构师、审计审查员
