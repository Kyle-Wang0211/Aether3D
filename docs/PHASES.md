# Aether3D Phases Definition

本文件定义 Aether3D 项目的 **阶段划分（Phase）**、**边界规则**、**进入条件** 与 **验收标准**。  
所有开发活动必须遵循本文件中的 Phase 约定。

---

## 核心回滚哲学（适用于所有 Phase）

- **历史只允许向前追加**
- **任何公共历史的修正必须是“新 commit”，而不是重写历史**
- **Phase Tag 是锚点（Anchor），不是分支，不可移动**

基本原则总结为一句话：

> **公开历史只允许修正，不允许假装没发生。**

---

## Phase 0 — Frozen Baseline（已冻结）

### 定义
Phase 0 是项目的**稳定基线**，代表：
- 项目整体架构已确认
- 工程可以正常编译 / 打开
- 作为所有后续阶段的**回滚锚点**

### 标识
- **Git Tag**：`phase0`
- 该 Tag **只读、永久存在、永不移动**

### 允许
- 查看代码
- 对比差异
- 使用 `git checkout phase0` 进行只读检查

### 禁止
- ❌ 移动或重建 `phase0` tag
- ❌ 使用 `git reset` / `git rebase` 改写任何会影响 `phase0` 所指向 commit 的历史
- ❌ `force push`

### 回滚方式
- **只能使用 `git revert`**
- 所有回滚必须生成新的 commit

### 验收标准（全部满足）
- `phase0` tag 存在
- main 分支可正常编译
- 仓库历史干净、无异常操作

---

## Phase 0.5 — Guardrails（护栏阶段）

### 定义
Phase 0.5 用于建立**开发护栏与版本控制制度**，目标是：

> 确保未来每一个阶段、每一个功能点 **都可回滚、可协作、可审计**。

这是一个 **制度阶段，不是功能阶段**。

### 允许
- 新增 / 修改文档（README、docs）
- 新增脚本（scripts）
- 新增 CI / 自动化检查
- 制定分支策略、回滚流程、协作规则

### 明确禁止（非常重要）
在 Phase 0.5 **不得修改任何功能或工程结构**，包括但不限于：

- ❌ Swift 源码（`.swift`）
- ❌ Metal Shader（`.metal`）
- ❌ Xcode 工程文件（`.xcodeproj/project.pbxproj`）
- ❌ Build Settings / Info.plist / Entitlements
- ❌ Package.swift（如存在）

> Phase 0.5 的唯一目标是 **“规则先于功能”**。

### 分支与历史规则（分级）

#### main 分支（最高保护级别）
- ❌ 禁止直接 push
- ❌ 禁止 `git reset` / `git rebase`
- ❌ 禁止 `git push --force` / `--force-with-lease`
- ✅ 只接受 Pull Request
- ✅ 回滚 **只能通过 `git revert`（PR 形式）**
- ✅ 历史只允许向前追加

#### feature / phase 分支
- **未 push 到远端之前**：
  - ✅ 允许 `git reset` / `git commit --amend` 整理本地历史
- **一旦 push / 创建 PR 后**：
  - ❌ 禁止 rebase / force push
  - ✅ 使用 `git revert` 或新的修复 commit

### Phase 0.5 子阶段说明（结构性划分）
> 子阶段用于**检查项与文档组织**，允许在执行时合并完成。

- **0.5-1**：分支策略 & Phase 定义
- **0.5-2**：回滚演练（Rollback Drill）
- **0.5-3**：Preflight 本地检查脚本
- **0.5-4**：最小 CI（只跑护栏，不跑构建）

### 验收标准（建议 checklist）
- Phase / Workflow / Rollback 文档齐全
- 至少完成一次真实 revert 演练（有 PR 记录）
- main 分支无直接 push
- 所有规则可被新成员直接执行

---

## Phase 1 — Feature Development（功能开发）

### 定义
Phase 1 是**核心功能开发阶段**。

### 进入条件（必须全部满足）
- Phase 0.5 全部护栏完成并合并至 main
- 建议在 main 上打一个锚点 Tag（例如：`guardrails0`）
- Phase 1 分支 **必须基于最新 main（护栏完成态）**

### 分支规则
- 分支命名示例：
  - `phase1/<topic>`
  - `feat/<topic>`
- 分支来源：`main`
- 同步方式：`git merge origin/main`（禁止 rebase）
- 合并后：立即删除分支（本地 + 远端）

### 回滚规则
- main：只允许 `git revert`
- feature 分支：
  - 未 push：可 reset
  - 已 push：只 revert 或新 commit 修复

