# RFC-002：核心层四大板块登峰造极设计

**状态**: Draft  
**日期**: 2026-02-11  
**作者**: AI-Assisted Architecture  
**参考**: 28PR_CORE_SYSTEM_ANALYSIS_2026, CURSOR_MEGA_PROMPT_V2.md §6.3（Core 常量 SSOT）

---

## 0. 摘要与公理

### 核心公理（Axiom）

> **Capture phase has no tour path; Authoring phase introduces Anchors/Hotspots and derives Tours deterministically from them.**
>
> 拍摄期不定义路线；创作期通过热点/锚点生成导览，该生成过程可审计、可复现、可交叉验证。

### 本文档目标

在用户提供的"大厂级 + 可审计 + 闭集解码 + 跨端一致"基础设计之上，融合 **2024–2025 国际与国内前沿研究**，提出**更激进、更极致**的算法与防护方案，达成**登峰造极**级工业实现。

### 融合来源

| 领域 | 前沿来源 | 融合要点 |
|------|----------|----------|
| 内容审核 | AEGIS、PROSAC (ICLR 24)、ShieldGemma2/ShieldVLM、AM3 (WACV 24)、CertPHash (USENIX 25) | 认证鲁棒、多模态联合推理、非对称混合模态、温度缩放 |
| 3D 笔迹 | 3Doodle (SIGGRAPH 24)、Neural 3D Strokes (CVPR 24)、Stroke-Cloud (ICLR 24) | 参数化 Bézier、确定性 Douglas-Peucker、op_log CRDT 预留 |
| 轨迹规划 | Ruckig (RSS 21)、Quintic Hermite/NURBS、ISO 9241-820:2024、Waterloo CNC | jerk 限制、C2 连续、SSQ/FMS 眩晕映射、15-segment profile |
| 数值稳定 | Kahan Summation、Neumaier 1974、LayerCast (NVIDIA) | 累加路径、极端条件强化、溢出防护 |
| 中国合规 | 信通院 T/CTA 20220013、T/GXDSL 041-2025、ChineseSafe、CCAC2024 | F1 星级、98%+变体识别、99.5%+深度伪造拦截 |
| CRDT/协作 | Yjs 2024、Automerge | 冲突无感、LWW+getConflicts、Undo/Redo 链 |
| Hash/寻址 | BLAKE3 (IETF draft)、RFC 8785 JCS、iroh | 并行树哈希、流式校验、确定性 JSON |

---

## 0.5 Provable Guarantees（可验证保证）

以下为**可写单测/性质测试**的硬承诺，优先于引用文献的“概念堆叠”。

| 保证 | 性质 | 验证方式 |
|------|------|----------|
| **Determinism** | 同输入、同 schema_version、同 constants_hash → content_hash/decision_hash 必须一致（跨 iOS/Linux） | Golden fixtures、交叉编译 CI |
| **Closed-set（分域）** | Security/Policy Critical 强闭集 unknown→fail；UGC/Display 弱闭集见 1.4 | Decoder fuzz、invalid enum fixtures |
| **Boundedness** | 所有集合长度、深度、字符串长度超限 → 必失败 | Property-based tests、边界 fixtures |
| **Explainability** | 每个 fail 必须给 `ReasonCode` + `PolicyTrace`（最小可解释链） | Assert 输出结构 |
| **Decision Reproducibility** | `decision_hash` 不含 nonce，同一 policy+input+result 必得同一 hash | 复算 fixtures |

---

## 1. 总体落地策略（强化版）

### 1.1 三件事（与基础设计一致 + 强化）

1. **Schema 版本化 + 闭集解码**：`schema_version` 必选；`unknown` 一律解码失败，禁止 silent fallback。
2. **Canonicalization + Quantization**：所有参与 hash/audit 的结构必须先 canonicalize，再 hash。累加用 Kahan；舍入用 DeterministicRounding（见 1.3）。
3. **四分 Hash 法**（可复现 vs 防重放拆分）：
   - `content_hash`：内容本体
   - `decision_hash`：规则 + 输入指纹 + 输出，**必须可复现**，禁止含 nonce
   - `event_hash`：`H(decision_hash || anchor_present_flag || timestamp_anchor? || nonce/event_id)`；timestamp_anchor 可选，离线可占位
   - `bundle_hash`：一组对象的 Merkle root

### 1.2 新增：九层防护清单（L1–L5 基础，L6–L9 登峰造极见 11D.5）

| 层级 | 措施 |
|------|------|
| **L1 数值** | Kahan/Neumaier 用于**累加**（路径长度、弧长、能量积分）；BBox 用量化 + 有序遍历 + NaN/Inf fail-fast |
| **L2 Hash 歧义** | 浮点量化后再参与 hash；禁止 raw float 直接 hash |
| **L3 闭集** | Security Critical 强闭集 unknown→fail；UGC/Display 见 1.4 扩展槽位 |
| **L4 边界** | 数组长度、字符串、深度、对象数 SSOT 常量；超限 → fail |
| **L5 工作预算** | `MaxDecodeWorkUnits`：每对象最多 token/节点/递归步；超限 → `ErrorCode.workBudgetExceeded` |
| **L6–L9** | Neumaier 强化累加、统一延迟防枚举、模型漂移 fail-safe、PII 预算（详见 11D.5） |

### 1.3 DeterministicRounding（不可协商条款）

- **规则**：`round-half-away-from-zero`；负数同样 away-from-zero（如 -2.5 → -3）。
- **跨语言**：Swift / C++ / Python 必须给一致参考实现；**禁止用默认 round()**。
- **Golden fixtures**：`DeterministicRounding` 模块必须有 golden vectors，CI 校验。

### 1.4 前向兼容：强闭集 vs 扩展槽位（解决 closed-set 与产品迭代矛盾）

| Schema 类型 | 策略 | 说明 |
|-------------|------|------|
| **Security/Policy Critical（强闭集）** | unknown→fail | Moderation、ACL、ReasonCode、DecisionHashInput、OpKind |
| **UGC/Display（弱闭集）** | 允许 `extensions` | Comment/Annotation 的 display 字段：白名单键、总大小上限、**不参与 hash** |
| **CRDT op** | 双层：`op_kind` 强闭集；`op_payload_extensions` 白名单 | 新增 op_kind 须 bump op_schema_version；旧端遇新版本可 skip 并保持审计一致（见 4.4） |

