# Cross-Platform Consistency

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义跨平台一致性规则，确保 iOS/Android/Server 产出相同结果。

---

## CROSS_PLATFORM_HASH_001: Hash Input Byte Order Specification

**规则 ID:** CROSS_PLATFORM_HASH_001  
**名称:** Hash Input Byte Order Specification  
**状态:** IMMUTABLE

### 通用规则

- 所有整数: Big-Endian
- 所有浮点: 禁止直接 hash（必须先量化为整数）
- 字符串: UTF-8 编码，长度前缀（uint32_be byteLength + UTF-8 bytes，无 NUL）
- 数组: 先写长度（uint32），再依次写元素

### Domain Separation（域分离前缀，闭集）

| 用途 | 前缀（ASCII + \0） |
|------|-------------------|
| patchId | "AETHER3D:PATCH_ID\0" |
| geomId | "AETHER3D:GEOM_ID\0" |
| meshEpochSalt | "AETHER3D:MESH_EPOCH\0" |
| assetRoot | "AETHER3D:ASSET_ROOT\0" |
| evidenceHash | "AETHER3D:EVIDENCE\0" |

**注意**：v1.1.1 要求所有前缀必须在 DOMAIN_PREFIXES.json 中注册。

### Hash 算法

- **首选**: BLAKE3（快、标准、跨平台）
- **备选**: SHA-256（若体系已固定）
- **v1.1.1 最终确定**: SHA-256（单一算法，任何未来替代需要新 schema）
- 输出: 32 bytes

### CROSS_PLATFORM_HASH_001A: String Encoding Override（v1.1 增强）

**规则 ID:** CROSS_PLATFORM_HASH_001A  
**状态:** IMMUTABLE

v1.0 规定：字符串: UTF-8 编码，末尾加 \0。v1.1 添加更严格的规则以防止平台/库差异：

**规范字符串编码（覆盖所有 PR#1 新代码）**：
- 字符串必须编码为：
  1. uint32_be byteLength
  2. UTF-8 bytes（精确长度）
- **不使用 NUL 终止符**

**域分离前缀编码**：
- v1.0 中列出的前缀必须使用相同的长度 + bytes 规则。

**理由**：
- 防止跨 Swift/Kotlin/C/Python 工具链的意外截断或不匹配行为。

---

## CROSS_PLATFORM_QUANT_001: Coordinate Quantization Specification

**规则 ID:** CROSS_PLATFORM_QUANT_001  
**名称:** Coordinate Quantization Specification  
**状态:** IMMUTABLE

### 量化精度常量

```
QUANT_POS_GEOM_ID: Double = 1e-3   // 1mm，用于 geomId（跨 epoch 稳定）
QUANT_POS_PATCH_ID: Double = 1e-4  // 0.1mm，用于 patchId（epoch 内精确）
```

### 量化算法

```
quantize(value: Double, precision: Double) -> Int64 =
  round(value / precision)  // 使用 round，不是 floor
```

### 顶点排序（Canonical Ordering）

- 三角形 3 个顶点量化后，按字典序排序
- 排序键: (qx, qy, qz) 作为 tuple
- 排序后: v0 <= v1 <= v2

### 验证要求

- CI 必须包含跨平台一致性测试
- 测试用例: 同一 mesh 在 iOS/Android/Server 产出相同 geomId/patchId

### CROSS_PLATFORM_QUANT_001A: Rounding Mode Definition（v1.1 增强）

**规则 ID:** CROSS_PLATFORM_QUANT_001A  
**状态:** IMMUTABLE

v1.0 使用 round(value / precision)。v1.1 指定舍入模式：

**量化舍入模式**：
- 必须是 ROUND_HALF_AWAY_FROM_ZERO

**规范函数**：
- 在每个平台实现本地 quantize 函数，不依赖标准库舍入默认值

**溢出规则**：
- 如果量化值超过 Int64 范围，验证必须失败：
  - EdgeCaseType.COORDINATE_OUT_OF_RANGE AND EdgeCaseType.MESH_VALIDATION_FAILED

