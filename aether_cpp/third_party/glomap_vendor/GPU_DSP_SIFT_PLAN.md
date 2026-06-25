# GPU DSP-SIFT Extraction — Architecture & Staged Roadmap

Status: **DESIGN + Stage-1 kickoff** (2026-06-22). Multi-week build (~8-11 weeks,
~2300-3500 LOC). Grounded by a 8-agent design workflow over the VLFeat/COLMAP CPU
reference + the in-repo Dawn/WGSL stack.

## Why
On-device extraction is the SfM bottleneck: **~10s/frame @ 4224×2376** (n~12k kp).
CPU optimization caps at ~1.5× (stage-1 descriptor threading 1.16-1.34× +
stage-2 affine threading + SIMD/DSP). To reach a usable ~2-3s/frame (3-5×) the
detection + affine stages must move to the GPU. Goal: preserve affine-covariant
+ domain-size-pooling (the 0.933px quality engine) — **parity target = reproj ≤
0.933px / 50-of-50 registered**, NOT bit-identical (GPU FP ≠ CPU FP).

## Architecture decision: WGSL-everywhere (Dawn), not Metal-native
Build the whole extractor in WGSL on Dawn → one codebase iOS/Android/Web/desktop.
Justification (grounded in this repo):
- The compaction/sort/atomic primitives the port needs already ship here:
  `shaders/wgsl/{prefix_sum_scan*, sort_count/scan/scatter/reduce}.wgsl`
  (Blelloch scan + radix sort with workgroup `atomic<u32>`).
- WGSL→Metal on the A16 is a shipped result: `iosapp/dawnmatchapp/` ran the WGSL
  matcher on a real iPhone 14 Pro via Dawn→Tint→Metal.
- The hard stages are per-keypoint 2×2 SVD, not GEMM — no `simdgroup_matrix`
  needed, so Metal-native buys nothing the quality target requires.
- Reserved escape hatch: a Metal-native `.metal` fast path for ONLY the S5b
  128-D reduction, added via host `#ifdef` *iff* on-device profiling demands it.

## Data flow — gss residency is the load-bearing constraint
```
gray fp32 (10.03M floats)
 └ S1 gss build (separable Gaussian, fp16 store / fp32 in-register)
        → gss pyramid 642 MB fp16 ── RESIDENT ON GPU THE WHOLE FRAME ──┐
 └ S2 DoG = adjacent gss subtract, FUSED into S3 (never materialize css) │ re-read
 └ S3 detect: 26-neighbour test → atomic-append → Newton refine → gates  │ by S3,
 └ S4a affine-shape: per-kp iterative 2×2 SVD (reads gss patches)        │ S4a,
 └ S4b orientation: per-kp 36-bin histogram, 1-4× expand (reads gss)     │ S4b,
 └ S5a radix sort (octave desc, scale desc) + clamp 8192 on band edge    │ S5b
 └ S5b DSP descriptor: N×10 ellipse-warp patches (reads gss) + mean + L1_ROOT ┘
 └ readback → FeatureKeypoints + FeatureDescriptors (128×N uint8)
```
gss = 642 MB fp16, re-read ~4×. On A16 unified memory there's no physical copy,
but it must **never** be rebuilt or round-tripped (a single 642 MB GPU↔CPU trip
eats the whole budget). Engineer away the 3 mid-pipeline count-readbacks (S1/2/3)
with GPU atomic counters + `dispatchWorkgroupsIndirect` (the radix-sort
indirect-args pattern is the template) → ONE forced round-trip/frame (the result).

## The non-negotiable: preserve affine-covariant + DSP
COLMAP hard-blocks plain GPU SIFT (`sift.cc:118-119,525-526`
`THROW_CHECK(!estimate_affine_shape)/!domain_size_pooling`). Every OSS GPU SIFT
(PopSift MPL-2.0 / VulkanSift MIT / CudaSift NC-conflict / SiftGPU NC) extracts an
isotropic upright patch and abandons the ellipse + DSP. Preservation is structural
in 3 places no OSS GPU code has: (1) affine **ellipse warp** of the sampling patch
(VLFeat `covdet.c extract_patch_helper ~2166`), (2) iterative **affine-shape**
2nd-moment+SVD loop (`covdet.c:2462`), (3) **domain-size pooling** (10 dsp_scales,
average, then RootSIFT — `sift.cc:426-433,242`). These port line-by-line from
VLFeat (BSD-2, in-tree). OSS GPU SIFT is read-reference for plumbing ONLY.

## fp32 discipline (the single most important parity lever)
Store gss fp16, but **load→subtract→refine→descriptor-accumulate in fp32
in-register**. DoG subtracts near-equal levels (catastrophic cancellation); fp16
DoG would shift threshold crossings. All warp + descriptor math fp32-in-register,
fp16 storage only.