- 核心语义闭集不变；扩展槽位仅用于 UI/展示演进。

---

## 2. Content Moderation Policy（P0）— 登峰造极

### 2.1 前沿融合

- **Policy 边界**：Core 只定义 `PolicySnapshot` 的 schema + 合法性约束（权重范围、单步变化上限、单调性）；系统层负责更新与存储；Core 负责验证 snapshot 合法并计算 decision_hash。
- **公平性校准**：Fairness-aware ensemble（counterfactual balanced eval、threshold-agnostic metrics）；`Rule` 支持 `FairnessOverrideRule`。
- **温度缩放**：模型分数经 Temperature Scaling 后再进规则；Core 存 `policy_fingerprint` 含 `T`，复现时一致。
- **中国合规**：支持 `privacy_sensitive`（身份证/车牌）、`copyright_risk`；与 T/CTA 20220013、CCAC2024 八类对齐。

### 2.2 极致算法：Calibrated Ensemble Rule

- **ScoreSpace（闭集）**：`logit | prob | logprob`；输入 fingerprint 必须声明 score_space。
- **Temperature scaling 位置**：若 score_space=prob，须先转 logit `log(p/(1-p))/T` 再转回 prob；若 logit 则 `z' = z/T`。Core 只定义纯逻辑转换。
- **EnsembleRule**：aggregator (max|trimmed_mean_05|winsorized_mean)、min_agreement、temperature。

### 2.3 数值与安全

- **sexual_minors（显式规则）**：`category == sexual_minors && score.isPresent == true => BLOCK`；分数只用于解释。
- **sexual_minors 不得自动降级**：永远不能是 pass 或 review_required 的通道；管理员 override 必须进入审计链，且权限在 Social/ACL 中定义。
- **置信度区间**：`Score` 可带 `[lo, hi]` 校准区间；规则可基于区间下界判定。
- **Redaction 指纹**：`redaction_info` 含裁剪/模糊/降采样参数 hash。

### 2.4 Core 文件

```
Core/Moderation/
  ModerationCategory.swift       # 闭集，含 sexual_minors 显式规则
  ModerationPolicy.swift         # EnsembleRule, FairnessOverrideRule, PolicyTrace
  ModerationConstants.swift      # T_default（无 min_confidence，sexual_minors 用 isPresent 规则）
  ModerationCalibration.swift    # Temperature scaling 纯逻辑
  ModerationInputFingerprint.swift
  ModerationEvidence.swift
  ModerationResult.swift         # 含 PolicyTrace
  ModerationDecisionHash.swift
  ModerationAppeal.swift
  CounterfactualTestVector.swift # Core 定义结构，系统层跑
  ModerationInvariants.swift
  ModerationTests/
```

---

## 3. Social & UGC Metadata（P1）— 登峰造极

### 3.1 前沿融合

- **ABAC + RBAC 混合**：`evaluate(permission, principal, space_acl, context)` 支持 `context.resource_type`、`context.sensitivity` 等属性。
- **关系图语义**：好友/关注在系统层，Core 定义 `FriendPolicy`/`FollowerPolicy` 的判定语义（含缓存失效规则）。

### 3.2 Decision Hash 与 Event Hash 拆分

```
decision_hash = H(policy_fingerprint || input_fingerprint || canonical(result))
  - 可复现，禁止 nonce

event_hash = H(decision_hash || anchor_present_flag || timestamp_anchor? || nonce/event_id)
  - timestamp_anchor: optional；离线用 local_time_anchor 占位，上云后补齐“升级锚定”链
  - anchor_present_flag: 1-bit，避免有锚/无锚 hash 语义混乱
```

### 3.3 评论深度炸弹防护

- `depth` 由 Core 计算并强制 `<= MAX_REPLY_DEPTH`（建议 8）
- 递归解析时提前终止，返回 `DecodeError.depth_exceeded`

---

## 4. Spatial Drawing & Annotation（P2）— 登峰造极

### 4.1 前沿融合

- **3Doodle / Neural 3D Strokes**：支持参数化表示（Cubic Bézier）与点序列双模式。
- **笔迹顺序**：笔迹本质有顺序（时间与方向决定形状），**不可**用“交换性”破坏语义。
- **双 Hash 分离**：
  - `stroke_hash`：含时间顺序（t-ordered），用于 UI/协作/回放；
  - `shape_hash`：几何形状（Morton sort / set-like），用于去重/聚类。
- **Douglas-Peucker**：入库前可选 RDP 简化（ε 来自 `AnnotationConstants.RDP_EPSILON_M`）。

### 4.2 数值稳定性（Kahan 用于累加，BBox 不用 Kahan）

- **Kahan/Neumaier**：用于**路径长度、弧长、能量积分**等累加；BBox 是 min/max，用量化 + 有序遍历 + NaN/Inf fail-fast 保证确定性。
- **量化精度**：position 0.5mm；time 1/120s；pressure 10-bit。

### 4.3 双模式 Stroke

| 模式 | 表示 | 用途 |
|------|------|------|
| `point_sequence` | `[StrokePoint]` | 手写/自由绘制，RDP 可简化 |
| `parametric` | `CubicBezier3` 或 `SuperquadricContour` | 风格化/导出，紧凑 |

- 两种模式都可生成 `content_hash`；`parametric` 的 control points 也需量化。

### 4.4 CRDT op_log 版本与 skip 语义

- **op_kind**：强闭集（add_point、split_stroke、delete_range…）；未知→fail。
- **op_payload_extensions**：白名单键、大小上限、不参与 hash。
- **op_schema_version**：单独版本化；旧端遇新版本 op 可 **skip**：跳过执行但保留 op_id 于审计链，content_hash 为 skip 后剩余 op 的 Merkle root；skip 须带 `ReasonCode.OP_VERSION_UNSUPPORTED`。

---

## 5. Path & Camera Tour（P3）— 登峰造极

### 5.1 前沿融合

