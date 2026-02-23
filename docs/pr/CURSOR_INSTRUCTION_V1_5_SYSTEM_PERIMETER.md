# CURSOR 指令：整合 PR5 v1.5 系统外围加固

## 你的任务

将 v1.5 补充文档（系统外围加固）整合到现有的 v1.4 plan 文档中。

## 文件位置

1. **现有 Plan 文档**：
   `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md`

2. **v1.4 补充文档**：
   `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_4_SUPPLEMENT.md`

3. **v1.5 补充文档（新内容）**：
   `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md`

---

## 第一步：应用 v1.4 的勘误修正（关键！）

v1.5 文档指出 v1.4 有三个数值硬伤，必须先修正：

### 勘误 1：网络重试次数（反安全模式）

```
问题：U: maxRetryAttempts = 50 (lab) 是反安全的
- 制造重试风暴，掩盖真实网络问题
- 放大 DDoS 影响
- 爆炸成本和队列深度

修正：
- lab: maxRetryAttempts = 2（比 production 更严格！）
- 用故障注入测试网络异常，不要用重试掩盖
- 新增：maxRetryAttempts_P0_incident = 0（事故期间禁用重试）
```

### 勘误 2：审计保留期（可证明性违规）

```
问题：W: auditRetentionDays = 1 (lab) 破坏可证明性
- lab 是验证环境，需要更多审计数据，而不是更少
- 1天保留期无法进行测试后分析

修正：
- lab: auditRetentionDays = 30（比 debug 长，用于分析）
- debug: auditRetentionDays = 7
- production: auditRetentionDays = 2555（7年，合规）
```

### 勘误 3：内存警告阈值（平台不匹配）

```
问题：X: lowMemoryWarningMB = 10 (lab) 平台无效
- iOS/Android 低内存回调不会在精确 MB 值触发
- 单一阈值导致误判

修正：
- 用三信号系统替换单一阈值：
  1. systemLowMemorySignal: Boolean（OS 回调）
  2. workingSetTrendMB: [Int]（5样本移动平均）
  3. consecutiveWarningCount: Int（防抖）
- Lab 配置：workingSetTrendThreshold = 50MB, consecutiveWarningCount = 2
```

---

## 第二步：更新版本号

将版本更新为 v1.5.0：

```markdown
# PR5 v1.5.0 Complete Hardening Patch 完整实现计划

## 概述

本计划实现 PR5 Capture Optimization v1.5.0 Complete Hardening Patch，解决 **315 个生产级关键漏洞**
（v1.2: 60个 + v1.3: 52个 + v1.3.2: 108个 + v1.4补充: 112个 + v1.5补充: 95个 = 315个去重后总计），
涵盖从传感器到云端再到运营合规的完整系统。

## 版本演进

- **v1.2**: 基础加固（60个漏洞）
- **v1.3**: 生产验证加固（52个新漏洞）
- **v1.3.2**: 极端加固（108个新漏洞）- 五大核心方法论
- **v1.4**: 高级安全加固（112个新漏洞）- 端云闭环验证
- **v1.5**: 系统外围加固（95个新漏洞）← 新增
  - PART AC: 供应链安全与可复现构建
  - PART AD: 密钥与机密管理加固
  - PART AE: 身份鉴权与最小权限
  - PART AF: 滥用/DDoS/速率限制/成本护栏
  - PART AG: 备份/灾难恢复/多区域一致性
  - PART AH: 隐私攻击面（推断、关联、模型泄露）
  - PART AI: 用户同意与政策 UX 合约
  - PART AJ: 事故响应与红队闭环
```

---

## 第三步：添加 v1.5 极端值参考表

在现有极端值表后追加：

