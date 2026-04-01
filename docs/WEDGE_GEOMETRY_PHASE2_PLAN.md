# 楔形几何 Phase 2 — 完整执行计划 v4

> **v4 变更**：增加前沿研究融合、现有空间算法整合、v3 批判性分析、多重验证策略、
> 全纯视觉架构（无 LiDAR 依赖）、自研算法方案

---

## 第一部分：v3 计划的批判性分析

### 1.1 方法论缺陷

| 缺陷 | 分析 | v4 方案 |
|------|------|---------|
| Union-Find 聚类缺乏感知一致性 | v3 仅用欧几里得距离+质量做合并，忽略了法线方向变化。弧面和平面交界处的三角形被错误合并会产生视觉断裂 | 引入法线角度约束：相邻三角形法线夹角 > 30° 时禁止合并 (谱图聚类启发) |
| 无时间一致性保证 | 每帧独立算聚类，相邻帧的 cluster 可能剧烈跳变 → 闪烁 | 引入 EMA 时间平滑 + cluster ID 帧间追踪（匈牙利匹配） |
| 厚度公式使用固定指数 | `pow(1-d, 0.86)` 在 d=0.4~0.6 区间衰减过快，实际手持设备上 S2→S3 的视觉落差太大 | 使用 Oklab 感知亮度映射驱动厚度（Weber-Fechner 对数感知律），确保等距 display 增量产生等距视觉厚度变化 |
| PBR 单光源模型 | v3 Pass 1 只用单一 primaryLightDirection，ARKit 球谐系数（9系数L2）只做 ambient | 球谐驱动完整 IBL：用 SH 做 diffuse irradiance（已有），加 prefiltered specular approximation（Split-Sum近似，无 IBL cubemap 但可用 SH 拟合 dominant direction 做 approximate reflection）|
| S4→S5 过渡硬编码阈值 | `smoothstep(0.85, 0.98)` 不考虑每个 cell 的 DS 不确定性宽度 | 引入已有 `uncertainty_width` 驱动过渡区间：高不确定性 → 宽过渡带（更保守），低不确定性 → 快速过渡 |
| 边框无 MSDF 抗锯齿 | barycentric SDF 在三角形边缘精度低，远距离出现 aliasing | 使用多通道 SDF (MSDF) 思路：3 通道分别对应 3 条 barycentric 边，中值运算获得精确距离，消除角点 artifact |

### 1.2 数值精度风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| `half` 精度不足 | `NDF_GGX_Safe` 在 roughness<0.1 时 `a2=a*a` 在 half 下可能 underflow → specular 闪烁 | 已使用 Filament cross-product 技巧（`cross(N,H)²`），但额外添加 `roughness = max(roughness, 0.045h)` 地板值（Filament 2025 推荐最低值） |
| `fwidth()` 在瓦片边界不连续 | GPU tile-based 架构下 fwidth() 在 tile 边缘产生跳变 → 边框宽度抖动 | 使用 `max(fwidth(bary.x), fwidth(bary.y), fwidth(bary.z))` 取全局最大值做宽度标准化 |
| 大深度下的 `depth_gap_scale` 溢出 | safe_depth clamp 到 3.0m，但纯视觉方案下 MVS 深度可能 >5m | 扩展 `safe_depth` 上限到 8.0m，增加 `depth_norm = log1p(safe_depth) / log1p(8.0)` 对数映射 |

### 1.3 用户体验隐患

| 隐患 | 场景 | 修复 |
|------|------|------|
| 帐篷厚度在低质量时过高 | S0 display=0 时 peak 凸起 8mm，大面积扫描初期整个表面看起来"起泡" | 限制最大视觉凸起为 4mm (原 8mm/2)，且让凸起高度与 `1-display` 的**感知**而非线性值成正比 |
| 翻转动画与聚类变化冲突 | 聚类在帧间重新分配后，正在翻转的三角形可能 cluster_id 突变 → 动画断裂 | 翻转锁：正在播放动画的三角形的 cluster_id 在动画期间冻结 |
| 涟漪跨聚类传播语义不清 | 涟漪 BFS 基于 mesh 邻接，但聚类合并后视觉上只有 cluster 边界可见 → 涟漪在视觉上"穿透"无边框的内部 | 涟漪 BFS 改为双层：cluster 内部快速传播（无视觉表现），cluster 边界处产生可见波纹 |
| 文字白色+背景白色冲突 | S4 附近楔形 fill_gray → 1.0（白色），此时白色边框不可见 | 在 display > 0.7 时边框从纯白渐变到浅灰（`border_luminance = 1.0 - 0.2 * smoothstep(0.7, 0.9, display)`），保持对比度 |

### 1.4 纯视觉架构缺口

v3 计划完全没有说明空间数据从何而来。以下是关键整合点：

| 需要 | 数据源 | 现有算法 |
|------|--------|----------|
| 三角形网格 | ARKit scene geometry (LiDAR) **或** MVS dense reconstruction (纯视觉) | `mvs_initializer.h` → Census Transform SGM → dense point cloud → marching cubes → mesh |
| 每三角形 display 值 | Coverage estimator → DS mass function → belief coverage | `coverage_estimator.h` → Dempster-Shafer + Fisher weighting |
| 相机位置 | ARSession.currentFrame.camera.transform | 已有 |
| 环境光 SH 系数 | ARFrame.lightEstimate.sphericalHarmonicsCoefficients | 已有（9×RGB） |
| 三角形邻接图 | mesh topology → half-edge 或 shared-vertex 查询 | **缺失** — 需要新增 |
| 语义分区 | 语义分割 → 同语义三角形优先合并 | `semantic_interface.h` → SAGOnline / UniCLift / LatentAM |
| 拍摄轨迹引导 | 相机轨迹密度 → 区域 evidence 权重 | `view_diversity_tracker.h` → 角度桶 + Fisher info |
| 纯视觉质量门控 | 8 道门控无 LiDAR 依赖 | `pure_vision_runtime.h` → baseline_pixels / blur / ORB / parallax / depth_sigma / closure / unknown_voxel / thermal |

