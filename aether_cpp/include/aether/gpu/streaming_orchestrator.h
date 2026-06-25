// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// streaming_orchestrator.h — per-frame STREAMING loop + bounded queue for the
// GPU DSP-SIFT incremental-SfM capture pipeline (PocketWorld).
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT THIS IS
// ═══════════════════════════════════════════════════════════════════════════
// During capture, for every frame the camera delivers, in real time:
//
//     frame ──▶ EXTRACT (GPU DSP-SIFT) ──▶ MATCH (ARKit-pose-prior guided)
//                                       ──▶ register + LOCAL-BA (COLMAP incr.)
//                                       ──▶ sparse point cloud GROWS
//
// The growing sparse cloud IS the on-screen guidance: there is no proxy
// tracker, no separate "coverage" visualization. The real per-frame SfM result
// (the points) is fed straight to the existing UI sink. This orchestrator does
// not own or change the UI; it only produces the cloud snapshot the UI renders.
//
// ═══════════════════════════════════════════════════════════════════════════
// TWO PROBLEMS THIS SOLVES
// ═══════════════════════════════════════════════════════════════════════════
// 1. PIPELINING. Extraction runs on the GPU; match + local-BA run on the CPU.
//    They are independent resources, so we overlap them: while the CPU registers
//    frame N, the GPU extracts frame N+1. Steady-state per-frame cost collapses
//    from sum(extract, sfm) to max(extract, sfm). On A16 that is
//    max(~697ms GPU, ~640ms+match CPU) ≈ ~0.7-0.9s vs the ~2s capture cadence —
//    i.e. it keeps up, with headroom.
//
// 2. BOUNDED QUEUE + DRAIN. When the phone heats, extraction slows (thermal
//    throttling can push it past the cadence). By Little's Law, if per-frame
//    service time > inter-arrival time the backlog grows without bound. We cap
//    it: a BOUNDED queue of pending frames absorbs short overflow; when it is
//    full the producer applies a drop policy (drop-oldest by default — the
//    freshest frames carry the most useful new viewpoints). The queue DRAINS
//    during capture pauses (user holds still) and after capture STOPS, so no
//    accepted frame is silently lost when thermals recover.
//
// Region selection for refinement is POST-capture and is NOT part of this loop.
//
// ═══════════════════════════════════════════════════════════════════════════
// DESIGN: STAGE FUNCTIONS (so this is testable host-side + binds to real ABIs)
// ═══════════════════════════════════════════════════════════════════════════
// The orchestrator does not #include the device-only COLMAP archives or the GPU
// extractor directly. Instead the two stages are injected as std::function:
//
//   ExtractFn  : gray → keypoints + descriptors    (binds to aether_gpu_sift_*)
//   IngestFn   : (frame meta + features) → registered? + cloud snapshot
//                                                  (binds to aether_sfm_add_frame
//                                                   + a per-frame local solve)
//
// In production iOS these bind 1:1 to aether_gpu_sift_extract and the SfM C ABI.
// In the host test harness they are mock closures with the grounded A16
// latencies, so the queue/drain/pipelining behaviour is exercised on this Mac
// without the arm64-only archives. Task A's real extractor drops in unchanged.

#ifndef AETHER_GPU_STREAMING_ORCHESTRATOR_H
#define AETHER_GPU_STREAMING_ORCHESTRATOR_H

