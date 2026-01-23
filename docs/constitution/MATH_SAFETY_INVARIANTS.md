# Math Safety Invariants

**Document Version:** 1.1  
**Status:** IMMUTABLE  
**Rule ID:** MATH_SAFE_001

---

## 概述

本文档定义数学安全不变量，确保所有数学计算在边界情况下保持安全和可审计。

---

## MATH_SAFE_001: Safe Division Rule

**规则 ID:** MATH_SAFE_001  
**名称:** Safe Division Rule  
**状态:** IMMUTABLE

### 定义

任何 ratio 计算必须遵循：

```
safeRatio(numerator, denominator) =
  if denominator == 0:
    return 0.0
  else:
    return clamp(numerator / denominator, 0.0, 1.0)
```

### 不变量

- ratio 的语义是"比例"，必须 ∈ [0, 1]
- 除零不抛异常，返回 0.0
- 超出 [0, 1] 自动 clamp

### 审计要求

- 若触发 clamp，必须记录 rawValue 用于审计

### MATH_SAFE_001A: SafeRatio Audit Metadata（v1.1 增强）

**规则 ID:** MATH_SAFE_001A  
**状态:** IMMUTABLE

v1.0 规则 safeRatio(numerator, denominator) 仍然有效。v1.1 添加必需的审计元数据以防止下游混淆。

**每个 ratio/score 计算的必需输出**：
- `clampedValue: Double`（下游逻辑使用的值）
- `rawValue: Double?`（仅在 clampTriggered == true 或特殊条件需要审计时存在）
- `clampTriggered: Bool`
- `edgeCaseTriggered: EdgeCaseType?`（nil 除非触发）

**特殊审计规则**：
- 如果 denominator == 0，返回 clampedValue = 0.0 并设置：
  - `edgeCaseTriggered = EdgeCaseType.EMPTY_GEOMETRY` 或更具体的适用 EdgeCaseType（模块必须选择最具体的闭集值）
- 如果 numerator/denominator > 1.0 或 < 0.0，clamp 并设置 clampTriggered = true 并记录 rawValue

---

## MATH_SCORE_001: RawScore vs Ratio Semantics

**规则 ID:** MATH_SCORE_001  
**状态:** IMMUTABLE

- `rawWeightedScore ∈ [0, +∞)` 是分数（风险强度）
- `unreliableAppearanceRatio_weighted ∈ [0, 1]` 是比例（比例语义）

**强制规则**：
- `unreliableAppearanceRatio_weighted = min(rawWeightedScore, 1.0)`
- 每当 rawWeightedScore > 1.0 时，必须输出 rawWeightedScore（用于审计）

---

## MATH_CLAMP_001: Global Clamp Rules

**规则 ID:** MATH_CLAMP_001  
**名称:** Global Clamp Rules  
**状态:** IMMUTABLE

| 指标类型 | 下限 | 上限 | 超限处理 |
|----------|------|------|----------|
| ratio（比例） | 0.0 | 1.0 | clamp + 记录 rawValue |
| score（评分） | 0.0 | 1.0 | clamp + 记录 rawValue |
| weight（权重） | 0.0 | 无上限 | 只 clamp 下限 |
| count（计数） | 0 | 无上限 | 只 clamp 下限 |
| area（面积 m²） | 0.0 | 无上限 | 只 clamp 下限 |

**输出要求**：
- `clampedValue`: 实际使用值
- `rawValue`: 原始计算值（仅当触发 clamp 时）
- `clampTriggered: Bool`

---

## NaN/Inf 输入防御

**规则 ID:** MATH_SAFE_002  
**状态:** IMMUTABLE

所有进入确定性量化或身份推导的值必须满足：
- 输入类型必须是 Double
- Float 明确禁止作为身份输入
- 所有输入必须通过：`isFinite == true`
- NaN / +Inf / -Inf 必须触发确定性 EdgeCase

**规范化零规则**：
- -0.0 必须在量化前归一化为 +0.0

---

## 负数输入策略

**规则 ID:** MATH_SAFE_003  
**状态:** IMMUTABLE

面积/计数不应为负，出现时触发 EdgeCase。

**策略（闭集）**：
- `NEGATIVE_INPUT_POLICY ∈ {clamp_to_zero_and_flag, reject_and_flag}`
- v1.1 选择：`clamp_to_zero_and_flag`
- 记录 `EDGE_NEGATIVE_INPUT`

---

## 审计字段一致性

**规则 ID:** MATH_SAFE_004  
**状态:** IMMUTABLE

触发 clamp 或 edgecase 时 rawValue 必须存在；否则必须为 nil，不能乱填。

**规则**：
- `rawValue` 必须存在 iff `clampTriggered == true OR edgeCasesTriggered.nonEmpty`
- 否则 `rawValue` 必须为 nil
