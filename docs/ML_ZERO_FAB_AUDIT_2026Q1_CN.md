# Aether3D 零造假 ML 方案全量审查报告（2026Q1）

- 审查日期：2026-02-17
- 审查范围：本地几何主干（TSDF/MarchingCubes/Determinism/Merkle）+ 全球 2025-2026 前沿论文/开源
- 检索语言：中文、英文、西语、法语、阿拉伯语（主出版语种仍以英文论文为主）

## 1. 结论（先给结论）

1. 目前方案不能承诺“完美适配”，但可以做到“法证级高兼容”。
2. 在不改动你“零造假”底线前提下，ML 应只进入 `校准/筛除/打分` 三类接口，不得进入 `补全/生成/改写几何`。
3. 按本文 P0/P1 修订执行后，预计可把“纯几何主干 + ML增强”的工程兼容度从约 85-90% 提升到 95%+。

## 2. 你现有纯几何主干（代码审计）

本地代码已经具备非常强的“可审计”基础，这决定了 ML 可以“外挂”，不必侵入改写内核。

1. TSDF 主干明确且门控完备：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFVolume.swift:80`
2. TSDF 关键阈值均在 SSOT 常量：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:28`
3. MC 只对足够观测块出网格：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/MarchingCubes.swift:317`
4. 三角形质量拒绝已有实现：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/MeshOutput.swift:52`
5. 确定性三角化与跨平台稳定逻辑已有：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Quality/Geometry/DeterministicTriangulator.swift:38`
6. Merkle 已按 RFC 9162 结构实现，但一致性证明尚未完成：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/MerkleTree/MerkleTree.swift:104`

## 3. 2025-2026 全球前沿核查（逐环节）

### 3.1 标定校正（ML 可做“校”，不改场景）

1. GeoCalib（ECCV 2024）适合作为内参先验入口；有官方代码与许可证，工程可落地。  
   来源：arXiv + GitHub
2. WACV 2025 不确定性感知标定工作支持把标定结果输出为置信区间（适合法证表述“误差区间”）。  
   来源：WACV 2025 open access
3. TLC-Calib（RA-L 2026）显示了把 Gaussian 映射用于无靶标 LiDAR-相机标定的可行性。  
   来源：IEEE RA-L 2026
4. OmniCal（CVPR 2025）显示在线持续标定趋势，适合你多设备长期漂移场景。  
   来源：arXiv 2025

审查结论：标定模块可与纯几何管线高兼容，推荐作为最先接入的 ML 模块（P0）。

### 3.2 多视几何前端（ML 可做“几何估计候选”，不能替代真值主干）

1. VGGT（CVPR 2025）是强候选：单前向输出相机/深度/点/轨迹，适合作为初始化与交叉验证。  
   来源：CVPR 2025 + 官方代码
2. DUSt3R 仍是强基线，但天然 pairwise 架构在大视图数下复杂度和工程负担更高。  
   来源：CVPR 2024

审查结论：VGGT 适合当“候选几何层”，但测量与证据链仍必须以 TSDF/MC 主干为准。

### 3.3 去噪与外点剔除（ML 只能“删/标”，默认不改坐标）

1. Score-based point cloud denoising（ICCV 2021）仍是稳健基线。  
   来源：arXiv 2110.11502 + 代码
2. StraightPCF（CVPR 2024）参数量小，工程上更适合移动端候选。  
   来源：CVPR 2024
3. PointCleanNet（CGF 2020）仍可做老牌对照组。  
   来源：项目页 + 代码
4. Open3D 的 `remove_statistical_outlier` 与 `remove_radius_outlier` 应作为 P0 的“零学习可审计基线”。  
   来源：Open3D 官方文档

审查结论：你方案里“去噪可移动点”要收紧。法证模式默认只允许“剔除/降权/标记”。

### 3.4 3DGS 不确定性与结构约束

1. UNG-GS（2024）给出不确定性感知高斯优化路径。  
2. OUGS（2025）提供解析不确定性传播框架，适合“可解释不确定性”。  
3. 3DGS-MCMC（NeurIPS 2024）支持概率化采样与不确定性估计。  
4. SGS（2025）强调安全关键视角下的 3DGS 不确定性需求。

审查结论：不确定性路线可行，但要统一口径：训练不确定性与几何残差不确定性不能混用。

### 3.5 溯源、防篡改、证据链