- **Ruckig 思想**：jerk/acc/vel 限制、多 DoF 时间同步、中间路点支持；Core 定义约束语义，不实现 Ruckig 本身（可调用或自研）。
- **Quintic Hermite**：C2 连续（pos/vel/acc），适合离线导览；每段 5 次多项式，系数 deterministic。
- **Waterloo CNC**：quintic + feedrate limit → 梯形加速度轮廓；`speed_profile: jerk_limited` 时按此生成。

### 5.2 极致算法：双通道交叉验证

```
Route A（几何/约束驱动）：
  - 用 PathSchema + CameraConstraints 生成轨迹
  - 插值：Quintic Hermite
  - 速度：jerk_limited（Ruckig 或 7-segment profile）

Route B（热点/语义驱动）：
  - 从 Hotspots 生成故事链：entrance → object → detail → panorama
  - 每个 hotspot 可带 constraints_override

CrossValidate(pathA, pathB, constraints) -> ValidationReport
  - 差异区段（t_start, t_end, reason_code）
  - 冲突原因码：OVERSPEED | OVERSIZED_TURN | COLLISION_RISK | SEMANTIC_JUMP | COMFORT_REGRESSION
  - ComfortScore/ComfortTier：基于速度、角速度、jerk、FOV、roll；输出 comfort_regression 若眩晕风险上升
  - 建议策略：REDUCE_SPEED | ADD_WAYPOINT | MERGE_HOTSPOTS
```

### 5.3 坐标系与 CameraFramePolicy（蜘蛛侠自由度契约）

- **CameraFramePolicy**（闭集）：
  - `frame`: world | anchorLocal | surfaceNormal
  - `up`: gravity | anchorNormal | custom
  - `roll`: locked | free | bounded
- **Roll=0 基准**：相对 `up` 定义；`roll=locked` 时 roll 恒 0；`free` 允许蜘蛛侠自由度。
- **ReferenceFrame**：热点在墙上时，`surfaceNormal` + `anchorNormal` 定义“上方向”。

### 5.4 姿态插值（Quaternion + SLERP + Roll Policy）

- **Orientation**：quaternion；插值用 `SLERP`；多段用 `SQUAD`。
- **角速度/角加速度**：基于 quaternion delta；`max_ang_speed`、`max_ang_accel` 在 TourConstants。

### 5.5 ComfortScore 公式与归一化

- **采样频率**：60Hz 或 120Hz（常量）。
- **指标**：线速度 v、角速度 ω、jerk j、ΔFOV、Δroll；权重 w1..w5，归一化到 [0,1]。
- **公式**：`comfort = 1 - clamp(w1*norm(v) + w2*norm(ω) + w3*norm(j) + w4*norm(ΔFOV) + w5*norm(Δroll), 0, 1)`。
- **ComfortTier**：A ≥ 0.8、B ∈ [0.5,0.8)、C < 0.5（闭集）；分界点在 TourConstants。

### 5.6 数值与约束

- `max_ang_accel`：防止角加速度突变导致眩晕（文献约 0.5–2 rad/s²）。
- `min_distance_to_surface`：与 TSDF/网格查询对接；Core 只定义常量。
- **角速度/角加速度**：基于 quaternion delta 计算；`max_ang_speed`、`max_ang_accel` 为 TourConstants。
- 否则实现时每端各搞一套，跨端一致性会碎。

## 6. Hash 与指纹

### 6.1 Hash Algorithm Policy

- **默认**：SHA-256；迁移须 hash_alg_id + version；禁止平台依赖；BLAKE3 须先验证跨平台比特一致。

### 6.2 Domain Separation + Hash Input Ordering（防安全 reviewer 挑刺）

- **域标签**：`H(domain_tag || hash_input_schema_version || payload)`；domain_tag 闭集：`content_v1`、`decision_v1`、`event_v1`、`bundle_v1`。
- **拼接顺序**：每个 hash 的 payload 拼接顺序为“不可更改”契约；改动须 bump `hash_input_schema_version`，否则历史哈希不可复算。
- **文档**：每个 hash 的 `(domain_tag, version, field_order)` 写入 constitution。

### 6.3 Content Hash

- **Stroke**：`stroke_hash = H(t_ordered_canonical(points) || brush || frame_id)`；`shape_hash = H(morton_sorted(points) || brush)`（去重用）。
- **Path**：`content_hash = H(canonical(waypoints) || interpolation_type || timing_model)`
- **Comment**：`content_hash = H(canonical(body) || body_hash)`

### 6.4 Decision Hash

```
decision_hash = H(policy_fingerprint || input_fingerprint || canonical(result_without_hash))
```

### 6.5 Event Hash

```
event_hash = H(decision_hash || anchor_present_flag || timestamp_anchor? || nonce/event_id)
```
- `anchor_present_flag`：1-bit，避免有锚/无锚 hash 语义混乱。
- `timestamp_anchor`：可选；离线用 local_time_anchor 占位。

### 6.6 Bundle Hash

- 沿用现有 MerkleTree；新增 `BundleManifest` 扩展支持 ModerationResult、Comment、Stroke、Path 的混合 bundle。
- **input_fingerprint**：系统层提供；Core 定义其参与 `decision_hash` 的拼接顺序。

## 6A. Canonical JSON + Unicode Contract（跨端一致性命根子）

- **Key 排序**：UTF-8 字典序（稳定）；与 SSOTEncoder 对齐。
- **浮点**：禁止科学计数法；小数位固定（如 6 位）；禁止本地化逗号。
- **-0.0**：归一化为 +0.0；否则 hash 分叉。
- **NaN/Inf**：编码层直接 fail，不输出。
- **Unicode 文本**：参与 hash 前必须 NFC 归一化；换行统一 LF（禁止 CRLF 混入）。
- **Fixtures**：每个规则必须有 golden fixture。

---

## 6B. Schema Evolution Policy（版本演进宪法）

| 变更类型 | 处理 | schema_version |
|----------|------|----------------|
| 字段新增（核心语义） | breaking | bump major |
| 扩展槽位（extensions 内） | 不 breaking | 可不 bump 或 patch |
| 旧版遇新数据 | fail / skip / degrade | 按 Schema 类型决定 |
| 新增 ReasonCode | breaking | bump major |

