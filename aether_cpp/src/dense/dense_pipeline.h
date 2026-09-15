// dense_pipeline.h — the on-device dense point cloud job (Stage 1 + Stage 2 end to end):
//   session table (dense_session) -> photos (dense_images) -> per-view inference (dense_runner) written to an
//   on-disk pack -> session released -> certified fusion from the pack (dense_fuse_pack) -> PLY.
// Every stage is the gated one; this file only sequences them and owns the disk pack.
//
// [2026-09-15 Stage 3] Progressive delivery. With a chunk callback the job no longer waits for the last view:
// after each inferred view every reference frame whose ref view and all nsrc source views are now inferred is
// fused (FuseScheduler + fuse_pack_frame) and its points are handed to the caller immediately, while
// inference is still running. The fused points are spilled to work_dir/fused_<f>.bin and the PLY is assembled
// in frame order at the end, so out_ply and FusePackStats are byte-for-byte what the chunk-less path writes
// (gated on the certified fixture pack by test_progressive.cc). chunk == nullptr takes the pre-Stage-3 path
// unchanged: infer everything, release the ORT session, then fuse_pack() the whole range.
#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include "dense_fuse.h"
#include "dense_fuse_pack.h"
#include "dense_session.h"

namespace aether::dense {

struct DenseJob {
    std::vector<SessionFrame> frames;      // registered poses sorted by frame_id
    std::vector<std::string> jpeg_paths;   // per frame, same order (materialised JPEGs)
    std::vector<float> points;             // sparse points N*3 (official_sfm_sparse.ply xyz)
    SessionParams session;
    FuseParams fuse;
    std::string model_path;                // fused CasDiffMVS ONNX
    bool webgpu = true;
    std::string work_dir;                  // pack files (depth/conf/rgb/cams/neighbors/meta) are written here
    std::string out_ply;
    uint64_t noise_seed = 0x5EEDDEE5ULL;
    // Selection box (SelectionBox, lib/official_capture/selection_box.dart; BoxFilter in dense_fuse_pack.h): when set,
    // only frames that see >= 1 sparse point inside the box are used — the certified session recipe runs UNCHANGED on
    // that subset — and only fused points inside the box are delivered. Fewer than nsrc+1 such frames -> whole set.
    bool has_box = false;
    double box_c[3] = {0, 0, 0}, box_s[3] = {0, 0, 0};
    double box_rot[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    // ---- test hooks (device parity bench) ----
    int ref_begin = 0, ref_end = -1;       // reference frames to fuse (-1 = all); views they need are inferred
    const float* ext_noise = nullptr;      // per session frame: (H/4*W/4 + H/2*W/2) floats, NF blocks (nullptr -> make_noise)
    const float* ref_depth = nullptr;      // per session frame H*W (parity stats), nullptr -> none
};

struct DenseStats {
    int NF = 0, inferred = 0, images = 0;
    int frames_selected = 0; bool box_fallback = false;   // selection subset size / fell back to all frames
    double session_ms = 0, images_ms = 0, ort_session_ms = 0, infer_ms_median = 0, infer_ms_total = 0, fuse_ms = 0;
    // parity vs ref_depth over inferred views: bench_main.cc criteria
    size_t parity_pixels = 0, parity_bad1 = 0, parity_nonfinite = 0; double parity_worst_rel = 0;
    FusePackStats fuse;
    std::string error;
};

// Called once per REFERENCE frame the moment that frame's fusion is done, in dependency order. xyz = n*3
// floats, rgb = n*3 bytes, in the sparse PLY's world frame and already box-filtered — exactly the bytes that
// frame contributes to out_ply. frame_index indexes DenseJob::frames. Buffers live only for the call.
// Non-zero return cancels the job (dense_run returns 1).
typedef int (*dense_chunk_fn)(int frame_index, const float* xyz, const uint8_t* rgb, int n_points, void* user);

// Returns 0 ok, 1 cancelled, 2 input error, 3 model error, 4 fusion error.
// `user` is passed to both callbacks. chunk == nullptr -> the pre-Stage-3 schedule, bit-for-bit.
int dense_run(const DenseJob& job, dense_progress_fn progress, dense_chunk_fn chunk, void* user, DenseStats* stats);

// Pre-Stage-3 signature, kept for the device parity bench (ios_dense_bench/dense_bench_main.cc:76).
inline int dense_run(const DenseJob& job, dense_progress_fn progress, void* user, DenseStats* stats) {
    return dense_run(job, progress, (dense_chunk_fn) nullptr, user, stats);
}

}  // namespace aether::dense
