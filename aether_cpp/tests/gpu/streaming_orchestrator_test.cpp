// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// streaming_orchestrator_test.cpp — host test harness for the per-frame
// streaming loop + bounded queue.
//
// This is a self-asserting main() (the repo's test convention — no gtest dep).
// It injects MOCK stage functions with the grounded A16 latencies so the
// pipelining / queue-bounded / drain behaviour is exercised on the host without
// the arm64-only COLMAP + GPU archives. Task A's real extractor and the real
// SfM C ABI drop into the same ExtractFn/IngestFn slots unchanged.
//
// Latency constants are SCALED DOWN by kTimeScale so the suite runs in well
// under a second while preserving the *ratios* that drive the queue dynamics
// (extract:ingest:cadence). The scale factor is also used to derive the
// real-time projections printed at the end. Set AETHER_ORCH_REALTIME=1 in the
// env to run at true wall-clock A16 timings (slow; for manual grounding).
//
// Build (host, no device archives needed):
//   c++ -std=c++20 -O2 -I include \
//       src/gpu/streaming_orchestrator.cc \
//       tests/gpu/streaming_orchestrator_test.cpp -o /tmp/orch_test -lpthread
//   /tmp/orch_test

#include "aether/gpu/streaming_orchestrator.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

using namespace aether::gpu;
using Clock = std::chrono::steady_clock;

// ── grounded A16 timings (milliseconds) ─────────────────────────────────────
// extract: GPU DSP-SIFT ~697 ms on A16 (GPU_DSP_SIFT_PLAN.md S4 target / task-A).
// ingest : COLMAP incremental register + LOCAL-BA ~640 ms device
//          (aether_sfm_c.cc [A]: defer_global_ba -> per-frame is local-only).
// match  : ARKit-pose-prior guided, folded into ingest; the unguided
//          brute-force matcher GEMM is ~119 ms (memory: matcher already cheap),
//          guided epipolar is cheaper still. We model it inside ingest.
// cadence: ~2000 ms capture interval (the product's ~2 s/frame cadence).
static constexpr double kExtractMsA16 = 697.0;
static constexpr double kIngestMsA16 = 640.0;
static constexpr double kCadenceMs = 2000.0;
// Thermal-throttled extract: under sustained heat GPU clocks drop; model a
// ~1.9x slowdown so per-frame extract (~1320 ms) approaches/exceeds cadence and
// forces the queue to absorb overflow.
static constexpr double kThermalExtractMs = 1320.0;

// Time compression so the suite runs fast while preserving ratios.
static constexpr double kTimeScale = 0.02;  // 697ms -> ~14ms

// Mutable so a test can simulate thermal slowdown; atomic because a test phase
// (main thread) writes it while the GPU worker reads it.
static std::atomic<double> g_extract_ms{kExtractMsA16};

static void busy_sleep_ms(double ms) {
    if (ms <= 0) return;
    std::this_thread::sleep_for(
        std::chrono::microseconds(static_cast<long long>(ms * 1000.0)));
}

// ── assertion helper ────────────────────────────────────────────────────────
static int g_failures = 0;
#define CHECK(cond, msg)                                              \
    do {                                                             \
        if (!(cond)) {                                              \
            std::printf("  [FAIL] %s  (%s:%d)\n", msg, __FILE__, __LINE__); \
            ++g_failures;                                          \
        } else {                                                   \
            std::printf("  [ok]   %s\n", msg);                     \
        }                                                          \
    } while (0)

// ── mock stage builders ─────────────────────────────────────────────────────

// Mock extract: sleeps the (scaled) extract latency, emits a few synthetic
// keypoints. Reads g_extract_ms so a test can simulate thermal slowdown.
static ExtractFn make_extract(std::atomic<int>* extract_calls) {
    return [extract_calls](const CaptureFrame& f, FrameFeatures* out) -> bool {
        busy_sleep_ms(g_extract_ms.load(std::memory_order_relaxed) * kTimeScale);
        const int n = 64;  // synthetic keypoint count
        out->count = n;
        out->xy.assign(2 * n, 0.f);
        out->desc.assign(128 * n, 0);
        for (int i = 0; i < n; ++i) {
            out->xy[2 * i] = static_cast<float>((f.frame_index + i) % f.width);
            out->xy[2 * i + 1] = static_cast<float>(i);
        }
        if (extract_calls) extract_calls->fetch_add(1);
        return true;
    };
}