---

## 第二部分：设计愿景（v4 修订）

### 2.1 渲染层架构
```
┌──────────────────────────────────────────────┐
│  Layer 3: SwiftUI HUD (按钮、引导提示)         │  ← 最上面
├──────────────────────────────────────────────┤
│  Layer 2: Metal 楔形叠加层                     │  ← 本计划核心
│  Pass 1: 帐篷填充 + PBR (Cook-Torrance + SH IBL) │
│  Pass 2: 外轮廓白色边框 (MSDF-like 3-channel)    │
│  Pass 3: Fresnel 环境反射                       │
│  Pass 4: Oklab 色温校正                         │
│  Pass 5: 感知空间环境遮蔽 (Cavity AO)            │
│  Pass 6: 时域蓝噪声纹理感 (STBN替代sin-hash)     │
├──────────────────────────────────────────────┤
│  Layer 1: AR Camera feed (物体原色)             │  ← 最底层
└──────────────────────────────────────────────┘
```

### 2.2 核心原则

1. **纯视觉优先**：所有空间计算基于 `footage semantic analysis + camera trajectory`，LiDAR 只是可选精度增强
2. **算法全 C++ 核心层**：Swift 极致薄（ARKit 数据提取 → C API → 结果 → GPU 上传）
3. **感知驱动**：所有视觉量（厚度、亮度、边框宽度、alpha）使用感知空间（Weber-Fechner / Oklab / Stevens' Power Law），不使用线性插值
4. **信息论保证**：S5 过渡由 DS 不确定性宽度 + Lyapunov 收敛率 + PAC 置信度三重验证
5. **时间稳定性**：所有帧间变化使用 EMA 平滑 + 单调性约束（Lyapunov V(t) 只降不升）
6. **热自适应**：通过 thermalAdapter 控制 LOD + pass mask，严重过热时只保留 Pass 1-2

---

## 第三部分：8 个执行步骤（v4 增强版）

### 步骤 1: 移除 Voronoi 碎片化 + 1输入=1输出

**根本问题**：`WedgeGeometryGenerator.generate()` 调用 `fractureTriangles()` → `aether_generate_fracture_display_triangles()` → Voronoi 碎片化 → 碎玻璃效果。

**修改清单**：

**`Core/Quality/Geometry/WedgeGeometryGenerator.swift`**：
- `generate()` 方法：删除 `fractureTriangles()` 调用
- 直接遍历输入 `triangles[]`，每个三角形直接构造 `FractureTriangle` (1:1 映射)
- `lastTriangleParentIndices` = `[0, 1, 2, ..., n-1]`
- 保留 `stylePatchKey` 生成（对 C++ style runtime 的 non-rollback 状态至关重要）
- 保留 `fallbackTriangles()` 作为安全后退

**`App/ScanGuidance/ScanGuidanceRenderPipeline.swift`**：
- 移除 `expandPerTriangleValues()` 的使用（动画/边框数组已经 1:1）
- 简化 `update()` 数据流

**测试预期**：
- `testLOD3FlatGeneration` ✅ (1输入→1输出→3v/3i)
- `testLOD3FlatNoExtrusion` ✅ (3v/3i)
- `testLODLevelsGenerateCorrectly` ✅ (triangleCount=1)

---

### 步骤 2: 帐篷状楔形 + edge_mask（C++ 核心层）

**设计**：每个输入三角形 → 质心沿法线抬起 → 3个子三角形组成帐篷。

**感知厚度公式**（Weber-Fechner 对数感知律）：

```
// C++ core — replace linear decay with perceptual curve
float perceptual_thickness(float display, float area_sq_m, float median_area) {
    float d = clamp(display, 0.0f, 1.0f);

    // Weber-Fechner: 感知差异 ∝ log(stimulus)
    // 映射 display → 感知空间：thickness ∝ exp(-k * display)
    // 这确保 display 每增加 0.1 产生的视觉厚度变化是等距的
    float perceptual_decay = exp(-3.2f * d);  // 3.2 = tuned for 0→1 range

    float area_ratio = sqrt(max(area_sq_m, 1e-8f) / max(median_area, 1e-6f));
    float area_factor = clamp(area_ratio, 0.5f, 2.0f);

    float base = 0.004f;   // 4mm base (down from 8mm — v3 critique)
    float minimum = 0.0002f; // 0.2mm floor

    return max(minimum, base * perceptual_decay * area_factor);
}
```

**C++ 文件 `aether_cpp/src/render/wedge_geometry.cpp`**：

新增 `generate_tent_wedge()`，替代所有 prism 生成函数：

