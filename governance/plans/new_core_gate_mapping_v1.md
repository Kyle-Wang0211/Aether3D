# New Core Gate Mapping v1 (Current Gates -> NC Lanes)

## 1. 目的
- 把当前 `ci_gate_matrix.json` 的 gate 逐条映射到新核心双车道：
  - `NC_RELEASE_HARD` (发布阻断)
  - `LEGACY_COMPAT_SOFT` (兼容观察)
- 映射结果只用于计划，不改现有执行配置。

## 2. 映射总规则
- 规则 A：直接验证新核心契约/审计/KPI 的 gate -> `NC_RELEASE_HARD`
- 规则 B：依赖历史 `PR*` 命名目标、或与新核心边界不直接相关 -> `LEGACY_COMPAT_SOFT`
- 规则 C：混合 gate -> 拆分为 `NC-fast` 与 `legacy-deep` 两条

## 3. 逐条映射

| Current Gate | Current Role | New Lane | NC Replacement | 处理策略 |
|---|---|---|---|---|
| `G-LONG-LIVED-BRANCH` | 分支治理 | NC_RELEASE_HARD | `NC-G-003` | 保留，直接迁移 |
| `G-PHASE-ORDER` | Phase 顺序 | NC_RELEASE_HARD | `NC-G-101` | 保留，直接迁移 |
| `G-CONTRACT-VALIDATOR` | SSOT 验证 | NC_RELEASE_HARD | `NC-G-011` | 保留，直接迁移 |
| `G-AUDIT-ANCHOR-CLIENT-FIRST` | 审计锚策略 | NC_RELEASE_HARD | `NC-G-041` | 保留，直接迁移 |
| `G-RUNBOOK-GENERATION` | Runbook 确定性 | NC_RELEASE_HARD | `NC-G-012` | 保留，直接迁移 |
| `G-FIXTURE-BASELINE` | 金样本基线 | NC_RELEASE_HARD | `NC-G-021` | 保留但拆出 legacy fixture 子集 |
| `G-SWIFT-BUILD` | 全量编译 | Split | `NC-G-011A` + `LEGACY-BUILD-OBS` | 新核心目标硬阻断；旧目标观察 |
| `G-BLUR-CONSTANT-DRIFT` | 质量常量漂移 | NC_RELEASE_HARD | `NC-G-031` | 保留，直接迁移 |
| `G-SCAN-GUIDANCE-INTEGRATION` | 扫描引导 | Split | `NC-G-032` + `LEGACY-SCAN-OBS` | 新核心引导硬阻断；历史 UI 路径观察 |
| `G-UPLOAD-CHUNK-HASH` | 上传哈希契约 | NC_RELEASE_HARD | `NC-G-043` | 保留，直接迁移 |
| `G-P0-QUALITY-IMPLEMENTATION` | P0 占位路径清零 | NC_RELEASE_HARD | `NC-G-013` | 保留，直接迁移 |
| `G-UPLOAD-CONTRACT-CONSISTENCY` | 上传协议一致性 | NC_RELEASE_HARD | `NC-G-044` | 保留，直接迁移 |
| `G-PURE-VISION-RUNTIME-FIXTURE` | 纯视觉 runtime | NC_RELEASE_HARD | `NC-G-061` | 保留，直接迁移 |
| `G-FIRST-SCAN-SUCCESS-KPI` | 首扫 KPI | NC_RELEASE_HARD | `NC-G-062` | 保留，直接迁移 |
| `G-DUAL-LANE-UPLOAD-POLICY` | 双通道上传策略 | NC_RELEASE_HARD | `NC-G-063` | 保留，直接迁移 |
| `G-FLAG-DEFAULT-OFF` | Track X 默认关 | NC_RELEASE_HARD | `NC-G-014` | 保留，直接迁移 |
| `G-FLAG-NAMESPACE` | flag 命名空间 | NC_RELEASE_HARD | `NC-G-015` | warning -> error |
| `G-DOC-SECTION-ORDER` | 文档层序 | NC_RELEASE_HARD | `NC-G-102` | 保留，直接迁移 |
| `G-FULL-GATE-SWEEP` | 全量扫描 | Split | `NC-G-901` + `LEGACY-SWEEP-OBS` | 发布只看 NC 全扫，legacy 单独报告 |
| `G-PHASE13-E2E-SMOKE` | Phase13 烟测 | Split | `NC-G-064` + `LEGACY-E2E-OBS` | 新核心闭环硬阻断，旧链路观察 |

## 4. 特别说明：历史 PR 测试集
- 下列集合默认归入 `LEGACY_COMPAT_SOFT`，不允许直接进入 `NC_RELEASE_HARD`：
  - `PR4*`
  - `PR5CaptureTests`
  - 任何以历史实现阶段命名的测试目标
- 如需纳入 `NC_RELEASE_HARD`，必须先完成“去历史耦合重命名 + 新核心契约重验”。

## 5. 迁移里程碑 (计划)
- M1: 完成 gate 分类与 ID 对照（本文件）。
- M2: 输出 `ci_gate_matrix_new_core.json` 草稿（仅 NC gates）。
- M3: 影子运行 2 周，比较 `NC_RELEASE_HARD` 与当前矩阵差异。
- M4: 影子期后切换发布阻断来源为 NC。

## 6. 切换准入条件
- 连续 14 天：`NC_RELEASE_HARD` 日跑通过率 >= 99%。
- 所有 Phase 的 `NC` 必需产物齐全且可复验。
- 兼容车道失败不影响发布，但必须纳入清债路线图。

