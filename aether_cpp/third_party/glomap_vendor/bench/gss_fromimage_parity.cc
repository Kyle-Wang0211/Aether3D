// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// gss_fromimage_parity.cc — DECISIVE parity check of the GPU-FROM-IMAGE gss
// build (the path the production GpuSiftExtractor now uses) vs the VLFeat host
// gss. UNLIKE extract_gpuparity.cc --full (which seeds octave-0 firstSub from
// the CPU VLFeat level), this harness builds octave-0 firstSub FULLY ON THE GPU
// from the raw image — image copy + top-up Gaussian blur to the firstSub sigma —
// exactly as gpu_sift_extractor.cc build_resident_gss_from_image does. It then
// chains every subsequent level/octave on the GPU and compares EVERY level to
// VLFeat's gss, so it quantifies the drift (if any) introduced by seeding the
// octave-0 base from the image rather than the CPU level.
//
// Build: bench/build_gss_fromimage_parity.sh. Run from aether_cpp/ root:
//   /tmp/gss_fromimage_obj/gss_fromimage_parity_exe \
//     third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \
//     shaders/wgsl/sift_gss_blur.wgsl shaders/wgsl/sift_gss_resample.wgsl

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
#include "covdet.h"
#include "scalespace.h"
#include "imopv.h"
#include "mathop.h"
}

#include "dawn_kernel_harness.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

std::string read_file(const char* path) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f) return {};
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::string s((size_t)sz, '\0');
  size_t rd = std::fread(s.data(), 1, (size_t)sz, f);
  std::fclose(f);
  s.resize(rd);
  return s;
}

// Identical tap construction to gpu_sift_extractor.cc vlfeat_gaussian_taps_f.
std::vector<float> taps_f(double sigma, int* out_radius) {
  const int width = (int)std::ceil(sigma * 3.0);
  const int size = 2 * width + 1;
  std::vector<float> filter((size_t)size);
  float mass = 1.0f;
  filter[(size_t)width] = 1.0f;
  for (int i = 1; i <= width; ++i) {
    const double x = (double)i / sigma;
    const float gg = (float)std::exp(-0.5 * x * x);
    mass += gg + gg;
    filter[(size_t)(width - i)] = gg;
    filter[(size_t)(width + i)] = gg;
  }
  for (int i = 0; i < size; ++i) filter[(size_t)i] /= mass;
  *out_radius = width;
  return filter;
}

