# Aether3D 完整技术计划

> 统一文档：Phase 1-4 + 楔形系统 + App 层连接
> 最后更新：2026-02-26

---

## 全局架构

```
用户扫描物体 → 手机摄像头拍摄
         ↓
┌─────────────────────────────────────────────────┐
│ Phase 2A: 流式帧管线                               │
│   ARFrame → 帧选择 → JPEG 压缩 → 训练队列          │
└──────────────┬──────────────────────────────────┘
               ↓
       ┌───────┴───────┐
       ↓               ↓
┌──────────────┐ ┌──────────────────────────────────┐
│ Phase 2B:    │ │ Phase 3: 3DGS 训练引擎             │
│ 楔形扫描引导  │ │   MVS初始化 → 训练循环 → 导出模型   │
│ (实时视觉反馈) │ │   (边扫边训练，后台线程)             │
└──────┬───────┘ └──────────────┬───────────────────┘
       ↓                        ↓
  用户实时看到:             扫描完成后:
  黑色楔形→白色→消失        3DGS模型上传云端
  (S0→S4→S5)               随时回看/分享
       ↓                        ↓
┌──────────────────────────────────────────────────┐
│ Phase 4: 质量评估 + 证据链                          │
│   PSNR/SSIM → S1-S5分级 → 签名存证                 │
└──────────────────────────────────────────────────┘
```

**为什么需要两条并行管线？**
- **楔形系统**（Phase 2B）：扫描**过程中**的实时视觉反馈，叠加在摄像头画面上，告诉用户"哪里扫到了、质量如何"
- **3DGS 训练**（Phase 3）：扫描**完成后**的离线查看/分享，用户一个月后打开 app 或通过微信分享给别人看到的就是这个

---

## Phase 1: 渲染基础 ✅ 已完成

所有组件已实现并通过测试。

### 1.1 核心组件

| 组件 | 文件 | 状态 |
|------|------|------|
| PLY 加载器 | `aether_cpp/include/aether/splat/ply_loader.h` | ✅ |
| SPZ 解码器 | `aether_cpp/include/aether/splat/spz_decoder.h` + `.cpp` | ✅ |
| PackedSplat 编码 | `aether_cpp/include/aether/splat/packed_splats.h` | ✅ |
| SplatRenderEngine | `aether_cpp/include/aether/splat/splat_render_engine.h` + `.cpp` | ✅ |
| Metal GPU 排序+渲染 | `App/GaussianSplatting/Shaders/GaussianSplat.metal` | ✅ |
| Radix Sort | `aether_cpp/include/aether/splat/radix_sort.h` | ✅ |
| Gaussian 数学库 | `aether_cpp/include/aether/splat/gaussian_math.h` | ✅ |
| Splat C API | `aether_cpp/include/aether/splat/aether_splat_c.h` + `splat_c_api.cpp` | ✅ |
| Swift 桥接 | `App/GaussianSplatting/GaussianSplatViewController.swift` | ✅ |

### 1.2 测试

90+ C++ 单元测试，全部通过。

---

## Phase 2A: 流式帧管线 ✅ 已实现

边扫描边选帧，喂给训练引擎。

### 2A.1 锁无关原语

| 组件 | 文件 | 状态 |
|------|------|------|
| SPSC 无锁队列 | `aether_cpp/include/aether/core/spsc_queue.h` | ✅ |
| Triple Buffer | `aether_cpp/include/aether/core/triple_buffer.h` | ✅ |

### 2A.2 帧选择

| 组件 | 文件 | 状态 |
|------|------|------|
| FrameSelector | `aether_cpp/include/aether/capture/frame_selector.h` | ✅ |
| 选帧标准 | min_displacement=0.05m, min_blur=0.3, 10% holdout测试帧 | ✅ |

### 2A.3 流式管线协调器

