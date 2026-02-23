## 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `aether_cpp/src/tsdf/soft_eviction.cpp` | 修改：定点化衰减 |

---
---

# T14: Meshlet/Cluster LOD 原型 + Two-Pass 遮挡最小链

**依赖**: T06（需要索引化 mesh）, T10（复用 HZB mip chain）
**优先级**: P3（原型，有硬门槛）

## 目标

构建最小可验证原型：将 remesher 输出的 mesh 划分为 64-128 三角形的 meshlet clusters，为 Nanite 式像素级 LOD 选择铺路。

## v1.2 修订：最小链优先策略

> 参考: VTK WebGPU HZB (2025-2026), two-pass hierarchical z-buffer

原始设计仅做 meshlet 划分。当前计划要求先实现 **two-pass occlusion 最小链**，再叠加 cluster LOD：

1. **Pass 1 (coarse)**: 用上一帧 HZB（T10 输出）对 meshlet 粗剔除。通过的 meshlet 送入 GPU 渲染。
2. **Pass 2 (refine)**: 用 Pass 1 更新后的 depth buffer 重建 HZB，对 Pass 1 中被保守拒绝的 meshlet 重测。通过的补充渲染。

这是 Nanite 管线的最小必要子集。VTK WebGPU 实测：two-pass 单独贡献 1.5-1.6x（仅遮挡），结合 frustum culling 可达 5-6x。

**v1.3 澄清：CPU HZB (T10) vs GPU HZB (T14)**：
- T10 构建的是 CPU 侧 32×32 mip chain，用于帧间粗剔除，开销极低。
- T14 的 two-pass 需要 GPU 侧 depth buffer → HZB rebuild（Pass 1 渲染后重建）。这是 **独立于 T10 的 GPU HZB**，不复用 T10 的 CPU mip 数据。
- T14 的依赖 T10 含义是：T10 的 CPU HZB 作为 Pass 1 的输入源（上一帧粗 depth），Pass 2 的 HZB 由 GPU depth buffer 在 Pass 1 后重建。
- **v1.4 修正**：不按 SoC 名称硬编码（例如“A14 以下”），统一采用运行时能力探测（feature gate）。

## v1.4 补充：三端后端矩阵（iOS / Android / 鸿蒙）

| 端 | Mesh Shader 路径 | Two-Pass HZB 路径 | 最低保底 |
|----|------------------|-------------------|---------|
| iOS (Metal) | `MTLDevice` 能力满足 mesh/object shading 时启用 | 支持 | T10 CPU HZB + 普通 draw |
| Android (Vulkan) | `VK_EXT_mesh_shader` + `meshShader/taskShader` 启用 | 支持 | T10 CPU HZB + compute/普通 draw |
| 鸿蒙 (Vulkan/OpenGL) | Vulkan feature 可用时启用；否则走 OpenGL/compute 路径 | 支持（Vulkan） | T10 CPU HZB + 普通 draw |

可选桌面验证（非主验收端）：
- D3D12 (Windows)：`CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7)` 且 `MeshShaderTier != NOT_SUPPORTED` 时启用 mesh shader 路径。

执行顺序：
1. 优先 Tier-A：Mesh Shader + Two-Pass（可用时）。
2. 退化 Tier-B：Two-Pass + 非 Mesh Shader 渲染。
3. 最后 Tier-C：仅 CPU HZB 粗剔除（T10），保证 iOS/Android/鸿蒙 都可运行。

**本 task 的最小链**：
- meshlet 划分 + Pass 1 粗剔除（CPU HZB from T10） = 必须
- Pass 2 补偿渲染（GPU HZB rebuild） = 如 Pass 1 误剔率 > 0.5% 才启用
- Cluster LOD 选择 = 如 meshlet 数 > 500 才启用

## 硬门槛

- 可见召回率 < 99.5%（误剔除过高）→ 止损
- 端到端帧时延无改善 → 止损
- Two-pass 额外开销 > 节省的遮挡计算开销 → 退回单 pass
- 任一主验收端（iOS/Android/鸿蒙）无可用 fallback → 止损
- 不进主线，仅作评估分支