```cpp
void generate_tent_wedge(
    const WedgeTriangleInput& tri,
    const innovation::Float3& normal,
    uint8_t edge_mask,  // 从聚类算法获得
    std::vector<WedgeVertex>* verts,
    std::vector<uint32_t>* indices)
{
    // 质心
    Float3 centroid = mul3(add3(add3(tri.v0, tri.v1), tri.v2), 1.0f/3.0f);
    // Peak = 质心沿法线抬起 thickness
    Float3 peak = add3(centroid, mul3(normal, tri.thickness));

    uint32_t base = static_cast<uint32_t>(verts->size());

    // 3个子三角面的法线
    Float3 n01 = safe_face_normal(tri.v0, tri.v1, peak, normal);
    Float3 n12 = safe_face_normal(tri.v1, tri.v2, peak, normal);
    Float3 n20 = safe_face_normal(tri.v2, tri.v0, peak, normal);

    // 子三角形 0: (v0, v1, peak)
    // edge_mask bit 0 = v0-v1 边是否为外轮廓
    uint8_t em0 = (edge_mask & 0x01);
    append_vertex_em(verts, tri.v0, n01, tri, em0);
    append_vertex_em(verts, tri.v1, n01, tri, em0);
    append_vertex_em(verts, peak,  n01, tri, em0);

    // 子三角形 1: (v1, v2, peak)
    uint8_t em1 = (edge_mask & 0x02) ? 0x01 : 0x00;
    append_vertex_em(verts, tri.v1, n12, tri, em1);
    append_vertex_em(verts, tri.v2, n12, tri, em1);
    append_vertex_em(verts, peak,  n12, tri, em1);

    // 子三角形 2: (v2, v0, peak)
    uint8_t em2 = (edge_mask & 0x04) ? 0x01 : 0x00;
    append_vertex_em(verts, tri.v2, n20, tri, em2);
    append_vertex_em(verts, tri.v0, n20, tri, em2);
    append_vertex_em(verts, peak,  n20, tri, em2);

    for (int i = 0; i < 3; ++i)
        append_tri(indices, base+i*3, base+i*3+1, base+i*3+2);
}
```

**LOD 级别重新定义**：

| LOD | 形状 | 顶点 | 索引 | 用途 |
|-----|------|------|------|------|
| LOD3 (flat) | 平面三角形 | 3 | 3 | 超远/热节流/S5附近 |
| LOD2 (low) | 帐篷（无底面） | 9 | 9 | 中远距离 |
| LOD1 (medium) | 帐篷+底面封闭 | 12 | 18 | 中距离 |
| LOD0 (full) | 帐篷+底面+edge chamfer | 18 | 30 | 近距离 |

**结构体修改**：

`aether_cpp/include/aether/render/wedge_geometry.h`：
```cpp
struct WedgeVertex {
    innovation::Float3 position;
    innovation::Float3 normal;
    float metallic{0.0f};
    float roughness{0.0f};
    float display{0.0f};
    float thickness{0.0f};
    std::uint32_t triangle_id{0u};
    std::uint8_t edge_mask{0x07u};  // 新增: 3 bits for 3 edges, default=all outer
    std::uint8_t padding[3]{};      // 对齐到 4 bytes
};

struct WedgeTriangleInput {
    // ... existing fields ...
    std::uint8_t edge_mask{0x07u};  // 新增: 聚类算法设置
};
```

`aether_cpp/include/aether_tsdf_c.h`：
```c
typedef struct {
    // ... existing fields ...
    uint8_t edge_mask;
} aether_wedge_vertex_t;

typedef struct {
    // ... existing fields ...
    uint8_t edge_mask;
} aether_wedge_input_triangle_t;
```

`Core/Quality/Geometry/WedgeGeometryGenerator.swift` — `WedgeVertexCPU` 新增 `edgeMask: UInt8`。

---

### 步骤 3: 白色边框只画外轮廓 (MSDF-like 精确 SDF)

**核心改进**：从 v3 的单通道 `min(bary.x, bary.y, bary.z)` 升级为 3 通道独立 SDF，仅对 edge_mask 标记的边计算距离。

**Metal shader 关键代码**：

```metal
// ScanGuidance.metal — borderStrokeFragment 重写

struct BorderVertexOut {
    // ... existing VertexOut fields ...
    uint  edgeMask;  // 从 vertex buffer 传入
};

fragment half4 borderStrokeFragment(
    BorderVertexOut in [[stage_in]],
    float3 bary [[barycentric_coord]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    float borderWidth = max(in.borderWidth, 0.0);
    half borderAlpha = clamp(half(in.borderAlpha), 0.0h, 1.0h);

    if (borderWidth < in.borderMinWidth || borderAlpha <= in.borderMinAlpha) {
        discard_fragment();
    }

    // MSDF-like: 3 通道分别对应 3 条 barycentric 边
    // 只对 edge_mask 标记的边计算距离
    float3 edgeDists = float3(1e10, 1e10, 1e10);
    if (in.edgeMask & 0x01u) edgeDists.x = bary.z;  // edge v0-v1 的距离 = bary of opposite vertex
    if (in.edgeMask & 0x02u) edgeDists.y = bary.x;  // edge v1-v2
    if (in.edgeMask & 0x04u) edgeDists.z = bary.y;  // edge v2-v0

    // MSDF 中值运算：消除角点 artifact
    float edgeDist = median3(edgeDists.x, edgeDists.y, edgeDists.z);
    if (edgeDist > 0.5) {
        // 如果所有标记边都很远，用最小距离回退
        edgeDist = min3(edgeDists.x, edgeDists.y, edgeDists.z);
    }

    if (edgeDist > 0.99) discard_fragment();

    // fwidth 标准化 — 取全局最大值避免 tile 边界不连续
    float fw = max(max(fwidth(bary.x), fwidth(bary.y)), fwidth(bary.z));
    fw = max(fw, in.borderFwidthEpsilon);

    float borderBaryWidth = borderWidth * fw;
    float aa = fw * max(in.borderAAFactor, 0.0);
    float edgeMask = 1.0 - smoothstep(borderBaryWidth, borderBaryWidth + aa, edgeDist);

    half alpha = borderAlpha * half(clamp(edgeMask, 0.0, 1.0));
    if (alpha <= half(in.borderDiscardAlpha)) discard_fragment();

    // v4: 高 display 时边框从白色渐变到浅灰，保持与浅色填充的对比度
    half borderLum = 1.0h - 0.2h * half(smoothstep(0.7, 0.9, in.display));
    half3 borderColor = half3(borderLum);
    borderColor *= alpha;

    return half4(borderColor, alpha);
}

// MSDF 中值函数
inline float median3(float a, float b, float c) {
    return max(min(a, b), min(max(a, b), c));
}

inline float min3(float a, float b, float c) {
    return min(a, min(b, c));
}
```

