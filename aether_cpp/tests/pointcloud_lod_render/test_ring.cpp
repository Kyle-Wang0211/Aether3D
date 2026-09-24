// Host test for the plan-3b / B1 render thread (Flutter camera-plugin shape)
// behind pwlod_viewer.h, on Dawn's native backend with plain textures.
//
//   test_pointcloud_lod_render_ring <octree dir> <scratch dir>
//
// A producer thread keeps moving the camera (so the render thread always has
// work); the test's main thread plays the UI's copyPixelBuffer at 60 Hz: it
// calls pwlod_viewer_acquire_latest every 16 ms and keeps sampling the target
// it got until the next call (FlutterDarwinExternalTextureMetal keeps the last
// buffer it was handed). Frames are produced at target_frame_ms = 10 ms.
//
//   B1  normal run: acquire_latest p99 < 0.5 ms; every publish reconciles
//       (frame_number <= completed_frame_number when published); the target
//       the consumer held and the latest published target are never chosen
//       for rendering; frames keep coming (no stall).
//   B2  debug_render_sleep_ms = 50: acquire_latest p99 still < 0.5 ms (it never
//       waits for the render thread) AND the stall detector fires (the frame
//       number stops advancing for > 4 x target_frame_ms).
//   B3  debug_publish_before_done = 1: the reconciliation alarm fires
//       (published frame_number > completed_frame_number).
//   B5  a slow consumer (holds each target 35 ms, > 3 producer frames -- a
//       janking raster thread): the held target is still never written.
//   B4  negative control for B5: same slow consumer with the "not the
//       consumer's target" rule removed (SetIgnoreHeldExclusion) -- the probe
//       must catch a write into the held target. (A 60 Hz consumer cannot
//       trigger it: with 3 targets a plain rotation only reaches the held one
//       after 3 frames.)
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"
#include "aether/pointcloud_lod_render/viewer_probe.h"
#include "judges.h"

using namespace pwlod_judges;
using Clock = std::chrono::steady_clock;

