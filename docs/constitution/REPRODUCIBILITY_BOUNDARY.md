# Reproducibility Boundary

**Document Version:** 1.1.1  
**状态:** IMMUTABLE

---

## 概述

本文档定义可重现性输入边界，指定最小重放 bundle 的闭集。

---

## E2: Reproducibility Input Boundary

**规则 ID:** E2  
**状态:** IMMUTABLE

### 解决的问题

定义最小重放 bundle，确保资产可以完全重现。

### 最小重放 Bundle（闭集）

以下输入构成最小重放 bundle：

```
reproducibilityBundle = {
  rawVideoDigest,
  cameraIntrinsicsDigest,
  reconstructionParamsDigest,
  pipelineVersion,
  deterministicEncodingVersion,
  deterministicQuantizationVersion,
  colorSpaceVersion
}
```

### 字段说明

| 字段 | 说明 | 版本化要求 |
|------|------|-----------|
| rawVideoDigest | 原始视频摘要 | 必须 |
| cameraIntrinsicsDigest | 相机内参摘要 | 必须 |
| reconstructionParamsDigest | 重建参数摘要 | 必须 |
| pipelineVersion | 管道版本 | 必须 |
| deterministicEncodingVersion | 确定性编码版本 | 必须（v1.1.1） |
| deterministicQuantizationVersion | 确定性量化版本 | 必须（v1.1.1） |
| colorSpaceVersion | 颜色空间版本 | 必须（v1.1.1） |

### 版本化要求

所有版本字段必须：
- 明确标识实现版本
- 存储在 SSOT 中
- 在输出契约中记录

### 重放保证

给定相同的 reproducibilityBundle：
- 必须产出相同的 patchId
- 必须产出相同的 geomId
- 必须产出相同的 meshEpochSalt
- 必须产出相同的 L3 证据（在相同颜色空间版本下）

### 实施要求

- 所有重放操作必须验证 bundle 完整性
- 缺少任何必需字段必须拒绝重放
- 版本不匹配必须触发迁移流程

### 测试要求

- `test_reproducibility_boundary_complete()` - 验证可重现性边界完整性
- 测试必须验证相同 bundle 产出相同结果

---

## 重放与审计

**规则 ID:** E2_AUDIT  
**状态:** IMMUTABLE

可重现性边界用于：
- 争议解决
- 审计验证
- 资产验证
- 跨平台一致性验证

所有重放操作必须：
- 记录使用的 bundle
- 记录产出结果
- 可用于审计查询

---

## 版本兼容性

**规则 ID:** E2_COMPAT  
**状态:** IMMUTABLE

不同版本的 bundle 可能不兼容：
- 旧版本 bundle 可能需要迁移
- 新版本 bundle 必须明确标识
- 版本不兼容必须显式处理，不能静默失败
