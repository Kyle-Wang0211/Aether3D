# New Core Draft Field -> Existing Script Param Mapping v1 (Design Only)

## 1. 目标
- 给两个新核心草案补一份“字段到现有脚本参数/行为”的映射表。
- 明确哪些字段可以直接落地，哪些需要适配层。
- 本文档仅做实施对照，不触发代码执行变更。

## 2. 现有可复用脚本与参数

| 脚本 | 现有参数 | 当前固定输入 |
|---|---|---|
| `governance/scripts/run_gate_matrix.py` | `--phase-id`, `--full-sweep`, `--min-severity`, `--skip-gate-id`, `--dry-run` | `governance/ci_gate_matrix.json`, `governance/phase_plan.json` |
| `governance/scripts/validate_governance.py` | `--strict`, `--report`, `--only`, `--check-branch` | `governance/contract_registry.json`, `governance/phase_plan.json`, `governance/ci_gate_matrix.json`, `governance/code_bindings.json`, `governance/structural_checks.json` |
| `governance/scripts/generate_cursor_runbooks.py` | `--output`, `--check` | 同上（读取 `phase_plan.json` 与 `ci_gate_matrix.json`） |
| `governance/scripts/generate_code_bindings.py` | `--registry`, `--output`, `--check` | 默认读 `governance/contract_registry.json` |
| `governance/scripts/eval_first_scan_runtime_kpi.py` | 无 CLI 参数 | 固定读 registry + fixture，输出 `governance/generated/first_scan_runtime_metrics.json` |

## 3. 草案一映射：`ci_gate_matrix_new_core` 字段

| 草案字段 | 对应现有参数/行为 | 映射状态 | 一次性实施建议 |
|---|---|---|---|
| `metadata.matrix_version` | 无 CLI；仅 JSON 自身字段 | 部分支持 | 保留为元数据；若要强校验，新增 schema gate 或在 `validate_governance --only registry` 增加版本断言 |
| `metadata.last_updated` | 无 CLI；仅 JSON 自身字段 | 部分支持 | 同上 |
| `metadata.scope` | 无 | 未支持 | 由适配层在导出时检查必须为 `new_core_only` |
| `metadata.toolchain_pin.swift` | 无直接参数；可通过 gate `commands[]` 调脚本校验 | 间接支持 | 映射到某个硬 gate 命令（例如 pin 校验脚本） |
| `metadata.toolchain_pin.python` | 无直接参数 | 间接支持 | 同上，作为 gate 命令前置检查 |
| `metadata.lane_policy.*` | 无 | 未支持 | 由适配层决定导出硬车道或软车道 gate 集 |
| `metadata.quota_policy_ref` | 无 | 未支持 | 保留为文档引用；实际配额由 phase 侧脚本补充校验 |
| `gates[].id` | `run_gate_matrix` 选择与执行 gate 的主键 | 直接支持 | 可直接使用；若未来启用现有 schema，需把 `NC-G-*` 适配为 `G-NC-*` 或放宽 schema |
| `gates[].name` | `run_gate_matrix` 输出，`generate_cursor_runbooks` 展示 | 直接支持 | 无需适配 |
| `gates[].severity` | `run_gate_matrix --min-severity` 过滤 | 直接支持 | 无需适配 |
| `gates[].commands[]` | `run_gate_matrix` 顺序执行 | 直接支持 | 无需适配 |
| `gates[].artifacts[]` | 仅 runbook 展示；当前 runner 不检查产物存在性 | 部分支持 | 加一个“产物核验 gate”命令，或新增 artifact verifier 适配脚本 |
| `gates[].x_lane` | 无 | 未支持 | 适配层按 lane 过滤后导出到 `ci_gate_matrix.json` |
| `gates[].x_layer` | 无 | 未支持 | 适配层按层级组装 `fast/deep/full` 运行清单 |
| `gates[].x_phase_scope` | 无 | 未支持 | 适配层在按 phase 导出时裁剪 gate |
| `gates[].x_mode` | 无 | 未支持 | 适配层映射到 profile（fast/deep） |
| `gates[].x_timeout_sec` | 无 | 未支持 | 适配层可包装为 `timeout` 命令前缀 |
| `gates[].x_retry` | 无 | 未支持 | 适配层做重试包装（runner 本体目前不支持） |
| `gates[].x_owner` / `x_tags` | 无 | 未支持 | 报告层字段，不影响执行 |
| `gates[].x_preconditions` / `x_postconditions` | 无 | 未支持 | 适配层在执行前后做 DAG 校验 |
| `gates[].x_fail_class` | 无 | 未支持 | 适配层决定 hard block / soft observe 处理 |
| `profiles.fast` | 无 profile 参数；可用 `--phase-id` + `--min-severity error` 近似 | 间接支持 | 通过 wrapper 预解析 profile 后调用 `run_gate_matrix` |
| `profiles.deep` | 无 profile 参数；可用 `--phase-id` + `--min-severity warning` 近似 | 间接支持 | 同上 |
| `profiles.full_sweep` | `run_gate_matrix --full-sweep` | 直接支持 | 无需适配 |
| `lane_bindings.*` | 无 | 未支持 | 适配层在导出阶段执行 allow/deny 规则 |

## 4. 草案二映射：`phase_plan_new_core` 字段

