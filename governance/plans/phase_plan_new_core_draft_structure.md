# Draft Structure: `phase_plan_new_core.json` (Design Only)

## 1. 目标
- 定义“新核心层专用 phase plan”的 JSON 结构草案。
- 保持与当前 `phase_plan.schema.json` 的主干兼容。
- 增加新核心所需的严格字段：测试配额、lane 约束、产物合同、回退协议。
- 本文档仅为结构设计，不创建、不启用实际 JSON 配置文件。

## 2. 兼容基线
- 当前 `phase_plan.schema.json` 必填字段：
  - `metadata.plan_version/last_updated/phase_id_span`
  - `phases[].id/name/track/objective/prerequisite_phase_ids/required_contract_ids/required_gate_ids/deliverables/cursor_steps`
- 新草案采用扩展字段（`x_*`）策略，保持可降级到当前 schema。

## 3. 结构草案（目标形态）

```jsonc
{
  "metadata": {
    "plan_version": "2.0.0-draft",
    "last_updated": "2026-02-17",
    "source": "governance/plans/phase_plan_new_core_draft_structure.md",
    "phase_id_span": { "min": 0, "max": 13 },
    "scope": "new_core_only",
    "execution_contract": "strict_no_skip",
    "x_lane_policy": {
      "hard": "NC_RELEASE_HARD",
      "soft": "LEGACY_COMPAT_SOFT"
    },
    "x_quota_policy_ref": "new_core_phase_gate_contract_v1.md#3-phase-合同矩阵"
  },
  "phases": [
    {
      "id": 5,
      "name": "Quality + System Integration Closure (New Core)",
      "track": "PX",
      "objective": "Close quality/system hard blockers for new core release lane.",
      "prerequisite_phase_ids": [4],
      "required_contract_ids": ["C-BLUR-SSOT-SINGLE-VALUE", "C-UPLOAD-CHUNK-HASH-VERIFY"],
      "required_gate_ids": ["NC-G-001", "NC-G-011", "NC-G-031", "NC-G-043", "NC-G-901"],
      "deliverables": [
        "governance/generated/nc/phase-05/gate_run_manifest.json",
        "governance/generated/nc/phase-05/quality_closure_report.json"
      ],
      "cursor_steps": [
        "Run NC fast profile",
        "Run NC deep profile",
        "Run NC full sweep",
        "Sign-off only when all hard gates pass"
      ],
      "x_release_lane": "NC_RELEASE_HARD",
      "x_observe_lane": "LEGACY_COMPAT_SOFT",
      "x_test_quota": {
        "total_min": 3500,
        "deterministic_min": 900,
        "property_min": 650,
        "metamorphic_min": 400,
        "fuzz_min": 600,
        "adversarial_min": 320,
        "soak_stress_min": 180,
        "e2e_replay_min": 220
      },
      "x_stop_conditions": [
        "any_hard_gate_failed",
        "quota_not_met",
        "artifact_missing"
      ],
      "x_rollback_policy": {
        "strategy": "batch_revert_and_replay",
        "max_forward_without_full_sweep": 0
      },
      "x_artifact_contract": [
        "gate_run_manifest.json",
        "first_scan_runtime_metrics.json",
        "audit_chain_report.json"
      ]
    }
  ]
}
```

## 4. 字段定义（草案）

### 4.1 `metadata`
- `scope`: 固定 `new_core_only`。
- `execution_contract`: 固定 `strict_no_skip`（不允许跳过硬 gate）。
- `x_lane_policy`: 新核心硬/软车道定义。
- `x_quota_policy_ref`: 指向配额合同文档。

### 4.2 `phases[]` 主干字段（兼容）
- 保持当前 schema 要求，确保可降级可迁移。

### 4.3 `phases[]` 扩展字段（新核心严格模式）
- `x_release_lane`: 发布阻断车道（固定 `NC_RELEASE_HARD`）。
- `x_observe_lane`: 兼容观察车道（固定 `LEGACY_COMPAT_SOFT`）。
- `x_test_quota`: 每 phase 的测试配额合同。
- `x_stop_conditions`: 强制阻断条件。
- `x_rollback_policy`: 批次失败回退协议。
- `x_artifact_contract`: 必交证据产物列表。
- `x_signoff_rules`（可选）：签收要求与审批级别。

## 5. Phase 分组模板（草案）

### Group A: 基础确定性（Phase 0-4）
- 核心目标：工具链锁、纯函数、重放一致。
- 强制重点：
  - 任何 nondeterministic 输出直接失败。
  - 合同验证失败不允许打 tag。

### Group B: 质量与系统闭环（Phase 5-7）
- 核心目标：质量门禁、协议一致、并发安全。
- 强制重点：
  - `Placeholder/TODO/fatalError` 关键路径清零。
  - 上传协议、哈希验证、限流幂等等价性通过。

### Group C: 纯视觉与端侧强化（Phase 8-12）
- 核心目标：首扫成功率、性能稳定、真实性保持。
- 强制重点：
  - KPI 必须来自真实回放，不接受文本自证。
  - 热控/内存/延迟门限 fail-closed。

### Group D: 总编排与发布收口（Phase 13）
- 核心目标：E2E 全闭环、审计链完备、最终签收。
- 强制重点：
  - 场景 A/B/C/D 全绿。
  - 首锚/周期锚/尾锚完整。
  - 双通道上传终态策略符合合同。

## 6. Phase 级签收模板（草案）

```jsonc
{
  "phase_id": 13,
  "hard_gates_passed": true,
  "quota_met": true,
  "artifacts_complete": true,
  "replay_reproducible": true,
  "top_failures": [],
  "signoff": {
    "eligible_for_tag": true,
    "tag_name": "phase-13-pass",
    "approvers_required": 2
  }
}
```

## 7. 严格执行规则（草案）
- `Rule-PP-1`: `required_gate_ids` 中任一失败 => phase 状态强制 `blocked`。
- `Rule-PP-2`: `x_test_quota` 任一项不足 => phase 状态强制 `blocked`。
- `Rule-PP-3`: `x_artifact_contract` 缺项 => phase 状态强制 `blocked`。
- `Rule-PP-4`: `x_rollback_policy.max_forward_without_full_sweep = 0` 不可放宽。
- `Rule-PP-5`: phase 前进必须附带 `gate_run_manifest` 哈希摘要。

## 8. 两个关键 phase 的结构示例

### 8.1 Phase 5（草案）
- `x_test_quota.total_min = 3500`
- 必带 gate：
  - `NC-G-031`（质量/拓扑）
  - `NC-G-043`（上传哈希/协议）
  - `NC-G-901`（全量收口）

### 8.2 Phase 13（草案）
- `x_test_quota.total_min = 5000`
- 必带 gate：
  - `NC-G-041`（审计锚）
  - `NC-G-061`（首扫 KPI 回放）
  - `NC-G-064`（E2E smoke）
  - `NC-G-901`（全量收口）

## 9. 迁移策略（计划书级）
- Step 1: 基于本草案生成 `phase_plan_new_core.json` 评审版（仅文档，不执行）。
- Step 2: 做“旧 phase -> 新 phase”字段映射报告。
- Step 3: 影子运行验证签收模板与产物齐全性。
- Step 4: 确认后再进入 runner 适配。

## 10. 非目标（明确）
- 不修改现有 `phase_plan.json`。
- 不修改执行脚本。
- 不触发 CI 行为改变。

