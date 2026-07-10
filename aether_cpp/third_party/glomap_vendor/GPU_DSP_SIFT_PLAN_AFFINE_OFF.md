# GPU WGSL DSP-SIFT 移植 — 逐 Stage 实现计划(affine-off 路线)

> 2026-06-29。读码基线 `~/Developer/Aether3D-cross/`。基于实读 7 个文件(行号见正文),与树内既有 `GPU_DSP_SIFT_PLAN.md`(8-11周/保 affine)做了对齐/分歧标注。**核心分歧 = 本计划默认关 affine。**

## 0. 与既有 plan 的关系(先消歧)

树内已有 `GPU_DSP_SIFT_PLAN.md`(2026-06-22)。关键分歧:

| 维度 | 既有 PLAN.md | 本计划(采纳) |
|---|---|---|
| affine-shape | 保留(S4 per-kp 2×2 SVD,最难) | **默认关闭**(实测零提取成本) |
| 骨架 | 自研全 covdet 移植 | `sift-wgpu`(MIT)6-pass 骨架 + DSP pooling |
| 工程量 | ~2300-3500 LOC / 8-11wk | **~2100-2300 LOC / 5-7wk** |
| workgroup 内存 | 请求 32KB(41×41 patch,破 16KB portable) | **512B**(关 affine 红利) |

**可复用既有事实**:`GPU_DSP_SIFT_PLAN.md:127-135` first_octave=0 已 A/B 验(fo-1=1.0076px vs fo0=1.0217px,噪声内),gss 642→161MB,**采纳 fo=0 baseline**;week-1 gss memory gate 已 PASS。

> ⚠️ **parity 后果**:关 affine → CPU parity 基线也必须关 affine。当前 `dsp_sift_c.cc:48` 调用是 `estimate_affine_shape=true`。**M0 第一件事 = 新增 affine-off 的 CPU 参考 ABI**,否则 ellipse 一关 keypoint 集就不同,parity 永远对不上。

## 1. 集成架构

**注入点**:GPU 走第三个并存实现,C ABI 完全不变。新增 `aether_dsp_sift_extract_gpu(...)`(签名逐字同 `dsp_sift_c.cc:87` 的 `_threaded`),输出契约(xy顺序/128维/UBC reorder/RootSIFT round(512v))逐字复刻 `dsp_sift_c.cc:62-77` + `aether_threaded_extract.cc:332`。**CPU fallback** 永远在位:GPU init 失败/容量溢出/parity 触发 → `return aether_dsp_sift_extract_threaded(...)`,调用方无感。iOS 侧加 `use_gpu_extract` flag(仿 `aether_sfm_c.cc:274` 的 `use_gpu_match`)。

**数据流**:JPEG→gray u8→GPU(S0 /255 → S1 GSS金字塔[fo=0,~160MB,RESIDENT 不回传] → S2 DoG[融S3寄存器] → S3 极值+亚像素+剔除[atomic append] → S4 主方向 → S5 DSP描述子[patch-warp])→ **唯一一次 readback**(raw_desc 12MB)→ CPU 收尾(L1Root归一+量化+UBC reorder,数值锁死 `utils.cc:49-69`)→ COLMAP db。

## 2. 逐 Stage compute pass

风格沿用 `sift_gss_blur.wgsl:16-32`:`Params` uniform、`@group(0)`、storage `array<f32>` row-major、`@workgroup_size(8,8,1)`、边界守卫、clamp-to-edge。

- **S0 灰度归一**(新~30LOC):`f=u8/255`,对齐 `sift.cc:383`。bit-exact。
- **S1 GSS 模糊**【已有 `sift_gss_blur.wgsl`】:separable h/v,taps=VLFeat sigma recurrence,edge=VL_PAD_BY_CONTINUITY。每 octave S+3 level(`octave_resolution=3`)。gate: max-rel≤1e-3/RMS≤2e-4。
- **S1b Octave 降采样**(新~50LOC):2× 整数抽取(对齐 vl_imdownsample,无插值)。fo=0→octave0 原分辨率。
- **S2 DoG**:`gss[l+1]-gss[l]` **在 S3 fp32 寄存器内相减,不物化**(灾难性抵消,f16 移阈值)。
- **S3 极值+refine+剔除**(新~400-600LOC,**高风险①**):26邻域极值→Newton亚像素(≤5迭代)→peak剔除(`|D|≥0.00667`)→edge剔除(`tr²/det<(r+1)²/r`,r=10)→`atomicAdd` append。**parity 必踩**:`keypoint.x=frame.x+0.5` half-pixel 偏移(`sift.cc:422`)。gate: recall/precision≥0.97, pos-err≤0.05px。对照 VulkanSift `ExtractKeypoints.comp`(MIT)+ 树内 covdet.c。
- **S4 主方向**(新~150-250LOC):threadgroup-per-kp,36-bin 直方图(workgroup shared)→主峰+0.8副峰(max_orient=2)→atomic append。gate: median≤1°。
- **S5 DSP 描述子**(新~400-600LOC,**高风险②**):**必须复刻 CPU 的 patch-warp 三段式**(`aether_threaded_extract.cc:252-305`,不是 sift-wgpu 的 gss 直采!):for s in dsp_num_scales(=10):frame×dsp_scale(affine off→各向同性)→`vl_covdet_extract_patch_for_frame` 31×31 patch(gss双线性 warp,kPatchRelativeExtent=7.5,kSigma=7.5/(3·5/2)/0.5)→极坐标梯度→4×4×8 三线性投直方图(workgroup shared,f32)→10 scale 累加 ×(1/10) mean。gate: cosine median≥0.998/p95≥0.99。
- **收尾(CPU,零 parity 风险)**:colwise mean→L1RootNormalize(`utils.cc:49`)→round(512v)u8→TransformVLFeatToUBC(q={0,7,6,5,4,3,2,1},`aether_threaded_extract.cc:38`)。