**`App/ScanGuidance/ScanGuidanceVertexDescriptor.swift`**：
- attribute(7) = edgeMask, format `.uchar`, offset after `triangleId`
- stride 调整 (原 44 → 48 bytes with edge_mask + 3 padding)

---

### 步骤 4: 自适应聚类 v2（C++ 核心·空间感知·时间稳定）

**新增 C++ 文件**：
- `aether_cpp/include/aether/render/adaptive_clustering.h`
- `aether_cpp/src/render/adaptive_clustering.cpp`

**算法设计**（融合前沿研究 + 已有空间算法）：

```
================================================================================
自适应聚类 v2: 多信号融合 + 时间稳定 + 语义感知
================================================================================

输入：
  triangles[N]           — mesh 三角形 (vertices + normals + areas)
  display[N]             — 每三角形 DS-belief evidence [0,1]
  uncertainty[N]         — DS uncertainty width (plausibility - belief) [0,1]
  camera_position        — 当前相机世界坐标
  camera_trajectory[K]   — 最近 K 帧相机位置 (轨迹密度分析)
  semantic_labels[N]     — 语义标签 (来自 semantic_interface.h, 可选)
  prev_cluster_ids[N]    — 上一帧的聚类 ID (时间稳定性)

输出：
  cluster_id[N]          — 每三角形属于哪个聚类
  cluster_count          — 聚类总数
  boundary_edge_mask[N]  — 每三角形 3 bits 标记哪些边在聚类边界

================================================================================
Phase A: 邻接图构建 (half-edge extraction)
================================================================================

从 mesh face_indices 构建 CSR 格式邻接图。
对每对相邻三角形 (i, j)：
  - 共享顶点 → 相邻
  - 存储共享边的两个顶点索引（用于 boundary_edge_mask 计算）

================================================================================
Phase B: 合并亲和度计算 (多信号融合)
================================================================================

对每对相邻三角形 (i, j)，计算合并亲和度 affinity(i,j) ∈ [0,1]:

  1. 距离因子 (纯视觉深度)
     centroid_i = mean(v0_i, v1_i, v2_i)
     depth_i = ||centroid_i - camera_position||

     # 对数映射 (v3 critique: 3m 线性上限不够)
     depth_norm_i = log1p(depth_i) / log1p(8.0)

     distance_affinity = 0.5 * (depth_norm_i + depth_norm_j)

  2. 质量因子 (evidence-driven)
     # 低质量 → 高亲和度 (合并成大块)
     # 高质量 → 低亲和度 (保持细节)
     quality_affinity = 1.0 - 0.5 * (display_i + display_j)

  3. 法线一致性约束 (v3 缺失 — 谱图聚类启发)
     cos_angle = dot(normal_i, normal_j)
     # 法线夹角 > 30° (cos < 0.866) → 强烈惩罚
     normal_affinity = smoothstep(0.5, 0.95, cos_angle)

  4. 不确定性感知 (利用 DS mass function)
     # 高不确定性 → 保守不合并 (信息不够不要冒险)
     uncertainty_penalty = 0.5 * (uncertainty_i + uncertainty_j)

  5. 语义一致性 (如果可用)
     semantic_affinity = (semantic_labels[i] == semantic_labels[j]) ? 1.0 : 0.3

  6. 轨迹密度感知 (利用 camera trajectory)
     # 相机轨迹在该区域附近经过多少次 → view diversity
     # 高 view diversity → 更高置信度 → 允许更细的分区
     trajectory_density = count_trajectory_points_within(centroid_i, 0.5m, camera_trajectory)
     trajectory_penalty = min(1.0, trajectory_density / 10.0)  # 多次经过 → 惩罚合并

  最终:
  affinity(i,j) = distance_affinity * 0.30
                + quality_affinity * 0.25
                + normal_affinity * 0.20
                + (1.0 - uncertainty_penalty) * 0.10
                + semantic_affinity * 0.10
                + (1.0 - trajectory_penalty) * 0.05

================================================================================
Phase C: Union-Find 合并（带约束）
================================================================================

  1. 初始化：每个三角形自成一组
  2. 所有邻接对按 affinity 降序排列
  3. 遍历：
     for (i, j) in sorted_pairs:
       if affinity(i,j) < merge_threshold: break

       # 约束检查
       root_i = find(i), root_j = find(j)
       if root_i == root_j: continue

       # 大小约束 (动态)
       max_size = dynamic_max_cluster_size(depth_norm, display)
       if cluster_size[root_i] + cluster_size[root_j] > max_size: continue

       # 法线散度约束: cluster 内法线标准差不能太大
       if merged_normal_variance(root_i, root_j) > 0.15: continue

       union(root_i, root_j)

  dynamic_max_cluster_size:
    far + low_quality: 80 三角形 (一面墙 2-3 个楔形)
    near + high_quality: 1 三角形 (不合并)
    公式: max(1, int(80 * depth_norm * (1 - display)))

================================================================================
Phase D: 时间稳定性 (帧间平滑)
================================================================================

  # 匈牙利匹配: 当前帧 cluster → 上一帧 cluster
  # 基于 Jaccard 相似度 (交集/并集)

  for each current_cluster:
    overlap = count_triangles_in_common(current_cluster, prev_cluster)
    jaccard = overlap / (|current| + |prev| - overlap)
    if jaccard > 0.6: inherit prev_cluster_id
    else: assign new cluster_id

  # EMA 对 cluster 属性 (颜色、边框宽度等) 做时间平滑
  # alpha = 0.15 (来自 CoverageEstimatorConfig.ema_alpha)

================================================================================
Phase E: 边界标记 (boundary_edge_mask)
================================================================================

  for each triangle i:
    for each edge e of triangle i (0=v0v1, 1=v1v2, 2=v2v0):
      neighbor_j = adjacency[i][e]
      if neighbor_j < 0 or cluster_id[i] != cluster_id[neighbor_j]:
        boundary_edge_mask[i] |= (1 << e)  # 这条边是聚类边界
```

