# Cross-Platform Canonicalization

**Document Version:** 1.1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义规范化规则作为一等契约，确保跨平台确定性。

---

## A1: Floating-Point Canonicalization Rules

**规则 ID:** A1  
**状态:** IMMUTABLE

### 解决的问题

如果量化前的浮点表示在平台间不同，量化确定性会被破坏。

### 新契约

所有进入确定性量化或身份推导的值必须满足：

- **输入类型必须是 Double**
- **Float 明确禁止作为身份输入**
- 所有输入必须通过：`isFinite == true`
- NaN / +Inf / -Inf 必须触发确定性 EdgeCase

### 规范化零规则

- **-0.0 必须在量化前归一化为 +0.0**

### 实施

- DeterministicQuantization.swift 添加规范化前奏部分
- 所有量化函数在量化前检查并规范化输入

### 测试要求

- `test_quantization_negative_zero_normalized()` - 验证 -0.0 归一化为 +0.0
- `test_quantization_nan_inf_rejected_with_edgecase()` - 验证 NaN/Inf 触发 EdgeCase
- `test_float_input_rejected_for_identity()` - 验证 Float 类型被拒绝

---

## A2: String Canonicalization Rules

**规则 ID:** A2  
**状态:** IMMUTABLE

### 解决的问题

Unicode 规范化差异导致字节级分歧，尽管视觉上相同的字符串。

### 最终决策（锁定）

- 所有进入确定性编码的字符串必须规范化到 Unicode NFC
- 编码保持：uint32_be byteLength + UTF-8 bytes
- 无 NUL 终止符
- 嵌入 NUL bytes 禁止

### 实施

- DeterministicEncoding.swift 强制执行 NFC 规范化
- 所有字符串在编码前规范化

### 测试要求

- `test_string_nfc_nfd_equivalence()` - 验证 NFC/NFD 等价性
- `test_string_canonicalization_applied_before_encoding()` - 验证规范化在编码前应用

---

## 规范化作为一等契约

规范化规则不是"最佳实践"，而是平台级契约。

违反规范化规则会导致：
- 跨平台身份分歧
- 审计不可追溯
- 用户信任崩溃

因此，规范化必须在所有身份相关操作中强制执行。