## Staged roadmap (each stage ships behind the hybrid C-ABI, gated by e2e reproj)
| Stage | Scope | Cum. win @4224 | Effort | Parity gate |
|---|---|---|---|---|
| **S1** | gss build + fused DoG + extremum TEST (rest CPU) | 1.4-1.7× (~6-7s) | ~600-900 LOC, MED, 1-2 wk | gss max-rel ≤1e-3, RMS ≤2e-4; e2e reproj ≤0.933 |
| **S2** | GPU compaction (scan) + Newton refine + gates → finish detection on GPU | ~2× | ~500-800 LOC, HARD, 2-3 wk | kp recall/precision ≥0.97, median pos-err ≤0.05px; reproj ≤0.933 |
| **S3** | GPU DSP descriptor + RootSIFT + UBC reorder | ~2.3-2.6× | ~400-600 LOC, MED, 1.5-2 wk | per-desc cosine median ≥0.998, p95 ≥0.99; match-recall ≥0.95 |
| **S4** | GPU affine-shape + orientation (gss never leaves GPU) — **TARGET** | **3-5× (2-3s)** | ~800-1200 LOC, HARDEST, 3-4 wk | ellipse rel-Frob median ≤2e-2; orient median ≤1°; reproj ≤0.933 |

Order is risk-managed: biggest-safest-first (S1), hardest-last (S4) so the
highest-regret stage keeps a CPU fallback until proven. Total ~8-11 wk.