### 验收标准（示例）
- 最小可运行功能
- 核心模块日志 / 错误路径可追踪
- 出现事故可在 main 上一键 revert

---

### Phase 1-0: 接口合同冻结（Router / Plugin / UI Contract）

#### 定位与目标

**Phase 1-0 是"接口冻结阶段"，不实现功能，只冻结契约。**

- **本质**：工程合同级定义，为 Phase 1 后续实现提供不可歧义的接口边界
- **目标**：完成后，任何人可按合同独立开发 Router / Plugin / UI，无需相互等待
- **约束**：接口冻结后，Phase 1-1 ~ 1-5 不得引入新接口字段，只能实现已冻结的接口

#### 做什么 / 不做什么

**✅ 必须完成**：
- 定义 Router Contract（输入/输出字段、BuildPlan 结构）
- 定义 Plugin Contract（Plugin B 必须遵守的接口）
- 定义 UI Contract（最小 UI 状态枚举）
- 定义 Fail-soft 机制（照片空间输出）
- 定义 AssetBundle 草案（一次性资产格式）
- 冻结所有接口字段，确保可编译但实现为空

**❌ 明确禁止**：
- 不实现 Router / Plugin / UI 的具体算法
- 不涉及设备检测、性能测量、渲染管线
- 不引入 Phase 2 内容（训练式插件、增量补拍等）

---

#### 1. Router Contract（必须）

**Router 的职责**：根据素材特征、设备能力、实时状态，输出 BuildPlan（预算描述），不直接选择算法。

##### 1.1 输入字段（Router 必须接收）

**素材特征（MaterialFeatures）**：
- `photo_count: Int` - 照片数量
- `coverage: Float` - 覆盖度（0.0-1.0）
- `quality_score: Float` - 质量评分（0.0-1.0）
- `parallax_min: Float` - 最小视差（用于判断是否可进入）

**设备能力（DeviceCapabilities）**：
- `tier: DeviceTier` - 设备层级（L/M/H，按能力不按机型）
- `max_memory_mb: Int` - 最大可用内存（MB）
- `thermal_state: ThermalState` - 热状态（normal/warning/critical）
- `battery_level: Float` - 电池电量（0.0-1.0）
- `is_charging: Bool` - 是否充电中

**实时状态（RealtimeState）**：
- `current_memory_mb: Int` - 当前内存使用（MB）
- `cpu_usage: Float` - CPU 使用率（0.0-1.0）
- `gpu_usage: Float` - GPU 使用率（0.0-1.0）

##### 1.2 输出字段（BuildPlan）

**BuildPlan 必须是"预算描述"，而不是算法名。**

**预算参数（Budget）**：
- `time_budget_ms: Int` - 时间预算（毫秒）
- `frame_budget: Int` - 帧数预算
- `max_splats: Int` - 最大 splat 数量
- `lod_level: Int` - LOD 级别（0-N）
- `sh_order: Int` - 球谐函数阶数（0/1/2/3）
- `progressive_enabled: Bool` - 是否启用渐进式输出

**终止策略（StopRules）**：
- `thermal_threshold: ThermalState` - 热状态触发阈值
- `battery_threshold: Float` - 电池电量触发阈值（0.0-1.0）
- `memory_threshold_mb: Int` - 内存使用触发阈值（MB）
- `max_duration_ms: Int` - 最大持续时间（毫秒，硬超时）

**关键约束**：
- ❌ Router **不得**输出算法名（如 "use_plugin_b"、"use_neural_radiance_field"）
- ✅ Router **只能**输出预算参数和终止策略
- ✅ Plugin 根据 BuildPlan 自行选择实现方式

---

#### 2. Plugin Contract（Plugin B）

**Plugin 的职责**：遵守 BuildPlan，实现端上快速拟合，支持 progressive 输出，可被安全中断。

##### 2.1 必须遵守 BuildPlan

- Plugin 必须接收 BuildPlan 作为输入
- Plugin 必须遵守所有预算参数（time_budget_ms、max_splats、lod_level 等）
- Plugin 不得超出 BuildPlan 规定的资源限制

##### 2.2 必须支持 Progressive 输出

- Plugin 必须支持渐进式质量提升
- 输出格式：`ProgressiveOutput`
  - `quality_level: Int` - 当前质量级别（0-N，递增）
  - `splats: [Splat]` - 当前 splat 数据
  - `is_final: Bool` - 是否为最终输出
  - `progress: Float` - 进度（0.0-1.0）

##### 2.3 必须支持安全中断

- Plugin 必须实现 `cancel()` 方法
- Router 可在任意时刻调用 `cancel()`，Plugin 必须：
  - 立即停止计算（不超过 100ms）
  - 释放已分配资源
  - 返回当前最佳结果（如有）或 fail-soft 输出
