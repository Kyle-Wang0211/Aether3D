# CURSOR 指令：更新 PR5 v1.3.2 Plan 文档

## 你的任务

将补充文档 `PR5_PATCH_V1_4_SUPPLEMENT.md` 的内容整合到现有的 plan 文档中。

## 文件位置

1. **现有 Plan 文档（需要更新）**：
   `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md`

2. **补充文档（新内容来源）**：
   `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_4_SUPPLEMENT.md`

---

## 操作步骤

### 第一步：阅读两个文档

1. 完整阅读现有的 `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md`
2. 完整阅读补充文档 `PR5_PATCH_V1_4_SUPPLEMENT.md`（约 5,900 行）

### 第二步：应用勘误修正

补充文档包含 3 个必须应用到 v1.3.2 的勘误：

```
勘误 1：Stage 编号重复
- 找到 STAGE K-007 出现两次的地方 → 将第二个重命名为 STAGE K-007b
- 找到 STAGE L-003 冲突的地方 → 重命名为 STAGE L-003-PERF

勘误 2：配置运行时调整 vs 跨平台确定性冲突
- 在允许运行时配置调整的部分：添加说明"运行时调整仅影响非确定性路径（UI、日志）"
- 在跨平台确定性部分：添加说明"确定性路径（质量计算、锚点验证）使用冻结的配置快照"
- 添加新小节解释可调整配置和冻结配置的边界

勘误 3：崩溃注入覆盖率定义
- 找到测试部分的"100% 覆盖率"声明
- 替换为："100% 的关键路径（代码中标记 @CriticalPath）必须有崩溃注入测试。
  非关键路径要求最低 80% 覆盖率。"
```

### 第三步：更新文档头部

将版本更新为 v1.4.0：

```markdown
# PR5 v1.4.0 Complete Hardening Patch 完整实现计划

## 概述

本计划实现 PR5 Capture Optimization v1.4.0 Complete Hardening Patch，解决 **220 个生产级关键漏洞**
（v1.2: 60个 + v1.3: 52个 + v1.3.2: 108个原有 + v1.4补充: 112个新增 = 220个去重后总计），
涵盖从传感器到云端的完整捕获管道。

## 版本演进

- **v1.2**: 基础加固（60个漏洞）
  - PART 0-11: 传感器、状态机、帧处理、质量、动态、纹理、曝光、隐私、审计、平台、性能、测试

- **v1.3**: 生产验证加固（52个新漏洞）
  - PART A-R: Raw溯源、时间戳、状态机增强、帧处理、质量指标、动态场景等

- **v1.4**: 高级安全加固（112个新漏洞）← 新增
  - PART S: 云端决策镜像与账本验证
  - PART T: 远程证明/设备完整性
  - PART U: 网络协议精确一次语义
  - PART V: 配置治理管道（Kill Switch）
  - PART W: 租户隔离 + 数据驻留
  - PART X: 操作系统事件中断管理
  - PART Y: 活体证明与防重放
  - PART Z: 误差预算账本（量化稳定性）
  - PART AA: 生产 SLO 规范与自动缓解
  - PART AB: 引导预算管理器
```

### 第四步：添加极端值参考表

在配置部分之后插入以下极端值表（用于 lab profile 压力测试）：

```markdown
## 极端值参考表（Lab Profile）

| 模块 | 参数 | Production | Debug | Lab (极端) |
|------|------|------------|-------|------------|
| S: 云端验证 | mirrorValidationTimeout | 30s | 60s | 5s |
| S: 云端验证 | ledgerConsistencyWindow | 1000ms | 5000ms | 100ms |
| T: 证明 | attestationRefreshInterval | 24h | 1h | 60s |
| T: 证明 | maxAttestationAge | 72h | 4h | 120s |
| U: 网络 | idempotencyKeyTTL | 24h | 1h | 60s |
| U: 网络 | maxRetryAttempts | 3 | 10 | 50 |
| U: 网络 | ackTimeoutMs | 5000 | 15000 | 500 |
| V: 配置 | canaryRolloutPercent | [1,5,25,50,100] | [50,100] | [100] |
| V: 配置 | rollbackTriggerErrorRate | 0.01 | 0.05 | 0.001 |
| V: 配置 | killSwitchPropagationMax | 60s | 300s | 5s |
| W: 租户 | crossBorderBlockEnabled | true | false | true |
| W: 租户 | encryptionKeyRotationInterval | 90d | 7d | 1h |
| X: 中断 | sessionRebuildTimeoutMs | 5000 | 15000 | 500 |
| X: 中断 | gpuResetDetectionThreshold | 3 | 10 | 1 |
| Y: 活体 | prnuSampleFrames | 10 | 5 | 30 |
| Y: 活体 | challengeResponseTimeoutMs | 3000 | 10000 | 500 |
| Z: 误差预算 | maxAccumulatedErrorULP | 1000 | 5000 | 100 |
| Z: 误差预算 | quantizationAuditFrequency | 1/100 | 1/10 | 1/1 |
| AA: SLO | errorBudgetBurnRateWindow | [1h,6h,24h] | [5m,1h] | [1m,5m,15m] |
| AA: SLO | circuitBreakerFailureThreshold | 5 | 20 | 2 |
| AB: 引导 | maxGuidancePerSession | 20 | 100 | 5 |
| AB: 引导 | fatigueDecayHalfLifeMs | 30000 | 5000 | 1000 |
```

