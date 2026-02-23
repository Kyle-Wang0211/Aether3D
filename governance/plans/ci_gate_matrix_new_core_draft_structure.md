# Draft Structure: `ci_gate_matrix_new_core.json` (Design Only)

## 1. 目标
- 定义“新核心层专用 gate matrix”的 JSON 结构草案。
- 与历史 PR 测试彻底解耦，保留双车道：
  - `NC_RELEASE_HARD`（阻断）
  - `LEGACY_COMPAT_SOFT`（观察）
- 本文档仅为结构设计，不创建、不启用实际 JSON 配置文件。

## 2. 兼容基线
- 当前运行器基于 `gate_matrix.schema.json` 的最小字段：
  - `metadata.matrix_version`
  - `metadata.last_updated`
  - `gates[].id/name/severity/commands/artifacts`
- 新草案采用“可前向扩展”模式：
  - 核心兼容字段保留不变。
  - 扩展字段通过 `x_*` 前缀或独立 section 声明。
  - 迁移时可先降级导出为旧 schema 兼容子集。

## 3. 结构草案（目标形态）

```jsonc
{
  "metadata": {
    "matrix_version": "2.0.0-draft",
    "last_updated": "2026-02-17",
    "source": "governance/plans/ci_gate_matrix_new_core_draft_structure.md",
    "scope": "new_core_only",
    "toolchain_pin": {
      "swift": "6.2.3",
      "python": "3.10+"
    },
    "lane_policy": {
      "hard_lane": "NC_RELEASE_HARD",
      "soft_lane": "LEGACY_COMPAT_SOFT",
      "hard_lane_blocking": true,
      "soft_lane_blocking": false
    },
    "quota_policy_ref": "new_core_phase_gate_contract_v1.md#3-phase-合同矩阵",
    "x_notes": "draft only"
  },
  "gates": [
    {
      "id": "NC-G-011",
      "name": "New core strict build clean",
      "severity": "error",
      "commands": [
        "swift build"
      ],
      "artifacts": [
        "governance/generated/nc/build_manifest.json"
      ],
      "x_lane": "NC_RELEASE_HARD",
      "x_layer": "L1",
      "x_phase_scope": [0,1,2,3,4,5,6,7,8,9,10,11,12,13],
      "x_mode": "both",
      "x_timeout_sec": 1800,
      "x_retry": 0,
      "x_owner": "core",
      "x_tags": ["determinism", "concurrency", "compile"],
      "x_preconditions": ["NC-G-001"],
      "x_postconditions": ["NC-G-014"],
      "x_fail_class": "hard_block"
    }
  ],
  "profiles": {
    "fast": {
      "description": "每批迁移的快速阻断面",
      "required_layers": ["L0", "L1", "L2", "L4"]
    },
    "deep": {
      "description": "夜间深度回归面",
      "required_layers": ["L0", "L1", "L2", "L3", "L4", "L5", "L6"]
    },
    "full_sweep": {
      "description": "phase 收口前全量覆盖",
      "required_layers": ["L0", "L1", "L2", "L3", "L4", "L5", "L6"]
    }
  },
  "lane_bindings": {
    "NC_RELEASE_HARD": {
      "allow_gate_id_prefixes": ["NC-G-"],
      "deny_patterns": ["PR4", "PR5CaptureTests", "PR[0-9]+"]
    },
    "LEGACY_COMPAT_SOFT": {
      "allow_gate_id_prefixes": ["LG-G-", "LEGACY-"],
      "report_only": true
    }
  }
}
```

## 4. 字段定义（草案）

### 4.1 `metadata`
- `matrix_version`: 字符串版本号。
- `last_updated`: 日期。
- `scope`: 固定 `new_core_only`。
- `toolchain_pin`: 新核心硬锁工具链。
- `lane_policy`: 双车道阻断语义。
- `quota_policy_ref`: 指向 phase 配额合同文档。

### 4.2 `gates[]`（兼容 + 扩展）
- 兼容字段：
  - `id`, `name`, `severity`, `commands`, `artifacts`
- 扩展字段：
  - `x_lane`: `NC_RELEASE_HARD` / `LEGACY_COMPAT_SOFT`
  - `x_layer`: `L0`..`L6`
  - `x_phase_scope`: gate 适用 phase 列表
  - `x_mode`: `fast` / `deep` / `both`
  - `x_timeout_sec`, `x_retry`
  - `x_owner`, `x_tags`
  - `x_preconditions`, `x_postconditions`
  - `x_fail_class`: `hard_block` / `soft_observe`

### 4.3 `profiles`
- `fast`: 小批迁移必跑，追求快速阻断。
- `deep`: 深度验证，覆盖 fuzz/soak/adversarial。
- `full_sweep`: phase 收口准入。

### 4.4 `lane_bindings`
- 负责“命令级去耦”规则：
  - 硬车道禁止历史 PR 命名目标。
  - 软车道仅观测不阻断。

## 5. Gate 分层命名规范
- `NC-G-00x`: 工具链/环境锁
- `NC-G-01x`: 静态语义/并发安全
- `NC-G-02x`: 确定性/可重放
- `NC-G-03x`: 几何真实性/证据完备
- `NC-G-04x`: 安全/合规/审计
- `NC-G-05x`: 性能/热/内存
- `NC-G-06x`: 业务闭环/KPI
- `NC-G-90x`: 聚合 gate（full sweep、phase signoff）

## 6. 严格执行规则（草案）
- `Rule-CM-1`: `NC_RELEASE_HARD` 任一 gate fail => phase 阻断。
- `Rule-CM-2`: fast 通过但 deep 失败 => 不得推进批次。
- `Rule-CM-3`: 产物缺失 => 视同 gate fail。
- `Rule-CM-4`: 软车道永不改变阻断决策，但必须出报告。
- `Rule-CM-5`: `NC-G-90x` 不允许被 skip。

## 7. 最小 gate 集建议（MVP for new-core matrix）
- 基础治理：
  - `NC-G-001` Swift 6.2.3 pin
  - `NC-G-003` branch contract
  - `NC-G-011` strict build
- 新核心真实性：
  - `NC-G-021` replay bit-exact
  - `NC-G-031` non-manifold = 0
  - `NC-G-042` merkle verify = 100%
- 新核心业务：
  - `NC-G-061` first-scan runtime replay KPI
  - `NC-G-063` dual-lane upload policy
  - `NC-G-064` phase13 e2e smoke
- 收口：
  - `NC-G-901` new-core full sweep

## 8. 与现有 `G-*` 的过渡方式（草案）
- 先并行：`G-*` 与 `NC-G-*` 同时运行 2 周。
- 再切换：阻断来源改为 `NC-G-*`，`G-*` 退为观察。
- 切换条件：
  - `NC_RELEASE_HARD` 连续 14 天通过率 >= 99%。

## 9. 产物合同（草案）
- 每个 gate 必须写入：
  - `governance/generated/nc/gate_run_manifest.json`
  - `governance/generated/nc/<gate-id>/...`
- `full_sweep` 必须包含：
  - gate 执行列表
  - pass/fail 摘要
  - 失败根因 Top-K

## 10. 非目标（明确）
- 本草案不触发：
  - 任何 CI workflow 变更
  - 任何 runner 脚本变更
  - 任何业务代码变更