```markdown
## 极端值参考表（Lab Profile）- v1.5 系统外围

| 模块 | 参数 | Production | Debug | Lab (极端) |
|------|------|------------|-------|------------|
| AC: 供应链 | unpinnedDependencyPolicy | warn | allow | **hard-fail** |
| AC: 供应链 | sbomMatchRequired | true | false | **true** |
| AC: 供应链 | maxBuildVarianceBytes | 1024 | 10240 | **0** (字节精确) |
| AC: 供应链 | slsaLevelRequired | 2 | 1 | **3** |
| AD: 密钥 | ephemeralSessionKeyTTLSec | 3600 | 7200 | **60** |
| AD: 密钥 | maxKeyAgeForSigningSec | 86400 | 172800 | **300** |
| AD: 密钥 | breakGlassRequires2Approvers | true | false | **true** |
| AD: 密钥 | revocationPropagationP99Sec | 60 | 300 | **5** |
| AE: AuthZ | defaultDeny | true | false | **true** |
| AE: AuthZ | crossProjectAccess | deny | warn | **hard-deny** |
| AE: AuthZ | privilegedActionReauthSec | 300 | 3600 | **60** |
| AF: 滥用 | maxUploadSessionsPerUserPerHour | 10 | 100 | **1** |
| AF: 滥用 | maxActiveJobsPerTenant | 50 | 200 | **2** |
| AF: 滥用 | mirrorVerificationCPUBudgetMsP95 | 100 | 500 | **10** |
| AF: 滥用 | costSpikeAutoMitigatePercent | 50 | 100 | **20** |
| AG: 灾备 | rpoMinutes | 15 | 60 | **5** |
| AG: 灾备 | rtoMinutes | 30 | 120 | **15** |
| AG: 灾备 | deletionProofMustIncludeBackup | true | false | **true** |
| AG: 灾备 | drDrillFrequencyDays | 90 | 180 | **7** |
| AH: 隐私攻击 | maxLocationReidentificationRisk | 0.10 | 0.25 | **0.05** |
| AH: 隐私攻击 | trajectoryDownsampleFactor | 2 | 1 | **4** |
| AH: 隐私攻击 | highRiskDataPolicy | warn | allow | **localOnly+forbidUpload** |
| AI: 同意 | consentRequiredForUpload | true | false | **true** |
| AI: 同意 | consentReceiptRetentionDays | 2555 | 365 | **2555** |
| AI: 同意 | withdrawalEffectiveP99Sec | 60 | 300 | **5** |
| AJ: 事故 | p0DetectToContainP99Sec | 300 | 600 | **30** |
| AJ: 事故 | autoKillSwitchOnP0 | true | false | **true** |
| AJ: 事故 | redTeamScenariosPerRelease | 5 | 2 | **20** |
```

---

## 第四步：追加 PART AC 到 PART AJ

将 v1.5 补充文档中的以下内容完整追加：

### PART AC: 供应链安全与可复现构建 (SUPPLY-001 到 SUPPLY-015)
- BuildProvenanceManifest.swift (SLSA Level 3 合规)
- SBOMGenerator.swift + SBOMVerifier.swift
- DependencyLockPolicy.swift
- ArtifactSignatureVerifier.swift

### PART AD: 密钥与机密管理加固 (SECRETS-001 到 SECRETS-012)
- KeyHierarchySpec.swift (Root → Tenant → Dataset → Session)
- KeyUsageClosedSet.swift (加密/签名/包装分离)
- EnvelopeEncryption.swift
- BreakGlassPolicy.swift
- KMSAdapter.swift + KeyRevocationService.swift

### PART AE: 身份鉴权与最小权限 (AUTHZ-001 到 AUTHZ-010)
- AuthZModel.swift (ABAC 模型)
- AuthZEnforcer.swift + AuthZProofEmitter.swift
- 资源层级：Tenant → Project → Dataset → Session → Artifact

### PART AF: 滥用/DDoS/速率限制/成本护栏 (ABUSE-001 到 ABUSE-012)
- AbuseScoringModel.swift
- RateLimitPolicy.swift (Token Bucket 多层限流)
- CostBudgetSpec.swift
- DDOSShieldAdapter.swift

### PART AG: 备份/灾难恢复/多区域一致性 (DR-001 到 DR-010)
- BackupPolicy.swift
- DisasterRecoveryRunbook.swift
- BackupAwareDeletionProof.swift (删除证明必须覆盖备份)
- DRDrillGate.swift

