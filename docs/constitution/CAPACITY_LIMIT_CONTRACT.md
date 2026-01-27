# Capacity Limit Contract (PR1 C-Class)

**契约 ID:** CONTRACT_CAPACITY_LIMIT_001  
**文档版本:** 1.0  
**状态:** IMMUTABLE  
**创建日期:** 2026-01-26  
**范围:** PR1 C-Class - SOFT/HARD LIMIT (EEB体系 + 无文字UX + 闭集熔断)

---

## 概述

本契约定义 SOFT_LIMIT / HARD_LIMIT 的语义、单位、触发行为与可审计边界，确保：

1. **QA可稳定验收**：固定阈值与闭集行为
2. **内核第一性原则**：基于信息增益而非patch数
3. **无文字UX**：用户侧交互不得依赖文字提示
4. **证据不可撤销**：已接受的证据资产不得eviction

---

## 合约摘要（One-Screen Reference）

### Wire Values（Wire格式值）

**JobState:**
- `capacity_saturated` - 容量饱和状态（终端非错误状态）

**BuildMode:**
- `NORMAL` - 正常模式
- `DAMPING` - 阻尼模式（SOFT_LIMIT触发）
- `SATURATED` - 饱和模式（HARD_LIMIT触发）

### Constants（常量）

- `SOFT_LIMIT_PATCH_COUNT = 5000`
- `HARD_LIMIT_PATCH_COUNT = 8000`
- `EEB_BASE_BUDGET = 10000.0`

### Legal Transition（合法转换）

- `PROCESSING -> CAPACITY_SATURATED` - 容量饱和转换（一次性，终端状态）

### Enforcement（执行方式）

**Non-goals（非目标）:**
- ❌ No SSOT gates（无SSOT门控）
- ❌ No digests（无摘要验证）
- ❌ No manifest files（无清单文件）
- ❌ No recursive scanning（无递归扫描）

**Enforcement（执行）:**
- ✅ Unit tests only（仅单元测试）
- ✅ Tests-as-contract（测试即合约）
- ✅ Swift: `swift test --filter *ContractTests`
- ✅ Python: `python3 jobs/test_capacity_contract_v0.py`

---

## 1. 核心概念与分层（MUST）

### 1.1 双层指标：内核决策 vs QA影子验证

#### EEB (Effective Evidence Budget)

**类型**: continuous / real-valued scalar  
**语义**: 内核决策指标，体现"新增证据的有效信息增益空间"  
**角色**: 所有决策（admission、阻尼、引导）MUST以EEB为主变量  
**约束**: EEB是物理预算量，不是策略量

#### PatchCountShadow

**类型**: integer  
**语义**: QA/安全保险指标，用于阈值验收与硬熔断  
**角色**: 阈值触发、审计记录、稳定复现  
**禁止**: PatchCountShadow MUST NOT参与"价值/质量/该不该继续"的语义判断

### 1.2 固定阈值（MUST）

| 阈值 | 值 | 单位 | 语义 |
|------|-----|------|------|
| SOFT_LIMIT | 5000 | patch count (影子指标) | 以PatchCountShadow的"存活patch数"计数 |
| HARD_LIMIT | 8000 | patch count (影子指标) | 以PatchCountShadow的"存活patch数"计数 |

**约束**: 阈值MUST固定，不得动态调整

---

## 2. 计数口径（MUST / CLOSED WORLD）

### 2.1 PatchCountShadow计数对象（MUST）

PatchCountShadow计入"已被内核接受并进入evidential set的patch"：

**计入**:
- `ACCEPTED` (AcceptedPatch)

**不计入**:
- `REJECTED` (RejectedPatch)
- `DISPLAY_ONLY` (DisplayOnlyPatch)
- `DUPLICATE_REJECTED` (DuplicateRejectedPatch)

**解释**: 计数口径必须与证据资产一致，保证QA可复现。

### 2.2 No Eviction（MUST）

一旦patch被标记为AcceptedPatch：
- MUST NOT被eviction / drop / reclassify为非接受
- 系统仅允许Admission Control（决定"进不进"），禁止"进了再踢"