- Plugin 不得在中断后继续占用资源

##### 2.4 输出格式

- **成功**：返回 `PluginOutput.success(progressive_output: ProgressiveOutput)`
- **Fail-soft**：返回 `PluginOutput.fail_soft(photo_space: PhotoSpace)`
- **失败**：返回 `PluginOutput.failure(error: PluginError)`

---

#### 3. UI Contract（最小 UI）

**Phase 1 UI 是"测试工具级 UI"，不是产品 UI。**

##### 3.1 UI 职责边界

**✅ UI 必须**：
- 只依赖 Router / Plugin 的状态枚举
- 显示状态转换和进度信息
- 提供基本的交互（开始/取消/查看结果）

**❌ UI 不得**：
- 包含任何算法判断逻辑
- 直接调用设备检测或性能测量
- 绕过 Router 直接与 Plugin 交互

##### 3.2 状态枚举（UI 必须支持）

**基础状态**：
- `idle` - 空闲状态，等待用户操作
- `building_enter` - 正在构建 Enter 阶段（T+0 到 T+1-2s）
- `enter_ready` - Enter 阶段完成，可进入 Viewer
- `building_publish` - 正在构建 Publish 阶段（后台继续优化）
- `publish_ready` - Publish 阶段完成，高质量结果可用

**错误状态**：
- `fail_soft` - Fail-soft 输出（照片空间可用）
- `aborted` - 用户取消或系统中断

##### 3.3 UI 状态转换

```
idle → building_enter → enter_ready → building_publish → publish_ready
  ↓         ↓              ↓
fail_soft  aborted      aborted
```

**关键约束**：
- UI 必须通过 Router 获取状态，不得自行判断
- UI 必须能表达所有上述状态，不得遗漏

---

#### 4. Fail-soft 明确定义

##### 4.1 Fail-soft 的本质

**Fail-soft = 输出"照片空间"**

- **照片空间定义**：有限视角可进入的多照片渲染空间
- **本质目标**：不黑屏、不崩溃、不让用户白等
- **触发条件**：当 Plugin 无法在预算内完成 3D 构建时

##### 4.2 照片空间特征

- **有限视角**：用户可在多个固定视角间切换
- **多照片渲染**：每个视角对应一张或多张输入照片
- **可进入性**：用户可"进入"该空间并基本漫游（视角切换）
- **非 3D 重建**：不是真正的 3D 点云或 mesh，而是照片空间映射

##### 4.3 Fail-soft 触发机制

- **属于 Plugin 能力**：Plugin 必须能够输出照片空间
- **由 Router 触发**：Router 在 BuildPlan 中可设置 `fail_soft_enabled: Bool`
- **降级策略**：当 Plugin 检测到无法在预算内完成时，自动降级为照片空间输出

##### 4.4 Fail-soft 输出格式

- `PhotoSpace` 结构：
  - `viewpoints: [Viewpoint]` - 可用视角列表
  - `photos: [Photo]` - 照片数据
  - `transitions: [Transition]` - 视角间过渡信息

---

#### 5. AssetBundle 草案（Phase 1-0 冻结）

##### 5.1 Phase 1 Asset 特性

**Phase 1 Asset 是"一次性资产"**：
- ❌ 不支持补帧 / 追加训练
- ❌ 不支持增量素材追加
- ✅ 一次性构建完成后保存，后续只能加载查看

##### 5.2 最小结构

**必须包含**：
- `manifest.json` - 资产清单（版本、元数据、文件列表）
- `data/` - 数据目录（splats、纹理、相机参数等）

**格式选择**：
- 可以是文件夹结构（便于调试）
- 可以是 zip 压缩包（便于分发）
- **必须可版本化**：manifest 中必须包含 `version: String` 字段

##### 5.3 Manifest 结构（草案）

```json
{
  "version": "1.0.0",
  "created_at": "ISO8601 timestamp",
  "asset_type": "one_shot",
  "photo_count": 42,
  "splat_count": 1000000,
  "files": [
    {"path": "data/splats.bin", "size": 12345678},
    {"path": "data/cameras.json", "size": 1234}
  ]
}
```

**关键约束**：
- Phase 1-0 冻结此结构，Phase 1-1 ~ 1-5 不得修改 manifest 字段
- 后续版本可通过新增字段扩展，但不得删除或修改现有字段

---

#### 6. 验收标准（必须可检查）

##### 6.1 接口冻结标准

