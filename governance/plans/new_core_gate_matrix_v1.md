# New Core Gate Matrix v1 (Plan-Only, Decoupled from Legacy PR Tests)

## 0. 计划边界
- 这是“计划书”，不修改任何业务实现代码，不激活任何新 gate 执行脚本。
- 目标是定义一套“新核心层专用”门禁矩阵，和历史 `PR4* / PR5*` 测试彻底解耦。
- 历史测试仍保留，但降级到兼容性观察车道，不作为新核心发布阻断项。

## 1. 总体目标
- `唯一发布阻断来源`：新核心层专用矩阵 `NC-*`。
- `唯一真实性标准`：确定性、可重放、可审计、可量化误差。
- `唯一性能标准`：在稳定与安全约束下最大化性能，不允许以破坏证据真实性换吞吐。
- `唯一节奏标准`：每一小批迁移都要全量硬门禁通过后才能进入下一批。

## 2. 解耦策略 (硬规则)

### 2.1 双车道
- `Lane A: NC_RELEASE_HARD` (阻断车道)
  - 只运行 `NC-*` gate。
  - 决定是否允许 Phase 前进、打 tag、进入下一批迁移。
- `Lane B: LEGACY_COMPAT_SOFT` (观察车道)
  - 运行历史 `PR*`/遗留测试，产出告警与趋势。
  - 不阻断 `NC_RELEASE_HARD`，但会生成技术债台账。

### 2.2 命令级隔离
- `NC_RELEASE_HARD` 的 gate 命令禁止出现以下 filter/target：
  - `PR4`
  - `PR5CaptureTests`
  - 其他 `PR*` 历史命名测试目标
- `NC_RELEASE_HARD` 只允许调用“新核心域”测试目标/脚本：
  - `TSDF`
  - `Evidence`
  - `Merkle`
  - `TimeAnchoring`
  - `QualityPreCheck`
  - `ScanGuidance`
  - `Pipeline`
  - `Gates`
  - `server/tests` 中新核心契约相关子集

### 2.3 失败处理策略
- `Lane A` 任一 gate 失败 = 立即阻断，禁止开始下一批。
- `Lane B` 失败不阻断，但必须登记到 `legacy_debt_register` 并在后续批次清偿。

## 3. 新核心专用 Gate 分层

### Layer 0: 环境与工具链硬锁 (NC-G-00x)
- `NC-G-001` Swift 版本硬锁：`6.2.3` 全入口一致。
- `NC-G-002` 依赖锁完整性：`toolchain.lock` + 关键依赖签名。
- `NC-G-003` 分支策略：必须在长期集成分支执行。
- 失败级别：`error`。

### Layer 1: 静态语义与并发安全 (NC-G-01x)
- `NC-G-011` 新核心目标 `swift build` 全通过。
- `NC-G-012` strict concurrency 违规为 0（新核心域）。
- `NC-G-013` `fatalError/TODO/Placeholder` 在关键路径为 0（Quality/Evidence/TimeAnchoring/Merkle）。
- `NC-G-014` 命名空间一致性与常量绑定完整性（`all_active_constants`）。
- 失败级别：`error`。

### Layer 2: 确定性与可重放 (NC-G-02x)
- `NC-G-021` bit-exact 回放一致率：`100%`。
- `NC-G-022` 同输入多次运行哈希一致：`N=20` 全一致。
- `NC-G-023` 时间注入纯函数约束：核心策略函数禁止读取系统时钟。
- `NC-G-024` 浮点稳定性：跨后端余弦一致门限满足合同阈值。
- 失败级别：`error`。

### Layer 3: 几何真实性与证据完备 (NC-G-03x)
- `NC-G-031` TSDF/MC 拓扑健康：非流形计数 `= 0`。
- `NC-G-032` `closure_ratio` 合同门限达标，且诚实报告路径完整。
- `NC-G-033` Evidence 三态场与 S-tier 路径无非法跳转。
- `NC-G-034` 体积估计输出区间合法：`V_min <= V_max`，未知体素上限受控。
- 失败级别：`error`。

### Layer 4: 安全、合规、审计链 (NC-G-04x)
- `NC-G-041` RFC3161 客户端优先策略：会话首/尾强制锚 + 周期锚。
- `NC-G-042` Merkle 链可验证率：`100%`。
- `NC-G-043` 鉴权/限流/幂等等价性：重放与并发下行为一致。
- `NC-G-044` 内容合规审查 fail-closed：模型/规则不确定时阻断传播链路。
- 失败级别：`error`。

### Layer 5: 性能、热控、内存、稳定性 (NC-G-05x)
- `NC-G-051` 首扫时延预算：2-3 分钟目标窗内 KPI 达标。
- `NC-G-052` CT-VIO / FrameGate 延迟门限达标（p95/p99）。
- `NC-G-053` 内存峰值与热状态约束达标，critical = 0 容忍。
- `NC-G-054` 端侧负载优先策略：可下沉任务未越权上云。
- 失败级别：`error`。