### PART AH: 隐私攻击面 (PRIVACY-001 到 PRIVACY-012)
- InferenceRiskScorer.swift (位置重识别风险)
- TrajectoryAnonymizer.swift
- TrainingDataEligibilityGate.swift

### PART AI: 用户同意与政策 UX 合约 (CONSENT-001 到 CONSENT-012)
- ConsentReceipt.swift (可验证同意收据)
- ConsentVersionRegistry.swift
- WithdrawalEnforcer.swift

### PART AJ: 事故响应与红队闭环 (INCIDENT-001 到 INCIDENT-012)
- IncidentSeverity.swift (P0/P1/P2 闭集)
- IncidentRunbook.swift
- RedTeamScenarioSuite.swift
- PostmortemToGateCompiler.swift (攻击 → 测试 → 门控 → 风险注册表闭环)

---

## 第五步：更新项目结构

在项目结构中添加新目录：

```
Sources/
├── PR5Capture/
│   ├── Build/                             # PART AC: 供应链安全
│   │   ├── BuildProvenanceManifest.swift  # AC-001
│   │   ├── SBOMGenerator.swift            # AC-002
│   │   ├── SBOMVerifier.swift             # AC-003
│   │   ├── DependencyLockPolicy.swift     # AC-004
│   │   └── ArtifactSignatureVerifier.swift # AC-005
│   │
│   ├── Secrets/                           # PART AD: 密钥管理（扩展 Security/）
│   │   ├── KeyHierarchySpec.swift         # AD-001
│   │   ├── KeyUsageClosedSet.swift        # AD-002
│   │   ├── EnvelopeEncryption.swift       # AD-003
│   │   ├── BreakGlassPolicy.swift         # AD-004
│   │   ├── KMSAdapter.swift               # AD-005
│   │   └── KeyRevocationService.swift     # AD-006
│   │
│   ├── AuthZ/                             # PART AE: 授权（扩展 Tenant/）
│   │   ├── AuthZModel.swift               # AE-001
│   │   ├── AuthZEnforcer.swift            # AE-002
│   │   ├── AuthZProofEmitter.swift        # AE-003
│   │   └── ResourceHierarchy.swift        # AE-004
│   │
│   ├── Abuse/                             # PART AF: 滥用防护
│   │   ├── AbuseScoringModel.swift        # AF-001
│   │   ├── RateLimitPolicy.swift          # AF-002
│   │   ├── TokenBucketLimiter.swift       # AF-003
│   │   ├── CostBudgetSpec.swift           # AF-004
│   │   └── DDOSShieldAdapter.swift        # AF-005
│   │
│   ├── DR/                                # PART AG: 灾难恢复
│   │   ├── BackupPolicy.swift             # AG-001
│   │   ├── DisasterRecoveryRunbook.swift  # AG-002
│   │   ├── BackupAwareDeletionProof.swift # AG-003
│   │   └── DRDrillGate.swift              # AG-004
│   │
│   ├── InferencePrivacy/                  # PART AH: 隐私攻击面
│   │   ├── InferenceRiskScorer.swift      # AH-001
│   │   ├── TrajectoryAnonymizer.swift     # AH-002
│   │   └── TrainingDataEligibilityGate.swift # AH-003
│   │
│   ├── Consent/                           # PART AI: 同意管理
│   │   ├── ConsentReceipt.swift           # AI-001
│   │   ├── ConsentVersionRegistry.swift   # AI-002
│   │   └── WithdrawalEnforcer.swift       # AI-003
│   │
│   └── IncidentResponse/                  # PART AJ: 事故响应
│       ├── IncidentSeverity.swift         # AJ-001
│       ├── IncidentRunbook.swift          # AJ-002
│       ├── RedTeamScenarioSuite.swift     # AJ-003
│       └── PostmortemToGateCompiler.swift # AJ-004
```

---

## 第六步：更新汇总表