- ✅ 所有接口定义文件可编译（无语法错误）
- ✅ Router Contract 输入/输出字段完整定义
- ✅ Plugin Contract 方法签名完整定义
- ✅ UI Contract 状态枚举完整定义
- ✅ Fail-soft 机制明确定义
- ✅ AssetBundle 结构草案冻结

##### 6.2 文档完整性

- ✅ `docs/ROUTER_CONTRACT.md` - Router 接口规范
- ✅ `docs/PLUGIN_CONTRACT.md` - Plugin 接口规范
- ✅ `docs/UI_CONTRACT.md` - UI 接口规范
- ✅ 所有文档包含完整的字段定义和约束说明

##### 6.3 不可变更性保证

- ✅ 文档冻结后不允许接口字段变更
- ✅ Phase 1-1 ~ 1-5 不得引入新接口字段
- ✅ 如需扩展，必须通过 Phase 1-0 的修订流程（新 commit）

##### 6.4 团队对齐

- ✅ 团队 review 通过所有接口设计
- ✅ 所有接口定义通过代码审查
- ✅ 接口文档通过文档审查

---

#### Rollback Note

如需回滚到 Phase 1-0 之前：
```bash
git checkout -b rollback/before-phase1-0 main
git revert <phase1-0-commit-hash>
# 创建 PR 并合并
```

---

### Phase 1-3 — Output Artifact & Preview

#### 目标

将 Phase 1-2c 的"跑通结果"升级为"可管理的输出产物 + 可重复打开的预览"。

#### 进入条件（Entry Criteria）

必须全部满足：

- ✅ Phase 1-2c 已完成（真机可独立运行、Demo 入口稳定、UI 反作弊显示 plan summary）
- ✅ Xcode 编译通过，无 duplicate outputs
- ✅ Demo：PhotosPicker → Run → Finished 能完成（至少一次）
- ✅ PipelineRunner 能正常返回 BuildResult

#### 范围（Scope）

**✅ 只做**：

- 定义 `PipelineOutput`（产物结构，包含 buildPlan 和 artifact）
- 实现 `OutputManager`（内存级管理，singleton 模式）
- 新增 `ResultPreviewView`（可反复打开查看）
- Demo UI 增加"查看结果"入口（稳定导航）

**❌ 明确不做**：

- 不做持久化（Phase 1-4 才做）
- 不做分享/发布/账号/TestFlight
- 不做算法/渲染/训练优化
- 不做文件系统保存/加载

#### 设计约束（Design Constraints）

**OutputManager 必须是 singleton**：

- `OutputManager.shared` 静态属性
- 必须维护：
  - `outputs: [UUID: PipelineOutput]`（私有 setter，公开 getter）
  - `lastOutputID: UUID?`（用于 Preview 默认展示）
- 必须提供：
  - `func save(_ output: PipelineOutput) -> UUID`
  - `func latestOutput() -> PipelineOutput?`
  - `func output(id: UUID) -> PipelineOutput?`

**PipelineOutput 必须包含**：

- `let id: UUID`（唯一标识）
- `let buildPlan: BuildPlan`（反作弊关键字段，必须存在）
- `let artifact: PhotoSpaceArtifact`（或等价类型）
- `let createdAt: Date`
- `let sourceVideoName: String?`（可选，用于显示）

**类型安全约束**：

- `pluginResult` 允许为 `nil`，但类型必须明确（禁止 `Any`）
- 所有字段必须符合 `Sendable` 协议

#### 验收标准（Acceptance Criteria）

##### A) 代码结构（可 grep 验证）

**必须存在的文件与关键字段**：

1. **Core/Output/PipelineOutput.swift** 存在
   ```bash
   ls -la Core/Output/PipelineOutput.swift
   ```
   - 包含 `let buildPlan: BuildPlan`
   - 包含 `let id: UUID`
   - 包含 `let createdAt: Date`
   ```bash
   grep -n "buildPlan\|id.*UUID\|createdAt" Core/Output/PipelineOutput.swift
   ```

2. **Core/Output/OutputManager.swift** 存在
   ```bash
   ls -la Core/Output/OutputManager.swift
   ```
   - 包含 `static let shared`
   - 包含 `private(set) var lastOutputID: UUID?`
   - 包含 `func latestOutput() -> PipelineOutput?`
   ```bash
   grep -n "static let shared\|lastOutputID\|func latestOutput" Core/Output/OutputManager.swift
   ```

3. **App/Demo/ResultPreviewView.swift** 存在
   ```bash
   ls -la App/Demo/ResultPreviewView.swift
   ```
   - 包含 `LazyVGrid`（用于帧网格显示）
   - 包含 `debugSummary` 或 `planSummary`（反作弊显示）
   ```bash
   grep -n "LazyVGrid\|debugSummary\|planSummary" App/Demo/ResultPreviewView.swift
   ```

