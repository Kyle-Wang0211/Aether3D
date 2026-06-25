// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// parity_affine.cc — GPU vs CPU affine-shape (S4a) parity gate for the GPU
// DSP-SIFT port.
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S4 + "The two GPU-hard
// problems (b)". Stage gate (PLAN line 70): ellipse rel-Frobenius median
// <= 2e-2.
//
// This is a SEPARATE harness (sibling of bench/extract_gpuparity.cc; reuses the
// same prebuilt host Dawn + the minimal VLFeat .c subset + the read-only
// tools/dawn_kernel_harness.cpp). It does NOT modify extract_gpuparity.cc or any
// other agent's file.
//
// Strategy (isolate the S4a kernel from gss-build + detect error so the number
// is the affine kernel's, not the pyramid's or the detector's):
//   1. Build the CPU reference gss via VLFeat (vl_covdet_put_image) at the port
//      baseline first_octave=0; run vl_covdet_detect so the feature list holds
//      the POST-REFINE circular oriented-ellipse frames (covdet.c:2027-2037 —
//      a11=a22=sigma, a12=a21=0). These ARE the "post-refine keypoints" S4a
//      consumes (they would come from the S2 Keypoint buffer in production).
//   2. For EACH feature frame, compute VLFeat's reference adapted shape via
//      vl_covdet_extract_affine_shape_for_frame (covdet.c:2462) — the EXACT
//      function vl_covdet_extract_affine_shape calls per feature.
//   3. Feed the SAME frames + the SAME gss (flattened all-octaves buffer + an
//      octave geometry table) to the GPU sift_affine_shape.wgsl kernel
//      (threadgroup-per-keypoint). One dispatch, N workgroups.
//   4. Compare the two ellipses per keypoint: ellipse rel-Frobenius error
//      ||A_gpu - A_cpu||_F / ||A_cpu||_F. Report the median + max + the
//      converge/reject-decision agreement (how many GPU keep-vs-drop decisions
//      match VLFeat, and how many "flip" — the fp32-vs-fp64 boundary count).
//   GATE: ellipse rel-Frobenius median <= 2e-2.
//
// Build: third_party/glomap_vendor/bench/build_affine.sh (worktree-only fast
// path; unique OBJ dir /tmp/parity_affine_obj; reuses the prebuilt host Dawn).
// Run from the aether_cpp/ root:
//   /tmp/parity_affine_obj/parity_affine_exe \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \
//     shaders/wgsl/sift_affine_shape.wgsl [--first-octave N] [--max-kp M]

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

// ─── VLFeat (CPU reference) ───
extern "C" {
#include "covdet.h"
#include "scalespace.h"
}

// ─── Dawn kernel harness (GPU under test) ───
#include "dawn_kernel_harness.h"

// ─── stb_image (JPEG decode) ───
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

std::string read_file(const char* path) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f) return {};
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::string s(static_cast<size_t>(sz), '\0');
  size_t rd = std::fread(s.data(), 1, static_cast<size_t>(sz), f);
  std::fclose(f);
  s.resize(rd);
  return s;
}

// ── GPU-side structs (must match sift_affine_shape.wgsl std430/std140) ──
#pragma pack(push, 4)
struct OctGeom {       // binding(1) — 32 bytes (8 x 4)
  uint32_t width;
  uint32_t height;
  uint32_t base;       // float offset of (o, firstSub) within the gss buffer
  uint32_t pad;
  float step;
  float pad1, pad2, pad3;
};
struct InFrame {       // binding(2) — 32 bytes (8 x 4)
  float x, y, a11, a12, a21, a22, pad0, pad1;
};
struct AffineShape {   // binding(3) — 32 bytes (8 x 4)
  float a11, a12, a21, a22, x, y;
  uint32_t status;
  uint32_t iters;
};
struct Params {        // binding(4) uniform — 32 bytes
  uint32_t num_kp;
  uint32_t num_octaves;
  int32_t first_octave;
  int32_t last_octave;
  int32_t first_sub;
  int32_t last_sub;
  float octave_res;
  float base_scale;
};
#pragma pack(pop)

