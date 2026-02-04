# CURSOR 指令：将 PR5 Plan 从 v1.4 升级到 v1.5

## 🎯 你的任务

将现有的 `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md` 文件从 v1.4 升级到 v1.5，整合系统外围加固内容。

---

## 📁 必读文件（按顺序）

### 1. 现有 Plan 文档（需要升级）
```
pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md
```
这是你需要修改的目标文件。

### 2. v1.5 补充文档（4,164 行，完整 Swift 实现）
```
/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md
```
**必须完整阅读**，包含 8 个新模块的完整代码。

### 3. v1.5 整合指令
```
/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/CURSOR_INSTRUCTION_V1_5_SYSTEM_PERIMETER.md
```
包含详细的整合步骤。

---

## ⚠️ 必须先应用的 v1.4 勘误（3个关键修复）

在添加 v1.5 内容之前，**必须先修复 v1.4 的数值硬伤**：

### 勘误 1：网络重试次数（反安全模式）
```
❌ 错误：U: maxRetryAttempts = 50 (lab)
   问题：制造重试风暴，掩盖网络问题，放大DDoS影响

✅ 修正：
   - lab: maxRetryAttempts = 2（比 production 更严格！）
   - 新增：maxRetryAttempts_P0_incident = 0（事故期间禁用重试）
```

### 勘误 2：审计保留期（可证明性违规）
```
❌ 错误：W: auditRetentionDays = 1 (lab)
   问题：lab 是验证环境，需要更多审计数据

✅ 修正：
   - lab: auditRetentionDays = 30（比 debug 长，用于分析）
   - debug: auditRetentionDays = 7
   - production: auditRetentionDays = 2555（7年合规）
```

### 勘误 3：内存警告阈值（平台不匹配）
```
❌ 错误：X: lowMemoryWarningMB = 10 (lab)
   问题：iOS/Android 不会在精确 MB 值触发回调

✅ 修正：用三信号系统替换单一阈值：
   1. systemLowMemorySignal: Boolean（OS 回调）
   2. workingSetTrendMB: [Int]（5样本移动平均）
   3. consecutiveWarningCount: Int（防抖）
   - Lab: workingSetTrendThreshold = 50MB, consecutiveWarningCount = 2
```

---

## 📝 升级步骤

### 第一步：更新文档头部

将版本从 v1.4.0 更新为 v1.5.0：

```markdown
# PR5 v1.5.0 Complete Hardening Patch 完整实现计划

## 概述

本计划实现 PR5 Capture Optimization v1.5.0 Complete Hardening Patch，解决 **315 个生产级关键漏洞**
（v1.2: 60个 + v1.3: 52个 + v1.3.2: 108个 + v1.4: 112个 + v1.5: 95个 = 315个去重后总计），
涵盖从传感器到云端再到运营合规的完整系统。

## 版本演进

- **v1.2**: 基础加固（60个漏洞）
- **v1.3**: 生产验证加固（52个新漏洞）
- **v1.3.2**: 极端加固（108个新漏洞）- 五大核心方法论
- **v1.4**: 高级安全加固（112个新漏洞）- 端云闭环验证
- **v1.5**: 系统外围加固（95个新漏洞）← **新增**
  - PART AC: 供应链安全与可复现构建
  - PART AD: 密钥与机密管理加固
  - PART AE: 身份鉴权与最小权限
  - PART AF: 滥用/DDoS/速率限制/成本护栏
  - PART AG: 备份/灾难恢复/多区域一致性
  - PART AH: 隐私攻击面（推断、关联、模型泄露）
  - PART AI: 用户同意与政策 UX 合约
  - PART AJ: 事故响应与红队闭环
```

### 第二步：在现有极端值表后追加 v1.5 极端值表

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

### 第三步：追加 8 个新 PART（从 v1.5 补充文档复制）

从 `PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md` 中完整复制以下内容：

1. **PART AC: 供应链安全** (STAGE AC-001 到 AC-007)
   - BuildProvenanceManifest.swift
   - SBOMGenerator.swift, SBOMVerifier.swift
   - DependencyLockPolicy.swift
   - ArtifactSignatureVerifier.swift

2. **PART AD: 密钥管理** (STAGE AD-001 到 AD-008)
   - KeyHierarchySpec.swift (4级: Root → Tenant → Dataset → Session)
   - KeyUsageClosedSet.swift
   - EnvelopeEncryption.swift
   - KMSAdapter.swift, KeyRevocationService.swift

3. **PART AE: 授权模型** (STAGE AE-001 到 AE-005)
   - AuthZModel.swift (ABAC)
   - AuthZEnforcer.swift
   - AuthZProofEmitter.swift

4. **PART AF: 滥用防护** (STAGE AF-001 到 AF-006)
   - TokenBucketRateLimiter.swift
   - MultiLayerRateLimiter.swift
   - CostBudgetTracker.swift

5. **PART AG: 灾难恢复** (STAGE AG-001 到 AG-006)
   - BackupPolicy.swift (RPO/RTO)
   - BackupAwareDeletionProof.swift
   - DRDrillGate.swift