namespace {

double Ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

struct Published {
  std::mutex mu;
  uint64_t count = 0, ahead = 0, maxFrame = 0;
};
void OnFrame(void* user, uint32_t, const pwlod_frame_stats* st) {
  Published* p = static_cast<Published*>(user);
  std::lock_guard<std::mutex> lk(p->mu);
  p->count++;
  if (st->frame_number > st->completed_frame_number) p->ahead++;
  p->maxFrame = std::max(p->maxFrame, st->frame_number);
}

struct RunResult {
  double acquire_p99_ms = 0, acquire_max_ms = 0;
  double max_stall_ms = 0;        // longest time the acquired frame number did not advance
  uint64_t acquires = 0, frames_seen = 0, published = 0, ahead = 0;
  plr::ViewerProbe probe;
};

RunResult Run(pwlod_viewer* v, const Traj& T, uint32_t W, uint32_t H, double seconds,
              int64_t hold_us = 16667) {
  RunResult rr;
  Published pub;
  const plr::ViewerProbe p0 = plr::GetViewerProbe(v);
  std::atomic<bool> stop{false};
  // producer: the orbit pose moves every 2 ms
  std::thread producer([&] {
    int k = 0;
    while (!stop.load()) {
      const char* seg = "";
      const Pose ps = PoseAt(T, 0.48 + 0.25 * double(k % 1000) / 1000.0, &seg);
      double zn, zf; NearFar(T, ps, &zn, &zf);
      const plr::CamState cs = MakeCam(ps, (int)W, (int)H, zn, zf);
      pwlod_camera c{};
      std::memcpy(c.view_proj_row_major, cs.vp, sizeof c.view_proj_row_major);
      c.eye_world[0] = ps.eye.x; c.eye_world[1] = ps.eye.y; c.eye_world[2] = ps.eye.z;
      c.projection = PWLOD_PROJ_PERSPECTIVE;
      c.fov_y_degrees = 60.0;
      c.viewport_width_px = W; c.viewport_height_px = H;
      pwlod_viewer_set_camera(v, &c);
      ++k;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  });
  if (pwlod_viewer_start(v, &OnFrame, &pub) != PWLOD_OK) { stop = true; producer.join(); return rr; }
  // consumer
  std::vector<double> lat;
  uint64_t lastFrame = 0;
  Clock::time_point lastAdvance = Clock::now();
  Clock::time_point lastTake = Clock::now() - std::chrono::hours(1);
  const Clock::time_point end = Clock::now() + std::chrono::milliseconds((int64_t)(seconds * 1000));
  bool first = true;
  while (Clock::now() < end) {
    // 60 Hz consumer: the taken target stays held until the next call.
    if (Clock::now() - lastTake >= std::chrono::microseconds(hold_us)) {
      uint32_t idx = 0; uint64_t fn = 0;
      const Clock::time_point a = Clock::now();
      const pwlod_status s = pwlod_viewer_acquire_latest(v, &idx, &fn);
      const Clock::time_point b = Clock::now();
      if (s == PWLOD_OK) {
        lat.push_back(Ms(b - a));
        lastTake = b;
        if (fn != lastFrame) {
          if (!first) rr.max_stall_ms = std::max(rr.max_stall_ms, Ms(b - lastAdvance));
          first = false;
          lastFrame = fn;
          lastAdvance = b;
          rr.frames_seen++;
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  if (!first) rr.max_stall_ms = std::max(rr.max_stall_ms, Ms(Clock::now() - lastAdvance));
  stop = true;
  producer.join();
  pwlod_viewer_stop(v);
  std::sort(lat.begin(), lat.end());
  rr.acquires = lat.size();
  if (!lat.empty()) {
    rr.acquire_p99_ms = lat[std::min(lat.size() - 1, (size_t)std::ceil(0.99 * double(lat.size())) - 1)];
    rr.acquire_max_ms = lat.back();
  }
  {
    std::lock_guard<std::mutex> lk(pub.mu);
    rr.published = pub.count;
    rr.ahead = pub.ahead;
  }
  const plr::ViewerProbe p1 = plr::GetViewerProbe(v);
  rr.probe.frames_rendered = p1.frames_rendered - p0.frames_rendered;
  rr.probe.held_overwrites = p1.held_overwrites - p0.held_overwrites;
  rr.probe.latest_overwrites = p1.latest_overwrites - p0.latest_overwrites;
  rr.probe.published_ahead = p1.published_ahead - p0.published_ahead;
  return rr;
}

std::string Describe(const RunResult& r) {
  return Fmt("acquire p99 %.4f ms (max %.3f, n=%llu), rendered %llu, published %llu, frames seen %llu, "
             "max stall %.1f ms, ahead %llu, held-overwrites %llu, latest-overwrites %llu",
             r.acquire_p99_ms, r.acquire_max_ms, (unsigned long long)r.acquires,
             (unsigned long long)r.probe.frames_rendered, (unsigned long long)r.published,
             (unsigned long long)r.frames_seen, r.max_stall_ms, (unsigned long long)r.ahead,
             (unsigned long long)r.probe.held_overwrites, (unsigned long long)r.probe.latest_overwrites);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <octree dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  Report rep;

  pwlod_gpu gpu{};
  if (pwlod_gpu_create(nullptr, 0, &gpu) != PWLOD_OK) { std::fprintf(stderr, "gpu\n"); return 1; }
  plr::GpuCtx g;
  g.instance = gpu.instance; g.adapter = gpu.adapter; g.device = gpu.device; g.queue = gpu.queue;
  pwlod_viewer* v = nullptr;
  pwlod_viewer_create(&gpu, &v);
  if (pwlod_viewer_load_octree(v, dir.c_str()) != PWLOD_OK) { std::fprintf(stderr, "load\n"); return 1; }
  const lod::Octree oct = lod::loadOctree(dir);
  Traj T;
  ContentFrame(oct, &T.c, &T.R);

  const uint32_t W = 590, H = 1278;
  OwnedTarget t[3] = {MakeTarget(g, W, H), MakeTarget(g, W, H), MakeTarget(g, W, H)};
  const pwlod_target ts[3] = {{t[0].tex, nullptr}, {t[1].tex, nullptr}, {t[2].tex, nullptr}};
  if (pwlod_viewer_set_targets(v, ts, 3, WGPUTextureFormat_RGBA8Unorm, W, H) != PWLOD_OK) {
    std::fprintf(stderr, "targets\n");
    return 1;
  }
  pwlod_params base;
  pwlod_params_default(&base);
  base.target_frame_ms = 10.0;
  const double stallMs = 4.0 * base.target_frame_ms;

  // B1
  pwlod_viewer_set_params(v, &base);
  const RunResult a = Run(v, T, W, H, 1.5);
  std::printf("normal:        %s\n", Describe(a).c_str());
  rep.check("B1 acquire_latest p99 < 0.5 ms", a.acquires > 0 && a.acquire_p99_ms < 0.5,
            Fmt("p99 %.4f ms over %llu calls", a.acquire_p99_ms, (unsigned long long)a.acquires));
  rep.check("B1 every publish after its GPU work completed", a.published > 0 && a.ahead == 0 &&
                a.probe.published_ahead == 0,
            Fmt("%llu publishes, %llu ahead of completion", (unsigned long long)a.published,
                (unsigned long long)a.ahead));
  rep.check("B1 held / latest target never chosen for rendering",
            a.probe.frames_rendered > 0 && a.probe.held_overwrites == 0 && a.probe.latest_overwrites == 0,
            Fmt("%llu frames, held-overwrites %llu, latest-overwrites %llu",
                (unsigned long long)a.probe.frames_rendered, (unsigned long long)a.probe.held_overwrites,
                (unsigned long long)a.probe.latest_overwrites));
  rep.check("B1 no stall while the camera moves", a.frames_seen > 10 && a.max_stall_ms <= stallMs,
            Fmt("max stall %.1f ms (threshold %.0f), %llu new frames seen", a.max_stall_ms, stallMs,
                (unsigned long long)a.frames_seen));

  // B2
  pwlod_params slow = base;
  slow.debug_render_sleep_ms = 50;
  pwlod_viewer_set_params(v, &slow);
  const RunResult b = Run(v, T, W, H, 1.5);
  std::printf("sleep 50 ms:   %s\n", Describe(b).c_str());
  rep.check("B2 NEG render thread sleeps 50 ms: acquire p99 still < 0.5 ms",
            b.acquires > 0 && b.acquire_p99_ms < 0.5, Fmt("p99 %.4f ms", b.acquire_p99_ms));
  rep.check("B2 NEG render thread sleeps 50 ms: stall detected", b.max_stall_ms > stallMs,
            Fmt("max stall %.1f ms > %.0f", b.max_stall_ms, stallMs));

  // B3
  pwlod_params early = base;
  early.debug_publish_before_done = 1;
  pwlod_viewer_set_params(v, &early);
  const RunResult c = Run(v, T, W, H, 1.0);
  std::printf("publish early: %s\n", Describe(c).c_str());
  rep.check("B3 NEG publish before GPU completion: reconciliation alarms",
            c.ahead > 0 && c.probe.published_ahead > 0,
            Fmt("%llu of %llu publishes ahead of completion", (unsigned long long)c.ahead,
                (unsigned long long)c.published));

  // B5
  pwlod_viewer_set_params(v, &base);
  const RunResult e = Run(v, T, W, H, 1.0, 35000);
  std::printf("slow consumer: %s\n", Describe(e).c_str());
  rep.check("B5 slow consumer (35 ms hold): held target never written",
            e.probe.frames_rendered > 0 && e.probe.held_overwrites == 0 && e.probe.latest_overwrites == 0,
            Fmt("%llu frames, held-overwrites %llu", (unsigned long long)e.probe.frames_rendered,
                (unsigned long long)e.probe.held_overwrites));

  // B4
  plr::SetIgnoreHeldExclusion(v, true);
  const RunResult d = Run(v, T, W, H, 1.0, 35000);
  plr::SetIgnoreHeldExclusion(v, false);
  std::printf("no exclusion:  %s\n", Describe(d).c_str());
  rep.check("B4 NEG exclusion rule removed: probe catches a held-target write",
            d.probe.held_overwrites > 0,
            Fmt("%llu writes into the held target in %llu frames", (unsigned long long)d.probe.held_overwrites,
                (unsigned long long)d.probe.frames_rendered));

  pwlod_viewer_destroy(v);
  for (auto& x : t) ReleaseTarget(&x);
  if (plr::GpuErrorCount() != 0) rep.check("no WebGPU errors", false, plr::GpuErrorLog());
  pwlod_gpu_destroy(&gpu);
  return rep.finish();
}