## 止损阈值（v1.2）

| 指标 | 止损线 | 测量方式 |
|------|--------|---------|
| 帧时延改善 | < 5% | A/B 对比 100 帧中位数 |
| 可见召回率 | < 99.5% | 以软件光栅参考可见集对比（每帧） |
| 画质回退 SSIM | < 0.98 | 与无 LOD 参考帧对比 |
| Pass 2 额外耗时 | > Pass 1 的 50% | 独立计时 |
| 内存峰值增长 | > 基线的 130% | 块级内存追踪 |

## 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `aether_cpp/src/render/meshlet_builder.cpp` | 新建 |
| `aether_cpp/include/aether/render/meshlet_builder.h` | 新建 |
| `aether_cpp/src/render/two_pass_culler.cpp` | 新建 (v1.1) |
| `aether_cpp/include/aether/render/two_pass_culler.h` | 新建 (v1.1) |

---
---

# T15: Split-Sum IBL 预计算

**依赖**: 无
**优先级**: P3（原型，有硬门槛）

## 目标

在 `shader_source.cpp` 中新增 Split-Sum 近似的 BRDF LUT 预计算着色器源码。运行时用 256×256 2D 纹理替代每像素的 Cook-Torrance 积分。

## v1.3 补充：解析多项式替代方案

> 参考: Knarkowicz 2014 "Analytical DFG Term for IBL"；2026 年 IBL 实现博文给出工程观察：在其场景中 LUT 超过 128×128 后收益有限。

对移动端（三端中的 iOS / Android / 鸿蒙），LUT 纹理会带来额外纹理绑定 slot 和带宽开销。Knarkowicz 的解析近似 `EnvDFGPolynomial(specularColor, gloss, NdotV)` 用低阶多项式替代 LUT 查找，误差在移动端可接受范围内（PSNR > 42dB vs 全量积分）。

**本 task 应同时评估两条路径**：
1. **LUT 路径**：256×256 RGBA16F 纹理，预计算一次
2. **解析路径**：着色器内 4 行多项式，零额外纹理

验收时对两者分别测量 PSNR 和帧时延。若解析路径 PSNR ≥ 40dB 且帧时延更优，则**三端默认解析路径**；LUT 保留为高质量可选项。

## 硬门槛

- 画质与全量 BRDF 差异 > 视觉可感知 → 止损
- LUT 生成耗时 > 100ms → 止损
- 任一主验收端（iOS/Android/鸿蒙）既无解析路径也无 LUT fallback → 止损
- 不进主线，仅作评估分支

## 止损阈值（v1.2）

| 指标 | 止损线 | 测量方式 |
|------|--------|---------|
| BRDF 近似误差 PSNR | < 40dB | 与全量 Cook-Torrance 参考帧对比 |
| BRDF 近似误差 SSIM | < 0.98 | 与全量 Cook-Torrance 参考帧对比 |
| LUT 生成耗时 | > 100ms（移动端） | iOS / Android / 鸿蒙 三端单次生成计时 |
| 渲染帧时延改善 | < 3% | A/B 对比 100 帧中位数 |
| LUT 纹理内存 | > 512KB | 256×256×RGBA16F |

## 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `aether_cpp/src/render/shader_source.cpp` | 修改：新增 brdf_lut_source() |
| `aether_cpp/include/aether/render/shader_source.h` | 修改：新增声明 |

---
---

# T16: GPU Compute 批量翻转

**依赖**: 无
**优先级**: P3（原型，有硬门槛）

## 目标

将 `compute_flip_states()` 移到统一 GPU Compute 接口（iOS/Android/鸿蒙 三端实现各自 backend），用实例化渲染一次性处理所有翻转片元。CPU fallback 保留。

## 硬门槛

- 翻转片元 < 200 个时无加速 → 止损（GPU dispatch 开销抵消并行收益）
- 与任一端现有图形管线冲突（command/fence/barrier）→ 止损
- 任一主验收端（iOS/Android/鸿蒙）无 CPU fallback → 止损
- 不进主线，仅作评估分支

## 止损阈值（v1.2）