// Status flags (mirror the WGSL constants).
enum {
  ST_OK_CONVERGED = 0u,
  ST_OK_MAXITER = 1u,
  ST_OK_ANISO = 2u,
  ST_OK_DEGENERATE = 3u,
  ST_REJECT_OOB = 4u,
};

const char* status_name(uint32_t s) {
  switch (s) {
    case ST_OK_CONVERGED: return "converged";
    case ST_OK_MAXITER: return "maxiter";
    case ST_OK_ANISO: return "aniso-diverge(keep)";
    case ST_OK_DEGENERATE: return "degenerate(keep)";
    case ST_REJECT_OOB: return "reject-oob(drop)";
    default: return "?";
  }
}

double frob(double a11, double a12, double a21, double a22) {
  return std::sqrt(a11 * a11 + a12 * a12 + a21 * a21 + a22 * a22);
}

}  // namespace

int main(int argc, char** argv) {
  const char* img_path =
      "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* wgsl_path = "shaders/wgsl/sift_affine_shape.wgsl";
  int first_octave = 0;                 // PLAN 06-25 port baseline
  double peak_threshold = 0.02 / 3.0;   // COLMAP default (sift.h:54)
  double edge_threshold = 10.0;         // COLMAP default (sift.h:58)
  uint32_t max_kp = 20000u;             // cap the workgroup count for the bench
  {
    int pos = 0;
    for (int i = 1; i < argc; ++i) {
      std::string_view a(argv[i]);
      if (a == "--first-octave" && i + 1 < argc) {
        first_octave = std::atoi(argv[++i]);
        continue;
      }
      if (a == "--peak-threshold" && i + 1 < argc) {
        peak_threshold = std::atof(argv[++i]);
        continue;
      }
      if (a == "--max-kp" && i + 1 < argc) {
        max_kp = static_cast<uint32_t>(std::atoi(argv[++i]));
        continue;
      }
      if (a.size() >= 2 && a[0] == '-' && a[1] == '-') continue;  // unknown flag
      if (pos == 0)
        img_path = argv[i];
      else if (pos == 1)
        wgsl_path = argv[i];
      ++pos;
    }
  }

  // ── 1. Load image as grayscale fp32 (VLFeat convention: [0,255]) ──
  int iw = 0, ih = 0, ic = 0;
  unsigned char* pixels = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!pixels) {
    std::fprintf(stderr, "FAIL: stbi_load(%s): %s\n", img_path,
                 stbi_failure_reason());
    return 2;
  }
  std::printf("image: %s  %dx%d (orig %d ch) -> grayscale fp32\n", img_path, iw,
              ih, ic);
  std::vector<float> gray(static_cast<size_t>(iw) * static_cast<size_t>(ih));
  for (size_t i = 0; i < gray.size(); ++i)
    gray[i] = static_cast<float>(pixels[i]);
  stbi_image_free(pixels);

  // ── 2. CPU reference: build gss + detect -> post-refine feature frames ──
  VlCovDet* covdet = vl_covdet_new(VL_COVDET_METHOD_DOG);
  if (!covdet) {
    std::fprintf(stderr, "FAIL: vl_covdet_new null\n");
    return 2;
  }
  vl_covdet_set_first_octave(covdet, first_octave);
  vl_covdet_set_peak_threshold(covdet, peak_threshold);
  vl_covdet_set_edge_threshold(covdet, edge_threshold);
  vl_covdet_set_transposed(covdet, 0);  // default; up=y in the upright fixup
  vl_covdet_put_image(covdet, gray.data(), static_cast<vl_size>(iw),
                      static_cast<vl_size>(ih));
  vl_covdet_detect(covdet, 1u << 30);

  VlScaleSpace* gss = vl_covdet_get_gss(covdet);
  if (!gss) {
    std::fprintf(stderr, "FAIL: vl_covdet_get_gss null\n");
    vl_covdet_delete(covdet);
    return 2;
  }
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const int firstSub = static_cast<int>(g.octaveFirstSubdivision);
  const int lastSub = static_cast<int>(g.octaveLastSubdivision);
  const int numOct =
      static_cast<int>(g.lastOctave) - static_cast<int>(g.firstOctave) + 1;
  std::printf(
      "gss geometry: octaves [%ld..%ld] (%d) res=%lu subdiv [%d..%d] "
      "baseScale=%.6f\n",
      (long)g.firstOctave, (long)g.lastOctave, numOct,
      (unsigned long)g.octaveResolution, firstSub, lastSub, g.baseScale);

  const vl_size numFeatures = vl_covdet_get_num_features(covdet);
  VlCovDetFeature* feats = vl_covdet_get_features(covdet);
  uint32_t N = static_cast<uint32_t>(numFeatures);
  if (N > max_kp) {
    std::printf("note: capping %u features to --max-kp %u for the bench\n", N,
                max_kp);
    N = max_kp;
  }
  std::printf("post-detect features (post-refine frames): %u\n", N);
  if (N == 0) {
    std::fprintf(stderr, "FAIL: no features detected\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  // ── 3a. CPU reference adapted shape per frame (VLFeat's OWN affine-shape) ──
  // vl_covdet_extract_affine_shape_for_frame returns VL_ERR_OK for the keep
  // cases (converged / maxiter / aniso-diverge / degenerate-reset) and a non-OK
  // status only when the patch goes out of the scale space (the DROP case).
  struct CpuShape {
    double a11, a12, a21, a22;
    bool kept;  // VL_ERR_OK
  };
  std::vector<CpuShape> cpu(N);
  std::vector<InFrame> in_frames(N);
  size_t cpu_kept = 0;
  for (uint32_t i = 0; i < N; ++i) {
    VlFrameOrientedEllipse fr = feats[i].frame;
    in_frames[i] = InFrame{fr.x, fr.y, fr.a11, fr.a12, fr.a21, fr.a22, 0.f, 0.f};
    VlFrameOrientedEllipse adapted;
    int status = vl_covdet_extract_affine_shape_for_frame(covdet, &adapted, fr);
    cpu[i].kept = (status == VL_ERR_OK);
    cpu[i].a11 = adapted.a11;
    cpu[i].a12 = adapted.a12;
    cpu[i].a21 = adapted.a21;
    cpu[i].a22 = adapted.a22;
    if (cpu[i].kept) ++cpu_kept;
  }
  std::printf("CPU affine-shape: kept=%zu dropped=%zu (of %u)\n", cpu_kept,
              static_cast<size_t>(N) - cpu_kept, N);

  // ── 3b. Build the flattened gss buffer + octave geometry table for the GPU.
  // Layout per octave o: all subdivisions [firstSub..lastSub] contiguous,
  // level-major. base[o] = running float offset of (o, firstSub). This matches
  // the WGSL OctGeom.base + (s-firstSub)*W*H indexing.
  std::vector<OctGeom> octgeom(static_cast<size_t>(numOct));
  size_t total_floats = 0;
  const int nSub = lastSub - firstSub + 1;
  for (int oi = 0; oi < numOct; ++oi) {
    const int o = static_cast<int>(g.firstOctave) + oi;
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    octgeom[oi].width = static_cast<uint32_t>(og.width);
    octgeom[oi].height = static_cast<uint32_t>(og.height);
    octgeom[oi].base = static_cast<uint32_t>(total_floats);
    octgeom[oi].pad = 0u;
    octgeom[oi].step = static_cast<float>(og.step);
    octgeom[oi].pad1 = octgeom[oi].pad2 = octgeom[oi].pad3 = 0.f;
    total_floats += static_cast<size_t>(og.width) *
                    static_cast<size_t>(og.height) *
                    static_cast<size_t>(nSub);
  }
  std::printf("gss flat buffer: %zu floats (%.1f MB)\n", total_floats,
              total_floats * 4.0 / (1024.0 * 1024.0));
  std::vector<float> gss_flat(total_floats);
  for (int oi = 0; oi < numOct; ++oi) {
    const int o = static_cast<int>(g.firstOctave) + oi;
    VlScaleSpaceOctaveGeometry og = vl_scalespace_get_octave_geometry(gss, o);
    const size_t plane = static_cast<size_t>(og.width) *
                         static_cast<size_t>(og.height);
    for (int s = firstSub; s <= lastSub; ++s) {
      const float* lv = vl_scalespace_get_level_const(gss, o, s);
      std::memcpy(gss_flat.data() + octgeom[oi].base +
                      static_cast<size_t>(s - firstSub) * plane,
                  lv, plane * sizeof(float));
    }
  }

  // ── 4. GPU dispatch: sift_affine_shape.wgsl, one workgroup per keypoint ──
  std::string wgsl = read_file(wgsl_path);
  if (wgsl.empty()) {
    std::fprintf(stderr, "FAIL: could not read WGSL at %s\n", wgsl_path);
    vl_covdet_delete(covdet);
    return 2;
  }

  aether::tools::DawnKernelHarness harness;
  if (!harness.init()) {
    std::fprintf(stderr, "FAIL: DawnKernelHarness.init() (no host Dawn?)\n");
    vl_covdet_delete(covdet);
    return 2;
  }

  auto pipeline = harness.load_compute(wgsl, "affine_shape");

  wgpu::Buffer gss_buf =
      harness.upload(gss_flat.data(), gss_flat.size() * sizeof(float),
                     wgpu::BufferUsage::Storage);
  wgpu::Buffer oct_buf =
      harness.upload(octgeom.data(), octgeom.size() * sizeof(OctGeom),
                     wgpu::BufferUsage::Storage);
  wgpu::Buffer frame_buf =
      harness.upload(in_frames.data(), in_frames.size() * sizeof(InFrame),
                     wgpu::BufferUsage::Storage);
  const size_t out_bytes = static_cast<size_t>(N) * sizeof(AffineShape);
  wgpu::Buffer out_buf = harness.alloc(
      out_bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

  Params p{N,
           static_cast<uint32_t>(numOct),
           static_cast<int32_t>(g.firstOctave),
           static_cast<int32_t>(g.lastOctave),
           firstSub,
           lastSub,
           static_cast<float>(g.octaveResolution),
           static_cast<float>(g.baseScale)};
  wgpu::Buffer params_buf =
      harness.upload(&p, sizeof(p), wgpu::BufferUsage::Uniform);

  // Binding order matches the WGSL: gss(0), octs(1), frames(2), out(3), P(4).
  // One workgroup per keypoint (the workgroup owns 1 kp).
  harness.dispatch(pipeline, {gss_buf, oct_buf, frame_buf, out_buf, params_buf},
                   N, 1u, 1u);

  wgpu::Buffer staging = harness.alloc_staging_for_readback(out_bytes);
  harness.copy_to_staging(out_buf, staging, out_bytes);
  std::vector<uint8_t> obytes = harness.readback(staging, out_bytes);
  std::vector<AffineShape> gpu(N);
  std::memcpy(gpu.data(), obytes.data(), out_bytes);

  // ── 5. Compare ellipses + decision agreement ──
  // rel-Frobenius is computed only over the keypoints BOTH sides keep (the
  // shape of a dropped kp is undefined). Decision agreement is computed over ALL
  // keypoints (keep-vs-drop is itself a parity quantity, the fp32-vs-fp64
  // boundary). Status-level agreement is also tallied for diagnostics.
  std::vector<double> rel_errs;
  rel_errs.reserve(N);
  size_t both_keep = 0, both_drop = 0, flip_keep_gpu_drop = 0,
         flip_drop_gpu_keep = 0;
  // status histogram for GPU and the matched-status count.
  size_t gpu_status_count[5] = {0, 0, 0, 0, 0};
  size_t worst_idx = 0;
  double worst_rel = 0.0;

  for (uint32_t i = 0; i < N; ++i) {
    const bool gpu_keep = (gpu[i].status != ST_REJECT_OOB);
    const bool cpu_keep = cpu[i].kept;
    if (gpu[i].status < 5u) ++gpu_status_count[gpu[i].status];

    if (cpu_keep && gpu_keep) {
      ++both_keep;
      const double dn = frob(cpu[i].a11, cpu[i].a12, cpu[i].a21, cpu[i].a22);
      const double da11 = gpu[i].a11 - cpu[i].a11;
      const double da12 = gpu[i].a12 - cpu[i].a12;
      const double da21 = gpu[i].a21 - cpu[i].a21;
      const double da22 = gpu[i].a22 - cpu[i].a22;
      const double num = frob(da11, da12, da21, da22);
      const double rel = (dn > 1e-30) ? num / dn : num;
      rel_errs.push_back(rel);
      if (rel > worst_rel) {
        worst_rel = rel;
        worst_idx = i;
      }
    } else if (!cpu_keep && !gpu_keep) {
      ++both_drop;
    } else if (cpu_keep && !gpu_keep) {
      ++flip_keep_gpu_drop;  // CPU kept, GPU dropped
    } else {
      ++flip_drop_gpu_keep;  // CPU dropped, GPU kept
    }
  }

  double median = 0.0, p95 = 0.0, p99 = 0.0, mx = 0.0, mean = 0.0;
  size_t over_gate = 0;
  if (!rel_errs.empty()) {
    std::sort(rel_errs.begin(), rel_errs.end());
    median = rel_errs[rel_errs.size() / 2];
    p95 = rel_errs[static_cast<size_t>(0.95 * (rel_errs.size() - 1))];
    p99 = rel_errs[static_cast<size_t>(0.99 * (rel_errs.size() - 1))];
    mx = rel_errs.back();
    for (double e : rel_errs) {
      mean += e;
      if (e > 2e-2) ++over_gate;
    }
    mean /= static_cast<double>(rel_errs.size());
  }

  std::printf(
      "\n=== AFFINE-SHAPE PARITY (GPU sift_affine_shape.wgsl vs VLFeat "
      "vl_covdet_extract_affine_shape_for_frame) ===\n"
      "keypoints              : %u\n"
      "both keep              : %zu\n"
      "both drop              : %zu\n"
      "FLIP cpu-keep/gpu-drop : %zu\n"
      "FLIP cpu-drop/gpu-keep : %zu\n"
      "decision agreement     : %.6f  ((both_keep+both_drop)/N)\n",
      N, both_keep, both_drop, flip_keep_gpu_drop, flip_drop_gpu_keep,
      static_cast<double>(both_keep + both_drop) / static_cast<double>(N));
  std::printf(
      "GPU status histogram   : converged=%zu maxiter=%zu aniso=%zu "
      "degenerate=%zu reject-oob=%zu\n",
      gpu_status_count[0], gpu_status_count[1], gpu_status_count[2],
      gpu_status_count[3], gpu_status_count[4]);
  std::printf(
      "ellipse rel-Frobenius (over %zu both-keep): median=%.6e mean=%.6e "
      "p95=%.6e p99=%.6e max=%.6e  (>2e-2: %zu = %.4f%%)\n",
      rel_errs.size(), median, mean, p95, p99, mx, over_gate,
      rel_errs.empty()
          ? 0.0
          : 100.0 * static_cast<double>(over_gate) /
                static_cast<double>(rel_errs.size()));
  if (!rel_errs.empty()) {
    std::printf(
        "worst kp #%zu  rel=%.6e  status=%s\n"
        "  CPU A=[% .6f % .6f ; % .6f % .6f]\n"
        "  GPU A=[% .6f % .6f ; % .6f % .6f]\n",
        worst_idx, worst_rel, status_name(gpu[worst_idx].status),
        cpu[worst_idx].a11, cpu[worst_idx].a12, cpu[worst_idx].a21,
        cpu[worst_idx].a22, gpu[worst_idx].a11, gpu[worst_idx].a12,
        gpu[worst_idx].a21, gpu[worst_idx].a22);
  }

  // ── Gate: PLAN line 70 — ellipse rel-Frobenius median <= 2e-2. ──
  const double kGate = 2e-2;
  const bool pass = (!rel_errs.empty()) && (median <= kGate);
  std::printf("\ngate: ellipse rel-Frob median <= %.0e (%.6e %s)  =>  %s\n",
              kGate, median, median <= kGate ? "ok" : "FAIL",
              pass ? "PASS" : "FAIL");

  vl_covdet_delete(covdet);
  return pass ? 0 : 1;
}
