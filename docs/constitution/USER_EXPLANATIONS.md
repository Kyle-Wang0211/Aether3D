# User Explanations

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义用户解释层契约，规定每个 reason/edge/risk 对应的用户文案与建议动作。

---

## B1: User Explanation Catalog（强制要求）

**决策（最终）**：User Explanation Catalog **必须在 v1.1 中交付**。这是非可选的。

### 目的

此目录定义系统允许对用户说什么，独立于系统如何计算任何内容。

它是语义上限，不是 UI 工件。

### 结构（闭集）

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
  ],
  "meaningHash": "sha256_hash_of_canonical_semantic_summary",
  "meaningChangeRequiresRFC": true,
  "oneSentenceWhy": "The object had parts permanently hidden from view.",
  "oneSentenceFix": "Rescan from different angles to expose hidden areas.",
  "userActionVerb": "change_angle",
  "enforcement": "reject",
  "recoveryPath": "reshoot",
  "tonePolicy": "neutral",
  "supportTag": "OCCLUSION_001",
  "i18nKey": "reason.structural_occlusion"
}
```

### 硬规则

- code 是稳定的闭集枚举键
- 解释是：人类可读、确定性、不在运行时由 AI 生成
- 此目录：必须在 PR#6 之前存在，永远不能推断或自动生成

### 治理

- Append-only
- 无重命名
- 无语义漂移
- 任何变更需要：RFC、版本升级、迁移说明

### 字段说明

- **code**: 稳定的枚举键，引用自 PrimaryReasonCode/ActionHintCode/EdgeCaseType/RiskFlag
- **category**: 闭集 {primary_reason, action_hint, edge_case, risk_flag, grade, contract_note}
- **severity**: 闭集 {info, caution, critical}
- **shortLabel**: ≤32 字符
- **userExplanation**: ≤500 字符，用户可读解释
- **technicalExplanation**: 技术细节，供开发者/支持使用
- **appliesTo**: 此解释适用的领域数组 {user_ui, developer_logs, pricing, licensing, chain, audit}
- **actionable**: 是否可操作
- **suggestedActions**: ActionHintCode 数组（无自由文本）
- **meaningHash**: SHA-256 of canonical semantic summary（v1.1.1）
- **meaningChangeRequiresRFC**: true（v1.1.1）
- **oneSentenceWhy**: ≤140 字符（v1.1.1）
- **oneSentenceFix**: ≤140 字符（v1.1.1）
- **userActionVerb**: 闭集动词（v1.1.1）
- **enforcement**: 闭集 {reject, warn, info}
- **recoveryPath**: 闭集 {reshoot, reduce_duration, reduce_resolution, update_app, contact_support}
- **tonePolicy**: 闭集 {neutral, caution, critical}
- **supportTag**: 短稳定代码，用于日志
- **i18nKey**: 稳定键，当前为英文文本

---

## B2: Guaranteed Interpretability Fields

### 字段定义

这些字段是 schema-guaranteed，不是可选的：

1. **primaryReasonCode**: PrimaryReasonCode（exactly one, never null）
2. **primaryReasonConfidence**: {unknown, likely, confirmed}
3. **nextBestActionHints**: [ActionHintCode]（0+ entries；稳定顺序）
4. **computePhase**: {realtime_estimate, delayed_refinement, finalized}
5. **progressConfidence**: Double ∈ [0,1]

### 明确非目标

- 无评分逻辑
- 无优先级启发式
- 无本地化
- 无 UI 文案决策

---

## Gap Taxonomy（5 类）

**规则 ID:** U1  
**状态:** IMMUTABLE

在解释目录中定义 5 类 gap 分类：`gapType ∈ {true_missing, capture_occluded, structural_occluded, boundary_uncertain, not_applicable}`

实施：在相关 reason 条目中添加 gapType 字段；添加 REASON_COMPATIBILITY 规则以防止矛盾组合。

---

## No Empty Hints Rule

**规则 ID:** U2  
**状态:** IMMUTABLE

如果 `primaryReasonCode != NORMAL`，则 `nextBestActionHints` 必须包含 ≥1 条目。

实施：在 SYSTEM_CONTRACTS 中记录；在 CatalogSchemaTests + DocSync 测试中添加 CI 验证。

---

## User-Facing Tier Mapping

**规则 ID:** U5  
**状态:** IMMUTABLE

创建 userFacingTier 映射：{trade_ready, usable, reference_only}。定义从 S_state 到 tier 的固定映射（仅文档）。

实施：在目录中添加 tier，并在 USER_EXPLANATIONS.md 中包含映射表。

---

## Action Hints Must Be Action-Verbs

**规则 ID:** U8  
**状态:** IMMUTABLE

Action hints 必须是动作动词，不是算法术语。定义 userActionVerb 闭集：

```
{move_closer, rotate_around, improve_light, slow_down, clear_occlusion, 
 avoid_reflection, rescan_region, stabilize_object, reduce_glare, change_angle}
```

实施：在目录中每个 hint 存储 userActionVerb。

---

## Recovery Path for REJECT Edge Cases

**规则 ID:** U9  
**状态:** IMMUTABLE

对于每个 REJECT edge case，要求 recoveryPath ∈ {reshoot, reduce_duration, reduce_resolution, update_app, contact_support}。

实施：EDGE_CASE_TYPES.json 包括 enforcement=reject 和 recoveryPath；测试强制执行完整性。

---

## Explanation Tone Policy

**规则 ID:** U10  
**状态:** IMMUTABLE

tonePolicy ∈ {neutral, caution, critical}。"critical" 仅允许用于硬拒绝或高置信度反作弊阻止。

实施：测试扫描目录；lint 禁止对"suspected"标志使用指责性词语。

---

## DeclaredAssetType User-Explainable

**规则 ID:** U11  
**状态:** IMMUTABLE

如果 declared != standard，目录必须包括"expectedCeiling"和"why ceiling exists"。

实施：为每个 DeclaredAssetType 添加条目和声明提示。

---

## Appearance Promise Label

**规则 ID:** U12  
**状态:** IMMUTABLE

统一"外观无法承诺"标签跨 specular/transparent/porous：appearancePromise ∈ {can_promise, cannot_promise}。

实施：在目录中添加字段；在 USER_EXPLANATIONS.md 中定义一致的 badge 语义。

---

## Completion Definition

**规则 ID:** U14  
**状态:** IMMUTABLE

定义 completionDefinition：当 `computePhase=finalized AND nextBestActionHints empty AND S_state≥3` => "safe to stop"。

实施：仅文档；无算法。

---

## ComputePhase Messaging Rules

**规则 ID:** U15  
**状态:** IMMUTABLE

定义 computePhase 消息规则："realtime_estimate can change"，"finalized cannot change without supersede"。

实施：在 AUDIT_IMMUTABILITY 中强制执行（需要 supersede 事件）。

---

## Hand Occlusion Anti-Mislead Rule

**规则 ID:** U16  
**状态:** IMMUTABLE

"手遮挡反误导规则"：capture_occluded 必须在 primaryReason 选择中优先于 missing/boundary。

实施：在 REASON_COMPATIBILITY.json 中定义为优先级约束；无算法。

---

## L3 Color Not Inherited Explanation

**规则 ID:** U20  
**状态:** IMMUTABLE

解释"L3 颜色不跨 session 继承"，使用固定用户面向句子 + 提示 rescan_under_consistent_light。

实施：添加专用目录条目并链接到 session 边界规则。