1. GuardSplat / 3D-GSW（CVPR 2025）说明“水印可做第二防线”。  
2. GMEA / GSPure（2025-2026）说明“水印可被攻击”，不能当唯一防线。  
3. C2PA 2.2 与 c2pa-rs 已可工程落地。  
4. RFC 3161（时间戳）与 RFC 9162（Merkle日志结构）适合作为底层证明规范。

审查结论：你“Merkle + 时间戳 + C2PA + 可选链锚定”的三层结构是正确方向；必须补齐 consistency proof。

## 4. 关键不兼容点与修订（P0/P1）

### P0（必须先改）

1. 禁止默认“坐标改写型去噪”  
   现状风险：去噪模型若直接移动点，会破坏“观测真值”。  
   修订：`raw_recon` 不改；ML 只输出 `reject_mask` 和 `confidence_delta`。
2. 把“零造假约束”下沉为核心硬规则  
   规则：`no_inpaint`、`no_hole_fill`、`no_unknown_growth`。  
   违反即报错并写审计日志。
3. 统一确定性与复现策略  
   记录 `model hash + runtime + EP + driver + seed + precision mode`。  
   没有这些，跨平台复现实证会失败。
4. 完成 Merkle consistency proof  
   当前接口留有 TODO，法证链条不完整。

### P1（强烈建议）

1. Unknown 区只做显式显示，不做几何或纹理补足。  
2. 标定/去噪/置信度都做“多路交叉验证”，拒绝单模型单点失败。  
3. 训练/推理分离：线上永远只推理，不在线学习。  
4. 模型包签名化（ONNX + 阈值 + 配置）并强校验加载。

## 5. 数值参数复审（从“可跑”升级到“法证稳健”）

以下不是拍脑袋固定值，而是“推荐区间 + A/B 校准”：

1. `minValidPixelRatio` 现值 0.30  
   建议：法证模式 0.40-0.50；消费模式 0.30-0.35。  
   位置：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:49`
2. `weightMax` 现值 64  
   建议：实验 64/96/128 三档，比较边缘保真与滞后。  
   位置：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:35`
3. `minObservationsBeforeMesh` 现值 3  
   建议：平面低纹理场景升到 4；高纹理可保持 3。  
   位置：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:139`
4. `truncationMultiplier` 现值 3.0  
   建议：2.5/3.0/3.5 交叉验证，按 Chamfer + edge fidelity 选最优。  
   位置：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:28`
5. `poseJitterGateTranslation` 现值 1mm  
   建议：按设备噪声做温控分层阈值（热态放宽，冷态收紧）。  
   位置：`/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:137`

## 6. 多方法交叉验证（避免单模型幻觉）

建议每一环至少“双路验证”：

1. 标定：`GeoCalib` vs `Kalibr/传统PnP`，误差不一致则降级。
2. 几何：`VGGT候选` vs `TSDF融合`，只取交集高置信区域进入 Measured。
3. 外点：`Open3D规则滤波` vs `ML评分`，仅当两者同意才删除。
4. 不确定性：`解析传播(OUGS类)` vs `经验法(重投影残差/多视分歧)`。
5. 溯源：`Merkle证明` vs `C2PA声明` vs `时间戳` 三方一致性检查。

## 7. 基于你“三角形 + 四面体”底座的自研创新位点

你现有方案文档里已经有 TetAnchor/TET_REF 设计草案，可直接升为实验轨：

1. TetAnchor + Kuhn 5-tet（块内确定性分割）  
   参考位置：`/Users/kaidongwang/Documents/progecttwo/progect2/CURSOR_MEGA_PROMPT_V2.md:44222`
2. TET_REF Jacobian 不确定性传播  
   参考位置：`/Users/kaidongwang/Documents/progecttwo/progect2/CURSOR_MEGA_PROMPT_V2.md:47573`
3. 与 TRI_REF 双轨互证（表面 vs 体积）  
   一致则提高可信度，不一致则标记 Suspect/Unknown。
4. 把高斯锚定到三角/四面体局部坐标，限制漂移与漂浮高斯。
5. 参考 2025 的 Radiance Meshes / Mesh-driven 表示，做“几何先验约束高斯”的创新路线。  
   来源：CVPR 2025 Radiance Meshes

## 8. 对“能否完美适配”的最终判断

