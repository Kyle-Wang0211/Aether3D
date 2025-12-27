# Whitebox Specification

## Purpose

回答一句话：**B1 主 pipeline 在 fail-fast（≤180s）约束下是否成立？**

## Scope

- **Module 1: Input**
- **Module 2: Generate**
- **Module 3: Browse**

## Hard Constraints

- 仅 B1 pipeline（不启用 D1）
- ≤180s 硬约束（超时必须 fail-fast）
- 不测试画质、不测试体验质量

## Module Definitions

### Module 1: Input

- **输入**：拍摄 / 内部导入
- **输出**：合规视频数据（时长 / 分辨率 / 帧率）
- **验收**：至少一种输入路径稳定可用

### Module 2: Generate

- **输入**：合规视频数据
- **输出**：.splat / .ply 文件 或 明确失败原因
- **验收**：≤180s 内返回成功或失败结果

### Module 3: Browse

- **输入**：.splat / .ply 文件
- **输出**：可旋转 / 缩放的 3D 预览
- **验收**：连续操作 30s 不崩溃

## Non-Goals（明确不做）

- 社区 / 分享 / 云端账号
- 贴纸 / 编辑 / 多质量档位
- 保存 / 导出 / 离线渲染
- D1 保底质量

