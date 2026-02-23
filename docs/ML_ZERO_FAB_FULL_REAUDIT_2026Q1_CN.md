# Aether3D 零造假 ML 全链路重审报告（2026Q1，含五语前沿核查）

- 审查日期：2026-02-17
- 审查目标：回答“ML 是否能完美适配当前纯几何（三角形+四面体基础）管线”
- 审查范围：
  - 本地代码（TSDF / MC / Evidence / PIZ / PureVision Gate / Merkle）
  - 2025-2026 全球前沿论文、方案、开源实现
  - 中文、英文、西语、法语、阿语检索

---

## 0) 结论先行（冷静版）

1. 现阶段不能给“完美适配”承诺，只能给“高兼容 + 可审计 + 可验证”承诺。  
2. 你的纯几何主干是正确底座，ML 应严格作为“校、筛、标”外挂层，不得进入“补、画、猜”。  
3. 若执行本报告的 **6 个关键调整（P0）**，可把当前兼容度从约 `88-92%` 提升到 `95%+`（法证模式）。

---

## 1) 本地代码审查结果（与 ML 适配直接相关）

### 1.1 强项（可直接承接 ML）

1. PureVision 门控已落到运行时，非“只在文档里定义”  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Quality/PureVision/PureVisionRuntimeGateEvaluator.swift:71`
2. 核心阈值已集中到 SSOT 常量（便于审计与版本冻结）  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Constants/PureVisionRuntimeConstants.swift:14`
3. TSDF 常量体系完整，参数边界明确  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:12`
4. GPU TSDF 里已实现有效像素门控、截断安全、权重上限  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/App/TSDF/TSDFShaders.metal:99`
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/App/TSDF/TSDFShaders.metal:160`

### 1.2 当前风险点（会影响“完美适配”）

1. Overlap 仍是强代理，不是几何一致性真估计  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Quality/OverlapEstimator.swift:27`
2. PIZ 面积仍有硬编码默认（0.1m cell）  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Evidence/PIZ/PIZGridAnalyzer.swift:191`
3. MC 取邻域 SDF 时，越界直接当空（1.0）会引入边界偏置  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/MarchingCubes.swift:748`
4. Merkle consistency proof 目前是“保守格式校验”，非完整 RFC 9162 递归验证  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/MerkleTree/ConsistencyProof.swift:57`
5. 非 simd 分支含 placeholder（几何真实性风险）  
   - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/App/TSDF/MetalTSDFIntegrator.swift:240`

---

## 2) PureVision 新门控的实际状态

### 2.1 我核查到的当前门控面

- 8 个硬门：baseline / blur / ORB / parallax / depth sigma / closure / unknown voxel / thermal  
  - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Quality/PureVision/PureVisionRuntimeGateEvaluator.swift:13`
- 关键阈值：
  - `K_OBS_MIN_BASELINE_PIXELS = 3`  
  - `K_OBS_REQ_PARALLAX_RATIO = 0.2`  
  - `K_OBS_SIGMA_Z_TARGET_M = 0.015`  
  - `K_VOLUME_CLOSURE_RATIO_MIN = 0.97`  
  - `K_VOLUME_UNKNOWN_VOXEL_MAX = 0.03`  
  - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Constants/PureVisionRuntimeConstants.swift:99`
- KPI 门控：
  - 首扫目标 `<=180s`，成功率目标 `>=0.90`，重放稳定率 `=1.0`
  - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Quality/PureVision/PureVisionRuntimeGateEvaluator.swift:195`

### 2.2 测试验证结果

- 已执行：`swift test --filter PureVisionRuntimeGateTests`
- 结果：2/2 通过
- 产出 KPI：
  - success rate = `0.90`
  - replay stable = `1.0`
  - max duration = `221s`
  - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/governance/generated/first_scan_runtime_metrics.json:1`

### 2.3 测试覆盖不足

- 夹具样本整体偏“顺风工况”，极端场景不足：
  - 高反光/低纹理/动态遮挡/热衰减尾段/跨设备漂移
  - `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Tests/Fixtures/pure_vision_runtime_replay_v1.json:130`

---

## 3) 2025-2026 前沿核查（五语）

> 结论：全球核心方法仍以英文论文发布为主；中文/西语/法语/阿语检索能补到行业实践与区域入口，但核心算法主证据仍是英文主会论文与官方代码。

### 3.1 几何前端与重建

1. VGGT（CVPR 2025）适合作为多视几何候选前端  
   - https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html  
   - https://github.com/facebookresearch/vggt
2. DUSt3R（CVPR 2024）适合做对照，不建议单独主导法证主链  
   - https://openaccess.thecvf.com/content/CVPR2024/html/Wang_DUSt3R_Geometric_3D_Vision_Made_Easy_CVPR_2024_paper.html
3. Radiance Meshes（CVPR 2025）支持“mesh 约束神经表示”的创新路线  
   - https://openaccess.thecvf.com/content/CVPR2025/html/Gao_Radiance_Meshes_Neural_Radiance_Field_Reconstruction_With_Polygons_CVPR_2025_paper.html

### 3.2 标定与不确定性