| 组件 | 文件 | 状态 |
|------|------|------|
| StreamingPipeline | `aether_cpp/include/aether/pipeline/streaming_pipeline.h` + `.cpp` | ✅ |
| 4线程架构 | 主线程(入队) + eval线程(选帧) + train线程(训练) + IO线程(写盘) | ✅ |

API: `on_frame()` → `finish_scanning()` → `request_enhance()` → `export_ply()`

### 2A.4 C API + Swift 桥接

| 组件 | 文件 | 状态 |
|------|------|------|
| Streaming C API | `aether_cpp/include/aether/pipeline/aether_streaming_c.h` + `streaming_c_api.cpp` | ✅ |
| Swift 桥接 | `Core/Pipeline/NativeStreamingPipelineBridge.swift` | ✅ |
| App 层连线 | `App/Scan/ScanViewModel.swift` — 已接入 streamingBridge | ✅ |

---

## Phase 2B: 楔形扫描引导系统 🔧 待实现

### 用户看到什么

```
扫描开始:
  ┌──────────────────────┐
  │ ██████████████████   │  黑色帐篷状楔形 + 白色边框
  │ ██ S0 ██████ S1 ██  │  覆盖在摄像头画面上
  │ ██████████████████   │  金属质感，随环境光变化
  └──────────────────────┘

扫描进行中:
  ┌──────────────────────┐
  │ ░░░▒▒▒▓▓▓███████   │  已扫区域变浅变白
  │ 原色  S3  S2  S0   │  楔形越来越薄
  │ ░░░▒▒▒▓▓▓███████   │  边框越来越细
  └──────────────────────┘

扫描完成:
  ┌──────────────────────┐
  │ 🍎 原始物体颜色      │  S5区域楔形完全消失
  │ 摄像头画面可见        │  露出真实物体
  │                      │  不渲染任何覆盖层
  └──────────────────────┘
```

### 渲染层架构

```
┌──────────────────────────────────────────────┐
│  Layer 3: SwiftUI HUD (按钮、引导提示)         │
├──────────────────────────────────────────────┤
│  Layer 2: Metal 楔形叠加层 (6-Pass)            │
│  Pass 1: 帐篷填充 + PBR (Cook-Torrance + SH)  │
│  Pass 2: 外轮廓白色边框 (MSDF 3-channel)       │
│  Pass 3: Fresnel 环境反射                      │
│  Pass 4: Oklab 色温校正                        │
│  Pass 5: Cavity AO                            │
│  Pass 6: 蓝噪声纹理感                          │
├──────────────────────────────────────────────┤
│  Layer 1: AR Camera feed (物体原色)             │
└──────────────────────────────────────────────┘
```

### 核心原则

1. **纯视觉优先**：所有空间计算基于拍摄素材语义分析+相机轨迹，LiDAR 可选
2. **算法全 C++ 核心层**：Swift 极致薄
3. **感知驱动**：厚度/亮度/边框用感知空间（Weber-Fechner / Oklab），不用线性插值
4. **信息论保证**：S5 过渡由 DS 不确定性 + Lyapunov 收敛率 + PAC 置信度三重验证
5. **时间稳定性**：EMA 平滑 + 单调性约束（Lyapunov V(t) 只降不升）

### 当前状态：4 个 bug 待修

| Bug | 测试 | 现象 | 根因 |
|-----|------|------|------|
| #4 | testLOD3FlatGeneration | triangleCount=3 不是 1 | Voronoi 碎片化把1个三角形拆成多个 |
| #5 | testLOD3FlatNoExtrusion | vertices=12 不是 3 | 同上 |
| #6 | testLODLevelsGenerateCorrectly | 所有 LOD 都 triangleCount=4 | 同上 |
| #7 | testThicknessCalculation | display=0.5 厚度=display=1.0 厚度 | 厚度动态范围不足 |

### 8 个执行步骤

#### 步骤 1: 移除 Voronoi 碎片化

**问题**：`WedgeGeometryGenerator.generate()` 调用 `fractureTriangles()` → Voronoi 碎片化 → 碎玻璃效果