- **degrade**：仅用于 UGC display；Security Critical 必须 fail 或 skip。

---

## 7. 极致安全护栏（Core Invariants）

### 7.1 通用 Invariants

| 类型 | 规则 | 常量示例 |
|------|------|----------|
| 数组长度 | `points.count <= MAX_STROKE_POINTS` | 10000 |
| 字符串 | `body.count <= MAX_COMMENT_LENGTH` | 1000 |
| 深度 | `depth <= MAX_REPLY_DEPTH` | 8 |
| 对象数 | `waypoints.count <= MAX_PATH_WAYPOINTS` | 256 |

### 7.2 数值合法性

- NaN/Inf → `EdgeCase`，不参与 hash；编码层直接 fail。
- 极值 clamp：坐标在 `[-1e6, 1e6]` 米内；超出 → `COORDINATE_OUT_OF_RANGE`。
- 闭集解码：enum rawValue 若不在已知集合 → `DecodingError.unknownEnum(rawValue)`。

### 7.3 闭集解码

- 所有 enum 的 rawValue 若不在已知集合 → `DecodingError.unknownEnum(rawValue)`，不 silent 映射。

### 7.4 数值常量（来源 + 可调范围 + A/B 计划）

| 常量 | 默认值 | 来源 | 可调范围 | A/B 备选 |
|------|--------|------|----------|----------|
| `QUANT_POS_STROKE` | 5e-4 m | 介于 PATCH/GEOM | 1e-4 ~ 1e-3 | 1e-3 若存储压力大 |
| `QUANT_TIME_STROKE` | 1/120 s | 高刷 | 1/60 ~ 1/144 | — |
| `RDP_EPSILON_M` | 1e-3 | 约 1mm 容差 | 5e-4 ~ 2e-3 | — |
| `MAX_ANG_ACCEL_RAD_S2` | 1.0 | 文献 0.5–2 | 0.5 ~ 2.0 | 0.5 若强防眩晕 |
| `TEMPERATURE_DEFAULT` | 1.5 | Guo et al. 校准 | 1.0 ~ 2.5 | 2.0 若仍过自信 |

### 7.5 ReasonCode 闭集表（SSOT 约束）

新增 reason_code 必须 bump schema_version。

| ReasonCode | 域 | 语义 |
|------------|-----|------|
| `UNKNOWN_CATEGORY` | Moderation | 未知违规类别 |
| `DEPTH_EXCEEDED` | Social | 评论深度超限 |
| `BOUNDEDNESS_VIOLATION` | 通用 | 长度/深度/数量超限 |
| `OVERSPEED` | Tour | 速度超约束 |
| `OVERSIZED_TURN` | Tour | 转角超约束 |
| `COMFORT_REGRESSION` | Tour | 眩晕风险上升 |
| `OP_VERSION_UNSUPPORTED` | Annotation | CRDT op 版本旧端 skip |
| `WORK_BUDGET_EXCEEDED` | 通用 | 解析/验证复杂度超限 |

### 7.6 UI 契约

| 契约 | 内容 |
|------|------|
| ReasonCode → 用户文案 | Core 闭集；系统层 `userMessage(locale)` |
| ModerationStatus → 展示策略 | 对应不同 UI 态 |
| ValidationReport → 修复建议 | 闭集；前端渲染 |
| Stroke 预览 LOD | `simplifyForPreview` 的 RDP 语义 |

---

## 7A. Threat Model + Privacy Model

### 7A.1 Threat Model（至少 10 类）

| 威胁 | Core Invariant | System Mitigation | Test Plan |
|------|----------------|-------------------|-----------|
| 解析炸弹（深度/长度/递归） | Boundedness，depth/length 上限 | 提前终止解析 | Fuzzing, 深度 fixtures |
| hash 碰撞/替换攻击 | 闭集、canonical 顺序 | bundle 内不可重排 | Golden fixtures |
| 重放（social actions） | event_hash 含 nonce | 幂等校验 | 复算 + nonce 变化 |
| 灌水（评论/笔迹/热点） | RateLimitPolicy bucket 常量 | Token bucket 实现 | RateLimit fixtures |
| 对抗样本（绕过 moderation） | PolicyTrace 可审计 | 多模型、人工复核 | CounterfactualTestVector |
| 分布漂移（模型失效） | policy_version 必带 | 在线监控、权重更新 | Version fixtures |
| 规则版本不一致（端云不同） | constants_hash 入 policy_fingerprint | 部署前对账 | Cross-platform fixtures |
| 时戳伪造/回滚 | timestamp_anchor 与 TimeAnchoring | 多源锚定 | TripleTimeProof 测试 |
| 隐私泄露（fingerprint 含敏感） | FingerprintRedactionLevel 闭集 | 禁止可逆 embedding | Privacy fixtures |
| 申诉滥用（appeal spam） | Appeal schema + 限流 bucket | 系统层限流 | Appeal fixtures |
| 枚举探测（enumeration） | ACL/SpaceOwnership 失败不泄露存在性 | 统一错误码/统一延迟（系统层）；Core 定义 reason_code 闭集 | — |

### 7A.2 Privacy Model

- **input_fingerprint**：可审计但不可复原；仅聚合统计/模型输出摘要；禁止可逆 embedding。
- **FingerprintRedactionLevel**（闭集）：`full` | `aggregate_only` | `no_geo_below_meter`。
- **Fingerprint 结构约束**：各字段 bit-length 上限；禁止连续向量（只允许离散桶/摘要哈希）。
- **PII risk budget**：`MAX_GEO_PRECISION_M`；禁止精度到米级。

### 7A.3 Appeal 证据最小化

- **appeal** 只允许引用 `evidence_refs`（PIZ 区域摘要等），禁止原始图像。
- **redaction policy**：系统层提供可解释但不泄露的裁剪/模糊版本；Core 定义 redaction 参数 schema。

---

## 7B. 四大板块工业增强

### Moderation

- **PolicyTrace**：记录每条 rule 的命中与否（不含图像），用于申诉解释与回归测试。
- **CounterfactualTestVector**：Core 定义测试向量结构；系统层跑“同图不同裁剪/模糊”对比，输出 drift report。

