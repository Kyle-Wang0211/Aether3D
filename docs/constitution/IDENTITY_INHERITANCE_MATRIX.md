# Identity Inheritance Matrix

**Document Version:** 1.1.1  
**Status:** IMMUTABLE

---

## 概述

本文档定义身份继承矩阵，明确说明每个输入变更对 patchId/geomId/L3 证据继承的影响。

---

## B1: Identity Inheritance Matrix

**规则 ID:** B1  
**状态:** REQUIRED

### 解决的问题

没有显式继承规则，增量重建将导致静默身份漂移。

### 继承矩阵

下表定义，对于每个输入变更，以下是否可以继承：
- patchId
- geomId
- L3 Evidence（颜色/覆盖率/信任）

### 输入变更（闭集）

| 输入变更 | patchId 继承 | geomId 继承 | L3 证据继承 | 说明 |
|----------|-------------|-------------|-------------|------|
| rawVideoDigest 变更 | ❌ NO | ❌ NO | ❌ NO | 视频源变更，所有身份必须重新计算 |
| cameraIntrinsicsDigest 变更 | ❌ NO | ❌ NO | ❌ NO | 相机内参变更，几何和证据都受影响 |
| reconstructionParamsDigest 变更 | ❌ NO | ⚠️ MAYBE | ❌ NO | 重建参数变更，geomId 可能继承（取决于参数类型），但 patchId 和 L3 必须重新计算 |
| pipelineVersion 变更 | ❌ NO | ⚠️ MAYBE | ❌ NO | 管道版本变更，geomId 可能继承（如果几何语义未变），但 patchId 和 L3 必须重新计算 |
| colorSpaceVersion 变更 | ✅ YES | ✅ YES | ❌ NO | 颜色空间版本变更，geomId 可继承，L3 证据不可继承 |

### 规则示例（必须显式）

**示例 1**: colorSpaceVersion 变更
- geomId: **可继承**（几何未变）
- patchId: **可继承**（patch 几何未变）
- L3 证据: **不可继承**（颜色语义已变）

**示例 2**: reconstructionParamsDigest 变更（仅影响 L3 阈值）
- geomId: **可继承**（几何未变）
- patchId: **可继承**（patch 几何未变）
- L3 证据: **不可继承**（L3 评估规则已变）

**示例 3**: rawVideoDigest 变更
- geomId: **不可继承**（视频源已变）
- patchId: **不可继承**（视频源已变）
- L3 证据: **不可继承**（视频源已变）

### 实施要求

- 此矩阵必须在所有增量重建逻辑中强制执行
- 任何违反继承规则的实现必须被拒绝
- CI 必须验证继承矩阵完整性

### 测试要求

- `test_inheritance_matrix_complete()` - 验证继承矩阵完整性
- 测试必须验证所有输入变更组合的继承行为

---

## 继承决策流程

当输入变更时，系统必须：

1. 识别变更的输入类型
2. 查询继承矩阵
3. 根据矩阵决定哪些身份可以继承
4. 对于不可继承的身份，重新计算
5. 记录继承决策用于审计

---

## 迁移边界

**规则 ID:** B1_MIGRATION  
**状态:** IMMUTABLE

跨版本迁移时：
- 继承矩阵决定哪些数据可以携带
- 不可继承的数据必须重新计算
- 必须记录迁移决策用于审计

---

## 禁止静默继承

**规则 ID:** B1_NO_SILENT  
**状态:** IMMUTABLE

以下变更明确禁止静默继承：
- colorSpaceVersion 变更 → L3 证据不可继承
- reconstructionParamsDigest 变更 → L3 证据不可继承（如果影响 L3 规则）

这些变更需要：
- 显式迁移边界
- 审计记录
- 用户通知（如适用）