### 2.3 存活定义（MUST）

```
AlivePatch ≡ AcceptedPatch
```

因为No Eviction，AlivePatch与AcceptedPatch等价，避免歧义。

---

## 3. 超过SOFT_LIMIT的行为（MUST，且无文字UX）

### 3.1 触发条件（MUST）

当满足以下任一条件时，系统MUST进入阻尼模式：
- `PatchCountShadow >= SOFT_LIMIT` (5000)
- `EEB_remaining <= SOFT_BUDGET_THRESHOLD`

### 3.2 行为原则（MUST）

在阻尼模式下：
- 系统MUST允许继续采集（相机不锁、流程不中断）
- 系统MUST进入"阻尼模式 (Damping Mode)"：减少对低信息增益输入的响应
- 用户侧MUST NOT通过文字提示解释原因（no textual UX）

### 3.3 Admission阻尼（MUST）

在阻尼模式下，对每个候选patch：

**拒绝条件**:
- 若 `info_gain < IG_MIN_SOFT` 或 `novelty < NOVELTY_MIN_SOFT`:
  - MUST classify为`REJECTED`
  - MUST record `RejectReason = LOW_GAIN_SOFT`
  - MUST NOT进入evidential set

**接受条件**:
- 若满足阈值：
  - MAY classify为`ACCEPTED`（仍可入库）

**关键**: SOFT区间不是降采样"偷偷变糊"，而是"重复输入不再被系统奖励"。

### 3.4 无文字UX引导（MUST）

在阻尼模式下，用户侧反馈必须是**非文字、可感知的空间引导**：

**必须提供**:
- **Coverage Heat / Cool**: 缺口区域"热"、重复区域"冷"
- **Directional Affordance**: 箭头/边缘流动/高亮边界等（不限实现，但必须非文字）
- **重复区域反馈趋于静止**: 用户自然感知"这儿不值得拍"

**禁止**:
- 任何形式的"请换角度/光线不足/拍慢点"等文本提示
- Toast提示
- Tooltip解释
- 状态文本说明"限制已到达"

### 3.5 状态机（MUST）

- 超过SOFT_LIMIT MUST NOT导致状态机迁移到错误态
- 可选：在当前build state内设置内部标志：
  - `build_mode = DAMPING`
- 不引入新的用户可见state，避免认知成本上升

---

## 4. 达到/超过HARD_LIMIT的行为（MUST，闭集熔断）

### 4.1 触发条件（MUST）

当满足以下任一条件时，系统MUST进入饱和模式：
- `PatchCountShadow >= HARD_LIMIT` (8000)
- `EEB_remaining <= HARD_BUDGET_THRESHOLD` 且满足保险丝条件

### 4.2 行为闭集（MUST）

当达到/超过HARD_LIMIT时：
- 系统MUST停止接受任何新patch（Admission恒拒）
- 系统MUST NOT eviction（仍然禁止）
- 系统MUST NOT抛出不可恢复异常导致build崩溃（除非已定义为闭集错误）

### 4.3 状态机与终止语义（MUST）

**状态迁移**:
- MUST迁移到一个**非错误终止态**：
  - `S4_capacity_saturated`（终止态，不等于失败）

**状态语义**:
- 系统容量保险丝触发
- 证据集冻结
- build进入可结算/可提交路径

**约束**: 该状态MUST是终端状态，不允许进一步转换

### 4.4 用户侧表现（MUST，仍无文字）

硬限制触发后：
- 相机仍可操作（不锁拍摄）
- 但所有与"新增证据"相关的overlay/热力反馈MUST静止或不再更新
- 用户通过"无新增反馈"自然意识到采集已收敛
- 禁止任何文本解释

---

## 5. Coverage%计算（MUST，语义不受限制影响）

### 5.1 定义（MUST）

Coverage表示理论目标区域的证据消解比例：

```
coverage = resolved_area / theoretical_target_area
```

**分母约束**: 分母MUST使用`theoretical_target_area`，不得改为"当前存活patch数"等替代口径。

### 5.2 HARD_LIMIT不改语义（MUST）