### Social

- **CapabilityToken**（schema）：一次性/短期能力票据（如“允许在某空间发 1 条评论”）。
- **RateLimitPolicy**：Core 定义闭集 `bucket_id`（comment/stroke/hotspot）；系统层实现 token bucket，但 bucket 名称与边界常量由 Core 统一。

### Annotation

- **CRDT 预留**：`op_log` 模式：`add_point` / `split_stroke` / `delete_range`；每个 op 有 `op_id`（Core 定义 canonical format）；`content_hash` 可为 op_log 的 Merkle root。

### Tour

- **ComfortScore**：基于速度、角速度、jerk、FOV 变化、roll 变化。
- **ComfortTier**：A/B/C（闭集）；CrossValidate 输出加 `comfort_regression` 的 reason_code。

### PerformanceTier / Degradation

- **契约**：系统层采样 `thermal_state`、`battery_level` 并传入 Core；Core 定义 `THERMAL_THROTTLE_THRESHOLD`、`LOW_BATTERY_GRACE_LEVEL` 及 `evaluate(thermal, battery)→DegradationTier` 逻辑；与 TIER_FULL/REDUCED/MINIMAL 对齐。

---

## 7C. Verification Matrix（怎么证明）

| 验证类型 | 内容 | 通过标准 |
|----------|------|----------|
| Golden fixtures | 每 schema 1000 组随机受限样本 | iOS/Linux hash 一致 |
| **Seeded RNG（必补）** | TestRNG：xorshift/splitmix64，固定 seed；Swift/C++/Python 同实现；**单 authoritative generator**（Swift 生成→Python 校验，或反之） | fixtures 可复现 |
| Property-based tests | 边界、排序、量化、闭集解码 | 无漏网 |
| Differential testing | RouteA vs RouteB 差异报告 | reason_code 闭集、稳定 |
| Fuzzing | Decoder fuzz、JSON bomb、deeply nested | 不崩溃、未知→fail |
| Mutation tests | 1-bit flip 注入 | hash 改变或 decode fail |

| 契约 | 内容 | 作用 |
|------|------|------|
| **ReasonCode → 用户文案** | Core 定义闭集 `ReasonCode`；系统层提供 `ReasonCode.userMessage(locale)` | 文案可本地化，逻辑在 Core |
| **ModerationStatus → 展示策略** | `pass/fail/review_required/blocked_temporarily` 对应不同 UI 态 | 避免两端分支不一致 |

---

## 7D. 2026 研究驱动登峰造极 Core 升级（可落地架构）

> 将 PoisonBench、RobloxGuard、UNESCO、X-Guard、FanarGuard、中国标准等 2025–2026 前沿转化为**可写代码的 Core 契约**，非概念堆叠。

### 7D.1 投毒鲁棒：多模型 Ensemble 强制算法（PoisonBench 驱动）

**PoisonBench 结论**：大模型规模不抗投毒；攻击效果 log-linear 于 poison ratio；trigger 可泛化。→ Core 必须强制多模型交叉验证。

| 契约 | 内容 |
|------|------|
| **MIN_ENSEMBLE_MODELS** | ≥2；单模型输出不得直接进 decision_hash |
| **EnsembleVoteRule** | `aggregator: max \| trimmed_mean_05 \| winsorized_mean`；`min_agreement: Int`（至少 N 模型一致才通过） |
| **PoisonRatioMonitor** | 系统层传入 `training_poison_ratio_upper_bound`（可选）；Core 若收到且 > `MAX_ACCEPTABLE_POISON_RATIO` (0.01) → PolicySnapshot 合法性校验 fail |
| **TriggerExtrapolationDefense** | input_fingerprint 必须含 `model_fingerprint`；decision_hash 必含 model_fingerprint；同一 input 不同 model_fingerprint → 不同 decision，禁止复用 |
| **policy_version** | 必选；格式 `major.minor.patch`；参与 policy_fingerprint |

### 7D.2 Taxonomy 自适应：RobloxGuard 驱动

| 契约 | 内容 |
|------|------|
| **TaxonomySchema** | `{ taxonomy_id: String, taxonomy_version: semver, categories: [CategoryId], adapt_mode: static \| inferred }` |
| **taxonomy_adapt_mode** | 闭集：`static`（固定 taxonomy）；`inferred`（推理时推断，需 taxonomy_version） |
| **CategoryId** | 强闭集；unknown→fail；新增 category 须 bump taxonomy_version |
| **PolicySnapshot.taxonomy_ref** | 必选；指向 TaxonomySchema；跨 taxonomy 版本不可混合决策 |

### 7D.3 UNESCO/Access Now：Appeal 与人权契约

| 契约 | 内容 |
|------|------|
| **AppealSchema** | `{ appeal_id, decision_hash_ref, reason_code_ref, evidence_refs: [PIZRegionId], requested_action: redress \| explain \| escalate, created_at }`；禁止含原始图像 |
| **PolicyTrace 最小结构** | `[ { rule_id, triggered: Bool, score_used?: Float, category?: CategoryId } ]`；每条 rule 命中与否可审计 |
| **LeastRestrictiveOrder** | 决策顺序：pass → review_required → blocked_temporarily → block；不可跳过中间态（Access Now 比例性） |
| **HumanRightsCheckpoint** | Appeal 流程须支持 `escalate_to_human`；Core 定义 `EscalationReasonCode` 闭集 |

### 7D.4 多语言：X-Guard/POLYGUARD/FanarGuard 驱动

| 契约 | 内容 |
|------|------|
| **ReasonCodeLocaleMapping** | Core 定义 `ReasonCode` 闭集；系统层实现 `userMessage(locale: BCP47)`；必须支持 ar, ar-MA, ar-EG, fr, es, es-MX, zh, zh-CN |
| **JuryOfJudgesAggregator** | 可选；多标注者投票；`aggregator: majority \| unanimous \| supermajority_2_3`；Core 定义输入/输出 schema |
| **PipelineMode** | 闭集：`native`（语言专属分类器）；`translate_then_detect`（低资源语言）；系统层选择，Core 接收 mode 于 input_fingerprint |
| **CulturalContext** | ModerationInputFingerprint 可含 `cultural_region: BCP47 \| nil`；ar/ar-MA 时启用 FanarGuard 文化敏感路径 |
| **ReasonCodeCulturalVariant** | 同一 ReasonCode 可有文化变体文案（如 ar 的 `HATE_SPEECH` 与 en 文案不同）；Core 定义 variant 键白名单 |

