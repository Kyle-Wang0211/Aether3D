# PR1 v2.4 EXTREME Addendum — Implementation Output

## 关键修正说明

### A1: 修复确定性破坏者

**问题**：原计划中的 `CandidateOpaqueBytesLayout_v1` 包含可变字段（timestampNs, patchCountShadow, eebRemaining, buildMode, degradationLevel），这些字段会导致稳定ID和幂等性快照在时间和运行间不可重放。

**修正**：
1. **分离为两个布局**：
   - `CandidateStableIdOpaqueBytesLayout_v1`：仅包含不可变身份输入（sessionUuid, candidateId, policyHash, candidateKind）
   - `DecisionHashInputBytesLayout_v1`：用于决策哈希输入，可包含每决策状态，但必须来自事件流且重放下稳定

2. **移除时间字段**：
   - ExtensionResultSnapshot 的规范字节不包含"现在"时间
   - 仅包含稳定的请求ID、策略哈希、结果类型等

3. **明确可选字段编码**：
   - 使用 presenceTag: UInt8 (0=absent, 1=present) 模式
   - 禁止依赖 Codable 可选编码

4. **UUID 字节顺序**：
   - 精确指定为 RFC4122 网络序 16 字节
   - 使用 uuid.uuid (uuid_t) 内存顺序

### A2: 补充缺失字段

**问题**：PolicyHashCanonicalBytesLayout_v1 表缺少影响行为的字段。

**修正**：添加以下字段到 policyHash 输入字节：
- limiterTickNs (UInt64BE, 8字节)
- valueScoreWeightA/B/C/D (Int64BE, 各8字节)
- valueScoreMax (Int64BE, 8字节)

---

## 1. SSOT Markdown 文本（A2.1-A2.5）

以下文本应插入到 `docs/constitution/SSOT_FOUNDATION_v1.1.md` 的 "A2: 字节序和字符串编码" 章节之后：

