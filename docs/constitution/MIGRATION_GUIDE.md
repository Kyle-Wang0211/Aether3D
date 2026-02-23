# Migration Guide

**Document Version:** 1.1  
**Status:** IMMUTABLE

---

## 概述

本文档提供迁移模板和 v1.1 基线条目，用于指导未来版本迁移。

---

## Migration Template

每个迁移条目必须包含以下必需部分：

### 1. What Changed（什么改变了）

- 列出所有变更点
- 标识破坏性变更
- 说明非破坏性变更

### 2. Why Breaking（为什么是破坏性的）

- 解释为什么此变更需要迁移
- 说明对现有系统的影响
- 列出可能受影响的下游系统

### 3. How to Migrate（如何迁移）

- 提供逐步迁移说明
- 包含代码示例（如适用）
- 说明迁移工具或脚本（如适用）

### 4. Inheritance Rules（继承规则）

- 说明哪些数据可以继承
- 说明哪些数据不能继承
- 提供继承决策矩阵

---

## v1.1 Baseline Entry

### Version: 1.1

**What Changed:**
- 初始 SSOT Foundation 建立
- 所有规则和常量首次定义
- 无迁移（这是基线）

**Why Breaking:**
- N/A（基线版本）

**How to Migrate:**
- N/A（基线版本）

**Inheritance Rules:**
- 所有数据从 v1.1 开始
- 无历史数据需要迁移

---

## Future Migration Entries

未来版本变更必须在此文档中添加新条目，遵循上述模板。

每个条目必须明确说明：
- 哪些变更需要显式迁移
- 哪些变更可以静默继承
- 哪些变更需要新资产类别

---

## No Silent Inheritance Policy

**规则 ID:** MIGRATION_001  
**状态:** IMMUTABLE

对于以下变更，明确禁止静默继承：
- 颜色空间变更（CE）
- L3 证据格式变更
- 身份哈希算法变更
- 量化精度变更

这些变更需要：
- 新 schemaVersion
- 新资产类别
- 显式迁移边界