6. **PART AH: 隐私攻击面** (STAGE AH-001 到 AH-006)
   - InferenceRiskScorer.swift
   - TrajectoryAnonymizer.swift
   - TrainingDataEligibilityGate.swift

7. **PART AI: 同意管理** (STAGE AI-001 到 AI-006)
   - ConsentReceipt.swift
   - ConsentVersionRegistry.swift
   - WithdrawalEnforcer.swift

8. **PART AJ: 事故响应** (STAGE AJ-001 到 AJ-006)
   - IncidentSeverity.swift (P0/P1/P2/P3)
   - IncidentManager.swift
   - RedTeamScenarioSuite.swift

### 第四步：更新项目结构

在项目结构部分添加新目录：

```
Sources/
├── PR5Capture/
│   ├── Build/                             # PART AC
│   │   ├── BuildProvenanceManifest.swift
│   │   ├── SBOMGenerator.swift
│   │   └── ...
│   ├── Secrets/                           # PART AD
│   │   ├── KeyHierarchySpec.swift
│   │   └── ...
│   ├── AuthZ/                             # PART AE
│   │   ├── AuthZModel.swift
│   │   └── ...
│   ├── Abuse/                             # PART AF
│   │   ├── TokenBucketRateLimiter.swift
│   │   └── ...
│   ├── DR/                                # PART AG
│   │   ├── BackupPolicy.swift
│   │   └── ...
│   ├── InferencePrivacy/                  # PART AH
│   │   ├── InferenceRiskScorer.swift
│   │   └── ...
│   ├── Consent/                           # PART AI
│   │   ├── ConsentReceipt.swift
│   │   └── ...
│   └── IncidentResponse/                  # PART AJ
│       ├── IncidentManager.swift
│       └── ...
```

### 第五步：更新汇总表

```markdown
## 文件汇总

| PART | 文件数 | Stage 数 | 漏洞数 |
|------|--------|----------|--------|
| 原有 0-11 (v1.2) | ~30 | ~60 | 60 |
| 原有 A-R (v1.3/v1.3.2) | ~50+ | ~108 | 160 |
| S-AB (v1.4) | ~55 | ~55 | 112 |
| AC: 供应链 | 7 | AC-001 到 AC-007 | 15 |
| AD: 密钥 | 8 | AD-001 到 AD-008 | 12 |
| AE: AuthZ | 5 | AE-001 到 AE-005 | 10 |
| AF: 滥用防护 | 6 | AF-001 到 AF-006 | 12 |
| AG: 灾备 | 6 | AG-001 到 AG-006 | 10 |
| AH: 隐私攻击 | 6 | AH-001 到 AH-006 | 12 |
| AI: 同意 | 6 | AI-001 到 AI-006 | 12 |
| AJ: 事故响应 | 6 | AJ-001 到 AJ-006 | 12 |
| **总计** | **~185** | **~259** | **315** |
```

### 第六步：更新成功标准

在现有成功标准后追加：

```markdown
### v1.5 新增成功标准

✅ v1.4 勘误已修复（3个数值硬伤）
✅ SLSA Level 2+ 构建验证通过
✅ 密钥层级正确实现（4级）
✅ ABAC 授权测试 100% 通过
✅ 速率限制压力测试通过（lab: 1 session/user/hour）
✅ DR 演练在 RTO 内完成（lab: 15分钟）
✅ 隐私风险评分 < 0.05 (lab)
✅ 同意收据可验证且版本绑定
✅ P0 事故响应 < 30 秒 (lab)
✅ 红队场景覆盖所有 8 个攻击类别
```

---

## ✅ 完成后检查清单

- [ ] 版本号更新为 v1.5.0
- [ ] 漏洞总数更新为 315 个
- [ ] v1.4 勘误修正已应用（3个）
- [ ] v1.5 极端值表已添加
- [ ] 8 个新 PART 已完整追加（AC 到 AJ）
- [ ] 所有 Swift 代码已包含（来自补充文档）
- [ ] 项目结构已更新
- [ ] 汇总表已更新
- [ ] 成功标准已更新
- [ ] 五大核心方法论在新模块中一致应用

---

## 🔗 v1.4 与 v1.5 模块集成关系

```
v1.4 模块                    v1.5 模块
─────────────────────────────────────────────
T: 远程证明      ←── 签名来自 ──→  AC: 供应链
全部模块         ←── 密钥来自 ──→  AD: 密钥管理
S,U: 云端验证/上传 ←── 授权来自 ──→  AE: AuthZ
U: 网络协议      ←── 限流包装 ──→  AF: 滥用防护
W: 租户隔离      ←── 删除扩展 ──→  AG: 灾备
Y: 活体证明      ←── 风险增强 ──→  AH: 隐私攻击
S: 审计         ←── 同意绑定 ──→  AI: 同意管理
V: Kill Switch  ←── 事故触发 ──→  AJ: 事故响应
```

---

## 🚀 开始执行

1. **先读取** `PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md` 全文
2. **再读取** `CURSOR_INSTRUCTION_V1_5_SYSTEM_PERIMETER.md` 了解步骤
3. **然后修改** `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md`
4. **确保** 所有 Swift 代码完整复制，不要简化或省略

**立即开始执行升级！**