**merge_threshold 自适应**：
- 初始值 0.35
- 如果聚类结果产生超过 2000 个 cluster: 降低 threshold → 更多合并
- 如果聚类结果产生少于 100 个 cluster: 提高 threshold → 更多分裂
- 使用二分搜索在 [0.2, 0.7] 之间找到目标 cluster 数量

**C API**：
```c
int aether_compute_adaptive_clusters(
    const aether_float3_t* vertices,       // [V] 顶点位置
    const int32_t* face_indices,           // [N*3] 面索引
    int32_t triangle_count,
    const float* normals,                  // [N*3] 每三角形法线
    const float* display_values,           // [N] evidence
    const float* uncertainty_values,       // [N] DS 不确定性宽度 (可为 NULL)
    aether_float3_t camera_position,
    const aether_float3_t* camera_trajectory, // [K] 可为 NULL
    int32_t trajectory_count,
    const int32_t* semantic_labels,        // [N] 可为 NULL
    const int32_t* prev_cluster_ids,       // [N] 可为 NULL
    int32_t* out_cluster_ids,              // [N]
    uint8_t* out_boundary_edge_mask,       // [N] 3 bits per triangle
    int32_t* out_cluster_count
);
```

**性能预算**：
- N=7000 三角形 (nominal tier): <2ms on A14 单核
- Union-Find: O(N α(N)) ≈ O(N)
- 邻接排序: O(E log E) ≈ O(3N log N)
- 匈牙利匹配: O(C²) where C = cluster_count ≈ 50-200

---

### 步骤 5: S5 完全透明 + DS 不确定性驱动过渡

**v4 改进**：过渡区间不再硬编码，而是由 DS 不确定性宽度驱动。

**C++ `fracture_display_mesh.cpp` — `compute_visual_params()` 修改**：

```cpp
// 新增输入参数: uncertainty_width (来自 CoverageResult)
FragmentVisualParams compute_visual_params(
    float display, float depth, float triangle_area, float median_area,
    float uncertainty_width /* NEW */)
{
    // ... existing code ...

    // S5 过渡区间由不确定性驱动
    // 高不确定性 (0.15) → 宽过渡带 [0.80, 0.98]
    // 低不确定性 (0.02) → 窄过渡带 [0.92, 0.98]
    float uw = clamp(uncertainty_width, 0.01f, 0.20f);
    float fade_start = 0.98f - 0.18f * (uw / 0.15f);  // [0.80, 0.98]
    fade_start = clamp(fade_start, 0.80f, 0.95f);

    float fade_end = 0.98f;  // 固定上限

    if (d >= fade_start) {
        float fade = smoothstep(fade_start, fade_end, d);
        p.fill_opacity = max(0.0f, 1.0f - fade);
        p.border_alpha *= (1.0f - fade);
        p.border_width_px *= (1.0f - fade);
        p.wedge_thickness *= (1.0f - fade);
    }

    if (d >= fade_end) {
        p.fill_opacity = 0.0f;
        p.border_alpha = 0.0f;
        p.border_width_px = 0.0f;
        p.wedge_thickness = 0.0f;
    }
}
```

**Metal shader**：
```metal
// wedgeFillFragment — S5 discard
if (in.display >= 0.98) {
    discard_fragment();
}

// 不再使用 stochastic dither，改用 smoothstep alpha blend
// fill_opacity 已经在 C++ core 中由 DS uncertainty 驱动计算
// 直接使用 vertex 传入的 opacity
```

---

### 步骤 6: 厚度动态范围修复 + 感知解耦

**C++ `fracture_display_mesh.cpp`**：