### 7D.5 中国合规：信通院/GB/T 驱动

| 契约 | 内容 |
|------|------|
| **CertificationTier** | 闭集：`tier_5_star \| tier_4_star \| uncertified`；对应 F1 阈值 |
| **MIN_TEXT_VARIANT_RECALL** | 0.98（T/GXDSL）；变体识别召回率下界 |
| **MIN_DEEPFAKE_BLOCK_RATE** | 0.995（T/GXDSL）；深度伪造拦截率下界 |
| **CERT_F1_TIER_5_STAR** | 0.9（T/CTA 20220013）；五星认证 F1 阈值 |
| **DeepfakeBlockVerifier** | Core 定义接口：`verify(evidence, threshold) -> Bool`；系统层实现检测，Core 定义阈值与 decision_hash 参与 |

### 7D.6 Tool/Plugin 审计：MCPTox 驱动

| 契约 | 内容 |
|------|------|
| **ToolCallAuditSchema** | `{ tool_id, invocation_hash, input_fingerprint, result_fingerprint?, policy_version }` |
| **ToolCall 参与 event_hash** | 若系统层启用 Tool 审计，event_hash 域扩展 `tool_call_v1` |

### 7D.7 新增 ReasonCode（闭集扩展）

| ReasonCode | 域 | 语义 |
|------------|-----|------|
| `POISON_RATIO_EXCEEDED` | Moderation | 训练投毒比例超限 |
| `TAXONOMY_VERSION_MISMATCH` | Moderation | taxonomy 版本与 policy 不一致 |
| `ESCALATION_REQUIRED` | Appeal | 需人工升级 |
| `PIPELINE_MODE_UNSUPPORTED` | Moderation | 当前 locale 不支持 native，且 translate_then_detect 未启用 |
| `CERTIFICATION_THRESHOLD_FAILED` | Moderation | 中国合规阈值未达 |

---

## 8. 与现有 Core 的对接

### 8.1 DeterministicQuantization + DeterministicRounding

- Annotation 的 position 使用 `QUANT_POS_PATCH_ID` (0.1mm) 或 `QUANT_POS_STROKE` (0.5mm)。
- 舍入用 `DeterministicRounding`（round-half-away-from-zero，负数和正数一致）；禁止用默认 `round()`。

### 8.2 SSOTEncoder / CryptoHashFacade

- 所有 canonical JSON 用 `SSOTEncoder`。
- 所有 decision/content hash 用 `CryptoHashFacade`（SHA-256）。

### 8.3 TimeAnchoring

- `social_decision_hash`、`moderation_decision_hash` 可嵌入 `timestamp_anchor`。
- 与 `TripleTimeProof` 对接。
- 新增 `KahanSum` / `kahanSum(values:)` 用于**路径长度、弧长、能量积分**等累加。
- BBox 用量化 + 有序遍历，不用 Kahan。

- Moderation 的 `evidence_refs` 可与 PIZ region 关联；空间覆盖不足时，审核可要求 `review_required`。

### 8.5 MathSafetyConstants 扩展

- 建议新增 `KahanSum.add(_ value: Double)` 或 `kahanSum(values: [Double])` 到 `Core/Utils/` 或 `MathSafetyConstants` 配套模块。
- BBox 计算、轨迹长度累加等热路径应使用 Kahan 避免 FP 非结合性导致的跨平台分歧。

---

## 9. 实施顺序（与基础设计一致）

| Phase | 内容 |
|-------|------|
| **Phase 1** | Moderation 契约 + ModerationCalibration |
| **Phase 2** | Social (SpaceOwnership, AccessControl, Comment) |
| **Phase 3** | Annotation (StrokeSchema, BrushSchema) + Comment 对齐 |
| **Phase 4** | Tour (Anchor, Hotspot, Path, CrossValidate) |

| PROSAC (ICLR 2024 OpenReview) | 群体级对抗风险认证 (α,ζ)-safety |
| ShieldGemma 2 / ShieldVLM (arXiv 2025) | 4B 多模态 moderation、MMIT 隐式毒性 |
| AM3 (WACV 2024) | 非对称混合模态内容审核 |
| T/GXDSL 041-2025 | 生成式 AI 内容安全与伦理审查（98%/99.5% 指标） |
| Debiasing Ensemble (EMNLP 2024) | 公平性感知集成 |
| CertPHash (USENIX Security 2025) | 认证鲁棒感知哈希 |
| DeepMind Adversarial Benchmark (NeurIPS 2023) | 图像混淆对抗基准 |
| 3Doodle (SIGGRAPH 2024) | 3D stroke 参数化表示 |
| Neural 3D Strokes (CVPR 2024) | 多视角 3D 笔迹 |
| Ruckig (RSS 2021) | jerk-limited 实时轨迹 |
| Quintic Hermite / NURBS (PeerJ CS, IEEE, Springer) | C2 连续、Time-Energy-Jerk 优化 |
| ISO 9241-820:2024 | 沉浸式环境人因工程 |
| Yjs / Automerge (2024) | CRDT 冲突无感、LWW+conflicts |
| BLAKE3 (IETF draft 2024) | 并行树哈希、XOF/KDF |
| RFC 8785 (JCS) | JSON 确定性序列化 |
| iroh | 内容寻址、流式校验、16 KiB 分块 |
| Kahan / Neumaier 1974 | 数值稳定累加 |
| ChineseSafe / CCAC2024 | 中文内容安全基准 |
| 信通院 T/CTA 20220013 | 内容审核评估标准（F1 星级） |
| 3Doodle (SIGGRAPH 2024) | 3D stroke 参数化表示 |
| Neural 3D Strokes (CVPR 2024) | 多视角 3D 笔迹 |
| Ruckig (RSS 2021) | jerk-limited 实时轨迹 |
| Quintic Hermite (PeerJ CS) | C2 连续插值 |
| Kahan Summation | 数值稳定累加 |
| ChineseSafe / CCAC2024 | 中文内容安全基准 |
| 信通院 T/CTA 20220013 | 内容审核评估标准 |
| PHASER (DFRWS EU 2024) | 感知哈希评估框架 |