---

## CROSS_PLATFORM_ID_001: Triangle Orientation Handling

**规则 ID:** CROSS_PLATFORM_ID_001  
**状态:** IMMUTABLE

- geomId 不得依赖三角形缠绕/方向
- patchId 在 Phase1 不得依赖三角形缠绕/方向
- 任何法线/方向证据必须存储为观察元数据（Evidence 域），不在身份哈希中

这确保重新网格化或顶点顺序更改不会导致灾难性身份流失。

---

## CROSS_PLATFORM_COLOR_001: Color Space Conversion Constants

**规则 ID:** CROSS_PLATFORM_COLOR_001  
**名称:** Color Space Conversion Constants  
**状态:** IMMUTABLE

### sRGB → XYZ 转换矩阵（D65 白点）

| | X | Y | Z |
|---|-------|-------|-------|
| R | 0.4124564 | 0.3575761 | 0.1804375 |
| G | 0.2126729 | 0.7151522 | 0.0721750 |
| B | 0.0193339 | 0.1191920 | 0.9503041 |

### XYZ → Lab 转换参数

```
Xn = 0.95047  // D65 白点
Yn = 1.00000
Zn = 1.08883

delta = 6/29
f(t) = t^(1/3)           if t > delta^3
     = t/(3*delta^2) + 4/29  otherwise
```

### 禁止事项

- 禁止使用系统默认颜色转换 API（各平台实现不一致）
- 必须使用上述常量自行实现转换

---

## CROSS_PLATFORM_CONSISTENCY_001: Cross-Platform Consistency Requirements

**规则 ID:** CROSS_PLATFORM_CONSISTENCY_001  
**状态:** IMMUTABLE

| 计算类型 | 一致性要求 | 验证方法 |
|----------|-----------|----------|
| geomId | 字节级一致 | 同 mesh → 同 geomId（全平台） |
| patchId | 字节级一致 | 同 mesh + 同 epoch → 同 patchId |
| meshEpochSalt | 字节级一致 | 同输入参数 → 同 salt |
| coverage 计算 | 1e-4 相对误差内 | \|coverage_A - coverage_B\| / max < 1e-4 |
| Lab 颜色值 | 1e-3 绝对误差内 | 同 RGB → Lab 差异 < 0.001 |
| S_state | 完全一致 | 同输入 → 同状态 |

### CI 测试要求

- 每个 PR 必须跑跨平台一致性测试
- 测试矩阵: iOS-Simulator × Android-Emulator × Server-Linux
- 失败时阻断合并

---

## CL2: Cross-Platform Numerical Consistency Tolerances

**规则 ID:** CL2  
**状态:** IMMUTABLE

### 容差定义

| 指标类型 | 容差 | 类型 |
|----------|------|------|
| Coverage / Ratio 值 | 相对误差 ≤ 1e-4 | Relative |
| Lab 颜色分量 | 绝对误差 ≤ 1e-3 | Absolute |

这些容差适用于跨平台等价性检查，不是算法质量。

### CL2 约束

- 这些容差适用于跨平台等价性检查，不是算法质量阈值
- 这是跨平台等价性契约，不是质量标准
- 保证"相同输入 ≈ 相同输出"

---

## F1: Relative Error Formula Lockdown（v1.1.1）

**规则 ID:** F1  
**状态:** IMMUTABLE

**锁定公式**：

```
relErr(a, b) = |a - b| / max(eps, max(|a|, |b|))
eps = 1e-12
```

**适用于**：
- Coverage
- Ratios
- Confidence metrics

**理由**：不同团队以不同方式计算"相对误差"。此公式锁定防止分歧。

---

## F2: Lab Error Definition（CL2 Clarification）

**规则 ID:** F2  
**状态:** IMMUTABLE

**锁定规则**：
- Lab 容差是每通道绝对误差
- 不是 ΔE
- 通道: L*, a*, b*

**理由**：确保跨平台比较的一致性，避免 ΔE 计算的平台差异。