```cpp
// 1. gap_width 和 wedge_thickness 完全解耦
// gap_width 控制三角形间隙 (聚类后此概念弱化)
// wedge_thickness 控制帐篷凸起高度

// 2. 厚度使用 Weber-Fechner 感知曲线
const float thickness_base = 0.004f;  // 4mm (v3 critique: 从 8mm 降低)
const float thickness_min  = 0.0002f; // 0.2mm
const float perceptual_decay = exp(-3.2f * d);
float area_ratio = sqrt(max(1e-8f, triangle_area) / max(median_area, 1e-6f));
float area_factor = clamp(area_ratio, 0.5f, 2.0f);

// 深度感知 (对数映射)
float depth_scale = 0.6f + 0.4f * log1p(safe_depth) / log1p(8.0f);

p.wedge_thickness = max(thickness_min, thickness_base * perceptual_decay * area_factor * depth_scale);

// gap_width 极小 (聚类后三角形密铺，gap 只用于视觉微调)
p.gap_width = max(0.00001f, 0.0003f * perceptual_decay * area_factor);
```

**测试修复**：`testThicknessCalculation` 的 `display=0.5` 现在用感知曲线：
- `exp(-3.2 * 0.5) = 0.2019` vs `exp(-3.2 * 1.0) = 0.0408`
- 差异足够大，中间值明显大于最小值 ✅

---

### 步骤 7: PBR 金属质感 + 环境光照 (Pass 1 整合 + Pass 3-6)

**v4 增强**：基于 Google Filament 2025 移动 PBR 流程 + ARKit SH 系数驱动。

#### Pass 1: Wedge Fill + Full PBR

```metal
fragment half4 wedgeFillFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &u [[buffer(1)]]
) {
    if (in.display >= 0.98) discard_fragment();

    // Base color: Oklab 感知映射
    half3 baseColor = evidenceToOklabColor(half(in.display));
    half metallic = half(in.metallic);
    half roughness = max(half(in.roughness), 0.045h); // Filament minimum

    half3 N = normalize(half3(in.worldNormal));
    half3 V = normalize(half3(u.cameraPosition - in.worldPosition));

    // Primary directional light
    half3 L = normalize(half3(u.primaryLightDirection));
    half3 H = normalize(V + L);
    half NdotV = max(dot(N, V), 0.001h);
    half NdotL = max(dot(N, L), 0.0h);
    half LdotH = max(dot(L, H), 0.001h);

    half3 F0 = mix(half3(0.04h), baseColor, metallic);

    // Cook-Torrance specular BRDF
    half D = NDF_GGX_Safe(N, H, roughness);
    half Vis = VisibilityKelemen(LdotH, roughness);
    half3 F = FresnelSchlick(LdotH, F0);
    half3 specular = D * Vis * F;

    // Multi-scatter energy compensation (Filament approach)
    // 粗糙表面在单次散射模型下丢失能量 → 补偿
    half3 energyCompensation = 1.0h + F0 * (1.0h / max(half3(0.001h), F) - 1.0h);
    specular *= energyCompensation;

    // Diffuse BRDF
    half3 kD = (1.0h - F) * (1.0h - metallic);
    half3 diffuse = kD * baseColor / M_PI_H;

    // SH-based diffuse irradiance (L2 spherical harmonics)
    half3 irradiance = evaluateSH(float3(N), u.shCoeffs);

    // SH-based approximate specular (dominant direction from SH gradient)
    // 简化 Split-Sum: 用 SH L1 的 dominant direction 作为近似反射探针方向
    float3 shDominant = float3(u.shCoeffs[3].x, u.shCoeffs[1].x, u.shCoeffs[2].x);
    float3 approxReflDir = reflect(-float3(V), float3(N));
    // 粗糙度越高 → 越接近法线方向 (而非完美反射)
    approxReflDir = mix(approxReflDir, float3(N), float(roughness * roughness));
    half3 prefilteredColor = evaluateSH(approxReflDir, u.shCoeffs);

    // IBL specular approximation
    half3 envBRDF_approx = F0 * (1.0h - roughness) + half3(roughness * 0.1h);
    half3 iblSpecular = prefilteredColor * envBRDF_approx;

    half lightIntensity = half(u.primaryLightIntensity);

    half3 color = (diffuse + specular) * max(NdotL, 0.0h) * lightIntensity
                + irradiance * baseColor * kD * 0.4h      // SH diffuse
                + iblSpecular * 0.3h;                      // SH specular

    // Ripple highlight
    if (in.rippleAmplitude > in.rippleMinAmplitude) {
        half boost = half(in.rippleAmplitude * in.rippleBoostScale);
        color = min(color + half3(boost), half3(1.0h));
    }

    // S4→S5 alpha fade (fill_opacity 已由 C++ DS-uncertainty 驱动)
    half alpha = 1.0h;
    if (in.display > 0.80) {
        float fadeAlpha = 1.0 - smoothstep(0.80, 0.98, in.display);
        alpha = half(fadeAlpha);
    }
    if (alpha <= 0.001h) discard_fragment();

    color = linearToSRGB(color);
    color *= alpha;
    return half4(color, alpha);
}
```

#### Pass 3: Metallic 环境反射增强 (Fresnel Rim)

```metal
fragment half4 metallicLightingFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &u [[buffer(1)]]
) {
    if (in.display >= 0.98 || in.metallic < 0.01) discard_fragment();

    half3 N = normalize(half3(in.worldNormal));
    half3 V = normalize(half3(u.cameraPosition - in.worldPosition));
    half NdotV = max(dot(N, V), 0.0h);

    // Fresnel rim light
    half fresnel = pow(1.0h - NdotV, 5.0h);
    half3 envColor = evaluateSH(float3(reflect(-float3(V), float3(N))), u.shCoeffs);
    half rimIntensity = fresnel * half(in.metallic) * 0.35h;
    half3 rimColor = envColor * rimIntensity;

    // Fade near S5
    half alpha = rimIntensity * half(1.0 - smoothstep(0.85, 0.98, in.display));
    if (alpha <= 0.002h) discard_fragment();

    return half4(linearToSRGB(rimColor * alpha), alpha);
}
```