### Layer 6: 端到端业务门禁 (NC-G-06x)
- `NC-G-061` 首扫成功率 KPI 合规（真实回放，不是文本合规）。
- `NC-G-062` 失败原因可分解且复现实验可重现。
- `NC-G-063` 双通道上传策略一致：
  - 在线通道只推满足门禁素材触发优先渲染。
  - 会话收尾全量接纳剩余素材（S0-S5）用于最终完整渲染。
- `NC-G-064` 云端仅保留最终 S5 优化/渲染与法证归档，不承接可端侧完成步骤。
- 失败级别：`error`。

## 4. 测试类型矩阵 (最严格版)

### 4.1 测试类型
- `Deterministic`: 金样本与 bit-exact 重放。
- `Property`: 不变量与边界约束。
- `Metamorphic`: 输入变换后关系保持。
- `Fuzz`: 结构化随机输入与异常路径。
- `Adversarial`: 对抗样本、恶意请求、审计绕过尝试。
- `Soak/Stress`: 长时、热、内存、并发冲击。
- `E2E Replay`: 真实会话回放 + 指标复算。

### 4.2 最低配额 (每批迁移必须满足)
- 单批最小测试总数：`>= 3000`
- 其中：
  - Deterministic: `>= 800`
  - Property: `>= 600`
  - Metamorphic: `>= 400`
  - Fuzz: `>= 600`
  - Adversarial: `>= 300`
  - Soak/Stress: `>= 100`
  - E2E Replay: `>= 200`
- 不允许“只跑快测”进入下一批。

### 4.3 随机性控制
- 所有 fuzz/metamorphic 必须记录种子。
- 失败样本必须固化为回归 fixture，进入下批必跑集合。
- 同一批门禁至少执行两轮不同 seed 集。

## 5. Phase 对应最小门禁集

### Phase 5 (质量与系统闭环)
- 必过层：L0, L1, L2, L3, L4, L6。
- 最低测试配额：`>= 3500`。
- 强制关注：
  - Scan guidance 单调性与 UI-证据绑定一致性。
  - 上传 hash 校验与协议一致性。
  - 无 Placeholder/fatalError 逃逸路径。

### Phase 13 (流式+总编排)
- 必过层：L0~L6 全部。
- 最低测试配额：`>= 5000`。
- 强制关注：
  - E2E 场景 A/B/C/D 全绿。
  - 审计链起止锚与周期锚完整。
  - 会话终态全量接纳策略与最终渲染一致。

## 6. 新核心发布阻断规则
- `Rule-NC-1`: 任一 `NC-*` gate 失败，禁止打 `phase-*-pass`。
- `Rule-NC-2`: 未达到测试配额，视同失败。
- `Rule-NC-3`: 缺少审计产物（日志、哈希、指标 JSON），视同失败。
- `Rule-NC-4`: 未完成失败原因分解（Top-K）与复现链接，视同失败。
- `Rule-NC-5`: 未通过全量 `NC` sweep，不允许进入下一批。

## 7. 产物与审计格式 (必须)
- `gate_run_manifest.json`
  - gate id
  - commit sha
  - toolchain versions
  - test counts by type
  - pass/fail
  - artifact hashes
- `first_scan_runtime_metrics.json`
  - 成功率
  - 分桶失败原因
  - 时延分位
  - 重放一致率
- `audit_chain_report.json`
  - 会话起始锚
  - 周期锚序列
  - 会话结束锚
  - Merkle root 与证明

## 8. 与现有矩阵的迁移计划 (计划书级, 不执行)
- Step 1: 新建 `ci_gate_matrix_new_core.json` 设计稿（仅计划，不接入 runner）。
- Step 2: 新建 `phase_plan_new_core.json` 设计稿（仅计划，不覆盖现有）。
- Step 3: 对现有 gate 建立映射表：
  - `retain as NC`
  - `move to legacy soft lane`
  - `split into fast/deep`
- Step 4: 先影子运行 2 周：
  - 新旧矩阵并行
  - 仅 NC 矩阵决定前进
- Step 5: 影子期结束后，冻结旧阻断矩阵，旧矩阵只保留兼容观测职责。

## 9. 现阶段立即可执行的“计划动作”
- 在不改代码前提下，先完成三份文档：
  - `new_core_gate_matrix_v1.md`（本文件）
  - `new_core_gate_mapping_v1.md`（旧 gate 到 NC gate 的映射）
  - `new_core_phase_gate_contract_v1.md`（Phase × Gate × Artifact 合同）
- 然后再进入你批准后的“配置文件改造批次”。

## 10. 验收标准 (本计划书)
- 覆盖 0-13 所有 phase。
- 明确双车道解耦规则和失败阻断规则。
- 明确测试类型和最低配额，不允许口头化验收。
- 明确审计产物格式，支持复现与追责。