1. 现在：不能给“完美适配”承诺。  
2. 改完 P0：可达到“高可信兼容 + 零造假可审计”。  
3. 改完 P0+P1 并完成 8-12 周验证：可以对外宣称“法证级混合架构（几何真值主干）”。

## 9. 参考来源（主源，按模块）

### 几何与重建

1. VGGT（CVPR 2025）：https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html  
2. VGGT code：https://github.com/facebookresearch/vggt  
3. DUSt3R（CVPR 2024）：https://openaccess.thecvf.com/content/CVPR2024/html/Wang_DUSt3R_Geometric_3D_Vision_Made_Easy_CVPR_2024_paper.html  
4. Radiance Meshes（CVPR 2025）：https://openaccess.thecvf.com/content/CVPR2025/html/Gao_Radiance_Meshes_Neural_Radiance_Field_Reconstruction_With_Polygons_CVPR_2025_paper.html  
5. MeshAnything V2（arXiv 2025）：https://arxiv.org/abs/2504.00906

### 标定与不确定性

1. GeoCalib（ECCV 2024）：https://arxiv.org/abs/2409.15254  
2. GeoCalib code：https://github.com/cvg/GeoCalib  
3. WACV 2025 不确定性感知标定：https://openaccess.thecvf.com/content/WACV2025/html/Cocheteux_Uncertainty-Aware_Camera-LiDAR_Calibration_A_Deep_Learning_Approach_with_Optimal_Conformal_WACV_2025_paper.html  
4. TLC-Calib（RA-L 2026）：https://ieeexplore.ieee.org/document/11047244  
5. CalibFormer（arXiv）：https://arxiv.org/abs/2311.15241  
6. OmniCal（CVPR 2025）：https://arxiv.org/abs/2503.22169  
7. SAPR（CVPR 2025）：https://arxiv.org/abs/2503.08698

### 去噪/外点/不确定性（3DGS）

1. Score-Based Point Cloud Denoising（ICCV 2021）：https://arxiv.org/abs/2110.11502  
2. StraightPCF（CVPR 2024）：https://openaccess.thecvf.com/content/CVPR2024/html/de_Silva_Edirimuni_StraightPCF_Straight_Point_Cloud_Filtering_CVPR_2024_paper.html  
3. PointCleanNet（CGF 2020）：https://mrakotosaon.github.io/pointcleannet.html  
4. Open3D outlier removal docs：https://www.open3d.org/docs/latest/tutorial/Advanced/pointcloud_outlier_removal.html  
5. Mip-Splatting（CVPR 2024）：https://openaccess.thecvf.com/content/CVPR2024/html/Yu_Mip-Splatting_Alias-free_3D_Gaussian_Splatting_CVPR_2024_paper.html  
6. 3DGS-MCMC（NeurIPS 2024）：https://arxiv.org/abs/2404.09591  
7. OUGS（arXiv 2025）：https://arxiv.org/abs/2511.09397  
8. UNG-GS（arXiv 2024）：https://arxiv.org/abs/2403.18476  
9. SGS（arXiv 2025）：https://arxiv.org/abs/2503.11172

### 溯源/完整性

1. GuardSplat（CVPR 2025）：https://openaccess.thecvf.com/content/CVPR2025/html/Chen_GuardSplat_Safeguarding_3D_Gaussian_Splatting_via_Watermarking_CVPR_2025_paper.html  
2. 3D-GSW（CVPR 2025）：https://arxiv.org/abs/2505.12664  
3. GMEA（watermark attack，arXiv 2025）：https://arxiv.org/abs/2502.10453  
4. GSPure（watermark removal，arXiv 2025）：https://arxiv.org/abs/2507.23285  
5. C2PA Specification 2.2：https://c2pa.org/specifications/specifications/2.2/specs/C2PA_Specification.html  
6. c2pa-rs SDK：https://github.com/contentauth/c2pa-rs  
7. RFC 3161：https://www.rfc-editor.org/rfc/rfc3161  
8. RFC 9162：https://www.rfc-editor.org/rfc/rfc9162

### 多语言检索中的区域来源

1. 中文（Apollo）：https://apollo.baidu.com/docs/apollo/latest/md_modules_2calibration_2README__cn.html  
2. 西语检索命中（CVC/UAB）：https://www.cvc.uab.es/portfolio/a-multi-camera-system-for-depth-estimation-in-autonomous-driving/