#### Pass 4: Oklab 色温校正

```metal
fragment half4 colorCorrectionFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &u [[buffer(1)]]
) {
    if (in.display >= 0.98) discard_fragment();

    half d = half(in.display);
    // Oklab 色温映射: S0=冷蓝 → S4=暖白
    // a_ok: green-red axis
    half a_shift = mix(-0.006h, 0.004h, d);
    // b_ok: blue-yellow axis
    half b_shift = mix(-0.018h, 0.003h, d);

    // Convert shift to linear RGB delta
    half3 neutral = oklabToLinearSRGB(0.7h, 0.0h, 0.0h);
    half3 shifted = oklabToLinearSRGB(0.7h, a_shift, b_shift);
    half3 tintDelta = shifted - neutral;

    half intensity = 0.08h * (1.0h - d);
    half alpha = intensity;
    if (alpha <= 0.002h) discard_fragment();

    return half4(linearToSRGB(tintDelta * intensity * alpha), alpha);
}
```

#### Pass 5: Cavity AO (感知空间遮蔽)

```metal
fragment half4 ambientOcclusionFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &u [[buffer(1)]]
) {
    if (in.display >= 0.98) discard_fragment();

    half3 N = normalize(half3(in.worldNormal));
    half3 V = normalize(half3(u.cameraPosition - in.worldPosition));
    half NdotV = max(dot(N, V), 0.0h);

    // Cavity detection: 帐篷 peak 周围 NdotV 变化大 → 暗化
    half cavity = 1.0h - smoothstep(0.15h, 0.65h, NdotV);

    // 帐篷凸起处 (高 thickness) 阴影更重
    half thicknessFactor = clamp(half(in.thickness) * 500.0h, 0.0h, 1.0h);

    half aoStrength = cavity * 0.2h * (1.0h - half(in.display)) * (0.5h + 0.5h * thicknessFactor);
    if (aoStrength <= 0.002h) discard_fragment();

    half3 darkening = half3(-aoStrength);
    return half4(darkening * aoStrength, aoStrength);
}
```

#### Pass 6: 时域蓝噪声纹理感

```metal
fragment half4 postProcessFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &u [[buffer(1)]]
) {
    if (in.display >= 0.80) discard_fragment();

    // 时域蓝噪声: 替代 sin-hash (v3 critique: sin-hash 有明显条纹)
    // 使用 interleaved gradient noise (Jorge Jimenez, SIGGRAPH 2014)
    float2 screenPos = in.position.xy;
    float frame = u.time * 60.0;
    float magic = 52.9829189;
    float noise = fract(magic * fract(0.06711056 * screenPos.x + 0.00583715 * screenPos.y + frame * 0.125));
    noise = (noise - 0.5) * 0.025;  // [-0.0125, +0.0125]

    half alpha = half(abs(noise)) * half(1.0 - smoothstep(0.7, 0.95, in.display));
    if (alpha <= 0.001h) discard_fragment();

    return half4(half3(half(noise)) * alpha, alpha);
}
```

---

### 步骤 8: 算法下沉到 C++ + 空间算法整合

**8.1 删除 `AdaptiveBorderCalculator.swift`**

Border 计算已在 C++ style runtime (`aether_capture_style_runtime_resolve()`) 中完整实现。
Swift 版本冗余。

**8.2 整合已有空间算法到聚类管线**

聚类算法需要从已有空间系统获取输入：

```
数据流：
  ARFrame → NativeStreamingPipelineBridge
         → C++ streaming_pipeline
         → frame_selector (blur/quality gate)
         → coverage_estimator (DS mass → display + uncertainty)
         → pure_vision_runtime (8 quality gates)
         → view_diversity_tracker (angle buckets → trajectory density)
         → WedgeGeometryGenerator.generate()
           → aether_compute_adaptive_clusters()
             ← display[], uncertainty[], semantic_labels[], camera_trajectory[]
           → aether_generate_wedge_geometry() (tent shaped)
           → upload to Metal GPU
```

**8.3 纯视觉 mesh 来源**

对于无 LiDAR 的设备，mesh 来自：
1. `mvs_initializer.h` → Census Transform SGM → dense point cloud
2. `marching_cubes.h` → point cloud → implicit surface → mesh
3. mesh 质量比 LiDAR 低 → 聚类算法自动产生更大的 cluster（因为不确定性更高）

对于有 LiDAR 的设备：
1. ARKit scene geometry → 高质量 mesh
2. 聚类更细致（不确定性低）

**这意味着同一套算法在两种设备上自动适配**——不确定性驱动一切。

**8.4 文件修改清单**