```markdown
### A2.1: PolicyHashCanonicalBytesLayout_v1

**表：PolicyHashCanonicalBytesLayout_v1**（用于 CapacityTier policyHash 输入字节）

| 字段顺序 | 字段名 | 类型 | 编码规则 | 字节数 | 说明 |
|---------|--------|------|---------|--------|------|
| 1 | tierId | UInt16 | Big-Endian | 2 | 层级标识符 |
| 2 | schemaVersion | UInt16 | Big-Endian | 2 | 结构版本 |
| 3 | profileId | UInt8 | 直接 | 1 | 配置文件ID |
| 4 | policyEpoch | UInt32 | Big-Endian | 4 | 策略纪元（单调） |
| 5 | policyFlags | UInt32 | Big-Endian | 4 | 功能开关位集 |
| 6 | softLimitPatchCount | Int32 | Big-Endian | 4 | 软限制补丁数 |
| 7 | hardLimitPatchCount | Int32 | Big-Endian | 4 | 硬限制补丁数 |
| 8 | eebBaseBudget | Int64 | Big-Endian | 8 | EEB基础预算（BudgetUnit） |
| 9 | softBudgetThreshold | Int64 | Big-Endian | 8 | 软预算阈值（BudgetUnit） |
| 10 | hardBudgetThreshold | Int64 | Big-Endian | 8 | 硬预算阈值（BudgetUnit） |
| 11 | budgetEpsilon | Int64 | Big-Endian | 8 | 预算精度（BudgetUnit） |
| 12 | maxSessionExtensions | UInt8 | 直接 | 1 | 最大会话扩展数 |
| 13 | extensionBudgetRatio | Int64 | Big-Endian | 8 | 扩展预算比率（RatioUnit） |
| 14 | cooldownNs | UInt64 | Big-Endian | 8 | 冷却期（纳秒） |
| 15 | throttleWindowNs | UInt64 | Big-Endian | 8 | 节流窗口（纳秒） |
| 16 | throttleMaxAttempts | UInt8 | 直接 | 1 | 节流最大尝试数 |
| 17 | throttleBurstTokens | UInt8 | 直接 | 1 | 节流突发令牌数 |
| 18 | throttleRefillRateNs | UInt64 | Big-Endian | 8 | 节流补充速率（纳秒） |
| 19 | retryStormFuseThreshold | UInt32 | Big-Endian | 4 | 重试风暴熔断阈值 |
| 20 | costWindowK | UInt8 | 直接 | 1 | 成本窗口大小 |
| 21 | minValueScore | Int64 | Big-Endian | 8 | 最小价值分数（BudgetUnit） |
| 22 | shedRateAtSaturated | Int64 | Big-Endian | 8 | 饱和时脱落率（RatioUnit） |
| 23 | shedRateAtTerminal | Int64 | Big-Endian | 8 | 终端时脱落率（RatioUnit，必须为1.0固定点） |
| 24 | deterministicSelectionSalt | UInt64 | Big-Endian | 8 | 确定性选择盐值 |
| 25 | hashAlgoId | UInt8 | 直接 | 1 | 哈希算法ID（封闭世界：1=SipHash-2-4, 2=BLAKE3-64） |
| 26 | eligibilityWindowK | UInt8 | 直接 | 1 | 资格窗口大小 |
| 27 | minGainThreshold | Int64 | Big-Endian | 8 | 最小增益阈值（BudgetUnit） |
| 28 | minDiversity | Int64 | Big-Endian | 8 | 最小多样性（RatioUnit） |
| 29 | rejectDominanceMaxShare | Int64 | Big-Endian | 8 | 拒绝主导最大份额（RatioUnit） |
| 30 | flowBucketCount | UInt8 | 直接 | 1 | 流桶数量（固定，例如4） |
| 31 | flowWeights | [UInt16] | Big-Endian | flowBucketCount × 2 | 流权重数组（不编码长度，精确 flowBucketCount 个 UInt16） |
| 32 | maxPerFlowExtensionsPerFlow | UInt16 | Big-Endian | 2 | 每流最大扩展数 |
| 33 | limiterTickNs | UInt64 | Big-Endian | 8 | 限制器刻度纳秒（包含在policyHash中，影响行为） |
| 34 | valueScoreWeightA | Int64 | Big-Endian | 8 | ValueScore权重A（BudgetUnit，包含在policyHash中） |
| 35 | valueScoreWeightB | Int64 | Big-Endian | 8 | ValueScore权重B（BudgetUnit，包含在policyHash中） |
| 36 | valueScoreWeightC | Int64 | Big-Endian | 8 | ValueScore权重C（BudgetUnit，包含在policyHash中） |
| 37 | valueScoreWeightD | Int64 | Big-Endian | 8 | ValueScore权重D（BudgetUnit，包含在policyHash中） |
| 38 | valueScoreMax | Int64 | Big-Endian | 8 | ValueScore最大值（BudgetUnit，包含在policyHash中） |

**关键规则**：
- **policyHash 字段本身不包含在用于计算 policyHash 的字节中**（避免递归）
- flowWeights：**不编码长度**，编码恰好 flowBucketCount 个 UInt16（大端序）
- 如果 flowWeights 长度与 flowBucketCount 不匹配 => 失败关闭
- shedRateAtTerminal 必须为 1.0 固定点（RatioUnit == 1_000_000），否则失败关闭
- hashAlgoId 必须为封闭世界枚举值（当前仅支持 2=BLAKE3-64）
- 所有整数固定宽度大端序
- 无字符串、无 JSON、无变长编码（除非明确定义）

**policyHash 计算**：
- `digest = BLAKE3(canonicalBytes)`
- `policyHash = UInt64BE(digest[0..7])`
- 文档化在 SSOT 和代码注释中

### A2.2: CandidateStableIdOpaqueBytesLayout_v1

**表：CandidateStableIdOpaqueBytesLayout_v1**（用于 candidateStableId 推导）

| 字段顺序 | 字段名 | 类型 | 编码规则 | 字节数 | 说明 |
|---------|--------|------|---------|--------|------|
| 1 | layoutVersion | UInt8 | 直接 | 1 | 布局版本（固定为1） |
| 2 | sessionStableIdSourceUuid | UUID | RFC4122网络序 | 16 | 捕获会话UUID字节，不可变 |
| 3 | candidateId | UUID | RFC4122网络序 | 16 | 候选UUID字节，不可变 |
| 4 | policyHash | UInt64 | Big-Endian | 8 | 绑定稳定ID到策略，防止跨策略冲突 |
| 5 | candidateKind | UInt8 | 直接 | 1 | 封闭世界枚举（0=patchCandidate,1=frameCandidate），如未使用则编码0 |
| 6 | reserved | UInt8[3] | 直接 | 3 | 固定填充，必须为{0,0,0} |

**明确排除**：
- ❌ 无时间戳
- ❌ 无 patchCount
- ❌ 无 eebRemaining
- ❌ 无 buildMode
- ❌ 无 degradationLevel
- ❌ 无可选字段

**稳定ID推导规则**：
- `sessionStableId = blake3_64(sessionUuidBytes || policyHashBytes)`
- `candidateStableId = blake3_64(CandidateStableIdOpaqueBytesLayout_v1 bytes)`

**变更规则**：
- 任何未来变更 => 递增 layoutVersion
- 必须提升 schemaVersion 或 policyEpoch

### A2.3: ExtensionRequestIdempotencySnapshotBytesLayout_v1

**表：ExtensionRequestIdempotencySnapshotBytesLayout_v1**（用于 ExtensionResultSnapshot 幂等性）

| 字段顺序 | 字段名 | 类型 | 编码规则 | 字节数 | 说明 |
|---------|--------|------|---------|--------|------|
| 1 | layoutVersion | UInt8 | 直接 | 1 | 布局版本（固定为1） |
| 2 | extensionRequestId | UUID | RFC4122网络序 | 16 | 扩展请求ID |
| 3 | trigger | UInt8 | 直接 | 1 | 触发枚举值 |
| 4 | tierId | UInt16 | Big-Endian | 2 | 层级ID |
| 5 | schemaVersion | UInt16 | Big-Endian | 2 | 结构版本 |
| 6 | policyHash | UInt64 | Big-Endian | 8 | 策略哈希 |
| 7 | extensionCount | UInt8 | 直接 | 1 | 扩展计数 |
| 8 | resultTag | UInt8 | 直接 | 1 | 结果标签（0=extended,1=denied,2=alreadyProcessed） |
| 9 | denialReasonTag | UInt8 | 直接 | 1 | 拒绝原因存在标签（0=absent,1=present） |
| 10 | denialReason | UInt8 | 直接 | 0或1 | 拒绝原因（仅当denialReasonTag==1时存在） |
| 11 | eebCeiling | Int64 | Big-Endian | 8 | EEB上限（BudgetUnit） |
| 12 | eebAdded | Int64 | Big-Endian | 8 | EEB添加量（BudgetUnit） |
| 13 | newEebRemaining | Int64 | Big-Endian | 8 | 新EEB剩余（BudgetUnit，仅当extended时有意义；否则编码0） |
| 14 | reserved | UInt8[4] | 直接 | 4 | 固定填充，必须为{0,0,0,0} |

**明确排除**：
- ❌ 无墙钟时间
- ❌ 无处理时间
- ❌ 字节在重放下稳定

**变更规则**：
- 任何未来变更 => 递增 layoutVersion
- 必须提升 schemaVersion 或 policyEpoch

### A2.4: DecisionHashInputBytesLayout_v1

**表：DecisionHashInputBytesLayout_v1**（用于 CapacityMetrics decisionHash 输入）

| 字段顺序 | 字段名 | 类型 | 编码规则 | 字节数 | 说明 |
|---------|--------|------|---------|--------|------|
| 1 | layoutVersion | UInt8 | 直接 | 1 | 布局版本（固定为1） |
| 2 | policyHash | UInt64 | Big-Endian | 8 | 策略哈希 |
| 3 | sessionStableId | UInt64 | Big-Endian | 8 | 会话稳定ID（blake3_64） |
| 4 | candidateStableId | UInt64 | Big-Endian | 8 | 候选稳定ID（blake3_64） |
| 5 | classification | UInt8 | 直接 | 1 | 分类枚举值 |
| 6 | rejectReasonTag | UInt8 | 直接 | 1 | 拒绝原因存在标签（0=absent,1=present） |
| 7 | rejectReason | UInt8 | 直接 | 0或1 | 拒绝原因（仅当rejectReasonTag==1时存在） |
| 8 | shedDecisionTag | UInt8 | 直接 | 1 | 脱落决策存在标签（0=absent,1=present） |
| 9 | shedDecision | UInt8 | 直接 | 0或1 | 脱落决策（仅当shedDecisionTag==1时存在） |
| 10 | shedReasonTag | UInt8 | 直接 | 1 | 脱落原因存在标签（0=absent,1=present） |
| 11 | shedReason | UInt8 | 直接 | 0或1 | 脱落原因（仅当shedReasonTag==1时存在） |
| 12 | degradationLevel | UInt8 | 直接 | 1 | 降级级别枚举值 |
| 13 | degradationReasonCodeTag | UInt8 | 直接 | 1 | 降级原因代码存在标签（0=absent,1=present，v2.4+当degradationLevel!=NORMAL时强制为1） |
| 14 | degradationReasonCode | UInt8 | 直接 | 0或1 | 降级原因代码（仅当degradationReasonCodeTag==1时存在） |
| 15 | valueScore | Int64 | Big-Endian | 8 | 价值分数（BudgetUnit） |
| 16 | perFlowCounters | [UInt16] | Big-Endian | flowBucketCount × 2 | 每流计数器数组（不编码长度，精确flowBucketCount个UInt16） |
| 17 | throttleStatsTag | UInt8 | 直接 | 1 | 节流统计存在标签（0=absent,1=present） |
| 18 | windowStartTick | UInt64 | Big-Endian | 0或8 | 窗口起始刻度（仅当throttleStatsTag==1时存在） |
| 19 | windowDurationTicks | UInt32 | Big-Endian | 0或4 | 窗口持续时间（刻度数，仅当throttleStatsTag==1时存在） |
| 20 | attemptsInWindow | UInt32 | Big-Endian | 0或4 | 窗口内尝试数（仅当throttleStatsTag==1时存在） |

**关键规则**：
- 必须包含 policyHash 和稳定ID（sessionStableId, candidateStableId）或其来源
- 必须包含影响准入结果的最小确定性信号集
- ❌ 不包含任何非来自事件流的"现在时间"
- 如需时间，使用量化刻度值（确定性事件输入的一部分）
- perFlowCounters：编码恰好 flowBucketCount × UInt16BE，不编码长度，不匹配 => 失败关闭
- 所有可选字段使用 presenceTag 编码

### A2.5: policyEpoch 治理规则（P0）

**schemaVersion 变更规则**：
- schemaVersion 仅在**结构布局变更**时更改
- 例如：添加/删除字段、改变字段类型、改变字段顺序、改变字段在规范字节中的位置

**policyEpoch 变更规则**：
- policyEpoch 仅在**数值/阈值表变更**时递增
- 必须按 tierId **单调**（同一 tierId 的 policyEpoch 只能递增）
- 禁止重用已使用的 policyEpoch 值
- 示例：如果 STANDARD tier (tierId=1) 的阈值从 8000 改为 10000，则 policyEpoch 必须递增

**解码器验证规则**（P0，v2.4+强制）：
- 如果解码器看到 policyEpoch 回退（对于声明的 v2.4+ 会话）=> **失败关闭**
- 实现：在解码 CapacityTier 时，检查 policyEpoch >= 之前见过的同一 tierId 的最大 policyEpoch
- 使用进程本地注册表（不跨应用安装持久化）

**UUID 规范字节编码规则**：
- UUID 必须编码为 RFC4122 网络序的 16 字节
- 在 Swift 中：使用 `uuid.uuid` (uuid_t) 并写入内存顺序的 16 字节（在 Apple 平台上匹配 RFC4122 字节序）
- ❌ 禁止使用 `uuidString` 或任何字符串表示

**可选字段编码规则**：
- 任何可为 nil 的字段必须编码为：`presenceTag: UInt8` (0 = absent, 1 = present)，如果存在则后跟有效载荷字节
- ❌ 禁止依赖 Codable 可选编码
```