```markdown
## 文件汇总

| PART | 文件数 | Stage 数 | 漏洞数 |
|------|--------|----------|--------|
| 原有 A-R | ~50+ | ~108 | 108 |
| S-AB (v1.4) | ~55 | S-001 到 AB-002 | 112 |
| AC: 供应链 | 7 | AC-001 到 AC-007 | 15 |
| AD: 密钥 | 8 | AD-001 到 AD-008 | 12 |
| AE: AuthZ | 5 | AE-001 到 AE-005 | 10 |
| AF: 滥用防护 | 6 | AF-001 到 AF-006 | 12 |
| AG: 灾备 | 5 | AG-001 到 AG-005 | 10 |
| AH: 隐私攻击 | 5 | AH-001 到 AH-005 | 12 |
| AI: 同意 | 5 | AI-001 到 AI-005 | 12 |
| AJ: 事故响应 | 5 | AJ-001 到 AJ-005 | 12 |
| **总计** | **~151** | **~209** | **315** |
```

---

## 第七步：更新成功标准

```markdown
## 成功标准

✅ 所有 315 个加固措施实现
✅ 五大核心方法论完整实现
✅ 单元测试覆盖率 > 80%
✅ 集成测试通过所有场景
✅ 跨平台一致性测试通过
✅ 30分钟浸泡测试通过
✅ 崩溃注入覆盖率：关键路径 100%，非关键路径 80%
✅ 风险注册表 P0/P1 全部 verified
✅ 性能基准满足要求
✅ 内存使用稳定（无泄漏）
✅ 文档完整

### v1.5 新增成功标准
✅ SLSA Level 2+ 构建验证通过
✅ 密钥层级正确实现（4级）
✅ ABAC 授权测试 100% 通过
✅ 速率限制压力测试通过
✅ DR 演练在 RTO 内完成
✅ 隐私风险评分 < 0.1 (lab)
✅ 同意收据可验证
✅ P0 事故响应 < 30 秒 (lab)
```

---

## 质量检查清单

完成后验证：

- [ ] v1.4 勘误修正已应用（3 个修正）
- [ ] 版本已更新为 v1.5.0
- [ ] 8 个新 PART 已追加（AC 到 AJ）
- [ ] 极端值表已更新
- [ ] 汇总表已更新
- [ ] 项目结构已更新
- [ ] 成功标准已更新
- [ ] 总漏洞数更新为 315 个

---

## v1.5 补充文档内容概览

v1.5 补充文档（4,164 行）包含完整的 Swift 实现：

### 已完成的完整实现：

1. **PART AC: 供应链安全** (15 漏洞)
   - BuildProvenanceManifest.swift - SLSA Level 3 构建溯源
   - SBOMGenerator.swift - SBOM 生成与验证

2. **PART AD: 密钥管理** (12 漏洞)
   - KeyHierarchySpec.swift - 4 级密钥层级
   - KMSAdapter 协议定义

3. **PART AE: 授权模型** (10 漏洞)
   - AuthZModel.swift - ABAC 属性授权
   - AuthZEnforcer.swift - 授权执行与证明发射

4. **PART AF: 滥用防护** (12 漏洞)
   - TokenBucketRateLimiter - 令牌桶限流
   - CostBudgetTracker - 成本预算追踪

5. **PART AG: 灾难恢复** (10 漏洞)
   - BackupPolicy.swift - RPO/RTO 合规检查
   - BackupAwareDeletionProof.swift - 备份感知删除证明

6. **PART AH: 隐私攻击** (12 漏洞)
   - InferenceRiskScorer.swift - 重识别风险评分
   - TrajectoryAnonymizer.swift - 轨迹匿名化

7. **PART AI: 同意管理** (12 漏洞)
   - ConsentReceipt.swift - 可验证同意收据
   - WithdrawalEnforcer.swift - 快速撤回传播

8. **PART AJ: 事故响应** (12 漏洞)
   - IncidentManager.swift - 事故分级与自动遏制
   - RedTeamScenarioSuite.swift - 红队场景管理

---

## 补充文档路径

- v1.4 补充（端云闭环）：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_4_SUPPLEMENT.md`
- v1.5 补充（系统外围）：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md`

**立即开始**：阅读所有文档并执行整合。