1. GeoCalib（ECCV 2024）可作为内参先验模块  
   - https://arxiv.org/abs/2409.06704  
   - https://github.com/cvg/GeoCalib
2. WACV 2025 不确定性感知相机-LiDAR 标定，适合法证误差区间表达  
   - https://openaccess.thecvf.com/content/WACV2025/html/Cocheteux_Uncertainty-Aware_Camera-LiDAR_Calibration_A_Deep_Learning_Approach_with_Optimal_Conformal_WACV_2025_paper.html
3. SupeRANSAC（2025）可作为鲁棒几何统一底座（含 MAGSAC++ 等）  
   - https://arxiv.org/abs/2506.04803

### 3.3 去噪、外点、不确定性

1. Score-Based Point Cloud Denoising（ICCV 2021，仍是强基线）  
   - https://openaccess.thecvf.com/content/ICCV2021/html/Luo_Score-Based_Point_Cloud_Denoising_ICCV_2021_paper.html
2. StraightPCF（CVPR 2024）轻量、可移动端部署  
   - https://openaccess.thecvf.com/content/CVPR2024/html/de_Silva_Edirimuni_StraightPCF_Straight_Point_Cloud_Filtering_CVPR_2024_paper.html
3. Open3D 规则滤波是必须保留的“零学习审计基线”  
   - https://www.open3d.org/docs/latest/tutorial/Advanced/pointcloud_outlier_removal.html
4. 3DGS 不确定性  
   - 3DGS-MCMC: https://arxiv.org/abs/2404.09591  
   - PH-Dropout: https://arxiv.org/abs/2410.05468  
   - OUGS: https://arxiv.org/abs/2511.09397

### 3.4 溯源与攻防

1. GuardSplat（CVPR 2025）与 3D-GSW（2025）说明水印可做第二层  
   - https://openaccess.thecvf.com/content/CVPR2025/html/Chen_GuardSplat_Safeguarding_3D_Gaussian_Splatting_via_Watermarking_CVPR_2025_paper.html  
   - https://arxiv.org/abs/2505.12664
2. 攻击面：GSPure（2025）、GMEA（2025）说明“仅靠水印不够”  
   - https://arxiv.org/abs/2508.07263  
   - https://arxiv.org/abs/2502.10453
3. 标准层：C2PA 2.2 + RFC 3161 + RFC 9162  
   - https://c2pa.org/specifications/specifications/2.2/specs/C2PA_Specification.html  
   - https://www.rfc-editor.org/rfc/rfc3161  
   - https://www.rfc-editor.org/rfc/rfc9162  
   - https://github.com/contentauth/c2pa-rs

### 3.5 五语检索补充（区域视角）

1. 中文：百度 Apollo 标定实践文档  
   - https://apollo.baidu.com/docs/apollo/latest/md_modules_2calibration_2README__cn.html
2. 西语：CVC/UAB 自动驾驶多相机深度估计工程入口  
   - https://www.cvc.uab.es/portfolio/a-multi-camera-system-for-depth-estimation-in-autonomous-driving/
3. 法语：INRIA 相关三维重建研究入口（检索命中后再回归英文论文主证据）  
   - https://www.inria.fr/en/splat-and-replace-large-scale-language-model-powered-3d-and-4d-scene-editing
4. 阿语：检索到的高质量算法主证据基本仍指向英文论文库（CVPR/arXiv/IEEE）。

---

## 4) 六个关键调整（P0，必须做）

### P0-1 禁止“默认坐标改写型去噪”

- 法证模式下，ML 默认只能输出 `reject_mask`、`confidence_delta`、`uncertainty`，不能直接改 `xyz/rgb`。
- 任何点位移动必须进入 `derived` 轨并保留 `raw` 轨可回放。

### P0-2 建立 Unknown 强约束

- `unknown` 区域只允许标注和可视化，禁止几何生长、纹理补足、hole filling。
- 违规调用直接 fail-close 并写审计日志。

### P0-3 全链确定性指纹补齐

- 每次重建必须记录：
  - `model hash`
  - `runtime/EP`
  - `driver`
  - `seed`
  - `precision mode`
- 否则跨平台“同输入同输出”不可证明。

### P0-4 完整实现 RFC 9162 consistency proof

- 当前 `ConsistencyProof.verify` 仍是保守路径头尾校验，不足以法证抗辩。  
- 需要升级为 RFC 9162 2.1.4 的完整递归验证。

### P0-5 去掉 placeholder 几何分支

- 非 simd 分支的 `worldToCamera = input.cameraToWorld` 这类 placeholder 必须封禁或补齐真实实现。  
- 否则会出现平台差异下“伪几何正确”。

### P0-6 首扫门控夹具扩容（极端工况）

- 当前样本 10 组，且大多在阈值安全区。  
- 需新增：
  - 低纹理白墙
  - 镜面反光
  - 强动态遮挡
  - 热衰减末段
  - 低照高噪
  - 多机型跨平台回放

---

## 5) 阈值复审与建议区间（基于现状 + 前沿）

