# System Contracts

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义系统级契约，包括输入验证、输出保证字段和会话边界。

---

## CONTRACT_MESH_INPUT_001: Mesh Input Validation Contract

**契约 ID:** CONTRACT_MESH_INPUT_001  
**名称:** Mesh Input Validation Contract  
**状态:** IMMUTABLE

### 验证条件（全部必须通过）

| 条件 | 阈值 | 违反后果 |
|------|------|----------|
| 三角形数量下限 | >= 100 | REJECT |
| 三角形数量上限 | <= 500,000 | REJECT |
| 退化三角形比例 | < 1% (面积 < 1e-10 m²) | FILTER（剔除后继续） |
| 非流形边比例 | < 5% | WARNING（继续） |
| 顶点坐标范围 | 每轴 [-1000m, 1000m] | REJECT |
| 顶点 NaN/Inf | 0% | REJECT |

### 输出

```swift
meshValidationReport: {
  isValid: Bool,
  triangleCount: Int,
  degenerateCount: Int,
  nonManifoldRatio: Double,
  coordinateRange: (min: SIMD3, max: SIMD3),
  warnings: [String],
  rejectReason: MeshValidationFailureReason?  // 若 isValid=false
}
```

### CONTRACT_MESH_INPUT_001A: FailureReason Closed Set（v1.1 增强）

**契约 ID:** CONTRACT_MESH_INPUT_001A  
**状态:** IMMUTABLE

引入闭集枚举用于 meshValidationReport.rejectReason，避免自由格式字符串：

```
MeshValidationFailureReason ∈ {
  TRIANGLE_COUNT_TOO_LOW,
  TRIANGLE_COUNT_TOO_HIGH,
  NAN_OR_INF_DETECTED,
  COORDINATE_OUT_OF_RANGE,
  INPUT_CORRUPTED
}
```

**映射要求**：
- 每个 REJECT 必须：
  - 添加至少一个 edgeCasesTriggered 项
  - 映射到稳定的全局 ErrorCode（PR#1 范围）和稳定的 FailureReason token，供 PR#3 API 契约使用

---

## CONTRACT_OUTPUT_001: Guaranteed Output Fields Contract

**契约 ID:** CONTRACT_OUTPUT_001  
**名称:** Guaranteed Output Fields Contract  
**状态:** IMMUTABLE

### Guaranteed 字段（必须存在，类型固定，永不为 null）

| 字段 | 类型 | 范围 | 说明 |
|------|------|------|------|
| coverage_L2 | Double | [0, 1] | L2 覆盖率 |
| coverage_L3_strict | Double | [0, 1] | L3 严格覆盖率 |
| PIZ_score | Double | [0, 1] | 缺口评分 |
| unreliableAppearanceRatio_weighted | Double | [0, 1] | 加权不可靠外观比例 |
| S_state | Int | {0,1,2,3,4} | 状态等级 |
| warnings | [String] | - | 警告列表（可为空数组，不可为 null） |
| edgeCasesTriggered | [EdgeCaseType] | - | 触发的边界情况 |
| assetId | String | - | 资产唯一标识 |
| schemaVersion | Int | >= 1 | Schema 版本号 |
| foundationVersion | String | - | Foundation 版本（例如："1.1"） |
| contractVersion | Int | >= 1 | 契约版本号（仅在破坏性输出契约变更时递增） |

### Optional 字段（可能为 null，下游必须处理）

| 字段 | 类型 | 何时为 null |
|------|------|-------------|
| dynamicMotionScore | Double? | 检测方法不可用 |
| migrationReport | MigrationReport? | 无跨 epoch 迁移 |
| colorAnchorFrame | Int? | session 无有效锚点 |

### Deprecated Policy

- 任何字段废弃必须经过 RFC
- 废弃前必须有 2 个版本的 warning 期
- warning 期内字段仍必须输出，但标记 deprecated=true

### CONTRACT_OUTPUT_001A: Contract Metadata Fields（v1.1 增强）

**契约 ID:** CONTRACT_OUTPUT_001A  
**状态:** IMMUTABLE

除了 v1.0 schemaVersion，要求：

**保证字段（必须存在）**：
- `foundationVersion: String`（例如："SSOT_FOUNDATION_v1.1"）
- `contractVersion: Int`（>= 1；仅在破坏性输出契约变更时递增）

这防止多个模块生成输出时的静默漂移。

---

## CONTRACT_OUTPUT_002: Guaranteed Interpretability Fields（B2）

**契约 ID:** CONTRACT_OUTPUT_002  
**状态:** IMMUTABLE

这些字段是 schema-guaranteed，不是可选的。

### 字段定义