## 3. 两大高风险 spike

**①keypoint 稀疏收集(atomic+indirect,禁 decoupled-lookback)**:`KpRecord`(32B:x,y,octave,scale_s,resp,orient)+`kp_counter:atomic<u32>`+`kp_buffer[CAP=24000]`+`indirect_args[3]`。流程:S3 `let i=atomicAdd(&counter,1u); if(i<CAP){buf[i]=rec;}`→tiny pass 算 `indirect_args=[(count+WG-1)/WG,1,1]`→S4/S5 `DispatchWorkgroupsIndirect`(count 不回 CPU)。8192 clamp 延迟到收尾按(octave desc,scale desc)排序(`sift.cc:419-440`)。**harness 需补 `dispatch_indirect`**(`dawn_kernel_harness.cpp:218` 现只固定 dispatch)。

**②描述子归约(workgroup-barrier,无 warp-shuffle,f32)**:`@workgroup_size(64)`,`var<workgroup> hist:array<atomic<u32>,128>`(定点累加,Adreno-f16-无关)。64 lane 协作 warp 961 patch 像素→三线性投 hist→barrier→×(1/10) 写 raw_desc。**128×4B=512B ≪ 16KB**(关 affine 绕开既有 PLAN 的 20KB>16KB 坑)。

## 4. 显存预算(三栏)
4224×2376/fo=0/~8192kp:gray_f32 40MB + **gss ~160MB(f16-store→80MB)** + kp_buf ~2.3MB + raw_desc 12MB ≈ **~215MB f32 / ~135MB f16**。**Scale validation**:A16 jetsam ~3072MB,~215MB 极宽松(vs DA3 multi-view 692MB peak)。唯一往返=raw_desc 12MB。**Peer**:DSP-SIFT@fo0 161MB < XFeat sparse 318MB(`PLAN.md:134`)。

## 5. Parity 方法论(守 0.83px/0.933)
fork `extract_selfcheck.cc`→`extract_gpuparity.cc`。**L0 逐stage buffer dump**(harness `readback()` :287):gss max-rel≤1e-3、kp IoU recall≥0.97、desc cosine≥0.998。**CPU 参考必须 affine-off**。**L1 match-recall**(复用 `aether_sift_match` `dsp_sift_c.cc:216`)≥0.95。**L2 e2e reproj**(复用 `colmap_bench.cc:64` + 3 db fixture)**≤0.933/50-of-50**。每后端单独跑(iOS-Metal/Android-Vulkan/Web,WGSL FP variance 4× 矩阵)。金标准对照:PopSift(MPL-2.0)/VulkanSift(MIT);**SiftGPU(UNC非商用)绝不参考**。

## 6. 里程碑(go/no-go)
| M | 范围 | go 判据 |
|---|---|---|
| **M0** 基建对齐(~3-4d) | affine-off CPU 参考 ABI + parity 骨架 + harness `dispatch_indirect` + S0/S1/S1b | 单octave gss max-rel≤1e-3 |
| **M1** 单octave纯GPU切片 | S0-S5 全 GPU(只 octave0) | cosine≥0.998 + match-recall≥0.95 |
| **M2** 多octave | fo=0 全金字塔+跨octave atomic+延迟8192clamp | recall≥0.97,**e2e reproj≤0.933/50-of-50** |
| **M3** DSP调优+计时 | 真机A16 | **亚秒级(3-5×)**且守门 |
| **M4** 跨端+f16优化 | Android/Web各50帧 | 3端各 reproj≤0.933 |

任一 gate 不过 → CPU `_threaded` fallback(M0 起接好),**P0 阻碍签决不私自 pivot**。

## 7. 风险+工程量
最大风险:①CPU基线affine没关→parity永错(M0先解);②descriptor 照搬gss直采而非patch-warp(§2-S5锁死);③Newton +0.5 漏掉(L0抓);④WGSL跨端FP variance(关键pass f32)。**工程量**:WGSL ~1330LOC + C++编排 ~500-700 + parity ~300 = **~2100-2300 LOC / 5-7周**。

## Critical Files
- `aether_threaded_extract.cc:252-305`(CPU真实路径=parity金标准+S5蓝本)
- `dsp_sift_c.cc:26-82`(C ABI契约+extract_gpu注入)
- `shaders/wgsl/sift_gss_blur.wgsl`(S1已有+风格基准)
- `tools/dawn_kernel_harness.cpp:218-263`(GPU基建,补dispatch_indirect)
- `colmap-src/colmap/feature/sift.cc:364-540`(parity常量全在此)
- 对照:`GPU_DSP_SIFT_PLAN.md`(既有/保affine)、`feature/utils.cc:49-69`(归一化数值)