### 第五步：追加新 PART（S 到 AB）

将补充文档中的以下内容完整追加到现有文档的末尾（在最终总结之前）：

1. **PART S: 云端决策镜像与账本验证** (STAGE S-001 到 S-008)
   - DecisionMirrorService.swift
   - LedgerVerifier.swift
   - AuditConsistencyChecker.swift
   - 相关测试

2. **PART T: 远程证明/设备完整性** (STAGE T-001 到 T-009)
   - RemoteAttestationManager.swift (iOS App Attest, Android Play Integrity)
   - AttestationPolicy.swift
   - 服务端验证器

3. **PART U: 网络协议精确一次语义** (STAGE U-001 到 U-007)
   - UploadProtocolStateMachine.swift
   - IdempotencyKeyPolicy.swift
   - ACKTracker.swift

4. **PART V: 配置治理管道** (STAGE V-001 到 V-007)
   - ConfigSignedManifest.swift
   - ConfigRolloutController.swift (金丝雀发布)
   - KillSwitchPolicy.swift

5. **PART W: 租户隔离 + 数据驻留** (STAGE W-001 到 W-006)
   - TenantIsolationPolicy.swift
   - RegionResidencyRouter.swift
   - GDPR/跨境合规

6. **PART X: 操作系统事件中断管理** (STAGE X-001 到 X-005)
   - InterruptionEventMachine.swift
   - CameraSessionRebuilder.swift
   - GPUResetDetector.swift

7. **PART Y: 活体证明与防重放** (STAGE Y-001 到 Y-005)
   - LivenessSignature.swift (PRNU 指纹)
   - VirtualCameraDetector.swift
   - 挑战-响应机制

8. **PART Z: 误差预算账本** (STAGE Z-001 到 Z-003)
   - QuantizedValue.swift (Q16.16 误差追踪)
   - SafeComparator.swift
   - ErrorBudgetManifest.swift

9. **PART AA: 生产 SLO 规范与自动缓解** (STAGE AA-001 到 AA-003)
   - ProductionSLOSpec.swift
   - AutoMitigationRules.swift
   - 多燃烧率告警

10. **PART AB: 引导预算管理器** (STAGE AB-001 到 AB-002)
    - GuidanceBudgetManager.swift
    - 用户疲劳模型

### 第六步：更新汇总表

更新文档末尾的汇总表：

```markdown
## 文件汇总

| PART | 文件数 | Stage 数 | 漏洞数 |
|------|--------|----------|--------|
| 原有 A-R | ~50+ | ~108 | 108 |
| S: 云端验证 | 8 | S-001 到 S-008 | 15 |
| T: 远程证明 | 9 | T-001 到 T-009 | 20 |
| U: 网络协议 | 7 | U-001 到 U-007 | 15 |
| V: 配置治理 | 7 | V-001 到 V-007 | 15 |
| W: 租户隔离 | 6 | W-001 到 W-006 | 12 |
| X: 中断管理 | 5 | X-001 到 X-005 | 10 |
| Y: 活体/防重放 | 5 | Y-001 到 Y-005 | 15 |
| Z: 误差预算 | 3 | Z-001 到 Z-003 | 10 |
| AA: SLO 自动化 | 3 | AA-001 到 AA-003 | 10 |
| AB: 引导预算 | 2 | AB-001 到 AB-002 | 10 |
| **总计** | **~105+** | **~163** | **220** |
```

---

## 质量检查清单

完成后验证：

- [ ] 勘误修正已应用（3 个修正）
- [ ] 版本已更新为 v1.4.0
- [ ] 10 个新 PART 已追加
- [ ] 汇总表已更新
- [ ] 无重复的 Stage 编号
- [ ] 极端值表已添加
- [ ] 5 个核心方法论在新模块中一致应用：
  - 三域隔离（感知 → 决策 → 账本）
  - 双锚点（Session Anchor + Segment Anchor）
  - 双阶段质量门（Frame Gate + Patch Gate）
  - 确定性跨平台数学（Q16.16 定点）
  - 统一审计模式（AuditEntry 协议）

---

## 补充文档路径

完整的 Swift 实现代码在这里：
`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_4_SUPPLEMENT.md`

**立即开始**：阅读两个文档并执行整合。