---

## 2. 文件级差异计划

### SSOT 文档

**文件**：`docs/constitution/SSOT_FOUNDATION_v1.1.md`

**变更**：
- 在 "A2: 字节序和字符串编码" 章节后插入新章节 A2.1-A2.5
- 添加上述所有布局表和治理规则

### 核心代码文件

#### 1. `Core/Infrastructure/CanonicalBinaryCodec.swift`（新文件）

**创建**：实现规范二进制编码器

**内容**：
```swift
public class CanonicalBytesWriter {
    private var buffer: [UInt8]
    
    public init(initialCapacity: Int = 256) {
        buffer = []
        buffer.reserveCapacity(initialCapacity)
    }
    
    public func writeUInt8(_ value: UInt8) { ... }
    public func writeUInt16BE(_ value: UInt16) { ... }
    public func writeUInt32BE(_ value: UInt32) { ... }
    public func writeUInt64BE(_ value: UInt64) { ... }
    public func writeInt32BE(_ value: Int32) { ... }
    public func writeInt64BE(_ value: Int64) { ... }
    public func writeUUIDRfc4122(_ uuid: UUID) { ... } // RFC4122网络序16字节
    public func writeFixedZeros(count: Int) { ... }
    public func writeFixedArrayUInt16BE(array: [UInt16], expectedCount: Int) throws { ... }
    public func toData() -> Data { ... }
}
```

