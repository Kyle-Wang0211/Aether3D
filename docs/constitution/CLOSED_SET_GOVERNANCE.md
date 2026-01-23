# Closed-Set Governance

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义闭集治理规则，确保枚举和常量的稳定性和可审计性。

---

## Closed-Set Governance Rules

### 1. Closed-set governance

- enum 只能 append；禁止 rename / delete / re-order（写入 SSOT_FOUNDATION）
- 每次 append 必须同步更新 JSON catalog + tests

### 2. RFC gate for breaking

- 任何改变 hash 输入、量化精度、输出字段类型/含义 → 必须走 RFC（即使白盒阶段）

---

## B3: Enum Order Freezing（强制要求）

### 问题解决

没有顺序冻结：
- case 重排序静默破坏：日志、序列化差异、审计、历史比较
- 损害是微妙的、延迟的、不可逆的

这是长期平台中的已知失败模式。

### 规范

对于每个 append-only enum（包括但不限于）：
- EdgeCaseType
- RiskFlag
- PrimaryReasonCode
- ActionHintCode
- AuditEventType（v1.1.1）

必须强制执行以下内容：

### 1. Frozen Order Hash

每个 enum 必须定义规范 case 顺序 hash：

```swift
static let frozenCaseOrderHash: String
```

- 计算自：case names（按声明顺序）用 `\n` 连接，SHA-256 哈希
- 存储为字符串字面量
- 输入必须包括 rawValue，因此更改 rawValue 会破坏 CI

### 2. CI 强制执行

必须存在测试：
- 从 enum 声明重新计算 hash
- 与 `frozenCaseOrderHash` 比较
- 如果顺序改变、case 删除或重命名 → CI fail

### 3. 允许的变更模式

唯一允许的变更：在末尾追加新 cases

任何其他内容都是破坏性变更，必须被拒绝。

### 序列化规则

- 不信任 enum raw values
- 稳定性由以下保证：显式 case 顺序、冻结 hash、append-only 纪律

---

## CaseIterable Order Enforcement

**规则 ID:** D34  
**状态:** IMMUTABLE

CaseIterable 顺序必须匹配声明顺序；任何偏差视为 CI 失败。

实施：测试断言 CaseIterable 输出顺序匹配源声明顺序。

---

## Deprecation Policy

**规则 ID:** D31  
**状态:** IMMUTABLE

允许 `deprecated=true`，但永远不删除/重命名；要求 RFC 和 2 版本警告窗口。

实施：在 CLOSED_SET_GOVERNANCE 中记录，并在 JSON 中支持字段。

---

## Enum Freeze Uses Both Hash + Golden Order List

**规则 ID:** D32  
**状态:** IMMUTABLE

枚举冻结使用 hash + golden order list 文件。

实施：存储 ExpectedCaseOrder_<Enum>.txt 并验证它。

---

## RFC Gate Breaking Change Checklist

**规则 ID:** C46  
**状态:** IMMUTABLE

RFC gate 必须列出 EXACTLY 什么是破坏性的（编码、舍入、量化精度、前缀、哈希算法、输出含义）。

实施：CLOSED_SET_GOVERNANCE.md "Breaking Change Checklist"。

---

## Breaking Change Surface（v1.1.1）

**规则 ID:** C1  
**状态:** IMMUTABLE

"这是破坏性的吗？"不能是人工辩论。

添加新 JSON 目录：BREAKING_CHANGE_SURFACE.json

必须列出（闭集）：
- encoding.byte_order
- encoding.string_format
- encoding.unicode_normalization
- quant.geom_precision
- quant.patch_precision
- rounding_mode
- hash_algorithm
- domain_separation_prefixes
- color.white_point
- color.matrix
- cross_platform_tolerances
- guaranteed_output_fields

**规则**：
任何触及这些的变更需要：
- contractVersion bump
- RFC
- 显式迁移说明

---

## Schema Version Bump Rules

**规则 ID:** C87  
**状态:** IMMUTABLE

任何身份影响变更必须：
- 递增 schemaVersion
- 递增 contractVersion

实施：治理文档。

---

## Foundation Version Format

**规则 ID:** C89  
**状态:** IMMUTABLE

foundationVersion 字符串格式锁定："major.minor"（例如，"1.1"）。

实施：测试验证 regex。

---

## Contract Version Monotonicity

**规则 ID:** C90  
**状态:** IMMUTABLE

contractVersion 必须单调递增；禁止手动递减。

实施：文档 + 使用 repo 中存储的基线值的简单测试。
