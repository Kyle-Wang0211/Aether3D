# Whitebox Acceptance Criteria

## Pass Condition

同时满足以下三个模块通过。

### Module 1: Input — Pass

- 拍摄入口能进入录制界面
- 或 导入入口能选择素材
- 选择后进入 Generate 模块

### Module 2: Generate — Pass

**Phase 1 Requirements (Mandatory):**

- Pipeline returns success or failure with real-time progress reporting
- **Server MUST return at least one progress signal during processing:**
  - Either `progress` (float) OR `progress_stage` (string) must be present
  - Server MUST NOT return `processing` state with both signals missing for consecutive polls
- Stall detection: fails if no progress for 5 minutes (not if slow but moving)
  - Only triggers when server confirms `processing` state AND progress has not advanced
  - Network errors (timeouts, 5xx) do NOT count as stall
- Absolute max timeout: 2 hours maximum total processing time
- Network failure separation:
  - `networkTimeout`: cannot fetch job status (network errors, 5xx)
  - `stalledProcessing`: server confirms processing + no progress for 5 minutes
- Returns result (.splat / .ply) or explicit failure reason (logged)
- Must fail-fast (no hang)

**Phase 2 Extensions (Planned, Not Required):**
- Request-Id propagation for correlation
- Progress audit events (separate audit table)
- Lease token validation (ownership gating)
- Sub-stage enum expansion (sfm_extract, sfm_match, etc.)
- Polling backoff for queued state
- UI update throttling

### Module 3: Browse — Pass

- 能加载生成结果
- 能旋转 / 缩放
- 连续操作 30s 不崩溃

## Fail Condition

任一模块不通过 = 白盒不成立。

## Test Samples（3组样例规格）

| 样例类型 | 时长 | 分辨率 | 特征 |
|---------|------|--------|------|
| 室内小场景 | 10–15s | 1080p | 纹理丰富、光照稳定 |
| 室外静物 | 10–15s | 1080p | 天空 / 反光 / 光照变化 |
| 宠物 / 植物 | 10–15s | 1080p | 动态 / 细碎结构 |

**目的**：
打穿 B1 的稳定性边界；不要求成功，只要求 fail-fast 且失败可解释。

## Metrics to Record

| 指标 | 格式 | 说明 |
|------|------|------|
| 成功率 | % | 3组样例总体成功率 |
| P50 用时 | ms | 中位数处理时间 |
| P90 用时 | ms | 90 分位处理时间 |
| 失败类型 Top N | 枚举 | timeout / input_invalid / out_of_memory / pose_failed / … |

## Output Format（记录结构）

每次测试必须记录：

```json
{
  "sampleType": "indoor | outdoor | pet",
  "result": "success | fail",
  "elapsedMs": 120000,
  "failReason": "timeout | pose_failed | out_of_memory | ..."
}
```