| 草案字段 | 对应现有参数/行为 | 映射状态 | 一次性实施建议 |
|---|---|---|---|
| `metadata.plan_version` | 无 CLI；JSON 字段 | 部分支持 | 保留元数据；如需硬校验可扩展 `validate_governance --only phase-order` |
| `metadata.last_updated` | 无 CLI；JSON 字段 | 部分支持 | 同上 |
| `metadata.source` | `generate_cursor_runbooks` 索引会引用来源语义（间接） | 间接支持 | 保留 |
| `metadata.phase_id_span.min/max` | `validate_governance --only phase-order` 会强校验连续性 | 直接支持 | 无需适配 |
| `metadata.scope` | 无 | 未支持 | 适配层预检为 `new_core_only` |
| `metadata.execution_contract` | 无 | 未支持 | 适配层执行前断言 `strict_no_skip` |
| `metadata.x_lane_policy` | 无 | 未支持 | 适配层用于 lane 解析 |
| `metadata.x_quota_policy_ref` | 无 | 未支持 | 作为报告引用；配额校验由独立脚本承接 |
| `phases[].id` | `run_gate_matrix --phase-id` 选择 phase；runbook 按 id 排序 | 直接支持 | 无需适配 |
| `phases[].name` | `generate_cursor_runbooks` 展示 | 直接支持 | 无需适配 |
| `phases[].track` | runbook 展示；`validate_governance` 注册关系检查 | 直接支持 | 无需适配 |
| `phases[].objective` | runbook 展示 | 直接支持 | 无需适配 |
| `phases[].prerequisite_phase_ids` | `validate_governance --only phase-order` 校验 | 直接支持 | 无需适配 |
| `phases[].required_contract_ids` | `validate_governance --only registry` 校验 | 直接支持 | 无需适配 |
| `phases[].required_gate_ids` | `run_gate_matrix --phase-id` 读取执行；`validate_governance --only registry` 校验存在性 | 直接支持 | 无需适配（同样注意 `NC-G-*` 与现 schema 正则兼容问题） |
| `phases[].deliverables` | runbook 展示；当前无自动“文件存在”阻断 | 部分支持 | 增加 deliverable verifier gate |
| `phases[].cursor_steps` | runbook 展示；`validate_governance --only dual-lane-upload` 会对 Phase 8/13 关键文案做正则断言 | 部分支持 | 保留，并尽量结构化为可机读字段 |
| `phases[].x_release_lane` | 无 | 未支持 | 适配层用于选择硬车道 gate |
| `phases[].x_observe_lane` | 无 | 未支持 | 适配层用于选择软车道 gate |
| `phases[].x_test_quota.*` | 无通用参数；当前只有 `eval_first_scan_runtime_kpi.py` 做单项 KPI 报告 | 未支持 | 新增 quota evaluator 脚本并放入 gate commands |
| `phases[].x_stop_conditions[]` | 无 | 未支持 | 适配层执行阶段机逻辑 |
| `phases[].x_rollback_policy.*` | 无 | 未支持 | 适配层或 runbook 执行器承担 |
| `phases[].x_artifact_contract[]` | 无通用参数 | 未支持 | 新增 artifact manifest checker 脚本并作为硬 gate |
| `phases[].x_signoff_rules` | 无 | 未支持 | 由签收脚本读取并产出 signoff JSON |

## 5. Profile 到现有命令模板映射（可直接用）

| 目标 profile | 现有命令模板 | 说明 |
|---|---|---|
| `fast` | `python3 governance/scripts/run_gate_matrix.py --phase-id <N> --min-severity error` | 快速阻断面，按 phase 执行 error gate |
| `deep` | `python3 governance/scripts/run_gate_matrix.py --phase-id <N> --min-severity warning` | 深度面，包含 warning+error |
| `full_sweep` | `python3 governance/scripts/run_gate_matrix.py --full-sweep --min-severity warning --skip-gate-id G-FULL-GATE-SWEEP` | 全量扫面；与现有执行习惯对齐 |
| 严格收口 | `python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json` | 最终阻断判断 |
| 纯视觉 KPI | `python3 governance/scripts/eval_first_scan_runtime_kpi.py` | 产出运行时 KPI 报告供 validator 读取 |

## 6. 一次性实施最小适配层（仅计划）

| 适配层 | 输入字段 | 输出到现有脚本 | 目的 |
|---|---|---|---|
| `nc_matrix_exporter` | `ci_gate_matrix_new_core` + `lane/profile` | 导出兼容版 `ci_gate_matrix.json` | 让 `run_gate_matrix.py` 直接可跑 |
| `nc_phase_exporter` | `phase_plan_new_core` | 导出兼容版 `phase_plan.json` | 让 `run_gate_matrix.py` / `generate_cursor_runbooks.py` 无改动复用 |
| `artifact_verifier` | `gates[].artifacts`, `x_artifact_contract` | 作为 gate `commands[]` 子命令 | 把“仅展示”升级为“可阻断” |
| `quota_verifier` | `x_test_quota` | 作为 gate `commands[]` 子命令 | 把测试配额升级为运行时硬门禁 |

## 7. 结论
- 现有脚本能直接承载“主干字段执行”（gate id/severity/commands/phase-required gates）。
- 新核心扩展字段（lane/layer/quota/rollback/artifact contract）当前都需要适配层，不是现有 CLI 参数可直接表达。
- 采用“导出兼容 JSON + 附加 verifier gate”即可在不重写主 runner 的前提下一次性实施。