4. **PipelineRunner 完成点调用 OutputManager**
   - `PipelineRunner.finish(...)` 或等价完成点必须调用 `OutputManager.shared.save(...)`
   ```bash
   grep -n "OutputManager.shared.save" Core/Pipeline/PipelineRunner.swift
   ```

##### B) 功能行为（可录屏验证）

**Pipeline 完成后**：

- ✅ 出现"查看结果"入口（按钮或导航链接）
- ✅ 点击进入 Preview：
  - 显示 `outputID` 前 8 位 + `createdAt` 时间戳
  - 显示 `sourceVideo` 文件名（如有）
  - 显示帧网格（至少 1 帧，最多 6 帧）
  - 显示 `buildPlan.debugSummary` 原文（反作弊，原样展示，不改写）
- ✅ 返回主界面，再次进入 Preview：仍看到同一 output（不依赖 ViewModel 生命周期）

**录屏验证脚本（60 秒）**：

1. 启动 App（0-2s）
2. 选择视频并运行 Pipeline（2-15s）
3. Pipeline 完成后，点击"查看结果"（15-16s）
4. 验证 Preview 显示：outputID、时间、帧网格、debugSummary（16-25s）
5. 返回主界面（25-26s）
6. 再次点击"查看结果"（26-27s）
7. 验证：outputID 相同，内容一致（27-35s）

##### C) 生命周期策略（明确、可验证）

**仅内存管理**：

- ✅ App 重启后 `outputs` 清空是预期行为（不持久化）
- ✅ 进程存活期间：销毁 ViewModel 不影响 `OutputManager` 中的 output
- ✅ 验证命令：
  ```bash
  # 在 Xcode 调试器中
  po OutputManager.shared.outputs.count > 0  # 运行 Pipeline 后应为 true
  po OutputManager.shared.lastOutputID != nil  # 运行 Pipeline 后应为 true
  ```

#### Anti-cheat Validation（验收反作弊）

必须提供三种证据：

**1. 命令证据（文件存在 + grep 关键字段）**

执行以下命令并截图：

```bash
# 文件存在性
ls -la Core/Output/PipelineOutput.swift
ls -la Core/Output/OutputManager.swift
ls -la App/Demo/ResultPreviewView.swift

# 关键字段验证
grep -n "buildPlan.*BuildPlan" Core/Output/PipelineOutput.swift
grep -n "static let shared" Core/Output/OutputManager.swift
grep -n "debugSummary\|planSummary" App/Demo/ResultPreviewView.swift
grep -n "OutputManager.shared.save" Core/Pipeline/PipelineRunner.swift
```

**2. 录屏脚本（60 秒，必须两次进入 Preview 且 outputID 相同）**

录屏文件：`phase1-3-preview-replay.mp4`

时间轴：
- 0-15s：选择视频 → Run Enter → Finished
- 15-16s：点击"查看结果"
- 16-30s：验证 Preview 显示（outputID 前 8 位、createdAt、帧网格、debugSummary 原文）
- 30-31s：返回主界面
- 31-32s：再次点击"查看结果"
- 32-45s：验证 outputID 相同，内容一致

**3. 截图要求**

- **Preview 页截图**（必须包含 4 个区域）：
  1. outputID 显示区域（前 8 位）
  2. createdAt 时间戳
  3. 帧网格（至少 1 帧）
  4. `buildPlan.debugSummary` 原文显示（反作弊）
- **调试器命令截图**：
  - `po OutputManager.shared.outputs.count`（应 > 0）
  - `po OutputManager.shared.lastOutputID`（应不为 nil）

#### 提交与回滚

**Commit message 规范**：

```
docs: define Phase 1-3 (Output Artifact & Preview)
```

**回滚方式**：

```bash
git checkout -b rollback/before-phase1-3 main
git revert <phase1-3-commit-hash>
# 创建 PR 并合并
```

---

## 紧急情况例外（极少数）

### 适用场景
- 敏感信息（API Key / Token）泄露
- 合规 / 法律风险
- 严重数据破坏风险

### 处理顺序（必须）
1. **立即轮换 / 吊销密钥**
2. 再处理 Git 历史（必要时使用专用工具）
3. 记录 incident（时间、原因、影响面、修复措施）

> 即便在紧急情况下，**force push 也不是默认选项，而是最后手段**。

---

## 总结（一句话版本）

- Phase 是制度，不是感觉
- Tag 是锚点，不是分支
- main 的历史只能修正，不能改写
- 护栏先行，功能随后

**遵循本文件 = 项目永远可回滚、可协作、可扩展。**