| 指标 | 止损线 | 测量方式 |
|------|--------|---------|
| 片元数阈值 | < 200 | 低于此值 GPU dispatch 开销 > 并行收益 |
| 帧时延改善（≥200 片元） | < 10% | A/B 对比 100 帧中位数 |
| 三端管线兼容 | 任一端出现 command/fence/barrier 冲突 | 编码器切换 / fence 等待超时 |
| CPU fallback 一致性 | 旋转角误差 > 0.5° 或位置误差 > 1e-4 | 与 CPU 参考轨迹逐帧对比 |

## 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `aether_cpp/src/render/flip_animation_gpu.cpp` | 新建 |
| `aether_cpp/include/aether/render/flip_animation_gpu.h` | 新建 |

---
---

# 附录 A: 不修改的文件

以下文件经审计后确认无需改动：

| 文件 | 原因 |
|------|------|
| `shader_source.cpp/h` | ~~纯字符串常量，无算法优化空间~~ **v1.5 修正**：T15 会在此文件新增 `brdf_lut_source()` 着色器源码（Split-Sum LUT 和/或解析多项式）。本文件从"不修改"移至 T15 涉及文件列表。保留此行以记录审计历史。 |
| `screen_detail_selector.cpp/h` | 算法简洁正确，`detail = area_t * 0.7 + display_t * 0.3` 无改进余地 |
| `fracture_display_mesh.cpp/h` | fill_gray 的 smoothstep(0.75, 0.88) 已比 spec 更好 |
| `tsdf_constants.h` | 编译期常量，77 个值已稳定 |
| `flip_animation.cpp/h` | 非主线任务；仅在 T16 原型阶段保留 CPU fallback 对照，不做主线重构 |

---

# 附录 B: 收益预期矩阵（冷静版, v1.6 更新）

| 编号 | 模块 | 改前瓶颈 | 改后预期 | 实际收益需实测 |
|------|------|---------|---------|--------------|
| T01 | tsdf_volume 融合 | 无 SDF 写回 | 完整 TSDF 管线 | **基线建立** ✅ 必须 |
| T01 | tsdf_volume sub-volume | 逐体素遍历截断范围 | sub-volume 粗跳过 | **≥20% 节省** ⚠️ 需实测 (v1.1) |
| T02 | isotropic_remesher 拓扑 | 零约束 | manifold+法向+自交 | **正确性修复** ✅ 必须 |
| T03 | ripple_propagation | O(N²)，N=5000 约 50ms | O(N)，< 0.5ms | **50-100x** ✅ 确定 |
| T04 | isotropic_remesher collapse | O(k·N)，k=50,N=5000 约 10ms | O(k·6)，< 0.1ms | **5-15x** ✅ 确定 |
| T05 | isotropic_remesher flip | 12× acos per flip | 0× acos | **2-3x** ✅ 确定 |
| T06 | marching_cubes 顶点 | 3N 顶点 + 块边界缝隙 | ~N 顶点 + 跨块合并 | 顶点数 **-60%** ✅ 确定 |
| T07 | spatial_hash_table insert | 双探测 + % | 单探测 + & | **~1.5x** ✅ 确定 |
| T08 | dgrut_renderer 排序 | 拷贝整体 | 拷贝索引 + KHR 适配层 | 内存 **-50%** ✅ 确定 |
| T09 | adaptive_resolution pow | 3× pow/call | 1.5× pow/call + 预计算 | **1.5-2x** ⚠️ 需实测 |
| T10 | frustum_culler HZB | 逐像素 | mip 层级 + 分桶统计 | **1.5-3x** ⚠️ 分桶验收 (v1.2) |
| T11 | mesh_extraction_scheduler | 阶跃 halve | EMA 比例 | 稳定性 ⚠️ 需实测 |
| T12 | confidence_decay | 多分支 | branchless | **≥1.3x or 仅清理** ⚠️ AoS 下可能无效 (v1.3) |
| T13 | soft_eviction | float+floor | 定点整数 | **≥2x or 仅清理** ⚠️ 需 microbench (v1.5) |
| T14 | meshlet + two-pass | 三角形级 | 集群级 + HZB 链 | **1.5-6x** ⚠️ 有止损线 (v1.2) |
| T15 | Split-Sum IBL | 每像素全量积分 | LUT 或解析多项式 | **帧时延 ≥3%** ⚠️ 有止损线 (v1.2+v1.3) |
| T16 | GPU Compute 翻转 | CPU 逐片元 | GPU 批量 dispatch | **≥200 片元时 ≥10%** ⚠️ 有止损线 (v1.2) |