1. **primaryReasonCode**
   - `primaryReasonCode: PrimaryReasonCode`
   - 必须引用 USER_EXPLANATION_CATALOG.json 中的 code
   - 规则：exactly one，never null，deterministic
   - 表示影响资产状态的单一主导原因

2. **primaryReasonConfidence**
   - `primaryReasonConfidence: {unknown, likely, confirmed}`
   - 显式区分不确定性

3. **nextBestActionHints**
   - `nextBestActionHints: [ActionHintCode]`
   - 零个或多个 hint codes
   - 每个条目必须：存在于解释目录中、是 actionable、是 user-safe
   - 顺序有意义且稳定

4. **computePhase**
   - `computePhase: {realtime_estimate, delayed_refinement, finalized}`
   - 定义计算阶段

5. **progressConfidence**
   - `progressConfidence: Double ∈ [0,1]`
   - 告诉 UI：当前进度有多可信

**明确非目标**：
- 无评分逻辑
- 无优先级启发式
- 无本地化
- 无 UI 文案决策

这些字段定义下游系统和 UI 可以依赖什么，不定义如何计算 reason 或如何选择 hints。

---

## CONTRACT_SESSION_001: Session Boundary Constants

**契约 ID:** CONTRACT_SESSION_001  
**名称:** Session Boundary Constants  
**状态:** IMMUTABLE

### 触发新 Session 的条件（满足任一）

| 触发类型 | 阈值/定义 | 枚举值 |
|----------|-----------|--------|
| 时间间隔 | 连续无有效帧 > 30 分钟 | SESSION_TIME_GAP |
| 用户操作 | 用户点击"结束扫描" | SESSION_USER_EXPLICIT |
| App 后台 | 进入后台 > 5 分钟 | SESSION_APP_BACKGROUND |
| 锚点失效 | 锚点帧质量检测失效 | SESSION_ANCHOR_INVALID（仅 warning） |

### 常量定义

```
SESSION_TIME_GAP_THRESHOLD_MINUTES: Int = 30
SESSION_BACKGROUND_THRESHOLD_MINUTES: Int = 5
SESSION_ANCHOR_SEARCH_MAX_FRAMES: Int = 15
```

### 不可变规则

- Session ID 生成后不可变更
- Session 边界一旦触发，不可撤销
- 跨 Session 的 L3 颜色证据不可继承（硬规则）

### CONTRACT_SESSION_001A: EffectiveFrame Minimal Criteria（v1.1 增强）

**契约 ID:** CONTRACT_SESSION_001A  
**状态:** IMMUTABLE

为使 time_gap 跨平台一致，定义最小"有效帧"：

**EffectiveFrame** 是满足以下所有条件的帧：
1. 具有有效的 ISO8601 或单调时间戳
2. 具有有效的内参摘要（非空，schemaVersioned）
3. 通过基本健全性检查（非零分辨率，内参中无 NaN/Inf）
4. 与活动 sessionId 关联

**注意**：
- 这不是 PR#5 质量门控。这里不需要模糊/曝光指标。

---

## 字符串规范化要求（A2）

**规则 ID:** CONTRACT_STRING_001  
**状态:** IMMUTABLE

所有进入确定性编码的字符串必须：
- 规范化到 Unicode NFC
- 编码保持：uint32_be byteLength + UTF-8 bytes
- 无 NUL 终止符
- 嵌入 NUL bytes 禁止

**实施**：
- DeterministicEncoding.swift 强制执行 NFC 规范化
- SYSTEM_CONTRACTS.md 明确每个字符串字段的规范化要求

---

## Job Progress Update Ownership (Phase 2)

**契约 ID:** CONTRACT_JOB_PROGRESS_001  
**状态:** Phase 2 (Planned, Not Required for Phase 1)

### Phase 1 Behavior

- Single worker assumption (no lease validation)
- Progress updates written directly to `jobs` table
- No ownership gating required

### Phase 2 Requirements

**Lease Token Validation:**
- `jobs.worker_lease_token` column must exist
- `jobs.worker_lease_expires_at` column must exist
- Worker must acquire lease before updating progress
- Ownership check failure → 404 (not found or unauthorized)

**Lease Acquisition:**
- Worker requests lease via API endpoint
- Server assigns unique `worker_lease_token`
- Lease expires after configured TTL (e.g., 5 minutes)
- Worker must renew lease before expiration

**Progress Update Authorization:**
- Progress update requests must include `worker_lease_token`
- Server validates token matches active lease
- Server validates lease has not expired
- If validation fails: return 404 (not found) or 403 (forbidden)

**Rationale:**
- Prevents concurrent worker conflicts
- Ensures progress updates come from authorized worker
- Enables observability of worker health (lease expiration indicates worker failure)