#### 2. `Core/Constants/CapacityLimitConstants.swift`

**变更**：
- 添加 `CapacityTier.canonicalBytesForPolicyHash() -> Data` 方法
  - 按照 PolicyHashCanonicalBytesLayout_v1 表顺序写入
  - 排除 policyHash 字段本身
  - 强制 flowWeights.count == flowBucketCount，否则抛出错误
  - 强制 shedRateAtTerminal == 1_000_000，否则抛出错误
  - 强制 hashAlgoId == 2 (BLAKE3-64)，否则抛出错误
- 添加 `policyHash` 计算属性
  - `digest = BLAKE3(canonicalBytes)`
  - `policyHash = UInt64BE(digest[0..7])`
- 添加 `DegradationReasonCode: UInt8` 枚举
- 添加 policyEpoch 验证逻辑
- 添加编译时/运行时检查：禁止 Double/Float 在 CapacityTier 中

#### 3. `Core/Quality/Admission/ExtensionResultSnapshot.swift`（新文件或修改）

**变更**：
- 添加 `canonicalBytesForIdempotency() -> Data` 方法
  - 按照 ExtensionRequestIdempotencySnapshotBytesLayout_v1 表顺序写入
  - 使用 presenceTag 编码可选字段
  - ❌ 不包含任何时间字段