---

# 附录 C: 全球前沿参考文献（精选一手来源）

> v1.6 更新：修正 T08 相关来源的状态与链接（Neo 采用 arXiv 预印本口径；CLM 使用正式 DOI；Duplex-GS 修正 arXiv 编号），并补充 OpenHarmony Vulkan 指南（2026-01-21）与 Android Vulkan 设备适配官方建议。非同行评审工程博客仅作辅证，不单独驱动主线决策。

## v1.2 多语言检索覆盖（中/英/法/日/德/西/阿）

| 语言 | 检索密度 | 与本计划直接相关的一手材料 | 结论 |
|------|---------|------------------------|------|
| 中文 | 高 | TSDF/重建（含清华 eTSDF） | 可直接指导 T01/T07 |
| English | 很高 | 论文/规范/官方文档最全 | 作为主判据 |
| Français | 中 | 以英文源转引为主 | 用于交叉验证 |
| 日本語 | 中 | 可检索到网格优化条目索引 | 用于补充，不作唯一依据 |
| Deutsch | 中 | 工程文档与会议信息较多 | 可辅助验证实现路径 |
| Español | 中 | 主要为英文源镜像/报道 | 用于二次核对 |
| العربية | 低 | 与本任务直接相关的一手资料稀疏 | 结论以英文一手源为准 |

## v1.6 证据分级（执行时权重）

- **A 级（强证据）**：同行评审论文、官方规范、官方 API 文档（主决策依据）。
- **B 级（中证据）**：官方博客、官方示例工程（用于工程落地细节）。
- **C 级（弱证据）**：个人技术博客/社区讨论（仅启发，不做单独立项依据）。

## 2026 关键一手来源（按任务映射）