| 操作 | 文件 |
|------|------|
| 删除 | `Core/Quality/Visualization/AdaptiveBorderCalculator.swift` |
| 修改 | `App/ScanGuidance/ScanGuidanceRenderPipeline.swift` — 移除 borderCalculator |
| 修改 | `Package.swift` — 移除 AdaptiveBorderCalculator |
| 修改 | `aether_cpp/include/module.modulemap` — 添加 adaptive_clustering C API |
| 新增 | `aether_cpp/include/aether/render/adaptive_clustering.h` |
| 新增 | `aether_cpp/src/render/adaptive_clustering.cpp` |
| 修改 | `aether_cpp/include/aether_tsdf_c.h` — 添加聚类 + edge_mask C API |
| 修改 | `aether_cpp/src/c_api.cpp` — 实现聚类 + edge_mask C API |
| 修改 | `Core/Quality/Geometry/WedgeGeometryGenerator.swift` — 调用聚类 + 传递 edge_mask |

---

## 第四部分：前沿研究融合

### 4.1 已融合的研究

| 来源 | 领域 | 在本计划中的应用 |
|------|------|------------------|
| Google Filament 2025 | 移动 PBR | `roughness >= 0.045` 地板、cross-product GGX NDF、multi-scatter 能量补偿 |
| Chlumský MSDF (2015-2024) | 文字/矢量渲染 | 3 通道 barycentric SDF + median 运算 → 边框角点无 artifact |
| Jorge Jimenez (SIGGRAPH 2014) | 噪声 | Interleaved gradient noise 替代 sin-hash → 无条纹 |
| Weber-Fechner 感知律 | 心理物理学 | 厚度 = exp(-k*display) 感知指数衰减 → 视觉等距 |
| Björn Ottosson Oklab (2020) | 颜色科学 | 已实现色温映射 (Pass 4)，v4 扩展到 fill color |
| Dempster-Shafer theory | 证据理论 | 不确定性宽度驱动 S5 过渡带 + 聚类保守性 |
| Lyapunov 稳定性 | 控制论 | 单调非增收敛保证 (已在 coverage_estimator) |
| PAC learning bounds | 统计学习 | per-cell 风险 < 0.01 → 允许 S5 过渡 |
| Hungarian matching | 组合优化 | 帧间 cluster ID 匹配 → 时间稳定性 |

### 4.2 自研创新点

| 创新 | 描述 |
|------|------|
| DS-不确定性驱动过渡带 | 业界首创：用 Dempster-Shafer 不确定性宽度动态控制 S4→S5 渐变区间 |
| 多信号融合聚类 | 6 维亲和度（距离+质量+法线+不确定性+语义+轨迹密度）而非简单 Union-Find |
| 感知厚度映射 | Weber-Fechner 对数感知律替代线性衰减，确保视觉等距 |
| 时间稳定性: 匈牙利匹配 + EMA | 帧间 cluster 追踪防止闪烁，结合 Lyapunov 单调性保证 |
| LiDAR-agnostic 自适应 | 同一算法通过不确定性自动适配 LiDAR/纯视觉设备 |

---

## 第五部分：执行顺序 + 验证矩阵

### 执行顺序

```
步骤 1 ─── 移除 Voronoi ─────────────────────┐
步骤 2 ─── 帐篷楔形 + edge_mask (C++) ────────┤
步骤 3 ─── MSDF 边框 (Metal) ─────────────────┤→ 基本形状正确
步骤 6 ─── 厚度感知修复 (C++) ─────────────────┘
步骤 4 ─── 自适应聚类 v2 (C++) ───────────────── 聚类+边界标记
步骤 5 ─── DS-不确定性 S5 过渡 (C++) ──────────── 信息论保证
步骤 7 ─── PBR + Pass 3-6 (Metal) ────────────── 视觉质感
步骤 8 ─── 算法下沉 + 空间算法整合 ────────────── 架构清理
```

### 文件清单

| 步骤 | C++ 文件 | Swift 文件 | Metal 文件 |
|------|----------|-----------|-----------|
| 1 | — | WedgeGeometryGenerator.swift, ScanGuidanceRenderPipeline.swift | — |
| 2 | wedge_geometry.h, wedge_geometry.cpp, c_api.cpp, aether_tsdf_c.h | WedgeGeometryGenerator.swift (WedgeVertexCPU +edgeMask) | — |
| 3 | — | ScanGuidanceVertexDescriptor.swift | ScanGuidance.metal |
| 4 | **新** adaptive_clustering.h/.cpp, c_api.cpp, aether_tsdf_c.h | WedgeGeometryGenerator.swift | — |
| 5 | fracture_display_mesh.cpp | — | ScanGuidance.metal |
| 6 | fracture_display_mesh.cpp | — | — |
| 7 | — | — | ScanGuidance.metal |
| 8 | c_api.cpp, module.modulemap | 删除 AdaptiveBorderCalculator.swift, Package.swift | — |

### 验证矩阵

| 验证类型 | 方法 | 预期 |
|----------|------|------|
| 单元测试 | `swift test --filter WedgeGeometryTests` | 所有 9 个测试 ✅ |
| C++ 测试 | 新增 adaptive_clustering_test.cpp | 聚类正确性 + 时间稳定性 |
| 编译 | `xcodebuild build` | 零错误零警告 |
| 数值稳定性 | 随机 10000 个三角形 + edge case (degenerate, zero-area) | 无 NaN/Inf |
| 帧率 | iPhone 12 (A14, 无 LiDAR), 7000 三角形 | >= 58 FPS |
| 视觉 | 实机拍摄测试 | 无碎玻璃、无闪烁、帐篷形状、S5 透明 |
| 不确定性自适应 | 模拟高/低 uncertainty_width | 过渡带正确扩展/收缩 |
| LiDAR vs 纯视觉 | 有/无 LiDAR 设备对比 | 同一算法自动适配，视觉一致 |