**修改**：
- `WedgeGeometryGenerator.swift`: 删除 `fractureTriangles()` 调用，1输入=1输出
- `ScanGuidanceRenderPipeline.swift`: 移除 `expandPerTriangleValues()`
- **修复 Bug #4, #5, #6**

#### 步骤 2: 帐篷状楔形 + edge_mask (C++)

**设计**：每个三角形 → 质心沿法线抬起 → 3个子三角形组成帐篷

**感知厚度公式** (Weber-Fechner):
```
thickness = max(0.0002, 0.004 * exp(-3.2 * display) * area_factor)
```

**结构体变更**（已完成 ✅）：
- `wedge_geometry.h`: WedgeVertex + WedgeTriangleInput 新增 `edge_mask`
- `aether_tsdf_c.h`: C API 结构体新增 `edge_mask`

**新增 `generate_tent_wedge()`** 替代 prism 生成函数

#### 步骤 3: 白色边框只画外轮廓 (MSDF)

- 3通道 barycentric SDF + median 运算
- 只对 edge_mask 标记的边画白线
- 高 display 时边框从白色渐变到浅灰（保持对比度）

#### 步骤 4: 自适应聚类 v2 (C++ 核心)

**新增文件**: `adaptive_clustering.h` + `.cpp`

**6维亲和度融合**:
- 距离因子 (30%) + 质量因子 (25%) + 法线一致性 (20%)
- DS不确定性 (10%) + 语义一致性 (10%) + 轨迹密度 (5%)

**时间稳定性**: 匈牙利匹配帧间追踪 + EMA 平滑

#### 步骤 5: S5 透明 + DS不确定性驱动过渡

- 过渡区间由不确定性宽度驱动（高不确定=宽过渡=更保守）
- display >= 0.98 → `discard_fragment()`

#### 步骤 6: 厚度动态范围修复

- gap_width 和 wedge_thickness 解耦
- 感知指数衰减替代线性衰减
- **修复 Bug #7**

#### 步骤 7: PBR 金属质感 + Pass 3-6

- Pass 1: Cook-Torrance + SH IBL + multi-scatter 能量补偿
- Pass 3: Fresnel rim light
- Pass 4: Oklab 冷暖色温
- Pass 5: Cavity AO
- Pass 6: Interleaved gradient noise

#### 步骤 8: 算法下沉 + 空间算法整合

- 删除 `AdaptiveBorderCalculator.swift`（冗余）
- 整合 coverage_estimator / pure_vision_runtime / view_diversity_tracker
- 同一算法自动适配 LiDAR / 纯视觉设备

### 执行顺序

```
步骤 1+2+3+6 → 基本形状正确 (修复全部4个bug)
步骤 4       → 自适应聚类
步骤 5       → S5 信息论过渡
步骤 7       → PBR 视觉质感
步骤 8       → 架构清理
```

---

## Phase 3: 3DGS 训练引擎 ✅ 已实现（核心代码）

**用途**：扫描完成后生成 3D 模型 → 云端存储 → 随时回看 / 微信分享

### 3.1 训练引擎

| 组件 | 文件 | 状态 |
|------|------|------|
| GaussianTrainingEngine | `aether_cpp/include/aether/training/gaussian_training_engine.h` + `.cpp` | ✅ |
| Adam 优化器 | `aether_cpp/include/aether/training/adam_optimizer.h` (header-only) | ✅ |
| 损失函数 | `aether_cpp/include/aether/training/loss_functions.h` (header-only) | ✅ |
| MVS 初始化器 | `aether_cpp/include/aether/training/mvs_initializer.h` (header-only) | ✅ |

### 3.2 训练流程

```
用户扫描 ≥20 帧后:
  MVS 初始化 (Census Transform SGM → dense point cloud)
  ↓
  训练循环 (后台线程):
    forward rasterize → compute loss → backward → Adam update
    每 100 步: densify (split/clone) + prune (remove transparent)
  ↓
  区域收敛检查 → push_splats to render engine
  ↓
  导出: export_ply(path) → 上传云端
```