### T01 / T07（TSDF 融合、哈希与块管理）
- **[2026] eTSDF（清华）**: [DOI:10.26599/TST.2025.9010029](https://doi.org/10.26599/TST.2025.9010029)  
  启发点：sub-volume 粗截断跳过可迁移到 CPU 保守分支（T01）。
- **[2026] EC-SLAM（Pattern Recognition）**: [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0031320325006946)  
  启发点：哈希编码与实时约束并行设计（T01/T07）。

### T02（manifold / 法向 / 自交 / inter-angle）
- OpenMesh `is_collapse_ok()`：<https://www.graphics.rwth-aachen.de/media/openmesh_static/Documentations/OpenMesh-6.0-Documentation/a00247.html>
- libigl collapse decimation tutorial：<https://libigl.github.io/tutorial/>
- **[2026] Robust Tessellation with Self-Intersection Detection**（JCDE）：<https://academic.oup.com/jcde/advance-article/doi/10.1093/jcde/qwaf134/8383411>
- **[2026] Local Self-Intersection Repair for Remeshing**（CAD）：<https://www.sciencedirect.com/science/article/pii/S001044852500171X>
- **[2026] Zheng & Lv, "Isotropic Remeshing with Inter-Angle Optimization"**（ICIG 2025 / Springer LNCS 2026）
  启发点：四步重网格化流程中对 collapse/flip 施加 inter-angle 约束（度数判定 + 边界条件），与 T02 约束 A/B 的角度阈值策略直接互补（v1.5, A 级证据）。

### T08（KHR 对齐策略）
- **[2026] KHR_gaussian_splatting（核心规范）**：<https://registry.khronos.org/glTF/extensions/2.0/Khronos/KHR_gaussian_splatting/>
- **[2026] KHR_gaussian_splatting_pbr（可选 PBR）**：<https://registry.khronos.org/glTF/extensions/2.0/Khronos/KHR_gaussian_splatting_pbr/>
- **[2026] KHR_gaussian_splatting_compression_spz**：<https://registry.khronos.org/glTF/extensions/2.0/Khronos/KHR_gaussian_splatting_compression_spz/>
- **[2026] Khronos 技术预览公告**：<https://www.khronos.org/news/press/khronos-releases-technical-preview-of-gltf-extension-for-gaussian-splatting-3d>
- **[2026] Khronos GitHub 扩展状态（RC）**：<https://raw.githubusercontent.com/KhronosGroup/glTF/main/extensions/2.0/Khronos/KHR_gaussian_splatting/README.md>
- **[2026] Khronos GitHub 扩展状态（RC）**：<https://raw.githubusercontent.com/KhronosGroup/glTF/main/extensions/2.0/Khronos/KHR_gaussian_splatting/README.md>
- **[2026] Khronos GitHub 扩展状态（RC）**：<https://raw.githubusercontent.com/KhronosGroup/glTF/main/extensions/2.0/Khronos/KHR_gaussian_splatting/README.md>

### T10 / T14（HZB、Two-Pass 遮挡）
- VTK WebGPU release details（9.4）：<https://docs.vtk.org/en/latest/release_details/9.4/webgpu-occlusion-culler.html>
- VTK `vtkWebGPUComputeOcclusionCuller` API：<https://vtk.org/doc/nightly/html/classvtkWebGPUComputeOcclusionCuller.html>
- Kitware 官方博客（两遍 HZB 实测与流程）：<https://www.kitware.com/webgpu-occlusion-culling-in-vtk/>

### T06（跨块边界去重）
- **Transvoxel Algorithm** (Lengyel, 2010)：<https://transvoxel.org/>
  启发点：1-voxel overlap 策略确保跨块 MC 边产出 bit-exact 顶点（v1.3）。

### T08 / 3DGS 移动端（KHR + 预算排序 + 时序复用）
- **[2026] Mobile-GS: Real-time Gaussian Splatting for Mobile Devices**（ICLR 2026 Poster）：<https://openreview.net/forum?id=vRegY0pgvQ>
  启发点：去排序的 depth-aware OIT 达 116 FPS，对 T08 预算排序策略有参考价值（v1.3）。
- **[2026] Neo: Saving GPU Memory Crisis with GPU-Initiated On-Device 3D Gaussian Splatting**（ASPLOS 2026, KAIST/Meta）：<https://dl.acm.org/doi/10.1145/3669940.3707217>
  启发点：reuse-and-update sorting 利用帧间排序时序相关性，减少 70.4% 内存流量。直接支持 T08 增量排序评估（v1.5, A 级证据）。
- **[2025] Duplex-GS: Cell-level Rasterization Hierarchy**：<https://arxiv.org/abs/2505.11235>
  启发点：双层光栅化减少 sorting overhead，对大规模 splat 场景的预算排序有参考价值（v1.5, B/C 级证据）。
- **[2026] CLM: CPU-Leveraged Memory Optimization for On-Device 3DGS**（ASPLOS 2026, NYU）：<https://dl.acm.org/doi/10.1145/3669940.3707259>
  启发点：利用 CPU 内存缓冲突破 GPU 内存瓶颈，对移动端大场景 splat 管理有参考价值（v1.5, A 级证据）。

### T07（哈希表）
- **[2025] MrHash: Variance-Adaptive Multi-Resolution Voxel Grids**：<https://arxiv.org/abs/2511.21459>
  启发点：flat spatial hash table on GPU，constant-time access，支持动态多分辨率（v1.3）。

### T14 / T15 / T16（原型阶段 2026 前沿）
- **[2026] Real-time Rendering with a Neural Irradiance Volume**（Eurographics 2026）：<https://arxiv.org/abs/2602.12949>
- **[2026] Refine Now, Query Fast**（ICLR 2026）：<https://arxiv.org/abs/2602.15155>
- **[2026] Gaussian Mesh Renderer**（ICASSP 2026）：<https://arxiv.org/abs/2602.14493>
- **[2026] Mesh Splatting**：<https://arxiv.org/abs/2601.21400>
- Apple Metal Mesh Shaders (WWDC 2022)：<https://developer.apple.com/videos/play/wwdc2022/10162/>