---

## 11. 原创创新与更激进选项

### 11.1 原创：Policy-Evidence-Merkle 三角闭环

将 Moderation、Social、Annotation、Tour 的 decision_hash 统一接入 Merkle 审计链：

```
AuditChain:
  - 每个 decision_hash 作为叶子
  - 每个 bundle_hash 作为子树根
  - 与现有 MerkleTree / SignedTreeHead 对接
  - 支持“按时间戳 / 按空间 / 按用户”的审计切片查询（系统层实现，Core 定义 schema）
```

### 11.2 更激进选项（可选实施）

| 领域 | 激进选项 | 收益 | 风险 |
|------|----------|------|------|
| Moderation | 模型级 Calibration 曲线存储 | 每模型独立 T，更细粒度 | 策略复杂度上升 |
| Annotation | Bézier 自动拟合点序列 | 紧凑存储、平滑渲染 | 拟合非唯一、需约束 |
| Tour | Ruckig 原生集成（C++ 库 bridge） | 时间最优、实时重规划 | 依赖外部库、CI 负担 |
| Hash | BLAKE3 替代 SHA-256（若跨平台稳定） | 更快、更安全 | 需验证 Linux/macOS 一致性 |

### 11.3 与 UI 的“登峰造极”配合
### 11.3 与 UI 的"登峰造极"配合

- **渐进式加载**：Comment/Stroke 按 `content_hash` 分片；Core 定义分片边界 256 条。
- **离线优先**：`bundle_hash` 本地缓存校验；`CacheValid(bundle_hash, local_hash) -> Bool`。
- **实时协作**：`social_decision_hash` 链可作 CRDT causal 元数据（系统层实现）。

## 11D. 登峰造极增强层（2024–2025 前沿融合）

> 本节将国际与中国最新标准、顶会论文、工业实践融为一体，给出**更激进、更极致**的算法与数值策略，达成工程级顶点。

### 11D.1 Content Moderation：认证鲁棒 + 多模态 + 中国合规顶点

| 增强项 | 来源 | 落地策略 | 数值/约束 |
|--------|------|----------|-----------|
| **PROSAC（α,ζ）-safety** | ICLR 2024 OpenReview | 模型级 population-level 对抗风险认证；PolicySnapshot 可携带 `certified_radius`、`alpha`、`zeta`；对抗样本在认证半径内保证不误判 | cert_radius 闭集；α ≥ 0.99 建议 |
| **ShieldGemma 2 / ShieldVLM** | arXiv Apr 2025 / 2505 | 4B 级多模态 moderation 模型；MMIT 隐式毒性数据集；**图像+文本联合推理**（memes、提示注入、深度伪造） | 系统层可选集成；Core 定义 `ModerationInput.multimodal_mode` |
| **AM3 非对称混合模态** | WACV 2024 | 非对称融合架构 + cross-modality contrastive loss；保留 modality-unique 信号 | 多模型 Ensemble 可选用非对称融合；PolicyTrace 含 per-modality 贡献 |
| **T/GXDSL 041-2025** | 广西团体标准 2026-03 实施 | 生成式 AI 内容安全与伦理审查：**文本/变体识别 ≥98%**、**深度伪造拦截 ≥99.5%** | Core 常量：`MIN_TEXT_VARIANT_RECALL`=0.98、`MIN_DEEPFAKE_BLOCK_RATE`=0.995 |
| **信通院 T/CTA 20220013** | CAICT 2024 评估 | F1 星级：≥0.9 五星、0.8–0.9 四星；性能评估含热点数据集 | PolicySnapshot 可含 `certification_f1_tier` 闭集 |
| **DeepMind 对抗基准** | NeurIPS 2023 | 图像混淆/对抗 obfuscation 攻击 benchmark；超越 ℓp 有界威胁 | CounterfactualTestVector 可扩展 obfuscation 变体 |

### 11D.2 Tour & Comfort：ISO 9241-820 + 多指标眩晕防护

| 增强项 | 来源 | 落地策略 | 数值/约束 |
|--------|------|----------|-----------|
| **ISO 9241-820:2024** | 人机交互沉浸式环境 | AR/VR 人因工程指导；Core ComfortScore 与 SSQ/FMS/CSQ 等量表对齐 | TourConstants 注释引用 ISO；权重可基于 SSQ 子项映射 |
| **Quintic NURBS + S-shaped feedrate** | Springer 2014、IEEE | jerk-limited 轨迹 + 时间最优 feedrate 调度；Time-Energy-Jerk 三维优化 | `speed_profile: jerk_limited_nurbs` 可选；与 Ruckig 并列 |
| **15-segment profile** | PeerJ CS / Waterloo CNC | 多段 jerk 轮廓，实时执行；支持 C2 连续 | 实时重规划时可选 |
| **SSQ/FMS/CSQ 映射** | 2024 VR 研究 | Simulator Sickness Questionnaire、Fast Motion Sickness Scale 等；ComfortScore 权重可校准 | `ComfortTier` 可与 SSQ 子分数区间对应；A/B 测试可调 |

### 11D.3 Hash & 内容寻址：BLAKE3 + 流式校验

| 增强项 | 来源 | 落地策略 | 数值/约束 |
|--------|------|----------|-----------|
| **BLAKE3（IETF draft）** | 2024-07、BLAKE3-team | 并行、XOF/KDF/PRF、树哈希；替代 SHA-256 若**跨平台比特一致**验证通过 | `hash_alg_id: blake3` 可选；迁移须 version bump |
| **流式校验（iroh 模式）** | iroh.computer | 大 blob 分段验证；每 16 KiB 检测错误；与 bundle_hash 分层 | 系统层大资源校验；Core 定义 `ChunkVerifySchema` |
| **RFC 8785 JCS** | IETF 2020 | JSON Canonicalization Scheme；I-JSON 子集、UTF-8、属性排序、数字格式 | 与 6A Canonical JSON 对齐；实现可引用 JCS |

