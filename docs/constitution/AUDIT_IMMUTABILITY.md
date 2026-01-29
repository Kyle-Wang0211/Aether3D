# Audit Immutability

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义审计不可变原则，确保所有记录可审计、可追溯、不可删除。

---

## AUDIT_IMMUTABLE_001: Audit Record Immutability Principle

**规则 ID:** AUDIT_IMMUTABLE_001  
**名称:** Audit Record Immutability Principle  
**状态:** IMMUTABLE

### 核心原则

用户可以否认证据的"使用价值"，但不能抹去证据的"存在事实"。

### 不可变规则

1. 任何 observation 记录一旦创建，不可删除
2. 任何 patch 记录一旦创建，不可删除
3. 任何 session 记录一旦创建，不可删除
4. 任何 asset 记录一旦创建，不可删除

### 允许的操作

- 标记 `invalidated = true`（不再参与统计）
- 标记 `superseded = true`（被新版本取代）
- 添加 metadata（追加信息）

### 禁止的操作

- DELETE 任何记录
- UPDATE 已有字段值（除 invalidated/superseded 标记）
- TRUNCATE 任何表/集合

### AUDIT_IMMUTABLE_001A: ImmutableCore + AppendOnlyExtensions（v1.1 增强）

**规则 ID:** AUDIT_IMMUTABLE_001A  
**状态:** IMMUTABLE

v1.0 禁止 UPDATE 除 invalidated/superseded 外。v1.1 澄清安全、可执行的结构：

**每个可审计记录必须在概念上（并在 schema 中）拆分为**：

1. **ImmutableCore**（创建后永不更改）
   - recordId, createdAt, schemaVersion
   - hash inputs digests / provenance anchors
   - original raw observation pointers/digests

2. **AppendOnlyExtensions**（仅追加；永不覆盖）
   - warnings[]（仅追加）
   - derivedMetrics[]（仅追加条目，键为 (metricName, metricVersion)；新版本追加，永不覆盖）
   - signatures[]（仅追加）

**硬规则**：
- 不覆盖具有相同 (name, version) 键的现有扩展条目。

这避免"静默突变"，同时保持可执行。

---

## AUDIT_INVALIDATION_001: Invalidation Semantics

**规则 ID:** AUDIT_INVALIDATION_001  
**名称:** Invalidation Semantics  
**状态:** IMMUTABLE

### Invalidation 来源（闭集 enum）

```swift
enum InvalidationSource: String, Codable {
    case USER_MANUAL           // 用户手动撤销
    case SYSTEM_REPROJ_ERROR   // 重投影误差过大
    case SYSTEM_BA_UPDATE      // BA 优化后失效
    case SYSTEM_MIGRATION      // 跨 epoch 迁移时 L3 重置
    case SYSTEM_ANTI_CHEAT     // 防作弊检测
}
```

### Invalidation 记录要求

```swift
invalidationRecord: {
    invalidatedAt: ISO8601Timestamp,
    source: InvalidationSource,
    reason: String,           // 人类可读原因
    operatorId: String?,      // 若为人工操作
    reversible: Bool,         // 是否可恢复（默认 false）
    effect: InvalidationEffect  // exclude_from_stats, replaced_by_newer
}
```

### 统计规则

- `invalidated = true` 的记录不参与任何统计计算
- 但必须保留在存储中，可用于审计查询

### AUDIT_INVALIDATION_001A: Reinstatement Semantics（v1.1 增强）

**规则 ID:** AUDIT_INVALIDATION_001A  
**状态:** IMMUTABLE

如果 `reversible == true` 适用，恢复必须被审计：

**添加到 invalidationRecord 的可选字段**：
- `reinstatedAt: ISO8601Timestamp?`
- `reinstatedBy: String?`
- `reinstatementReason: String?`

**约束**：
- 恢复仅允许在当前 session 内，且仅适用于未跨 epoch 迁移的记录。