## The two GPU-hard problems
- **(a) Variable-count extrema compaction** — CPU in S1, GPU in S2. GPU contract:
  per-voxel keep-flag map → reuse in-repo `prefix_sum_scan.wgsl` + `sort_scatter.wgsl`
  to compact (or warp-aggregated atomic where subgroups exist, PopSift pattern) →
  per-kp Newton refine kernel (≤5 iters, let lanes idle). **Drop the octave
  early-out** (it's an optimization re-applied at the S5a clamp): over-detect to a
  24k cap, defer the 8192-clamp to S5a → removes the only serial cross-octave
  coupling + the only forced mid-pipeline count readback. VulkanSift
  `ExtractKeypoints.comp` (MIT) is an exact VLFeat transcription = refine parity ref.
- **(b) Per-keypoint iterative affine-shape** — CPU until S4, GPU in S4.
  **Threadgroup-per-keypoint, batched rounds**: 1 tg owns 1 kp; the 1681 patch
  pixels are warped/gradient'd/2nd-moment-reduced cooperatively by lanes; the two
  `vl_svd2` (closed-form scalar, `mathop.c:641`) + convergence run on lane 0 in
  workgroup memory. Iteration divergence is per-tg not per-lane. **WGSL limit:**
  41×41×3 fp32 ≈ 20KB > portable 16KB `maxComputeWorkgroupStorageSize` → fp16 patch
  storage (10KB) and/or tile in halves; request 32KB on iOS/desktop.

## Risks + the two early checkpoints that prevent sinking weeks
1. **first_octave=−1 is ~75% of gss** (240M of 321M floats). **Week-1 A/B**:
   first_octave −1 vs 0 on the 50-frame reproj bench. If reproj holds at 0, gss
   drops to ~160 MB fp16 and detection cost collapses. MUST validate (changes the
   tiny-feature set), never assume. Keep −1 as parity baseline; 0 is upside.
2. **S1 e2e timing, week 2**: if the hybrid gives <1.3× because the gss/patch
   transfer dominates, the boundary is misplaced → transfer flags only, or jump
   straight to S2 (finish detection on GPU, remove the boundary).
3. fp16 gss breaks parity → fall back fp32 gss (1284 MB, feasible on 6-8GB A16).
4. S4a affine fp32 (VLFeat uses fp64; WGSL has no fp64): hard convergence/anisotropy
   thresholds can flip prune/keep → emulate fp64 in `dlasv2` inner only, or
   last-resort keep S4a on CPU permanently (caps ~2.3×, still ships).
5. WGSL per-backend FP variance → each backend (iOS-Metal/Android-Vulkan/Web)
   needs its OWN 50-frame reproj pass. 4× validation matrix = the real cost of
   WGSL-everywhere (reproj-not-bitexact makes each pass likely).

## Parity harness (build once, ~2-3 days, ~700 LOC)
Fork `bench/extract_selfcheck.cc` → tolerance variant (`bench/extract_gpuparity.cc`);
reuse `aether_sift_match` (dsp_sift_c.cc) for descriptor recall; reuse
`colmap_bench.cc` + `aether_sfm_c.cc` for the e2e reproj gate on the 3 db fixtures
(4224/3200/2048). Desktop loop: `build-desktop` (host glog 0.7.1, host Dawn).

## Licenses (all clean)
VLFeat BSD-2 (port source), COLMAP BSD-3 (orchestration + e2e gate), in-repo WGSL
scan/sort Apache-2.0, Dawn/Tint BSD-3, VulkanSift MIT (plumbing read-ref only — its
plain-upright-SIFT cannot be lifted for affine/DSP).

## Stage-1 starting artifacts (this commit)
- `shaders/wgsl/sift_gss_blur.wgsl` — separable 1D Gaussian (row+col), fp16 store /
  fp32 accumulate, clamp-to-edge (VLFeat VL_PAD_BY_CONTINUITY). The first concrete
  kernel; NOT yet parity-validated — that is S1 week-1 work (gss max-rel ≤1e-3).
Next: `sift_gss_resample.wgsl`, `sift_dog_extrema_test.wgsl`, `src/gpu/
sift_pyramid_dawn.{h,cc}`, `bench/extract_gpuparity.cc`, then the week-1 A/B.

## 2026-06-25 — week-1 gates run + extractor choice CONFIRMED (desktop A/B)
- **Gate 1 (first_octave −1 vs 0): PASS.** bench50 50f@4224, COLMAP incremental, all DSP-SIFT opts equal:
  fo−1 → 50/50, reproj 1.0076px; **fo0 → 50/50, reproj 1.0217px (+0.014, noise)**. octave −1 = 75% of gss
  but ~1.6% of keypoints → **gss 642MB → 161MB (4×) confirmed.** **Adopt first_octave=0 as the port baseline.**
- **Extractor choice re-litigated (no sunk cost) and CONFIRMED: stay DSP-SIFT, do this GPU port.** XFeat
  desktop A/B (same fixture/mapper/BA, 3 matchers incl. its own LighterGlue): best XFeat = 1.086px vs
  DSP-SIFT COLMAP+CAUCHY 0.8319px (+30%); all XFeat variants 1.09-1.53px, 50/50 registered, strong inliers
  → fair failure on sub-pixel localization (structural: 8×8-cell/1-8-res heatmap). XFeat extract 25× faster
  (0.2s) but fails the quality gate; and DSP-SIFT @fo0 161MB < XFeat sparse 318MB → XFeat loses memory too.
  Full data: `pocketworld_research_benchmarks/experiments/frontend_extractor_ab_2026-06-25.md`.
- **Gate 2 (S1 gss parity): host Dawn proven (aether_dawn_hello_compute PASS); full parity harness
  (`extract_gpuparity.cc` + `sift_gss_resample.wgsl`) still to build.** NOTE: shaders/Dawn are under
  `aether_cpp/` (not `glomap_vendor/`) — the paths above are aether_cpp-relative.

## 2026-06-25 — S1 task A: fused DoG + 26-neighbour extremum TEST built + parity PASS
- **`shaders/wgsl/sift_dog_extrema_test.wgsl`** (entry `detect`): fused DoG (css[lvl]=gss[lvl]−gss[lvl+1],
  the VLFeat `_vl_dog_response` sign, fp32 in-register, no css materialized) + strict 26-neighbour scale-space
  extremum test gated by `detect_thr = 0.8*peakThreshold` + atomic-append. Replicates VLFeat `covdet.c`
  exactly: `_vl_dog_response` (1905), css geom `octaveLastSubdivision−=1` (1939) depth (2002),
  `vl_find_local_extrema_3` (1057-1126: threshold gate non-strict `>=`/`<=`, 26 neighbours STRICT `>`/`<`,
  interior bounds 1103-1105), threshold 0.8× (2013). Output interface (record layout, bindings, ~24k cap) in
  `bench/gpu_extrema_iface.md` + the .wgsl header — for task B (S2 compaction/Newton).
- **Parity: RECALL = PRECISION = 1.000000** on `sift_test.jpg` (4224×2376) vs VLFeat's OWN
  `vl_find_local_extrema_3` on the byte-identical CPU css. fo0: 36779 candidates, 0 miss / 0 extra across
  8 octaves. fo−1 baseline: 153551 candidates, 0/0 across 9 octaves. VLFeat default peak_threshold 0.01:
  identical. **No fp32 divergence** because the kernel is fed VLFeat's exact gss bytes (isolates DETECT from
  gss-build) and the subtract+compare are arithmetically exact — divergence (if any) lives in the separately
  gated gss-build (max-rel ≤1e-3), not the detector. `bench/extract_gpuparity.cc --detect` mode + the
  declared-extern `vl_find_local_extrema_3` (non-static, no public header).
- Harness: `tools/dawn_kernel_harness.cpp` got `maxStorageBufferBindingSize`/`maxBufferSize` bumped to 2 GB
  (one octave's 6 gss levels @4224×2376 = ~240 MB > default 128 MB binding; fo−1 octave −1 = ~963 MB >
  256 MB default). Permissive-only (cannot change existing kernel output). Build: `bench/build_gpuparity.sh`
  (reuses prebuilt host Dawn, no rebuild).