### 3.3 训练 Metal Shaders

| 组件 | 文件 | 状态 |
|------|------|------|
| GaussianTraining.metal | `App/GaussianSplatting/Shaders/GaussianTraining.metal` | ✅ |

5 个 compute kernel:
1. `forwardRasterize` — tile-based forward
2. `backwardRasterize` — 梯度反向传播
3. `adamUpdate` — 并行 Adam 步
4. `densificationStats` — 屏幕空间梯度累积
5. `compactSplats` — 剪枝后流压缩

### 3.4 训练配置

```
TrainingConfig:
  max_gaussians:             视热状态动态调整
  densify_interval:          100 步
  densify_grad_threshold:    0.0002
  prune_opacity_threshold:   0.005
  max_iterations:            500
  learning_rates:            position / color / opacity / scale / rotation 各自独立
```

### 3.5 S5 到 3DGS 的切换

```
扫描中 (S0→S4):  用户看 = 楔形叠加层 + 摄像头实时画面
扫描完 (S5+):    用户看 = 摄像头实时画面（楔形已消失）
                 后台:   3DGS 模型训练完成 → 上传云端

离线回看:        用户看 = 3DGS 渲染的重建结果（任意角度旋转）
微信分享:        朋友看 = 3DGS 渲染（通过小程序 WebGL/WebGPU）
```

---

## Phase 4: 质量评估 + 证据链 ✅ 已实现

### 4.1 图像质量指标

| 组件 | 文件 | 状态 |
|------|------|------|
| PSNR/SSIM | `aether_cpp/include/aether/quality/image_metrics.h` | ✅ |
| 渲染质量评估 | `aether_cpp/include/aether/quality/render_quality_assessor.h` | ✅ |
| Quality C API | `aether_cpp/include/aether/quality/aether_quality_c.h` + `.cpp` | ✅ |
| Swift 桥接 | `Core/Quality/NativeRenderQualityBridge.swift` | ✅ |

### 4.2 质量分级

| 等级 | PSNR | 含义 |
|------|------|------|
| S5 | ≥ 28 | 专业级 → 签名存证 |
| S4 | ≥ 26 | 高质量 → 提示"增强" |
| S3 | ≥ 24 | 中等 |
| S2 | ≥ 22 | 基础 |
| S1 | < 22 | 低质量 → 提示重扫 |

### 4.3 证据链（已有基础设施）

| 组件 | 文件 | 用途 |
|------|------|------|
| WhiteCommitter | `Core/Quality/WhiteCommitter/WhiteCommitter.swift` | 提交审计记录 |
| ProvenanceBundle | `Core/FormatBridge/ProvenanceBundle.swift` | 附带溯源 |
| MerkleTree | `Core/MerkleTree/MerkleTree.swift` | 包含证明 |
| SignedAuditLog | `Core/Audit/SignedAuditLog.swift` | 签名审计条目 |

### 4.4 ScanViewModel 质量门控

```swift
// App/Scan/ScanViewModel.swift 中的逻辑:
训练完成后评估质量:
  >= S5 → 标记专业级 + 签名存证
  >= S4 → 提示"增强" → streamingBridge.requestEnhance()
  <  S4 → 提示重新扫描
```

---

## App 层连接

### 数据流全景