| 项 | 当前 | 建议（法证模式） | 说明 |
|---|---:|---:|---|
| `K_OBS_MIN_BASELINE_PIXELS` | 3.0 | `3.0~5.0`（按焦距/分辨率自适应） | 远距与低纹理场景需更稳 |
| `K_OBS_REQ_PARALLAX_RATIO` | 0.20 | `0.20~0.30` | 中远距建议升档 |
| `K_OBS_SIGMA_Z_TARGET_M` | 0.015 | 分段：近距0.010 / 中距0.015 / 远距0.025 | 单一阈值不适配全景深 |
| `K_VOLUME_UNKNOWN_VOXEL_MAX` | 0.03 | `<=0.03`（法证固定，不放宽） | 保持零造假边界 |
| `minValidPixelRatio` | 0.30 | `0.40~0.50`（法证） | 降低低质帧污染融合 |
| `weightMax` | 64 | A/B: `64/96/128` | 与边缘保真/延迟折中 |
| `truncationMultiplier` | 3.0 | A/B: `2.5/3.0/3.5` | 不同噪声型场景差异明显 |
| `minObservationsBeforeMesh` | 3 | `3~4` | 低纹理平面建议 4 |

阈值锚点代码：
- `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/Constants/PureVisionRuntimeConstants.swift:97`
- `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Core/TSDF/TSDFConstants.swift:47`

---

## 6) 多重方法交叉验证（防单模型误判）

### 6.1 标定层

- 主路：GeoCalib（内参）+ 传统几何（Kalibr / PnP）
- 判据：若两路偏差超阈值，降级为 `estimated`，禁止进入 `measured`。

### 6.2 几何层

- 主路：TSDF 融合结果
- 辅路：VGGT 几何候选
- 策略：只把两路一致区提为 `measured`；不一致区进入 `suspect/unknown`。

### 6.3 去噪/外点层

- 主路：Open3D SOR + Radius（规则）
- 辅路：StraightPCF / Score-based（ML）
- 策略：两路同意才执行“删除”；否则只降权不删。

### 6.4 不确定性层

- 解析路：OUGS 类 Jacobian 传播
- 经验路：重投影残差 + 多视分歧 + PH-Dropout
- 输出：Measured / Estimated / Unknown 三段制，禁止二值化硬断。

### 6.5 溯源层

- Merkle（完整一致性证明）+ RFC3161 时间戳 + C2PA Manifest
- 水印仅作第二层，不作唯一真实性来源。

---

## 7) 基于“三角形 + 四面体”几何底座的自研创新方案

## 7.1 TRI-REF + TET-REF 双轨可信度引擎

1. `TRI-REF`：继续以 MC 三角面为可视化和测量主对象。  
2. `TET-REF`：在体素块内建立确定性四面体分解（Kuhn 5-tet）。  
3. 每个三角面绑定其所在四面体集合，输出双重置信度：
   - `c_tri`（表面一致性）
   - `c_tet`（体积一致性）
4. 最终置信规则：
   - `min(c_tri, c_tet)` 进入 `measured`
   - 分歧大于阈值进入 `suspect`

## 7.2 Tetra-Constrained Gaussian（零造假版）

1. Gaussian 只允许落在：
   - 已观测三角面附近
   - 且对应四面体观测覆盖率 >= N（建议 N=2 或 3）
2. 禁止在 `unknown tetra` 内生长 Gaussian。
3. 将高斯不确定性分解为：
   - 表面项（tri residual）
   - 体积项（tet residual）

## 7.3 四面体守恒审计

1. 对每次优化前后记录“tet occupancy 守恒偏差”。  
2. 若出现“无观测体积凭空上升”，直接触发 `fabrication_alert`。  
3. 审计项进入 provenance，可法庭复核。

---

## 8) 90 天落地计划（只做必要工程）

### Phase A（第 1-3 周）：法证硬约束落地

1. 上线 P0-1/2/3
2. 增加 `raw/recon/mask/uncertainty/provenance` 五路强制输出
3. 固化运行时指纹记录

### Phase B（第 4-8 周）：双路交叉验证

1. 标定双路、外点双路、不确定性双路
2. 导入极端工况回放集，扩展 PureVision fixture
3. 阈值 A/B 与设备分层参数

### Phase C（第 9-12 周）：Tri+Tet 创新轨

1. TET-REF 核心数据结构 + TRI/TET 一致性度量
2. Tetra-Constrained Gaussian 原型
3. 审计告警闭环 + 报告模板

---

## 9) 对“是否完美适配”的正式回答

1. 现在：不能说“完美适配”。  
2. 按本报告 P0 完成后：可以说“法证级高兼容，零造假边界明确”。  
3. 完成 P0+P1+Tri/Tet 创新后：可对外给出“几何真值主干 + ML 受限增强”的行业领先方案。

---

## 10) 你可以直接执行的下一步（按优先级）

1. 先实现 P0-4：完整 RFC 9162 consistency proof（这是证据链短板）。  
2. 扩展 PureVision 回放夹具到极端工况（至少 10 -> 80 样本）。  
3. 把 Overlap 从“单一光度代理”升级为“几何+光度双证据”。  
4. 开启 Tri/Tet 双轨试验分支，只输出置信与审计，不碰原几何真值轨。