### 11D.4 CRDT & 协作：Yjs/Automerge 级语义

| 增强项 | 来源 | 落地策略 | 数值/约束 |
|--------|------|----------|----------|
| **冲突无感（Yjs 风格）** | Yjs 2024 | 共享类型、无合并冲突、极小序列化；Core 的 op_log 设计可与 Yjs 型 CRDT 对接 | 系统层可用 Yjs；Core op 语义保持兼容 |
| **LWW + getConflicts（Automerge）** | Automerge | 同属性并发写：确定性 LWW 胜者 + 其余进 `conflicts`；可解释审计 | `op_log` 可支持 `conflict_resolution: lww`；conflicts 入 PolicyTrace |
| **Undo/Redo 链** | Yjs/Automerge | 可逆 op 链；Core 定义 `UndoOp`、`RedoOp` 为强闭集 op_kind | 版本化支持 |

### 11D.5 数值与安全：极致防护清单

| 层级 | 措施 | 来源/依据 |
|------|------|-----------|
| **L6 累加强化** | Neumaier 算法（Kahan 的改进版）用于极端条件累加 | 文献：Neumaier 1974 |
| **L7 闭集强化** | 枚举探测防护：ACL/Space 失败返回**统一错误码 + 统一延迟**；不泄露存在性 | 7A.1 Threat Model |
| **L8 模型漂移** | 分布漂移检测：policy_version + certified_radius；超半径自动 fail-safe | PROSAC、Aegis |
| **L9 PII 预算** | `MAX_GEO_PRECISION_M` 硬限制；`FingerprintRedactionLevel` 强制 | 7A.2 Privacy Model |

### 11D.6 UI/前端登峰造极契约（细化）

| 契约 | Core 定义 | 前端职责 | 极致点 |
|------|-----------|----------|--------|
| **ReasonCode → 文案** | 闭集 ReasonCode | `userMessage(locale, reasonCode)` 映射；**失败态统一延迟**（防探测） | 不泄露"不存在"等语义 |
| **ComfortScore → 实时 UI** | 0–1 归一化、A/B/C 档 | 实时舒适度条、警告阈值、**提前降速提示** | 早于眩晕触发干预 |
| **ValidationReport → 修复** | reason_code、建议策略闭集 | 可操作修复按钮（REDUCE_SPEED/ADD_WAYPOINT） | 一键应用建议 |
| **Stroke 预览 LOD** | RDP 语义、simplifyForPreview | 远距离低 LOD、近距高保真 | 按距离切换 |
| **渐进式加载** | 分片边界 256 条、content_hash 寻址 | 虚拟列表 + 按需拉取；**骨架屏 + 哈希校验** | 离线缓存一致性 |
| **多模态审核态** | ModerationStatus、PolicyTrace | 隐式/显式毒性分层展示；**置信区间可视化** | 符合 T/GXDSL 可解释要求 |

### 11D.7 常量顶点（新增）

| 常量 | 默认值 | 来源 | 说明 |
|------|--------|------|------|
| `MIN_TEXT_VARIANT_RECALL` | 0.98 | T/GXDSL 041-2025 | 文本/变体识别召回下限 |
| `MIN_DEEPFAKE_BLOCK_RATE` | 0.995 | T/GXDSL 041-2025 | 深度伪造拦截率下限 |
| `CERT_F1_TIER_5_STAR` | 0.9 | T/CTA 20220013 | 五星认证 F1 阈值 |
| `MAX_SSQ_SUBSCORE` | 4.0 | SSQ 量表 | 眩晕子项归一化上界（可选映射） |
| `COMFORT_WARNING_THRESHOLD` | 0.6 | 经验值 | 低于此值触发实时 UI 警告 |

---

## 12. 总结

1. **Moderation**：ScoreSpace 闭集 + Temperature 正确作用于 logit；sexual_minors 不自动降级、override 入审计；Policy 边界：Core 仅验 PolicySnapshot。
2. **Social**：ABAC + CapabilityToken + RateLimitPolicy；event_hash 含 anchor_present_flag；timestamp_anchor 可选、离线可占位。
3. **Annotation**：双 Hash；CRDT op 双层（kind 强闭集 + extensions）；op skip 语义可审计。
4. **Tour**：CameraFramePolicy（frame/up/roll）；ComfortScore 公式归一化；蜘蛛侠自由度契约化。
5. **通用**：强闭集 vs 扩展槽位；Canonical JSON + Unicode Contract；Domain Separation；Schema Evolution Policy；Seeded RNG；MaxDecodeWorkUnits。
6. **安全**：Appeal 证据最小化；Fingerprint 结构约束；枚举探测防御；Work budget。
7. **11D 登峰造极增强层**：PROSAC 认证鲁棒、ShieldVLM/AM3 多模态、T/GXDSL 98%/99.5% 指标、ISO 9241-820 眩晕映射、BLAKE3/JCS、Yjs/Automerge 语义、Neumaier 累加、统一延迟防枚举、UI 契约细化。

以上设计在保持 Core 边界的前提下，融合 2024–2026 国际与国内前沿，满足大厂架构评审对可落地、可证明、可运营、可演进的要求，达成**工程级顶点**与**登峰造极**目标。
3. **Annotation**：双模式 Stroke（点序列 + 参数化）+ RDP 确定性简化 + Kahan BBox。
4. **Tour**：Quintic Hermite C2 + Ruckig-style jerk 限制 + 双通道交叉验证。
5. **通用**：Kahan/高精度中间计算、三分 Hash、闭集解码、边界常量、可申诉链。
6. **UI 契约**：ReasonCode→文案、Status→展示策略、ValidationReport→修复建议，Core 定义闭集，前端一致实现。
7. **原创**：Policy-Evidence-Merkle 三角闭环，决策可审计、可切片、可对账。

以上设计在保持 Core 边界（纯逻辑、可测试、跨平台、无 I/O）的前提下，融合 2024–2025 国际国内前沿，达成工业顶级水平，并为更激进的演进预留空间。