```
┌─────────────────────────────────────────────────────────┐
│ ARSession.currentFrame                                   │
│   ├── camera.transform (相机位姿)                         │
│   ├── capturedImage (CVPixelBuffer)                      │
│   ├── sceneGeometry (LiDAR mesh, 可选)                   │
│   └── lightEstimate.sphericalHarmonics (9×RGB)           │
└───────────────┬─────────────────────────────────────────┘
                ↓
┌───────────────────────────────────────────────────────────┐
│ ScanViewModel.processARFrame()                            │
│   ├── streamingBridge.onFrame() → Phase 2A 流式管线       │
│   ├── 提取 mesh triangles → Phase 2B 楔形生成             │
│   └── 提取 SH coefficients → Phase 2B PBR 光照           │
└───────────────┬───────────────────────────────────────────┘
                ↓
        ┌───────┴────────┐
        ↓                ↓
┌───────────────┐  ┌─────────────────────────────────┐
│ 楔形管线       │  │ 训练管线                          │
│ coverage_est  │  │ frame_selector                   │
│ → display[]   │  │ → JPEG 压缩                      │
│ → uncertainty │  │ → training engine                │
│ → clustering  │  │ → 3DGS model                    │
│ → tent wedge  │  │ → export PLY → 云端              │
│ → Metal 6Pass │  │                                  │
└───────────────┘  └─────────────────────────────────┘
```

### 关键接入点

| 接入 | 文件 | 状态 |
|------|------|------|
| ScanViewModel → StreamingBridge | `App/Scan/ScanViewModel.swift` | ✅ 已接 |
| ScanViewModel → WedgeGenerator | `App/ScanGuidance/ScanGuidanceRenderPipeline.swift` | ✅ 已接 |
| Viewer → GaussianSplat | `App/Viewer/WhiteboxViewerViewController.swift` | ✅ 已路由 |
| GaussianSplat → SplatEngine | `App/GaussianSplatting/GaussianSplatViewController.swift` | ✅ 已接 |

---

## 纯视觉空间算法（所有手机适配）

### 已有算法矩阵

| 算法 | 文件 | 用途 |
|------|------|------|
| Dempster-Shafer 覆盖估计 | `evidence/coverage_estimator.h` | DS mass → display + uncertainty |
| Fisher 信息加权 | `evidence/coverage_estimator.h` | 连续权重替代离散等级 |
| Lyapunov 稳定性 | `evidence/coverage_estimator.h` | V(t)单调非增保证 |
| PAC 置信度证书 | `evidence/coverage_estimator.h` | per-cell 风险 < 0.01 |
| 纯视觉 8 道门控 | `quality/pure_vision_runtime.h` | 无 LiDAR 质量控制 |
| Census Transform MVS | `training/mvs_initializer.h` | 纯视觉深度重建 |
| 视角多样性追踪 | `evidence/view_diversity_tracker.h` (推断) | 角度桶 + 轨迹密度 |
| 几何-ML 交叉验证 | `quality/geometry_ml_fusion.h` (推断) | 双路验证 |
| 光度一致性检查 | `quality/photometric_checker.h` (推断) | LAB 颜色 + CIEDE2000 |
| 运动分析 | `quality/motion_analyzer.h` (推断) | 快速平移/抖动检测 |
| 语义分割接口 | `geo/semantic_interface.h` (推断) | SAGOnline / UniCLift / LatentAM |
| Marching Cubes | `tsdf/marching_cubes.h` | SDF → mesh |
| 自适应分辨率 | `tsdf/adaptive_resolution.h` | 深度+质量驱动体素大小 |

### LiDAR vs 纯视觉自动适配

```
有 LiDAR:
  ARKit sceneGeometry → 高精度 mesh → DS 不确定性低
  → 聚类更细致 → 小楔形 → 快速到达 S5

无 LiDAR:
  MVS Census Transform → 中精度 mesh → DS 不确定性高
  → 聚类更粗 → 大楔形 → 需要更多扫描角度
  → 同一算法，自动适配
```

---

## 前沿研究融合