// Separable blur on the GPU: axis=1 (vertical) then axis=0 (horizontal), the
// SAME order as the module's blur_rec and extract_gpuparity gpu_separable_blur.
std::vector<float> gpu_blur(aether::tools::DawnKernelHarness& h,
                            const std::string& wgsl,
                            const std::vector<float>& src, int w, int hh,
                            const std::vector<float>& taps, int radius) {
#pragma pack(push, 4)
  struct P { uint32_t width, height, radius, axis; };
#pragma pack(pop)
  const size_t n = (size_t)w * hh;
  const size_t bytes = n * sizeof(float);
  auto pipe = h.load_compute(wgsl, "main");
  wgpu::Buffer taps_buf = h.upload(taps.data(), taps.size() * sizeof(float), wgpu::BufferUsage::Storage);
  const uint32_t gx = ((uint32_t)w + 7u) / 8u, gy = ((uint32_t)hh + 7u) / 8u;

  wgpu::Buffer s0 = h.upload(src.data(), bytes, wgpu::BufferUsage::Storage);
  wgpu::Buffer d0 = h.alloc(bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  P pv{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 1u};
  wgpu::Buffer pvb = h.upload(&pv, sizeof(pv), wgpu::BufferUsage::Uniform);
  h.dispatch(pipe, {s0, taps_buf, d0, pvb}, gx, gy, 1u);
  wgpu::Buffer st = h.alloc_staging_for_readback(bytes);
  h.copy_to_staging(d0, st, bytes);
  std::vector<uint8_t> tb = h.readback(st, bytes);
  std::vector<float> tmp(n); std::memcpy(tmp.data(), tb.data(), bytes);

  wgpu::Buffer s1 = h.upload(tmp.data(), bytes, wgpu::BufferUsage::Storage);
  wgpu::Buffer d1 = h.alloc(bytes, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  P ph{(uint32_t)w, (uint32_t)hh, (uint32_t)radius, 0u};
  wgpu::Buffer phb = h.upload(&ph, sizeof(ph), wgpu::BufferUsage::Uniform);
  h.dispatch(pipe, {s1, taps_buf, d1, phb}, gx, gy, 1u);
  wgpu::Buffer st2 = h.alloc_staging_for_readback(bytes);
  h.copy_to_staging(d1, st2, bytes);
  std::vector<uint8_t> ob = h.readback(st2, bytes);
  std::vector<float> out(n); std::memcpy(out.data(), ob.data(), bytes);
  return out;
}

// GPU stride-2 decimation downsample (sift_gss_resample.wgsl `downsample`).
std::vector<float> gpu_downsample(aether::tools::DawnKernelHarness& h,
                                  const std::string& wgsl,
                                  const std::vector<float>& src, int sw, int sh,
                                  int dw, int dh) {
#pragma pack(push, 4)
  struct DP { uint32_t src_width, src_height, dst_width, dst_height; };
#pragma pack(pop)
  auto pipe = h.load_compute(wgsl, "downsample");
  const size_t sn = (size_t)sw * sh, dn = (size_t)dw * dh;
  wgpu::Buffer sb = h.upload(src.data(), sn * sizeof(float), wgpu::BufferUsage::Storage);
  wgpu::Buffer db = h.alloc(dn * sizeof(float), wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  DP dp{(uint32_t)sw, (uint32_t)sh, (uint32_t)dw, (uint32_t)dh};
  wgpu::Buffer dpb = h.upload(&dp, sizeof(dp), wgpu::BufferUsage::Uniform);
  const uint32_t gx = ((uint32_t)dw + 7u) / 8u, gy = ((uint32_t)dh + 7u) / 8u;
  h.dispatch(pipe, {sb, db, dpb}, gx, gy, 1u);
  wgpu::Buffer st = h.alloc_staging_for_readback(dn * sizeof(float));
  h.copy_to_staging(db, st, dn * sizeof(float));
  std::vector<uint8_t> ob = h.readback(st, dn * sizeof(float));
  std::vector<float> out(dn); std::memcpy(out.data(), ob.data(), dn * sizeof(float));
  return out;
}

struct Stats { double max_rel = 0, rms_rel = 0; float cpu_at = 0, gpu_at = 0; };
Stats compare(const std::vector<float>& gpu, const float* cpu, size_t n) {
  Stats s; double sse = 0, ref = 0; double mr = 0;
  for (size_t i = 0; i < n; ++i) {
    const double g = gpu[i], c = cpu[i];
    const double d = std::fabs(g - c);
    const double den = std::max(std::fabs(c), 1e-6);
    const double r = d / den;
    if (r > mr) { mr = r; s.cpu_at = (float)c; s.gpu_at = (float)g; }
    sse += (g - c) * (g - c); ref += c * c;
  }
  s.max_rel = mr;
  s.rms_rel = ref > 0 ? std::sqrt(sse / ref) : 0;
  return s;
}

}  // namespace

int main(int argc, char** argv) {
  const char* img_path = argc > 1 ? argv[1]
      : "third_party/glomap_vendor/iosapp/Resources/sift_test.jpg";
  const char* blur_path = argc > 2 ? argv[2] : "shaders/wgsl/sift_gss_blur.wgsl";
  const char* resamp_path = argc > 3 ? argv[3] : "shaders/wgsl/sift_gss_resample.wgsl";
  const double kMaxRelGate = 1e-3, kRmsGate = 2e-4;

  int iw = 0, ih = 0, ic = 0;
  unsigned char* px = stbi_load(img_path, &iw, &ih, &ic, 1);
  if (!px) { std::fprintf(stderr, "FAIL stbi_load(%s)\n", img_path); return 2; }
  std::vector<float> gray((size_t)iw * ih);
  for (size_t i = 0; i < gray.size(); ++i) gray[i] = (float)px[i];
  stbi_image_free(px);
  std::printf("image %s %dx%d\n", img_path, iw, ih);

  // CPU reference VLFeat gss (first_octave=0, DoG) — the ground truth.
  VlCovDet* cd = vl_covdet_new(VL_COVDET_METHOD_DOG);
  vl_covdet_set_first_octave(cd, 0);
  vl_covdet_set_octave_resolution(cd, 3);
  vl_covdet_put_image(cd, gray.data(), iw, ih);
  VlScaleSpace* gss = vl_covdet_get_gss(cd);
  VlScaleSpaceGeometry g = vl_scalespace_get_geometry(gss);
  const int firstSub = (int)g.octaveFirstSubdivision;
  const int lastSub = (int)g.octaveLastSubdivision;
  const int prevLevelIndex = std::min(firstSub + (int)g.octaveResolution, lastSub);
  std::printf("geom octaves[%ld..%ld] res=%lu subdiv[%d..%d] baseScale=%.6f nominal=%.6f prevLevel=%d\n",
              (long)g.firstOctave, (long)g.lastOctave, (unsigned long)g.octaveResolution,
              firstSub, lastSub, g.baseScale, g.nominalScale, prevLevelIndex);

  std::string blur = read_file(blur_path), resamp = read_file(resamp_path);
  if (blur.empty() || resamp.empty()) { std::fprintf(stderr, "FAIL read wgsl\n"); return 2; }
  aether::tools::DawnKernelHarness h;
  if (!h.init()) { std::fprintf(stderr, "FAIL harness init\n"); return 2; }

  auto sigma_of = [&](int o, int s) {
    return g.baseScale * std::pow(2.0, o + (double)s / (double)g.octaveResolution);
  };

  Stats worst; bool worst_init = false; bool pass = true;
  int fail_o = 0, fail_s = 0; const char* fail_kind = "";
  auto track = [&](const Stats& st, int o, int s, const char* kind) {
    if (!worst_init || st.max_rel > worst.max_rel) { worst = st; worst_init = true; }
    const bool ok = st.max_rel <= kMaxRelGate && st.rms_rel <= kRmsGate;
    if (!ok && pass) { pass = false; fail_o = o; fail_s = s; fail_kind = kind; }
    return ok;
  };

  std::vector<float> gpu_prev_seed; int prev_ow = 0, prev_oh = 0;

  for (int o = (int)g.firstOctave; o <= (int)g.lastOctave; ++o) {
    const int ow = iw >> o, oh = ih >> o;
    const double step = std::pow(2.0, o);
    const size_t on = (size_t)ow * oh;
    std::vector<float> gpu_level;

    if (o == (int)g.firstOctave) {
      // OCTAVE-0 firstSub FROM RAW IMAGE: copy (numOctaves=0) + top-up blur to
      // sigma(0,firstSub), step=1. (gpu_sift_extractor build_resident_gss_from_image)
      gpu_level = gray;  // octave-0 dims == image dims
      const double sigma0 = sigma_of(o, firstSub);
      const double imageSigma = g.nominalScale;
      if (sigma0 > imageSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - imageSigma * imageSigma);
        int radius = 0; std::vector<float> t = taps_f(ds / step, &radius);
        gpu_level = gpu_blur(h, blur, gpu_level, ow, oh, t, radius);
      }
      const float* cpu = vl_scalespace_get_level_const(gss, o, firstSub);
      Stats st = compare(gpu_level, cpu, on);
      std::printf("  o%d s%d [octave0-seed FROM IMAGE vs VLFeat] max_rel=%.3e rms_rel=%.3e %s\n",
                  o, firstSub, st.max_rel, st.rms_rel, track(st, o, firstSub, "oct0-from-image") ? "ok" : "FAIL");
    } else {
      std::vector<float> rs = gpu_downsample(h, resamp, gpu_prev_seed, prev_ow, prev_oh, ow, oh);
      const double sigma0 = sigma_of(o, firstSub);
      const double prevSigma = sigma_of(o - 1, prevLevelIndex);
      if (sigma0 > prevSigma) {
        const double ds = std::sqrt(sigma0 * sigma0 - prevSigma * prevSigma);
        int radius = 0; std::vector<float> t = taps_f(ds / step, &radius);
        gpu_level = gpu_blur(h, blur, rs, ow, oh, t, radius);
      } else gpu_level = rs;
      const float* cpu = vl_scalespace_get_level_const(gss, o, firstSub);
      Stats st = compare(gpu_level, cpu, on);
      std::printf("  o%d s%d [octave-seed/after-topup vs VLFeat] max_rel=%.3e rms_rel=%.3e %s\n",
                  o, firstSub, st.max_rel, st.rms_rel, track(st, o, firstSub, "octave-seed") ? "ok" : "FAIL");
    }

    if (prevLevelIndex == firstSub) { gpu_prev_seed = gpu_level; prev_ow = ow; prev_oh = oh; }

    for (int s = firstSub + 1; s <= lastSub; ++s) {
      const double sig = sigma_of(o, s), sigp = sigma_of(o, s - 1);
      const double ds = std::sqrt(sig * sig - sigp * sigp);
      int radius = 0; std::vector<float> t = taps_f(ds / step, &radius);
      gpu_level = gpu_blur(h, blur, gpu_level, ow, oh, t, radius);
      const float* cpu = vl_scalespace_get_level_const(gss, o, s);
      Stats st = compare(gpu_level, cpu, on);
      std::printf("  o%d s%d [within-octave chained vs VLFeat] max_rel=%.3e rms_rel=%.3e %s\n",
                  o, s, st.max_rel, st.rms_rel, track(st, o, s, "within-octave") ? "ok" : "FAIL");
      if (s == prevLevelIndex) { gpu_prev_seed = gpu_level; prev_ow = ow; prev_oh = oh; }
    }
  }

  std::printf("\n=== GSS-FROM-IMAGE PARITY VERDICT ===\n");
  std::printf("global worst max_rel = %.6e (cpu=%.4f gpu=%.4f)  rms<=gate everywhere\n",
              worst.max_rel, worst.cpu_at, worst.gpu_at);
  std::printf("gate: max_rel<=%.0e AND rms_rel<=%.0e EVERYWHERE => %s\n",
              kMaxRelGate, kRmsGate, pass ? "PASS" : "FAIL");
  if (!pass) std::printf("FIRST FAILURE: o=%d s=%d kind=%s\n", fail_o, fail_s, fail_kind);
  vl_covdet_delete(cd);
  return pass ? 0 : 1;
}