#### 4. `Core/Audit/CapacityMetrics.swift`

**变更**：
- 添加 `canonicalBytesForDecisionHashInput() -> Data` 方法
  - 按照 DecisionHashInputBytesLayout_v1 表顺序写入
  - 使用 presenceTag 编码可选字段
  - 强制 perFlowCounters.count == flowBucketCount，否则抛出错误
- 添加 `degradationReasonCode: DegradationReasonCode?` 字段
- 添加 `validateForEncoding(schemaVersion:) throws` 方法
  - v2.4+: policyHash != 0, 强制字段存在, perFlowCounters 大小精确
  - pre-v2.4: 允许默认值

#### 5. `Core/Quality/Admission/QuantizedLimiter.swift`（新文件或修改）

**变更**：
- 实现精确窗口语义：`[startTick, startTick + windowTicks)`（左闭右开）
- 请求处理顺序：`advanceTo(nowTick)` 然后 `consume`
- attempts 在 consume **之前**计数（尝试语义）
- refill 一步计算：`delta = nowTick - lastTick; tokens += delta * refillPerTick`（有界），更新 lastTick
- ❌ 无循环，无浮点数学

#### 6. `Core/Quality/Degradation/DegradationController.swift`

**变更**：
- 固定 SATURATED 升级目标为 **SHEDDING**（单一选择，锁定）
- 记录转换时包含 reasonCode
- 每个转换记录：`(newLevel, reasonCode, monoTimeNs)`

#### 7. `Core/Quality/Admission/CandidateStableId.swift`（新文件）

**创建**：实现稳定ID推导

**内容**：
- `sessionStableId = blake3_64(sessionUuidBytes || policyHashBytes)`
- `candidateStableId = blake3_64(candidateStableOpaqueBytes)`
- `deterministicSelectionU` 计算函数

---

## 3. 测试检查清单

### P0 级保证测试

#### K1. `Tests/CanonicalBytes/UUIDCanonicalBytesTests.swift`（新文件）

- [ ] `testUUIDRfc4122ByteOrder_MatchesExpectedHex()`
  - 验证已知 UUID -> 预期 16 字节（hex）
  - 确保 writeUUIDRfc4122 匹配预期 RFC4122 字节序

#### K2. `Tests/CanonicalBytes/CapacityTierCanonicalBytesTests.swift`（新文件）

- [ ] `testCapacityTierPolicyHash_CanonicalOrderAndEndian()`
  - 验证字段顺序符合 PolicyHashCanonicalBytesLayout_v1 表
  - 验证所有整数使用大端序
- [ ] `testPolicyHashExcludesPolicyHashField()`
  - 验证 policyHash 字段本身不包含在字节中
- [ ] `testFlowWeightsExactCountEnforced_FailClosed()`
  - 验证 flowWeights.count != flowBucketCount 时抛出错误
- [ ] `testPolicyHashDeterminismAcrossRuns()`
  - 多次运行相同输入，验证 policyHash 完全相同
