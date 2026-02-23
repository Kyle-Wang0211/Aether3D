# Whitebox Specification

## Status

This document is retained for historical traceability.  
Current execution policy is governed by `governance/phase_plan.json` and gate matrix contracts.

## Purpose

回答一句话：**B1 主 pipeline 在“首扫成功率优先”约束下是否成立（目标 2-3 分钟，硬上限 15 分钟）？**

## Scope

- **Module 1: Input**
- **Module 2: Generate**
- **Module 3: Browse**

## Hard Constraints

- Only B1 pipeline (D1 not enabled)
- Target scan window: 2-3 minutes for first-pass success
- Absolute hard cap: 15 minutes maximum total scan time
- Stall-based timeout: 5 minutes without progress change → fail-fast
- Network failure vs stall distinction: must correctly identify network errors vs processing stall
- **Server MUST return at least one progress signal during processing** (percent OR stage)
- No quality testing, no experience quality testing

**Phase 2 Extensions (Planned, Not Required):**
- Request-Id propagation for observability
- Progress audit events
- Lease token validation

## Module Definitions

### Module 1: Input

- **输入**：拍摄 / 内部导入
- **输出**：合规视频数据（时长 / 分辨率 / 帧率）
- **验收**：至少一种输入路径稳定可用

### Module 2: Generate

- **输入**：合规视频数据
- **输出**：.splat / .ply 文件 或 明确失败原因
- **验收**：Pipeline returns success or failure with real-time progress reporting. Stall detection: fails if no progress for 5 minutes (not if slow but moving). Absolute max: 2 hours total time.

### Module 3: Browse

- **输入**：.splat / .ply 文件
- **输出**：可旋转 / 缩放的 3D 预览
- **验收**：连续操作 30s 不崩溃

## Non-Goals（明确不做）

- 社区 / 分享 / 云端账号
- 贴纸 / 编辑 / 多质量档位
- 保存 / 导出 / 离线渲染
- D1 保底质量
