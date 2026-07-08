// dense_preproc.h — deterministic CasDiffMVS pre-processing, ported VERBATIM from
// the certified 'o' pipeline (pocketworld_research_benchmarks/tools/python:
// pw_diffmvs_common.make_proj_matrices/depth_values_tensor, pw_diffmvs_run.scaled_K).
// Byte-exact float32: the CoreML model must be fed inputs bit-identical to Python.
//
// Cross-platform C++17, no deps beyond <array>/<vector>. NO parameter is invented —
// every constant (PROC_H=512, PROC_W=896, NPZ_H=504, numdepth=384, stage scales
// 0.125/0.25/0.5/1.0) is copied from the production 'o' config.
#pragma once
#include <array>
#include <vector>
#include <cstdint>

namespace aether::dense {

// 'o' config constants (verbatim from pw_diffmvs_run.py / _common.py / trio).
constexpr int PROC_H = 512;      // model render height (npz native 504)
constexpr int PROC_W = 896;      // model render width
constexpr int NPZ_H = 504;       // npz intrinsics were baked at 504-tall
constexpr int NUM_DEPTH = 384;   // depth hypotheses

// scaled_K: K[1,:] *= PROC_H/NPZ_H (the npz K is for 504-tall; we render 512-tall).
// K is row-major 3x3 float32; returns the scaled copy.
std::array<float, 9> scaled_K(const std::array<float, 9>& K_npz);

// make_proj_matrices for ONE view: builds the (2,4,4) proj block for a given stage
// scale f, exactly as datasets/mvs.py: proj[0]=w2c, proj[1,:3,:3]=K, then
// proj[1,:2,:] *= f. w2c is row-major 4x4, K is row-major 3x3 (already scaled_K).
// out16 = the 2*4*4=32 floats? No: one stage's proj is (2,4,4)=32 floats. Returns
// the 32 floats [ w2c(16) , Kblock(16) ] with the Kblock's first two rows *f.
std::array<float, 32> make_proj_stage(const std::array<float, 16>& w2c,
                                      const std::array<float, 9>& K, float scale);

// The 4 production stage scales, in order stage1..stage4.
constexpr std::array<float, 4> STAGE_SCALES = {0.125f, 0.25f, 0.5f, 1.0f};

// depth_values_tensor: linspace(1/depth_max, 1/depth_min, NUM_DEPTH) in float32,
// replicating numpy.linspace's exact arithmetic (start + i*step, endpoint pinned).
std::array<float, NUM_DEPTH> depth_values(float depth_min, float depth_max);

}  // namespace aether::dense
