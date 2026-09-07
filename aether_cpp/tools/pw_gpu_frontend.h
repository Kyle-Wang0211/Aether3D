// PocketWorld GPU front end for XRSLAM (OpenCV 4.0.1 replicas on Dawn/WebGPU):
//   preprocess = CLAHE(clip, tiles) -> buildOpticalFlowPyramid(21x21, 3 levels, Scharr derivatives)
//   detect     = goodFeaturesToTrack(maxCorners, quality, minDistance, block 3, Harris k) on the CLAHE image
//   track      = calcOpticalFlowPyrLK(21x21, 3 levels, 30 it / 0.01, USE_INITIAL_FLOW)
// Every stage is verified bit-exact / corner-set-exact against the CPU (see xrslam-gpu-detect/docs/PLAN.md).
// No Dawn types leak through this header.
#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace pw::gpufe {
struct Keypoint { float x, y, response; };
struct Stats { double preprocess_ms = 0, detect_ms = 0, track_ms = 0; uint64_t n_preprocess = 0, n_detect = 0, n_track = 0;
               // wall-time split per stage: host prep (pack/WriteBuffer), GPU submit+wait (end_batch), readback map/copy, host post (sort/grid)
               uint64_t prefetch_declined = 0;   // preprocess_async requests refused because a prefetch was already in flight
               double pre_wait_ms = 0;   // time actually spent waiting in finish() (0 when the GPU finished while the CPU was busy)
               double pre_host_ms = 0, pre_gpu_ms = 0, pre_read_ms = 0, det_gpu_ms = 0, det_read_ms = 0, det_host_ms = 0, trk_host_ms = 0, trk_gpu_ms = 0, trk_read_ms = 0; };
class Frame;   // GPU-resident CLAHE'd pyramid + Scharr derivatives of one image
struct PyrLevel { int w, h, pw, ph, pwq, base; };   // one pyramid level inside the packed readback: padded pw×ph u8 (21 px REFLECT_101 border), rows of pwq words, at word offset base
class FrontEnd {
public:
    static std::unique_ptr<FrontEnd> create(std::string* error = nullptr);
    virtual ~FrontEnd() = default;
    // gray: 8-bit single channel, row stride in bytes. clahe_out (optional) receives the CLAHE'd image (w*h bytes),
    // byte-identical to cv::CLAHE, so CPU consumers of the image stay unchanged.
    virtual std::shared_ptr<Frame> preprocess(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, std::vector<uint8_t>* clahe_out) = 0;
    // Pipelined form: submit the GPU work and return at once (callable from the capture thread); finish() blocks until the
    // frame is ready and optionally reads the CLAHE image back. detect()/track() call finish() implicitly. Thread-safe.
    virtual std::shared_ptr<Frame> preprocess_async(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, bool want_clahe) = 0;
    virtual bool finish(const Frame& f, std::vector<uint8_t>* clahe_out) = 0;
    // Hybrid split: ONE submission per frame doing CLAHE + goodFeaturesToTrack (no GPU pyramid: the CPU builds its own pyramid
    // from the CLAHE image and runs the upstream CPU LK). detect() on such a frame only does the host-side selection.
    virtual std::shared_ptr<Frame> preprocess_detect(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, double quality, double harris_k, std::vector<uint8_t>* clahe_out, bool gpu_pyramid = false) = 0;   // gpu_pyramid: the GPU also builds the LK pyramid (no derivatives) and clahe_out receives the packed padded levels (see pyramid_layout) instead of w*h bytes synchronous form (never declined)
    virtual std::shared_ptr<Frame> preprocess_detect_async(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, double quality, double harris_k, bool gpu_pyramid = false) = 0;
    virtual bool pyramid_layout(const Frame& f, std::vector<PyrLevel>& out) = 0;
    // Diagnostic: build the pyramid from an image that is ALREADY CLAHE'd (no CLAHE applied). Used to replay device dumps.
    virtual std::shared_ptr<Frame> preprocess_preclahe(const uint8_t* clahe_gray, int w, int h, int stride) = 0;
    virtual bool detect(const Frame& f, int max_corners, double quality, double min_distance, double harris_k, std::vector<Keypoint>& out) = 0;
    // next_inout holds the initial flow on entry (OPTFLOW_USE_INITIAL_FLOW) and the tracked positions on exit.
    virtual bool track(const Frame& prev, const Frame& next, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status) = 0;
    // Forward + reverse in one GPU submission (XRSLAM's track_keypoints pattern): reverse tracks next_inout back into
    // `next` -> `prev` starting from rev_inout (= prev_pts on entry). Results identical to two track() calls.
    virtual bool track_fwd_rev(const Frame& prev, const Frame& next, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                               std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) = 0;
    virtual bool healthy() const = 0;
    virtual std::string take_error() = 0;
    virtual Stats stats() const = 0;
    // Runs a floating-point primitive self-check on the GPU (division, sqrt, int->float, fma guard, round, contraction)
    // against IEEE references computed on the host; returns a JSON fragment with mismatch counts per primitive.
    virtual std::string selfcheck() = 0;
    // Per-kernel mean GPU ms (JSON) when AETHER_GPU_TIMESTAMPS=1 was set before create(); "{}" otherwise.
    virtual std::string kernel_times() = 0;
    // Diagnostic: wall time (ms) of one trivial 1-workgroup submission + wait (GPU wake/scheduling latency).
    virtual double probe_latency() = 0;
    // Diagnostic: same as track_fwd_rev but with the one-thread-per-point kernel (no workgroup memory / barriers).
    // Diagnostic: LK with kernel variant v (0 = production workgroup kernel, 1 = one-thread-per-point kernel)
    virtual bool track_variant(int v, const Frame& prev, const Frame& next, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                               std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) = 0;
    virtual bool track_simple(const Frame& prev, const Frame& next, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                              std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) = 0;
    // Diagnostics: read back the padded pyramid (u8 per pixel, level by level, each (w+42)*(h+42)) and the Scharr
    // derivatives (int16 pairs, same layout); and build a Frame from CPU-provided padded levels/derivatives.
    virtual bool dump_pyramid(const Frame& f, std::vector<std::vector<uint8_t>>& levels, std::vector<std::vector<int16_t>>& derivs) = 0;
    virtual std::shared_ptr<Frame> upload_pyramid(int w, int h, const std::vector<std::vector<uint8_t>>& levels, const std::vector<std::vector<int16_t>>& derivs) = 0;
};
}  // namespace pw::gpufe