- HARD_LIMIT触发MUST NOT改变coverage的定义与分母口径
- coverage继续按空间事实计算，确保资产口径稳定

---

## 6. PIZ判定（MUST，不可因饱和而强制true）

### 6.1 定义（MUST）

PIZ是空间缺口事实，不是系统状态：
- PIZ MUST由缺口/连通性/区域空洞规则计算
- HARD_LIMIT触发MUST NOT自动设置`PIZ=true`

### 6.2 审计上下文（MAY）

可增加不影响语义的标记：
- `PIZ_eval_context = SATURATED`

仅用于分析/审计，不影响判定规则。

---

## 7. 审计与可验收性（MUST）

### 7.1 必须记录（MUST）

每次进入阻尼或饱和时，MUST记录以下结构化字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `patch_count_shadow` | Int | 当前存活patch数 |
| `eeb_remaining` | Double | 剩余EEB预算 |
| `build_mode` | BuildMode | NORMAL/DAMPING/SATURATED |
| `reject_reason_distribution` | Map<RejectReason, Int> | 关键拒绝原因分布（LOW_GAIN_SOFT / HARD_CAP / DUPLICATE等） |

**审计时机**:
- 进入DAMPING时MUST记录
- 进入SATURATED时MUST记录
- 每次admission决策时（如果可行）记录

### 7.2 QA验收用例（MUST）

**用例1: SOFT_LIMIT验收**
- 输入: 确定性输入流，达到`PatchCountShadow == 5000`
- 验证:
  - 系统进入DAMPING（可通过RejectReason分布变化验证）
  - Admission率下降（可测量）
  - RejectReason多样性上升
  - 无崩溃；无错误状态转换

**用例2: HARD_LIMIT验收**
- 输入: 确定性输入流，达到`PatchCountShadow == 8000`
- 验证:
  - 系统进入SATURATED
  - Admission恒拒（所有后续patch返回HARD_CAP）
  - PatchCountShadow停止增长
  - JobState迁移到`CAPACITY_SATURATED`并成为终端状态
  - Coverage语义不变

**用例3: 证据不可逆性验收**
- 验证:
  - AcceptedPatch MUST NEVER被移除或重分类
  - 重放审计日志MUST能精确重现PatchCountShadow和模式转换

**约束**: 任何阈值行为必须闭集：不得出现随机eviction / 随机drop。

---

## 8. 禁止项（MUST NOT）

以下行为MUST NOT发生：

1. **MUST NOT**以"文字提示"作为核心UX路径
2. **MUST NOT**通过silent downsample欺骗用户质量（除非作为display-only且明确不入证据集）
3. **MUST NOT** eviction已接受patch
4. **MUST NOT**用patch count作为"价值/质量"语义决策变量（它只是影子指标）
5. **MUST NOT**动态调整SOFT/HARD阈值
6. **MUST NOT**因设备性能绕过admission
7. **MUST NOT**"退款"EEB给被拒绝的patch

---

## 9. 实现落点（Non-Normative，对齐参考）

### 9.1 Contract常量

```swift
// Core/Constants/CapacityLimitConstants.swift
public enum CapacityLimitConstants {
    public static let SOFT_LIMIT_PATCH_COUNT: Int = 5000
    public static let HARD_LIMIT_PATCH_COUNT: Int = 8000
    public static let SOFT_BUDGET_THRESHOLD: Double = <TBD>
    public static let HARD_BUDGET_THRESHOLD: Double = <TBD>
    public static let IG_MIN_SOFT: Double = <TBD>
    public static let NOVELTY_MIN_SOFT: Double = <TBD>
}
```

```python
# jobs/contract_constants.py
class ContractConstants:
    SOFT_LIMIT_PATCH_COUNT = 5000
    HARD_LIMIT_PATCH_COUNT = 8000
```

### 9.2 Internal Flags