#ifdef __cplusplus

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace aether {
namespace gpu {

// ─── per-frame inputs ───────────────────────────────────────────────────────

// One captured frame handed to the orchestrator. `gray` is copied into the
// queue envelope on enqueue (the camera buffer is recycled immediately), so the
// caller may reuse its buffer the instant submit_frame() returns.
struct CaptureFrame {
    const std::uint8_t* gray{nullptr};  // row-major, top-down grayscale
    int width{0};
    int height{0};
    // ARKit intrinsics for this frame.
    float fx{0.f}, fy{0.f}, cx{0.f}, cy{0.f};
    // ARKit world->cam pose prior (free, every frame). Used for guided/epipolar
    // matching so matching is cheap. has_pose=false → matcher falls back to
    // unguided brute-force.
    bool has_pose{false};
    double pose_qwxyz[4]{1, 0, 0, 0};
    double pose_t[3]{0, 0, 0};
    double timestamp{0.0};        // seconds; used to detect capture pauses
    std::uint64_t frame_index{0}; // monotonic capture index
};

// Features for one frame, produced by the extract stage, consumed by ingest.
struct FrameFeatures {
    std::vector<float> xy;        // 2*N  (image pixel coords)
    std::vector<std::uint8_t> desc;  // 128*N RootSIFT
    int count{0};
};

// ─── sparse-cloud snapshot published to the UI ──────────────────────────────

struct CloudPoint {
    float x, y, z;
    std::uint8_t r, g, b, _pad;
};

// Snapshot of the growing sparse cloud after a frame is ingested. Published
// (double-buffered) to the UI thread; the UI renders the latest snapshot. This
// is the user's feedback — it is the real SfM cloud, not a proxy.
struct CloudSnapshot {
    std::vector<CloudPoint> points;
    int registered_frames{0};      // #frames COLMAP has registered so far
    std::uint64_t last_frame_index{0};  // capture index of the newest ingested frame
    double reproj_px{0.0};         // running mean reprojection error (quality)
};

// ─── stage functions (injection points) ─────────────────────────────────────

// EXTRACT: grayscale frame → features. Runs on the orchestrator's GPU thread.
// Binds to aether_gpu_sift_extract in production; CPU extractor in tests.
using ExtractFn =
    std::function<bool(const CaptureFrame& frame, FrameFeatures* out)>;

// INGEST: (frame meta + its features) → did it register? Fills `out_cloud` with
// the CURRENT full sparse cloud snapshot after this frame. Runs on the
// orchestrator's CPU/SfM thread. Binds to aether_sfm_add_frame + a per-frame
// local solve + aether_sfm_get_points in production. The ARKit pose in `frame`
// is the matching prior.
using IngestFn = std::function<bool(const CaptureFrame& frame,
                                    const FrameFeatures& feats,
                                    CloudSnapshot* out_cloud)>;

// CLOUD SINK: called (on the SfM thread) with each new snapshot so the host can
// hand it to the existing UI cloud renderer. The UI is NOT changed; this is the
// existing output path. May be null.
using CloudSink = std::function<void(const CloudSnapshot& snapshot)>;

// ─── configuration ──────────────────────────────────────────────────────────

struct OrchestratorConfig {
    // Bounded pending-frame queue. Sized to the thermal-overflow budget, not to
    // the whole capture: at the nominal cadence the queue stays near-empty
    // (pipelined service < arrival); it only fills during a thermal slowdown and
    // drains on the next pause. 12 frames ≈ ~24 s of slack at the 2 s cadence —
    // enough to ride out a throttle transient without unbounded RAM growth.
    std::size_t max_queue_depth{12};

    int max_features{2048};  // matches aether_sfm_options default

    // Drop policy when the queue is full and a new frame arrives.
    enum class DropPolicy {
        kDropNewest,  // refuse the incoming frame (back-pressure on the camera)
        kDropOldest,  // evict the stalest queued frame, keep the fresh one
    };
    DropPolicy drop_policy{DropPolicy::kDropOldest};

    // A gap larger than this between consecutive submitted timestamps is treated
    // as a capture PAUSE — the orchestrator is already draining continuously, so
    // this only feeds the pause/drain telemetry. Seconds.
    double pause_gap_seconds{1.5};
};

// ─── runtime stats (lock-free reads; for telemetry / tests) ─────────────────

struct OrchestratorStats {
    std::uint64_t submitted{0};       // frames handed to submit_frame()
    std::uint64_t enqueued{0};        // accepted into the queue
    std::uint64_t dropped_newest{0};  // refused (queue full, kDropNewest)
    std::uint64_t dropped_oldest{0};  // evicted (queue full, kDropOldest)
    std::uint64_t extracted{0};       // completed extract stage
    std::uint64_t ingested{0};        // completed ingest (register+localBA)
    std::uint64_t registered{0};      // ingest returned "registered"
    std::size_t queue_depth{0};       // instantaneous pending count
    std::size_t peak_queue_depth{0};  // high-water mark (queue-bounded proof)
};

// ═══════════════════════════════════════════════════════════════════════════
// StreamingOrchestrator
// ═══════════════════════════════════════════════════════════════════════════
// Two worker threads:
//   GPU thread:  pops the bounded queue → ExtractFn → hands features to the
//                inter-stage slot.
//   SfM thread:  takes features → IngestFn → publishes CloudSnapshot to the sink.
// The two stages overlap (extract N+1 while ingest N) → steady-state throughput
// ≈ max(extract, ingest), not the sum.
//
// Lifecycle:
//   start()                  spin up both threads, begin consuming.
//   submit_frame(frame)      O(1), non-blocking. Enqueue or apply drop policy.
//   stop_capture()           stop accepting new frames; KEEP draining the queue
//                            until empty (the "drain after stop" requirement),
//                            then join. Blocks until the backlog is processed.
//   stop_now()               hard stop: stop accepting AND abandon the queue
//                            (e.g. app teardown). Joins without draining.
class StreamingOrchestrator {
public:
    StreamingOrchestrator(ExtractFn extract, IngestFn ingest, CloudSink sink,
                          OrchestratorConfig config) noexcept;
    ~StreamingOrchestrator() noexcept;

    StreamingOrchestrator(const StreamingOrchestrator&) = delete;
    StreamingOrchestrator& operator=(const StreamingOrchestrator&) = delete;

    // Spin up the two worker threads. Idempotent (no-op if already running).
    void start() noexcept;

    // Producer (camera thread). Copies the frame into a queue envelope and
    // enqueues it. Non-blocking, O(frame bytes) for the copy. Returns true if
    // the frame was accepted into the queue, false if dropped by policy.
    bool submit_frame(const CaptureFrame& frame) noexcept;

    // Graceful stop: stop accepting frames, DRAIN the remaining queue (process
    // every accepted-but-pending frame), publish their snapshots, then join the
    // workers. Blocks until the backlog is fully consumed. This is the
    // "drain after capture stops" path the product requires.
    void stop_capture() noexcept;

    // Hard stop: stop accepting AND discard the pending queue, then join. Used
    // for teardown/cancel where the remaining frames are not wanted.
    void stop_now() noexcept;

    // Lock-free-ish snapshot of counters (a short lock for queue_depth).
    OrchestratorStats stats() const noexcept;

    // True while either worker still has work (queue non-empty OR a frame is
    // mid-flight in a stage). Lets a test/host know when the backlog is gone.
    bool busy() const noexcept;

private:
    // Inter-stage hand-off: one frame's (CaptureFrame, FrameFeatures) tuple.
    struct ExtractedItem {
        CaptureFrame frame;             // pose/intrinsics carried forward
        std::vector<std::uint8_t> gray_owned;  // backing store for frame.gray
        FrameFeatures feats;
    };
    // Queue envelope: owns its grayscale copy so the camera buffer is free
    // immediately after submit_frame returns.
    struct QueuedFrame {
        CaptureFrame frame;
        std::vector<std::uint8_t> gray_owned;
    };

    void gpu_thread_func() noexcept;
    void sfm_thread_func() noexcept;

    ExtractFn extract_;
    IngestFn ingest_;
    CloudSink sink_;
    OrchestratorConfig config_;

    // ── bounded pending-frame queue (producer → GPU thread) ──
    mutable std::mutex queue_mu_;
    std::condition_variable queue_cv_;
    std::deque<QueuedFrame> queue_;

    // ── inter-stage slot (GPU thread → SfM thread), depth-1 + overlap ──
    // A small bounded deque (depth 2) lets the GPU run one frame ahead of the
    // SfM stage without unbounded buffering. Depth 2 = "extract N+1 while
    // ingest N" with a one-slot landing pad; deeper buffering here would just
    // hide an undersized main queue.
    mutable std::mutex stage_mu_;
    std::condition_variable stage_cv_;
    std::deque<ExtractedItem> stage_;
    static constexpr std::size_t kStageCapacity = 2;

    std::thread gpu_thread_;
    std::thread sfm_thread_;

    std::atomic<bool> running_{false};
    std::atomic<bool> accepting_{false};  // false after stop_capture/stop_now
    std::atomic<bool> drain_{true};       // stop_capture keeps draining; stop_now false
    std::atomic<bool> gpu_busy_{false};
    std::atomic<bool> sfm_busy_{false};

    // counters
    std::atomic<std::uint64_t> submitted_{0};
    std::atomic<std::uint64_t> enqueued_{0};
    std::atomic<std::uint64_t> dropped_newest_{0};
    std::atomic<std::uint64_t> dropped_oldest_{0};
    std::atomic<std::uint64_t> extracted_{0};
    std::atomic<std::uint64_t> ingested_{0};
    std::atomic<std::uint64_t> registered_{0};
    std::atomic<std::size_t> peak_queue_depth_{0};
};

}  // namespace gpu
}  // namespace aether

#endif  // __cplusplus
#endif  // AETHER_GPU_STREAMING_ORCHESTRATOR_H