---

## AUDIT_UNDO_001: Undo/Rollback Rules

**规则 ID:** AUDIT_UNDO_001  
**名称:** Undo/Rollback Rules  
**状态:** IMMUTABLE

### 允许撤销

- 当前 session 内的 observation
- 撤销方式: 标记 `invalidatedByUser = true`

### 禁止撤销

- 已完成的 session（只能整体标记 abandoned）
- 已迁移到新 epoch 的历史证据
- 已上链/已发布的资产数据

### 撤销审计要求

```swift
undoRecord: {
    undoTimestamp: ISO8601Timestamp,
    undoSource: "user" | "system",
    affectedRecordIds: [String],
    reason: String
}
```

---

## AUDIT_ANTI_CHEAT_001: Anti-Cheat Risk Flags

**规则 ID:** AUDIT_ANTI_CHEAT_001  
**状态:** IMMUTABLE

### 风险标记枚举（闭集）

```swift
enum RiskFlag: String, Codable, CaseIterable {
    // 数据来源风险
    case SYNTHETIC_SUSPECTED       // 疑似 CGI/合成数据
    case NO_ORIGINAL_FRAMES        // 无原始帧数据
    case EXTERNAL_MESH_IMPORT      // 外部 mesh 导入
    
    // 时间相关风险
    case TIMESTAMP_ANOMALY         // 时间戳异常
    case CLOCK_MANIPULATION        // 疑似时钟篡改
    
    // 证据相关风险
    case EVIDENCE_INJECTION        // 疑似证据注入
    case OBSERVATION_WITHOUT_FRAME // observation 无对应帧
    
    // 设备相关风险
    case EMULATOR_DETECTED         // 检测到模拟器
    case ROOT_JAILBREAK_DETECTED   // 检测到 root/越狱
}
```

### 检测规则（Phase1: 标记不阻断）

| 风险类型 | 检测方法 | 后果 |
|----------|----------|------|
| SYNTHETIC_SUSPECTED | 相机内参异常规律性 | 标记，不阻断 |
| NO_ORIGINAL_FRAMES | 检测无原始帧数据 | 禁止进入 S4 |
| TIMESTAMP_ANOMALY | 与设备时间偏差 > 1h | 标记，不阻断 |
| EVIDENCE_INJECTION | observation 无对应帧 | 拒绝该 observation |

### 输出要求

```swift
riskAssessment: {
    flags: [RiskFlag],
    confidenceScores: [RiskFlag: Double],  // 0-1 置信度
    blockedFromS4: Bool,
    blockedReasons: [String],
    blockLevel: RiskBlockLevel  // none, block_strict, block_trade
}
```

---

## Audit Event Model（v1.1.1）

### AuditEventType Enum

**规则 ID:** E1  
**状态:** IMMUTABLE

```swift
enum AuditEventType: String, Codable, CaseIterable {
    case CREATED
    case INVALIDATED
    case SUPERSEDED
    case RECOMPUTED
    case MIGRATED
    case REDACTED
}
```

**要求**：
- APPEND_ONLY_CLOSED_SET
- 必须包含 `frozenCaseOrderHash`
- 初始 cases 顺序锁定

### Supersede Event

**规则 ID:** E1_SUPERSEDE  
**状态:** IMMUTABLE

如果 `computePhase=finalized`，后续更改需要 supersede 事件，不是就地编辑。

```swift
supersedeEvent: {
    oldRecordId: String,
    newRecordId: String,
    supersededAt: ISO8601Timestamp,
    reason: String
}
```

---

## Published Asset Rule

**规则 ID:** AUDIT_PUBLISH_001  
**状态:** IMMUTABLE

已发布的资产是仅追加的；仅允许 supersede。

- 一旦资产发布，ImmutableCore 字段不可更改
- 仅允许通过 supersede 事件创建新版本
- 必须保留所有历史版本用于审计