```swift
// Core/Constants/PatchClassification.swift
public enum PatchClassification: String, Codable {
    case ACCEPTED = "ACCEPTED"
    case REJECTED = "REJECTED"
    case DISPLAY_ONLY = "DISPLAY_ONLY"
    case DUPLICATE_REJECTED = "DUPLICATE_REJECTED"
}

// Core/Constants/RejectReason.swift
public enum RejectReason: String, Codable {
    case LOW_GAIN_SOFT = "LOW_GAIN_SOFT"
    case REDUNDANT_COVERAGE = "REDUNDANT_COVERAGE"
    case DUPLICATE = "DUPLICATE"
    case HARD_CAP = "HARD_CAP"
    case POLICY_REJECT = "POLICY_REJECT"
}

// Core/Router/BuildMode.swift (扩展)
public enum BuildMode {
    case enter
    case publish
    case failSoft
    case NORMAL      // 新增
    case DAMPING     // 新增
    case SATURATED   // 新增
}
```

### 9.3 State Machine

```python
# jobs/job_state.py
class JobState(str, Enum):
    # ... 现有状态 ...
    CAPACITY_SATURATED = "capacity_saturated"  # 新增，终端非错误状态

# 合法转换
LEGAL_TRANSITIONS: frozenset = frozenset([
    # ... 现有转换 ...
    (JobState.PROCESSING, JobState.CAPACITY_SATURATED),  # 新增
])
```

### 9.4 核心模块

- `Core/Quality/Admission/PatchTracker.swift`: 维护PatchCountShadow、EEB_remaining、build_mode
- `Core/Quality/Admission/AdmissionController.swift`: 单一权威的admission决策引擎
- `Core/Quality/Admission/InformationGainCalculator.swift`: 信息增益和新颖性计算（占位实现，有界[0,1]）
- `Core/Quality/Visualization/GuidanceRenderer.swift`: 无文字UX指导信号渲染

---

## 10. 验收检查清单

### 10.1 实现验收

- [ ] 常量定义：SOFT_LIMIT=5000, HARD_LIMIT=8000
- [ ] PatchClassification枚举：ACCEPTED/REJECTED/DISPLAY_ONLY/DUPLICATE_REJECTED
- [ ] RejectReason枚举：LOW_GAIN_SOFT/REDUNDANT_COVERAGE/DUPLICATE/HARD_CAP
- [ ] BuildMode扩展：NORMAL/DAMPING/SATURATED
- [ ] JobState扩展：CAPACITY_SATURATED（终端非错误状态）
- [ ] PatchTracker实现：线程安全的计数和状态管理
- [ ] AdmissionController实现：单一权威决策引擎
- [ ] 审计字段：结构化CapacityMetrics记录

### 10.2 行为验收

- [ ] SOFT_LIMIT触发：进入DAMPING，Admission率下降，无文字提示
- [ ] HARD_LIMIT触发：进入SATURATED，Admission恒拒，状态迁移
- [ ] 证据不可逆：AcceptedPatch不能被移除或重分类
- [ ] Coverage语义不变：分母仍为theoretical_target_area
- [ ] PIZ独立性：PIZ不因饱和而强制true
- [ ] 无文字UX：所有指导通过视觉信号（Heat/Cool、Directional Affordance）

### 10.3 QA验收

- [ ] 确定性重现：重放审计日志能精确重现状态转换
- [ ] 闭集行为：无随机eviction或drop
- [ ] 阈值固定：SOFT/HARD阈值不得动态调整

---

## 附录：术语表

| 术语 | 定义 |
|------|------|
| EEB | Effective Evidence Budget，有效证据预算（连续值，物理预算量） |
| PatchCountShadow | Patch计数影子指标（整数，QA/审计用） |
| AlivePatch | 存活patch，等价于AcceptedPatch（因No Eviction） |
| DAMPING | 阻尼模式，SOFT_LIMIT触发后的选择性admission模式 |
| SATURATED | 饱和模式，HARD_LIMIT触发后的恒拒模式 |
| S4_capacity_saturated | 容量饱和状态，终端非错误状态 |
| evidential set | 证据集，已接受的patch集合 |
| Admission Control | 准入控制，决定patch是否进入证据集 |
| No Eviction | 禁止eviction，已接受的patch不得被移除 |

---

**文档状态**: IMMUTABLE  
**最后更新**: 2026-01-26  
**维护者**: PR1 C-Class Implementation Team