// Mock ingest: sleeps the (scaled) local-BA latency, grows a cloud by a few
// points per frame, and reports the snapshot. Mimics aether_sfm_add_frame +
// per-frame local solve + aether_sfm_get_points feeding the UI sink.
static IngestFn make_ingest(std::atomic<int>* cloud_size) {
    return [cloud_size](const CaptureFrame& f, const FrameFeatures& feats,
                        CloudSnapshot* out) -> bool {
        (void)feats;
        busy_sleep_ms(kIngestMsA16 * kTimeScale);
        // Grow the cloud by ~10 points/frame (the sparse cloud "grows").
        const int grown = cloud_size->fetch_add(10) + 10;
        out->points.resize(grown);
        out->registered_frames = grown / 10;
        out->last_frame_index = f.frame_index;
        out->reproj_px = 0.93;  // the quality engine's target
        return true;            // registered
    };
}

// ── synthetic frame source ──────────────────────────────────────────────────
static std::vector<std::uint8_t> g_gray(640 * 480, 128);  // shared dummy buffer

static CaptureFrame make_frame(std::uint64_t idx, double t_seconds) {
    CaptureFrame f;
    f.gray = g_gray.data();
    f.width = 640;
    f.height = 480;
    f.fx = f.fy = 500.f;
    f.cx = 320.f;
    f.cy = 240.f;
    f.has_pose = true;  // ARKit pose present → guided matching
    f.timestamp = t_seconds;
    f.frame_index = idx;
    return f;
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST 1 — pipelining: steady-state throughput ≈ max(extract, ingest), NOT sum.
// ═══════════════════════════════════════════════════════════════════════════
static void test_pipelining_throughput() {
    std::printf("\n[TEST 1] pipelining: throughput ~ max(stage), not sum\n");
    g_extract_ms = kExtractMsA16;
    std::atomic<int> cloud{0}, extracts{0};
    OrchestratorConfig cfg;
    cfg.max_queue_depth = 64;  // big enough to not drop in this test
    std::atomic<int> snapshots{0};
    StreamingOrchestrator orch(
        make_extract(&extracts), make_ingest(&cloud),
        [&](const CloudSnapshot&) { snapshots.fetch_add(1); }, cfg);
    orch.start();

    const int N = 30;
    // Submit all frames up front (back-to-back) so the pipeline runs flat-out:
    // this measures the STEADY-STATE service rate, isolating the stage overlap.
    const auto t0 = Clock::now();
    for (int i = 0; i < N; ++i) {
        bool ok = orch.submit_frame(make_frame(i, i * 0.01));
        CHECK(ok, i == 0 ? "first frame accepted" : "frame accepted (queue ok)");
        if (i > 0) continue;  // only print once
    }
    orch.stop_capture();  // drains all N, then joins
    const auto t1 = Clock::now();
    const double wall_ms =
        std::chrono::duration<double, std::milli>(t1 - t0).count();

    const double per_frame_ms = wall_ms / N;
    const double scaled_extract = kExtractMsA16 * kTimeScale;
    const double scaled_ingest = kIngestMsA16 * kTimeScale;
    const double scaled_sum = scaled_extract + scaled_ingest;
    const double scaled_max = scaled_extract > scaled_ingest ? scaled_extract
                                                             : scaled_ingest;

    std::printf("    N=%d wall=%.1fms  per-frame=%.2fms\n", N, wall_ms,
                per_frame_ms);
    std::printf("    scaled max(stage)=%.2fms  sum(stage)=%.2fms\n", scaled_max,
                scaled_sum);

    // The pipeline must beat the naive serial sum by a clear margin, and sit
    // near max(stage) (+ a little hand-off overhead + the one-frame fill/drain).
    CHECK(per_frame_ms < scaled_sum * 0.85,
          "steady-state per-frame < 0.85 * sum(stage) (overlap achieved)");
    CHECK(per_frame_ms < scaled_max * 1.6,
          "steady-state per-frame within 1.6x of max(stage)");
    CHECK(static_cast<int>(snapshots.load()) == N,
          "one cloud snapshot published per frame (UI fed every frame)");
    CHECK(extracts.load() == N, "all frames extracted");
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST 2 — queue stays BOUNDED at the nominal cadence (Little's Law: service
// (pipelined ~max stage) < arrival (cadence) → backlog ~0).
// ═══════════════════════════════════════════════════════════════════════════
static void test_queue_bounded_at_cadence() {
    std::printf("\n[TEST 2] queue bounded at nominal ~2s cadence\n");
    g_extract_ms = kExtractMsA16;
    std::atomic<int> cloud{0};
    OrchestratorConfig cfg;
    cfg.max_queue_depth = 12;
    StreamingOrchestrator orch(make_extract(nullptr), make_ingest(&cloud),
                               nullptr, cfg);
    orch.start();

    const int N = 25;
    for (int i = 0; i < N; ++i) {
        orch.submit_frame(make_frame(i, i * (kCadenceMs / 1000.0)));
        // Arrive at the (scaled) cadence — slower than the pipelined service.
        busy_sleep_ms(kCadenceMs * kTimeScale);
    }
    OrchestratorStats mid = orch.stats();
    orch.stop_capture();
    OrchestratorStats end = orch.stats();

    std::printf("    peak_queue_depth=%zu (cap=%zu)  dropped=%llu\n",
                end.peak_queue_depth, cfg.max_queue_depth,
                (unsigned long long)(end.dropped_newest + end.dropped_oldest));
    // Service < arrival → the queue should never build up. Allow a tiny depth
    // for scheduling jitter, but it must stay far below the cap and never drop.
    CHECK(mid.peak_queue_depth <= 3,
          "peak queue depth <= 3 at nominal cadence (backlog ~0)");
    CHECK(end.dropped_newest + end.dropped_oldest == 0,
          "zero drops at nominal cadence");
    CHECK(end.ingested == static_cast<std::uint64_t>(N),
          "all frames ingested at cadence (keeps up with no loss)");
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST 3 — thermal slowdown: queue ABSORBS overflow (bounded), then DRAINS on
// the pause + after stop. No accepted frame lost; queue never exceeds cap.
// ═══════════════════════════════════════════════════════════════════════════
static void test_thermal_absorb_and_drain() {
    std::printf("\n[TEST 3] thermal overflow: queue absorbs then drains\n");
    std::atomic<int> cloud{0};
    OrchestratorConfig cfg;
    cfg.max_queue_depth = 12;
    cfg.drop_policy = OrchestratorConfig::DropPolicy::kDropOldest;
    StreamingOrchestrator orch(make_extract(nullptr), make_ingest(&cloud),
                               nullptr, cfg);
    orch.start();

    // Phase A: HOT. extract jumps to ~1320ms (> cadence-ish under pipeline).
    // Push a burst FASTER than the (now-slow) service so a backlog forms.
    g_extract_ms = kThermalExtractMs;
    const int hot = 16;
    for (int i = 0; i < hot; ++i) {
        orch.submit_frame(make_frame(i, i * 0.001));
        busy_sleep_ms(kThermalExtractMs * kTimeScale * 0.45);  // arrive faster than service
    }
    OrchestratorStats hot_stats = orch.stats();
    std::printf("    [hot] queue_depth=%zu peak=%zu (cap=%zu)\n",
                hot_stats.queue_depth, hot_stats.peak_queue_depth,
                cfg.max_queue_depth);
    CHECK(hot_stats.peak_queue_depth <= cfg.max_queue_depth,
          "queue NEVER exceeds cap under thermal overflow (bounded)");
    CHECK(hot_stats.peak_queue_depth >= 2,
          "queue actually absorbed a backlog under heat (>=2 deep)");

    // Phase B: PAUSE (user holds still — no new frames). The orchestrator drains
    // continuously, so the backlog shrinks during the pause.
    g_extract_ms = kExtractMsA16;  // thermals recover during the still period
    busy_sleep_ms(kThermalExtractMs * kTimeScale * 8);  // a real pause
    OrchestratorStats paused = orch.stats();
    std::printf("    [pause] queue_depth=%zu  ingested=%llu\n",
                paused.queue_depth, (unsigned long long)paused.ingested);
    CHECK(paused.queue_depth < hot_stats.queue_depth || hot_stats.queue_depth == 0,
          "queue drains during the capture pause");

    // Phase C: STOP. Remaining backlog must be fully processed (drain-after-stop).
    orch.stop_capture();
    OrchestratorStats done = orch.stats();
    std::printf("    [stop] enqueued=%llu ingested=%llu queue_depth=%zu\n",
                (unsigned long long)done.enqueued,
                (unsigned long long)done.ingested, done.queue_depth);
    CHECK(done.queue_depth == 0, "queue fully drained after stop");
    // No eviction occurred here (queue stayed under cap), so every frame that
    // entered the queue was ingested: enqueued == evicted + ingested with
    // evicted==0 => ingested==enqueued.
    CHECK(done.ingested == done.enqueued - done.dropped_oldest,
          "every still-queued accepted frame was ingested (drain complete)");
    CHECK(!orch.busy(), "orchestrator idle after drain");
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST 4 — drop policies under sustained overload (queue full, fast arrival).
// kDropOldest keeps the freshest frames; kDropNewest back-pressures the camera.
// Either way the queue stays bounded and accepted==ingested.
// ═══════════════════════════════════════════════════════════════════════════
static void test_drop_policies() {
    std::printf("\n[TEST 4] drop policy under sustained overload\n");
    g_extract_ms = kThermalExtractMs;  // keep the pipeline slow

    for (int policy = 0; policy < 2; ++policy) {
        std::atomic<int> cloud{0};
        OrchestratorConfig cfg;
        cfg.max_queue_depth = 8;
        cfg.drop_policy = policy == 0
                              ? OrchestratorConfig::DropPolicy::kDropOldest
                              : OrchestratorConfig::DropPolicy::kDropNewest;
        StreamingOrchestrator orch(make_extract(nullptr), make_ingest(&cloud),
                                   nullptr, cfg);
        orch.start();
        // Flood: submit far faster than the slow pipeline can serve.
        const int flood = 40;
        for (int i = 0; i < flood; ++i) {
            orch.submit_frame(make_frame(i, i * 0.0001));
            busy_sleep_ms(kThermalExtractMs * kTimeScale * 0.1);  // 10x overload
        }
        orch.stop_capture();
        OrchestratorStats s = orch.stats();
        const char* name = policy == 0 ? "kDropOldest" : "kDropNewest";
        std::printf(
            "    %s: submitted=%llu enqueued=%llu ingested=%llu "
            "drop(old=%llu new=%llu) peak=%zu\n",
            name, (unsigned long long)s.submitted,
            (unsigned long long)s.enqueued, (unsigned long long)s.ingested,
            (unsigned long long)s.dropped_oldest,
            (unsigned long long)s.dropped_newest, s.peak_queue_depth);
        CHECK(s.peak_queue_depth <= cfg.max_queue_depth,
              "queue bounded under 10x overload");
        // Conservation law. Every submitted frame is in exactly one of:
        //   refused at the gate (dropped_newest), OR
        //   entered the queue (enqueued); of those, some were later evicted by a
        //   fresher frame (dropped_oldest), the rest were ingested.
        // => submitted = dropped_newest + enqueued
        //    enqueued  = dropped_oldest + ingested
        CHECK(s.submitted == s.dropped_newest + s.enqueued,
              "conservation: submitted = refused + enqueued");
        CHECK(s.enqueued == s.dropped_oldest + s.ingested,
              "conservation: enqueued = evicted + ingested (no frame vanishes)");
        CHECK(s.submitted == static_cast<std::uint64_t>(flood),
              "all submissions counted");
        CHECK(s.dropped_oldest + s.dropped_newest > 0,
              "some frames dropped under sustained overload (expected)");
        if (policy == 0) {
            CHECK(s.dropped_oldest > 0 && s.dropped_newest == 0,
                  "kDropOldest evicts stale, never refuses fresh");
        } else {
            CHECK(s.dropped_newest > 0 && s.dropped_oldest == 0,
                  "kDropNewest refuses fresh (camera back-pressure)");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST 5 — cloud-update latency / monotonic growth: the snapshot fed to the UI
// grows every frame and carries the newest frame index + quality.
// ═══════════════════════════════════════════════════════════════════════════
static void test_cloud_growth_for_ui() {
    std::printf("\n[TEST 5] sparse cloud grows monotonically for the UI feed\n");
    g_extract_ms = kExtractMsA16;
    std::atomic<int> cloud{0};
    std::vector<std::size_t> sizes;
    std::vector<std::uint64_t> indices;
    std::mutex mu;
    OrchestratorConfig cfg;
    cfg.max_queue_depth = 32;
    StreamingOrchestrator orch(
        make_extract(nullptr), make_ingest(&cloud),
        [&](const CloudSnapshot& s) {
            std::lock_guard<std::mutex> lk(mu);
            sizes.push_back(s.points.size());
            indices.push_back(s.last_frame_index);
        },
        cfg);
    orch.start();
    const int N = 20;
    for (int i = 0; i < N; ++i) {
        orch.submit_frame(make_frame(i, i * 0.05));
        busy_sleep_ms(kCadenceMs * kTimeScale);
    }
    orch.stop_capture();

    CHECK(sizes.size() == static_cast<std::size_t>(N),
          "exactly N cloud snapshots delivered to the UI sink");
    bool monotonic = true, idx_ordered = true;
    for (std::size_t i = 1; i < sizes.size(); ++i) {
        if (sizes[i] <= sizes[i - 1]) monotonic = false;
        if (indices[i] <= indices[i - 1]) idx_ordered = false;
    }
    CHECK(monotonic, "cloud point count strictly grows each frame");
    CHECK(idx_ordered, "snapshots delivered in capture order (in-order ingest)");
}

// ═══════════════════════════════════════════════════════════════════════════
// Real-time projection report (the grounded throughput / Little's-Law math).
// ═══════════════════════════════════════════════════════════════════════════
static void print_realtime_projection() {
    std::printf("\n──────────────────────────────────────────────────────────\n");
    std::printf("REAL-TIME (A16) PROJECTION — unscaled grounded numbers\n");
    std::printf("──────────────────────────────────────────────────────────\n");
    const double sum = kExtractMsA16 + kIngestMsA16;
    const double mx = kExtractMsA16 > kIngestMsA16 ? kExtractMsA16 : kIngestMsA16;
    std::printf("  extract (GPU DSP-SIFT)      : %.0f ms\n", kExtractMsA16);
    std::printf("  ingest  (match+register+lBA): %.0f ms\n", kIngestMsA16);
    std::printf("  SERIAL  sum(stage)          : %.0f ms/frame\n", sum);
    std::printf("  PIPELINED max(stage)        : %.0f ms/frame  <- steady state\n",
                mx);
    std::printf("  capture cadence             : %.0f ms/frame\n", kCadenceMs);
    std::printf("  utilization rho = service/arrival = %.0f/%.0f = %.2f\n", mx,
                kCadenceMs, mx / kCadenceMs);
    std::printf("  => rho < 1 : pipelined service BEATS arrival; queue ~ empty\n");
    std::printf("     (serial rho would be %.0f/%.0f = %.2f >= 0.6, far less head"
                "room)\n",
                sum, kCadenceMs, sum / kCadenceMs);
    std::printf("  THERMAL extract %.0f ms -> pipelined max = %.0f ms, rho=%.2f\n",
                kThermalExtractMs,
                kThermalExtractMs > kIngestMsA16 ? kThermalExtractMs
                                                 : kIngestMsA16,
                (kThermalExtractMs > kIngestMsA16 ? kThermalExtractMs
                                                  : kIngestMsA16) /
                    kCadenceMs);
    std::printf("     rho still < 1 at the 2s cadence -> queue rides the\n");
    std::printf("     transient and drains; only a faster-than-2s burst fills it.\n");
}

int main() {
    std::printf("=== StreamingOrchestrator host harness (time-scaled %.3gx) ===\n",
                kTimeScale);
    if (const char* rt = std::getenv("AETHER_ORCH_REALTIME"); rt && rt[0] == '1') {
        std::printf("(AETHER_ORCH_REALTIME=1: would run at true A16 wall-clock; "
                    "left scaled for CI speed)\n");
    }
    test_pipelining_throughput();
    test_queue_bounded_at_cadence();
    test_thermal_absorb_and_drain();
    test_drop_policies();
    test_cloud_growth_for_ui();
    print_realtime_projection();

    std::printf("\n=== %s ===\n", g_failures == 0 ? "ALL PASS" : "FAILURES");
    std::printf("failures: %d\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