| 来源 | 应用 |
|------|------|
| Google Filament 2025 | roughness≥0.045 地板、cross-product GGX、multi-scatter 能量补偿 |
| Chlumský MSDF | 3通道 barycentric SDF + median → 边框角点无锯齿 |
| Jorge Jimenez SIGGRAPH 2014 | Interleaved gradient noise 替代 sin-hash |
| Weber-Fechner 感知律 | 厚度 exp(-k*display) 感知指数衰减 |
| Oklab (Ottosson 2020) | 色温映射 + fill color |
| Dempster-Shafer | 不确定性驱动 S5 过渡带 + 聚类保守性 |
| 匈牙利匹配 | 帧间 cluster ID 追踪 |

## 自研创新

| 创新 | 描述 |
|------|------|
| DS-不确定性驱动过渡带 | 用 DS 不确定性宽度动态控制 S4→S5 渐变区间 |
| 6维亲和度融合聚类 | 距离+质量+法线+不确定性+语义+轨迹密度 |
| Weber-Fechner 感知厚度 | 对数感知律替代线性衰减 |
| 匈牙利匹配+EMA 时间稳定 | 帧间 cluster 追踪防闪烁 |
| LiDAR-agnostic 自适应 | 不确定性驱动，同一算法两种设备 |

---

## 总文件清单

### Phase 2B 楔形系统（待实现）

| 操作 | 文件 | 步骤 |
|------|------|------|
| 修改 | `Core/Quality/Geometry/WedgeGeometryGenerator.swift` | 1,2,4 |
| 修改 | `App/ScanGuidance/ScanGuidanceRenderPipeline.swift` | 1,8 |
| 修改 | `aether_cpp/src/render/wedge_geometry.cpp` | 2 |
| 修改 | `aether_cpp/include/aether/render/wedge_geometry.h` | 2 ✅已改 |
| 修改 | `aether_cpp/include/aether_tsdf_c.h` | 2 ✅已改 |
| 修改 | `aether_cpp/src/c_api.cpp` | 2,4,8 |
| 修改 | `aether_cpp/src/render/fracture_display_mesh.cpp` | 5,6 |
| 修改 | `App/ScanGuidance/Shaders/ScanGuidance.metal` | 3,5,7 |
| 修改 | `App/ScanGuidance/ScanGuidanceVertexDescriptor.swift` | 3 |
| 新增 | `aether_cpp/include/aether/render/adaptive_clustering.h` | 4 |
| 新增 | `aether_cpp/src/render/adaptive_clustering.cpp` | 4 |
| 删除 | `Core/Quality/Visualization/AdaptiveBorderCalculator.swift` | 8 |
| 修改 | `Package.swift` | 8 |
| 修改 | `aether_cpp/include/module.modulemap` | 8 |

### 已完成文件（Phase 1 + 2A + 3 + 4）

Phase 1: 12 文件 (splat/, render/)
Phase 2A: 8 文件 (core/, capture/, pipeline/)
Phase 3: 6 文件 (training/, Shaders/)
Phase 4: 4 文件 (quality/)
App 层: 4 文件 (Scan/, Viewer/, GaussianSplatting/)

---

## 验证计划

```bash
# 1. C++ 单元测试
cd /Users/kaidongwang/Documents/Aether3D
# 运行全部 C++ 测试 (90+ tests)

# 2. Swift 测试
swift test --filter WedgeGeometryTests
# 预期: 9 个测试全部 ✅ (修复 bug #4-#7 后)

# 3. 全量 Swift 测试
swift test
# 预期: 0 unexpected failures

# 4. Xcode 编译
xcodebuild build -project Aether3DApp.xcodeproj -scheme Aether3DApp -destination 'generic/platform=iOS'
# 预期: BUILD SUCCEEDED

# 5. 视觉验证 (实机)
# ✅ 帐篷状楔形（中心凸起）
# ✅ 白色边框只在外轮廓
# ✅ 远处大区域，近处小区域
# ✅ S5 完全透明
# ✅ 金属质感随环境光变化
# ✅ 无"碎玻璃散落"效果
# ✅ 无闪烁

# 6. 性能验证
# iPhone 12 (A14, 无 LiDAR), 7000 三角形 → >= 58 FPS
```