- [ ] `testShedRateAtTerminalMustBeOne_FailClosed()`
  - 验证 shedRateAtTerminal != 1_000_000 时抛出错误
- [ ] `testIncludesLimiterTickAndValueScoreWeightsInPolicyHash()`
  - 验证 limiterTickNs 和 valueScoreWeightA/B/C/D/Max 包含在 policyHash 字节中

#### K3. `Tests/CanonicalBytes/CandidateStableIdBytesTests.swift`（新文件）

- [ ] `testCandidateStableIdOpaqueBytes_NoTimeNoMutableFields()`
  - 验证 CandidateStableIdOpaqueBytesLayout_v1 不包含时间或可变字段
- [ ] `testCandidateStableIdDeterminismAcrossRuns()`
  - 多次运行相同输入，验证 candidateStableId 完全相同

#### K4. `Tests/CanonicalBytes/ExtensionSnapshotByteStabilityTests.swift`（新文件）

- [ ] `testIdempotencySnapshotBytesStable_NoNowTime()`
  - 验证 ExtensionResultSnapshot 规范字节不包含"现在"时间
  - 验证字节在重放下稳定
- [ ] `testAlreadyProcessedReturnsSameCanonicalBytes()`
  - 验证 ExtensionResult.alreadyProcessed 包装原始快照时，规范字节相同

#### K5. `Tests/CanonicalBytes/DecisionHashInputBytesTests.swift`（新文件）

- [ ] `testDecisionHashInputStableAcrossRuns()`
  - 多次运行相同输入，验证 decisionHash 输入字节完全相同
- [ ] `testPerFlowCountersExactSizeEnforced()`
  - 验证 perFlowCounters.count != flowBucketCount 时抛出错误
- [ ] `testOptionalThrottleStatsPresenceEncodingStable()`
  - 验证 throttleStats 使用 presenceTag 编码，编码稳定

#### K6. `Tests/Governance/PolicyEpochGovernanceTests.swift`（新文件）

- [ ] `testPolicyEpochMonotonicityPerTierId()`
  - 验证同一 tierId 的 policyEpoch 必须单调递增
- [ ] `testRollbackFailsClosedForV24()`
  - 验证 v2.4+ 会话中 policyEpoch 回退导致失败关闭

### P1 级保证测试

#### K7. `Tests/Limiter/QuantizedLimiterEdgeSemanticsTests.swift`（新文件）

- [ ] `testWindowLeftClosedRightOpen()`
  - 验证窗口边界语义：`[startTick, startTick + windowTicks)`（左闭右开）
- [ ] `testBoundaryAtEndTick()`
  - 验证边界情况：startTick, startTick + windowTicks - 1, startTick + windowTicks
- [ ] `testDeterminismSameTickSequence()`
  - 验证相同刻度序列产生确定性结果
  - 验证 advanceTo 和 consume 的顺序影响

#### K8. `Tests/Degradation/DegradationReasonCodesTests.swift`（新文件）

- [ ] `testSaturatedEscalationSingleChoice()`
  - 验证 SATURATED 升级目标固定为单一选择（SHEDDING）
  - 验证不允许"或选择一个"歧义
- [ ] `testTransitionAuditsIncludeReasonCode()`
  - 验证每个转换记录包含 reasonCode
  - 验证 reasonCode 是有效的 DegradationReasonCode 枚举值

---

## 4. 实施约束

### 失败关闭规则（v2.4+）

以下情况必须失败关闭（抛出错误/硬熔断）：
- flowWeights.count != flowBucketCount
- shedRateAtTerminal != 1_000_000
- hashAlgoId != 2 (BLAKE3-64)
- policyHash == 0
- policyEpoch 回退检测
- perFlowCounters.count != flowBucketCount
- 未知枚举值

### 性能约束

- 所有热路径 O(1) 摊销
- 规范字节函数可能分配内存，但必须是有界且可预测的
- 预分配缓冲区大小（例如 256 字节初始容量）

### 禁止项

- ❌ 无占位符/TODO
- ❌ 无 JSONEncoder/PropertyListEncoder/Codable 用于哈希/幂等性字节
- ❌ 无 Double/Float 在 CapacityTier 或审计指标中（用于规范字节）
- ❌ 无 uuidString 或字符串表示用于 UUID 字节
- ❌ 无依赖 Codable 可选编码

---

**状态**：计划完成，等待实施确认
