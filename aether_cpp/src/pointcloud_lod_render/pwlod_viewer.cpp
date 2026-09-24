// pwlod_viewer.h implementation: the frozen C ABI over the moved LOD render
// pass (lod_render.cpp), plus the plan-3b / B1 render thread.
//
// Nothing algorithmic is written here. What is here is interface shape and
// thread glue, which have no upstream to copy, so they copy the house and the
// official plugin instead:
//   * entry-point shape: include/aether/pocketworld/scene_iosurface_renderer.h
//     (opaque handle, create / load / set / render / destroy);
//   * the frame hand-off: Flutter's camera plugin, flutter/packages @
//     fbc80a62002 packages/camera/camera_avfoundation/ios/.../DefaultCamera.swift
//       :28-31      one lock ("pixelBufferSynchronizationQueue") guards the
//                   latest frame; the producer never works while holding it
//       :1283-1296  producer: frame ready -> store as latest under that lock ->
//                   notify (onFrameAvailable)
//       :1518-1529  consumer (copyPixelBuffer): take the latest under that
//                   lock, never wait for anything else
//     and CameraPlugin.swift :297-303 (the notification is posted to the
//     platform thread; that part lives in each shell's pwlod_frame_ready_fn).
//   * "published only after its GPU work completed": wgpuQueueOnSubmittedWorkDone
//     (Dawn), the only completion signal webgpu.h has.
// Deviations from those shapes are R-numbers in src/pointcloud_lod_render/DEVIATIONS.md.
//
// Platform: C++20 + webgpu.h only. The render thread is a std::thread.
#include "aether/pointcloud_lod_render/pwlod_viewer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>

#include "aether/pointcloud_lod/octree.h"
#include "aether/pointcloud_lod/select.h"
#include "aether/pointcloud_lod_render/lod_render.h"
#include "aether/pointcloud_lod_render/viewer_look.h"
#include "aether/pointcloud_lod_render/viewer_probe.h"

#ifndef PWLOD_ENGINE_SHA8
#define PWLOD_ENGINE_SHA8 "unknown"
#endif
#define PWLOD_STR2(x) #x
#define PWLOD_STR(x) PWLOD_STR2(x)

namespace plr = aether::pointcloud_lod_render;
namespace lod = aether::pointcloud_lod;

namespace {

using Clock = std::chrono::steady_clock;

double NowMs() {
  return std::chrono::duration<double, std::milli>(Clock::now().time_since_epoch()).count();
}

bool Finite(double v) { return std::isfinite(v); }

bool ValidFormat(WGPUTextureFormat f) {
  return f == WGPUTextureFormat_RGBA8Unorm || f == WGPUTextureFormat_BGRA8Unorm;
}

// v3: a flat point set as the caller handed it (copied in set_points).
struct FlatData {
  std::vector<float> xyz;
  std::vector<uint8_t> rgb;   // empty when not coloured
  std::vector<uint8_t> vis;   // empty = every point visible
  uint64_t count = 0;
  bool colored = true;
};

enum SourceKind { kSourceNone = 0, kSourceFlat = 1, kSourceOctree = 2 };   // = pwlod_frame_stats.source

// Render state: owned by the render thread while it runs, by the caller while
// stopped (render_once, destroy).
struct RenderState {
  std::shared_ptr<const lod::Octree> oct;
  plr::Lod L;
  std::shared_ptr<const FlatData> flat_data;
  plr::FlatSet flat;
  int source = kSourceNone;
  plr::Pipe P;
  bool pipe_ok = false;
  lod::QualityController qc;
  pwlod_params params{};
  pwlod_camera cam{};
  plr::ViewerStyle style;
  uint64_t params_gen = 0, camera_gen = 0, source_gen = 0, style_gen = 0;   // applied
  size_t applied_cache = 0;
  int applied_async = -1;
  double applied_target_ms = -1;
  // the colour key the GPU copies were baked with (A11)
  int baked_viewer = -1;       // 1 = the viewer's display colours, 0 = raw rgb
  plr::ViewerStyle baked_style;
};

plr::ViewerStyle ToStyle(const pwlod_style& s) {
  plr::ViewerStyle v;
  v.point_size = s.point_size;
  v.sprite_px = s.sprite_px;
  v.disc_radius = s.disc_radius_px_at_scale1;
  v.max_sprite_scale = s.max_sprite_scale;
  v.tone = (int)s.tone;
  v.exposure = s.exposure;
  v.uncolored_min_y = s.uncolored_min_y;
  v.uncolored_inv_y_span = s.uncolored_inv_y_span;
  v.selection_mode = (int)s.selection_mode;
  for (int k = 0; k < 3; ++k) {
    v.selection_center[k] = s.selection_center[k];
    v.selection_size[k] = s.selection_size[k];
  }
  for (int k = 0; k < 9; ++k) v.selection_rot[k] = s.selection_rot_row_major[k];
  v.selection_out_argb = s.selection_out_argb;
  return v;
}

void ReleaseLodAll(plr::Lod* L) {
  L->aloader.reset();   // joins its workers first
  L->loader.reset();
  for (auto& kv : L->gpu) plr::ReleaseNode(kv.second);
  L->gpu.clear();
  L->gpu_bytes = 0;
}

size_t CacheBytesFor(const pwlod_params& p) {
  const uint64_t floor = 15ull * (uint64_t)p.point_budget;   // pwlod_viewer.h: default and minimum
  return (size_t)std::max<uint64_t>(p.cache_bytes, floor);
}

}  // namespace

struct pwlod_viewer {
  plr::GpuCtx g;   // handles borrowed from pwlod_gpu (not owned)

  // ---- state set by API callers, guarded by mu ----
  std::mutex mu;
  std::condition_variable cv;
  pwlod_params params{};
  uint64_t params_gen = 1;
  pwlod_camera camera{};
  uint64_t camera_gen = 0;     // 0 = never set
  pwlod_style style{};
  uint64_t style_gen = 1;
  // v3: the current source is whichever of set_points / load_octree came last
  int pending_kind = kSourceNone;
  std::shared_ptr<const lod::Octree> pending_oct;
  std::string pending_bin;
  std::shared_ptr<const FlatData> pending_flat;
  uint64_t source_gen = 0;     // 0 = nothing loaded
  bool stop_req = false;

  // ---- ring, guarded by ring_mu (DefaultCamera.swift:28-31's one lock) ----
  std::mutex ring_mu;
  pwlod_target targets[PWLOD_TARGET_COUNT]{};
  WGPUTextureView views[PWLOD_TARGET_COUNT]{};
  WGPUTextureFormat format = WGPUTextureFormat_Undefined;
  uint32_t tw = 0, th = 0;
  bool have_targets = false;
  int latest = -1;
  uint64_t latest_frame = 0;
  pwlod_frame_stats latest_stats{};
  int held = -1;
  int last_written = -1;

  // ---- probes (viewer_probe.h) ----
  std::atomic<uint64_t> frames_rendered{0}, held_overwrites{0}, latest_overwrites{0},
      published_ahead{0};
  std::atomic<bool> ignore_held{false};
  std::atomic<bool> debug_fill_max_spacing{false};

  // ---- render thread ----
  std::thread th_;
  bool running = false;        // caller-side only
  pwlod_frame_ready_fn cb = nullptr;
  void* user = nullptr;

  // ---- frame counters ----
  std::atomic<uint64_t> frame_counter{0};
  std::atomic<uint64_t> completed{0};

  RenderState rs;
};

namespace {

void Publish(pwlod_viewer* v, int idx, const pwlod_frame_stats& st) {
  {
    std::lock_guard<std::mutex> lk(v->ring_mu);
    v->latest = idx;
    v->latest_frame = st.frame_number;
    v->latest_stats = st;
  }
  if (st.frame_number > st.completed_frame_number) v->published_ahead.fetch_add(1);
  if (v->cb) v->cb(v->user, (uint32_t)idx, &st);
}

// Everything the submit hook needs (R3): the completion callback's own path,
// and -- only with debug_publish_before_done -- the early publish.
struct HookCtx {
  pwlod_viewer* v = nullptr;
  uint64_t frame_number = 0;
  int ring_index = -1;
  bool publish_early = false;
  double t_frame0 = 0;
  double t_submit = 0;
  double t_done = -1;
  pwlod_frame_stats* early = nullptr;   // filled if published early
  const lod::Octree* oct = nullptr;
  bool fill_max_spacing = false;
};

void OnWorkDone(WGPUQueueWorkDoneStatus status, WGPUStringView, void* u1, void*) {
  HookCtx* h = static_cast<HookCtx*>(u1);
  if (status != WGPUQueueWorkDoneStatus_Success) return;
  h->t_done = NowMs();
  // completed_frame_number: the highest frame whose OnSubmittedWorkDone fired.
  uint64_t cur = h->v->completed.load();
  while (cur < h->frame_number && !h->v->completed.compare_exchange_weak(cur, h->frame_number)) {
  }
}

// v2 lowest_spacing (A8, resolved per Potree): the frame's Selection::lowestSpacing
// as selectVisible computed it -- min over every node popped from the queue
// (Potree_update_visibility.js:276-280). It does not depend on what was drawn.
// 0 when nothing was popped (+infinity; the header's "<= 0 if the queue was empty").
// fill_max is the test-only negative control (viewer_probe.h): the root's
// spacing, i.e. the LARGEST spacing in the tree.
double LowestSpacingFor(const plr::FrameRec& fr, const lod::Octree* oct, bool fill_max) {
  if (fill_max && oct && !oct->nodes.empty()) return oct->nodes[0].spacing;
  if (!std::isfinite(fr.lowest_spacing)) return 0.0;
  return fr.lowest_spacing;
}

void FillStats(const plr::FrameRec& fr, uint64_t frame_number, pwlod_frame_stats* st) {
  st->frame_number = frame_number;
  st->points_drawn = fr.pts_drawn;
  st->nodes_drawn = fr.nodes_drawn;
  st->nodes_loading = fr.in_flight;
  st->uploads_this_frame = fr.uploads;
  st->dropped_for_cache = fr.dropped;
  st->cpu_ms = fr.submit_ms;
  st->gpu_ms = -1;
}

void SubmitHookFn(void* ctx, const plr::FrameRec& fr) {
  HookCtx* h = static_cast<HookCtx*>(ctx);
  pwlod_viewer* v = h->v;
  h->t_submit = NowMs();
  WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
  wi.mode = WGPUCallbackMode_WaitAnyOnly;   // fires only inside our WaitAny below
  wi.callback = OnWorkDone;
  wi.userdata1 = h;
  const WGPUFuture f = wgpuQueueOnSubmittedWorkDone(v->g.queue, wi);
  if (h->publish_early && h->ring_index >= 0 && h->early) {
    // Negative control (debug_publish_before_done): publish at submit.
    FillStats(fr, h->frame_number, h->early);
    h->early->completed_frame_number = v->completed.load();
    h->early->min_node_pixel_size = fr.px;
    h->early->lowest_spacing = LowestSpacingFor(fr, h->oct, h->fill_max_spacing);
    Publish(v, h->ring_index, *h->early);
  }
  plr::WaitFuture(v->g, f);   // render thread (or render_once's caller) only
}

// The frame body shared by the render thread and pwlod_viewer_render_once.
// ring_index < 0: render_once (nothing is published).
pwlod_status FrameBody(pwlod_viewer* v, const plr::Target& rt, WGPUTextureFormat fmt, uint32_t w,
                       uint32_t h, int ring_index, pwlod_frame_stats* out, bool* more_work) {
  RenderState& rs = v->rs;
  *more_work = false;
  // 1. snapshot what callers set
  int new_kind = kSourceNone;
  std::shared_ptr<const lod::Octree> new_oct;
  std::string new_bin;
  std::shared_ptr<const FlatData> new_flat;
  uint64_t pgen, cgen, sgen, stgen;
  pwlod_params params;
  pwlod_camera cam;
  pwlod_style style;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    pgen = v->params_gen; cgen = v->camera_gen; sgen = v->source_gen; stgen = v->style_gen;
    params = v->params; cam = v->camera; style = v->style;
    if (sgen != rs.source_gen) {
      new_kind = v->pending_kind;
      new_oct = v->pending_oct; new_bin = v->pending_bin; new_flat = v->pending_flat;
    }
  }
  if (sgen == 0 || cgen == 0) return PWLOD_ERR_STATE;          // no source / no camera yet
  if (cam.viewport_width_px != w || cam.viewport_height_px != h) return PWLOD_ERR_ARG;

  // 2. pipeline for this target format / size (R17: GPU copies stay valid)
  {
    std::string err;
    if (!rs.pipe_ok) rs.pipe_ok = plr::MakePipe(v->g, &rs.P, fmt, w, h, 0, &err);
    else if (!plr::RetargetPipe(v->g, &rs.P, fmt, w, h, &err)) rs.pipe_ok = false;
    if (!rs.pipe_ok) {
      std::fprintf(stderr, "pwlod: %s\n", err.c_str());
      plr::ReleasePipe(&rs.P);
      return PWLOD_ERR_GPU;
    }
  }

  // 3. apply a source switch at this frame boundary (camera and style untouched)
  bool reset_lod = false, upload_flat = false;
  if (sgen != rs.source_gen) {
    ReleaseLodAll(&rs.L);
    plr::ReleaseFlat(&rs.flat);
    rs.oct.reset();
    rs.flat_data.reset();
    rs.L.oct = nullptr;
    if (new_kind == kSourceOctree) {
      rs.oct = new_oct;
      rs.L.oct = rs.oct.get();
      rs.L.bin_path = new_bin;
      reset_lod = true;
    } else {
      rs.flat_data = new_flat;
      upload_flat = true;
    }
    rs.source = new_kind;
    rs.source_gen = sgen;
  }
  // 4. apply params and style
  const size_t cache = CacheBytesFor(params);
  if (pgen != rs.params_gen) {
    if (cache != rs.applied_cache || params.async_loading != rs.applied_async) reset_lod = true;
    if (params.target_frame_ms != rs.applied_target_ms) {
      lod::QualityController::Config qcfg;
      qcfg.targetFrameMs = params.target_frame_ms;
      rs.qc = lod::QualityController(qcfg);
      rs.applied_target_ms = params.target_frame_ms;
    }
    rs.params = params;
    rs.params_gen = pgen;
  }
  if (stgen != rs.style_gen) {
    rs.style = ToStyle(style);
    rs.style_gen = stgen;
  }
  // The point-size rule actually used (A9: a flat set has no octree, so
  // ADAPTIVE falls back to the viewer's own rule; FIXED stays FIXED).
  int psize = params.point_size_mode == PWLOD_PSIZE_FIXED ? 0
            : params.point_size_mode == PWLOD_PSIZE_ADAPTIVE ? 1 : 2;
  if (rs.source == kSourceFlat && psize == 1) psize = 2;
  // A11: colours are baked into the GPU copies (the painter caches them per
  // (cloud, exposure, tone), :1197-1213); a new colour key re-bakes.
  const int want_viewer = psize == 2 ? 1 : 0;
  if (want_viewer != rs.baked_viewer ||
      (want_viewer == 1 && plr::ColourKeyDiffers(rs.style, rs.baked_style))) {
    if (rs.source == kSourceOctree) reset_lod = true;
    if (rs.source == kSourceFlat) upload_flat = true;
    rs.baked_viewer = want_viewer;
    rs.baked_style = rs.style;
  }
  if (reset_lod && rs.source == kSourceOctree) {
    ReleaseLodAll(&rs.L);
    plr::ResetLod(&rs.L, cache, params.async_loading ? plr::LoadMode::Async : plr::LoadMode::Sync);
    rs.applied_cache = cache;
    rs.applied_async = params.async_loading;
  }
  int flat_uploads = 0;
  if (upload_flat && rs.source == kSourceFlat && rs.flat_data) {
    const FlatData& fd = *rs.flat_data;
    plr::UploadFlat(v->g, rs.P, fd.xyz.data(), fd.rgb.empty() ? nullptr : fd.rgb.data(),
                    fd.vis.empty() ? nullptr : fd.vis.data(), fd.count, fd.colored,
                    want_viewer ? &rs.style : nullptr, &rs.flat);
    flat_uploads = (int)rs.flat.chunks.size();
  }
  rs.cam = cam;
  rs.camera_gen = cgen;

  // 5. v3 camera -> CamState (the product's CloudProjection; D19, R16)
  plr::CamState cs{};
  cs.cam.position = lod::Vec3{cam.eye_world[0], cam.eye_world[1], cam.eye_world[2]};
  std::memcpy(cs.cam.viewProj, cam.view_proj_row_major, sizeof cs.cam.viewProj);
  std::memcpy(cs.vp, cam.view_proj_row_major, sizeof cs.vp);
  cs.cam.screenHeightPx = (int)cam.viewport_height_px;
  cs.cam.screenWidthPx = (int)cam.viewport_width_px;
  cs.cam.cloudProjection = true;
  cs.cam.focalPx = cam.focal_px;
  cs.cam.orbitDistance = cam.orbit_distance;
  cs.cam.orthoMix = cam.ortho_mix;
  cs.cam.fovYDegrees = 2.0 * std::atan(0.5 * double(cam.viewport_height_px) / cam.focal_px) * 180.0 /
                       3.14159265358979323846;   // informational; D19 uses focalPx
  cs.cam_dist = 1.0;   // only the bench's production formula reads it (R7)

  plr::DrawParams dp;
  if (rs.oct) {
    dp.octree_size = rs.oct->nodes[0].box.size().x;    // PointCloudOctree.js:318
    dp.octree_spacing = rs.oct->meta.spacing;           // PointCloudOctree.js:315
  }
  if (psize == 0) {
    // R7: Potree PointSizeType.FIXED, pointcloud.vs:680-681 + :699-700 with
    // PointCloudMaterial.js:32-34 (size 1, minSize 2) -> 2 px diameter -> r = 1 (P4).
    dp.r_min = 1.0;
    dp.r_max = 1.0;
  }
  for (int i = 0; i < 4; ++i) dp.clear_rgba[i] = params.background_rgba[i];
  dp.viewer = want_viewer ? &rs.style : nullptr;

  lod::SelectParams sp;
  sp.pointBudget = params.point_budget;
  sp.minimumNodePixelSize = rs.qc.pixelSize();

  plr::DrawOpts opt;
  opt.psize_mode = psize;

  // 6. one frame, same code path for the ring and render_once
  const uint64_t frame_number = v->frame_counter.fetch_add(1) + 1;
  pwlod_frame_stats early{};
  early.source = rs.source;
  HookCtx hc;
  hc.v = v;
  hc.frame_number = frame_number;
  hc.ring_index = ring_index;
  hc.publish_early = params.debug_publish_before_done != 0;
  hc.early = &early;
  hc.oct = rs.oct.get();
  hc.fill_max_spacing = v->debug_fill_max_spacing.load();
  hc.t_frame0 = NowMs();
  plr::SubmitHook hook;
  hook.fn = &SubmitHookFn;
  hook.ctx = &hc;
  const double px_before = rs.qc.pixelSize();
  plr::FrameRec fr;
  if (rs.source == kSourceOctree) {
    fr = plr::LodFrame(v->g, &rs.L, &rs.P, rt, cs, sp, dp, -1, 0, opt, hook);
    if (fr.access_failed) return PWLOD_ERR_GPU;
    // The bench fed the controller the frame's measured wall time (fr.wall).
    rs.qc.onFrame(fr.wall);
  } else {
    // A10: a flat set is drawn whole; the controller is not fed (no px to choose).
    fr = plr::FlatFrame(v->g, rs.flat, &rs.P, rt, cs, dp, opt, hook);
    if (fr.access_failed) return PWLOD_ERR_GPU;
    fr.uploads = flat_uploads;
  }

  pwlod_frame_stats st{};
  FillStats(fr, frame_number, &st);
  st.completed_frame_number = v->completed.load();
  st.min_node_pixel_size = rs.qc.pixelSize();
  st.gpu_ms = hc.t_done >= 0 ? hc.t_done - hc.t_submit : -1.0;
  st.lowest_spacing = LowestSpacingFor(fr, rs.oct.get(), hc.fill_max_spacing);
  st.source = rs.source;
  if (out) *out = st;

  // Something may still change without a new input: loads in flight or
  // queued, nodes promoted this frame, or the controller still moving.
  if (rs.source == kSourceOctree)
    *more_work = fr.in_flight > 0 || fr.pending_nodes > 0 || fr.uploads > 0 ||
                 rs.qc.pixelSize() != px_before;

  if (ring_index >= 0 && !hc.publish_early) Publish(v, ring_index, st);
  if (plr::GpuDeviceLost(v->g.device)) return PWLOD_ERR_GPU;
  return PWLOD_OK;
}

int ChooseTarget(pwlod_viewer* v) {
  std::lock_guard<std::mutex> lk(v->ring_mu);
  const bool ignore_held = v->ignore_held.load();
  int chosen = -1;
  for (int k = 1; k <= PWLOD_TARGET_COUNT && chosen < 0; ++k) {
    const int c = (v->last_written + k + PWLOD_TARGET_COUNT) % PWLOD_TARGET_COUNT;
    if (c == v->latest) continue;
    if (!ignore_held && c == v->held) continue;
    chosen = c;
  }
  if (chosen < 0) chosen = 0;   // unreachable with 3 targets and 2 exclusions
  if (chosen == v->held) v->held_overwrites.fetch_add(1);
  if (chosen == v->latest) v->latest_overwrites.fetch_add(1);
  v->last_written = chosen;
  return chosen;
}

// Input generations the render loop has already rendered (or tried to render)
// with. Kept apart from RenderState's "applied" counters so that a frame that
// could not run (no octree / camera yet, viewport mismatch) does not make the
// loop spin on the same unchanged inputs.
struct SeenGens {
  uint64_t p = 0, c = 0, o = 0, st = 0;
  bool differs(const pwlod_viewer* v) const {   // caller holds v->mu
    return v->params_gen != p || v->camera_gen != c || v->source_gen != o || v->style_gen != st;
  }
  void take(const pwlod_viewer* v) {
    p = v->params_gen; c = v->camera_gen; o = v->source_gen; st = v->style_gen;
  }
};

void RenderLoop(pwlod_viewer* v) {
  bool more = true;
  SeenGens seen;
  Clock::time_point last_start = Clock::now() - std::chrono::hours(1);
  for (;;) {
    double target_ms;
    int sleep_ms;
    {
      std::unique_lock<std::mutex> lk(v->mu);
      v->cv.wait(lk, [&] { return v->stop_req || more || seen.differs(v); });
      if (v->stop_req) break;
      // at most once per target_frame_ms
      target_ms = v->params.target_frame_ms;
      const auto next = last_start + std::chrono::microseconds((int64_t)(target_ms * 1000.0));
      v->cv.wait_until(lk, next, [&] { return v->stop_req; });
      if (v->stop_req) break;
      sleep_ms = v->params.debug_render_sleep_ms;
      seen.take(v);   // FrameBody snapshots these (or newer) inputs next
    }
    last_start = Clock::now();
    const int idx = ChooseTarget(v);
    plr::Target rt;
    rt.texture = v->targets[idx].texture;
    rt.view = v->views[idx];
    rt.memory = v->targets[idx].memory;
    bool more_work = false;
    const pwlod_status s = FrameBody(v, rt, v->format, v->tw, v->th, idx, nullptr, &more_work);
    if (s == PWLOD_OK) v->frames_rendered.fetch_add(1);
    more = (s == PWLOD_OK) && more_work;
    if (s == PWLOD_ERR_GPU) {
      std::unique_lock<std::mutex> lk(v->mu);   // device lost / pipeline failure: wait for stop
      v->cv.wait(lk, [&] { return v->stop_req; });
      break;
    }
    if (sleep_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
  }
}

bool ValidParams(const pwlod_params* p) {
  if (!p) return false;
  if (p->point_budget <= 0) return false;
  if (!Finite(p->target_frame_ms) || p->target_frame_ms <= 0) return false;
  if (p->point_size_mode != PWLOD_PSIZE_FIXED && p->point_size_mode != PWLOD_PSIZE_ADAPTIVE &&
      p->point_size_mode != PWLOD_PSIZE_VIEWER)
    return false;
  if (p->async_loading != 0 && p->async_loading != 1) return false;
  for (float c : p->background_rgba)
    if (!std::isfinite(c)) return false;
  if (p->debug_render_sleep_ms < 0 || p->debug_publish_before_done < 0 ||
      p->debug_publish_before_done > 1)
    return false;
  return true;
}

bool ValidCamera(const pwlod_camera* c) {
  if (!c) return false;
  for (double x : c->view_proj_row_major)
    if (!Finite(x)) return false;
  for (double x : c->eye_world)
    if (!Finite(x)) return false;
  if (c->viewport_width_px == 0 || c->viewport_height_px == 0) return false;
  // v3: CloudProjection (focal_px, orbit_distance, ortho_mix in [0, 1])
  if (!Finite(c->focal_px) || c->focal_px <= 0) return false;
  if (!Finite(c->orbit_distance) || c->orbit_distance <= 0) return false;
  if (!Finite(c->ortho_mix) || c->ortho_mix < 0 || c->ortho_mix > 1) return false;
  return true;
}

bool ValidStyle(const pwlod_style* s) {
  if (!s) return false;
  for (double x : {(double)s->point_size, (double)s->sprite_px, (double)s->disc_radius_px_at_scale1,
                   (double)s->max_sprite_scale, (double)s->exposure, (double)s->uncolored_min_y,
                   (double)s->uncolored_inv_y_span})
    if (!Finite(x)) return false;
  if (s->point_size <= 0 || s->sprite_px <= 0 || s->disc_radius_px_at_scale1 < 0 ||
      s->max_sprite_scale <= 0 || s->exposure < 0)
    return false;
  if ((int)s->tone < PWLOD_TONE_AGX || (int)s->tone > PWLOD_TONE_NONE) return false;
  if ((int)s->selection_mode < PWLOD_SEL_NONE || (int)s->selection_mode > PWLOD_SEL_CULL_OUTSIDE) return false;
  for (double x : s->selection_center)
    if (!Finite(x)) return false;
  for (double x : s->selection_size)
    if (!Finite(x) || x < 0) return false;
  for (double x : s->selection_rot_row_major)
    if (!Finite(x)) return false;
  return true;
}

bool TargetMatches(WGPUTexture t, WGPUTextureFormat f, uint32_t w, uint32_t h) {
  return t && wgpuTextureGetWidth(t) == w && wgpuTextureGetHeight(t) == h &&
         wgpuTextureGetFormat(t) == f &&
         (wgpuTextureGetUsage(t) & WGPUTextureUsage_RenderAttachment) &&
         (wgpuTextureGetUsage(t) & WGPUTextureUsage_CopySrc);
}

WGPUTextureView MakeView(WGPUTexture t) {
  WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
  return wgpuTextureCreateView(t, &vd);
}

}  // namespace

namespace aether::pointcloud_lod_render {

ViewerProbe GetViewerProbe(pwlod_viewer* v) {
  ViewerProbe p;
  if (!v) return p;
  p.frames_rendered = v->frames_rendered.load();
  p.held_overwrites = v->held_overwrites.load();
  p.latest_overwrites = v->latest_overwrites.load();
  p.published_ahead = v->published_ahead.load();
  return p;
}

void SetIgnoreHeldExclusion(pwlod_viewer* v, bool on) {
  if (v) v->ignore_held.store(on);
}

void SetFillMaxSpacing(pwlod_viewer* v, bool on) {
  if (v) v->debug_fill_max_spacing.store(on);
}

}  // namespace aether::pointcloud_lod_render

extern "C" {

pwlod_status pwlod_gpu_create(const WGPUFeatureName* required_features,
                              uint32_t required_feature_count, pwlod_gpu* out_gpu) {
  if (!out_gpu || (required_feature_count > 0 && !required_features)) return PWLOD_ERR_ARG;
  std::memset(out_gpu, 0, sizeof *out_gpu);
  plr::GpuCtx g;
  std::string err;
  if (!plr::CreateGpu(required_features, required_feature_count, &g, &err)) {
    std::fprintf(stderr, "pwlod_gpu_create: %s\n", err.c_str());
    return PWLOD_ERR_GPU;
  }
  out_gpu->instance = g.instance;
  out_gpu->adapter = g.adapter;
  out_gpu->device = g.device;
  out_gpu->queue = g.queue;
  out_gpu->backend = (WGPUBackendType)g.backend;
  return PWLOD_OK;
}

void pwlod_gpu_destroy(pwlod_gpu* gpu) {
  if (!gpu) return;
  plr::GpuCtx g;
  g.instance = gpu->instance;
  g.adapter = gpu->adapter;
  g.device = gpu->device;
  g.queue = gpu->queue;
  plr::ReleaseGpu(&g);
  std::memset(gpu, 0, sizeof *gpu);
}

void pwlod_params_default(pwlod_params* out) {
  if (!out) return;
  std::memset(out, 0, sizeof *out);
  out->point_budget = 3630000;               // (33.3 - 0.20) / 9.12 ms per M on A16
  out->target_frame_ms = 1000.0 / 30.0;      // QualityController::Config default
  out->point_size_mode = PWLOD_PSIZE_VIEWER;   // v3 default
  out->async_loading = 1;
  out->cache_bytes = 15ull * (uint64_t)out->point_budget;
  out->background_rgba[0] = 0.0f;
  out->background_rgba[1] = 0.0f;
  out->background_rgba[2] = 0.0f;
  out->background_rgba[3] = 1.0f;
  out->debug_render_sleep_ms = 0;
  out->debug_publish_before_done = 0;
}

pwlod_status pwlod_viewer_create(const pwlod_gpu* gpu, pwlod_viewer** out_viewer) {
  if (!gpu || !out_viewer || !gpu->instance || !gpu->device || !gpu->queue) return PWLOD_ERR_ARG;
  *out_viewer = nullptr;
  pwlod_viewer* v = new (std::nothrow) pwlod_viewer();
  if (!v) return PWLOD_ERR_NOMEM;
  v->g.instance = gpu->instance;
  v->g.adapter = gpu->adapter;
  v->g.device = gpu->device;
  v->g.queue = gpu->queue;
  v->g.has_timestamp = wgpuDeviceHasFeature(gpu->device, WGPUFeatureName_TimestampQuery);
  v->g.backend = (int)gpu->backend;
  pwlod_params_default(&v->params);
  pwlod_style_default(&v->style);
  *out_viewer = v;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_load_octree(pwlod_viewer* v, const char* octree_dir) {
  if (!v || !octree_dir) return PWLOD_ERR_ARG;
  const std::string dir(octree_dir);
  std::error_code ec;
  for (const char* f : {"/metadata.json", "/hierarchy.bin", "/octree.bin"})
    if (!std::filesystem::is_regular_file(dir + f, ec)) return PWLOD_ERR_IO;
  auto oct = std::make_shared<lod::Octree>(lod::loadOctree(dir));
  if (!oct->error.empty()) {
    std::fprintf(stderr, "pwlod_viewer_load_octree: %s\n", oct->error.c_str());
    return oct->error.rfind("cannot read", 0) == 0 ? PWLOD_ERR_IO : PWLOD_ERR_FORMAT;
  }
  if (oct->nodes.empty()) return PWLOD_ERR_FORMAT;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->pending_kind = kSourceOctree;
    v->pending_oct = oct;
    v->pending_bin = dir + "/octree.bin";
    v->pending_flat.reset();
    v->source_gen++;
  }
  v->cv.notify_all();
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_set_params(pwlod_viewer* v, const pwlod_params* params) {
  if (!v || !ValidParams(params)) return PWLOD_ERR_ARG;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->params = *params;
    v->params_gen++;
  }
  v->cv.notify_all();
  return PWLOD_OK;
}

void pwlod_style_default(pwlod_style* out) {
  if (!out) return;
  std::memset(out, 0, sizeof *out);
  out->point_size = 3.0f;              // SparseCloudView._pointSize (:382)
  out->sprite_px = 16.0f;              // the painter's 16x16 sprite (:826)
  out->disc_radius_px_at_scale1 = 7.0f;  // drawCircle(Offset(8, 8), 7) (:819-825)
  out->max_sprite_scale = 50.0f / 16.0f;  // kMaxPointSpriteScale (:235)
  out->tone = PWLOD_TONE_PBR_NEUTRAL;  // _tone = 2 (:384)
  out->exposure = 1.0f;                // _exposure (:383)
  out->uncolored_min_y = 0.0f;         // the painter's initial _minY / _invYSpan (:1262)
  out->uncolored_inv_y_span = 1.0f;
  out->selection_mode = PWLOD_SEL_NONE;
  for (int k = 0; k < 3; ++k) out->selection_size[k] = 1.0;
  out->selection_rot_row_major[0] = out->selection_rot_row_major[4] = out->selection_rot_row_major[8] = 1.0;
  out->selection_out_argb = 0xFFE05252u;   // kSelectionOutColor (:27)
}

pwlod_status pwlod_viewer_set_style(pwlod_viewer* v, const pwlod_style* style) {
  if (!v || !ValidStyle(style)) return PWLOD_ERR_ARG;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->style = *style;
    v->style_gen++;
  }
  v->cv.notify_all();
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_set_points(pwlod_viewer* v, const float* xyz, const uint8_t* rgb, uint64_t count,
                                     int32_t colored, const uint8_t* visibility) {
  if (!v || (count > 0 && !xyz) || (colored != 0 && colored != 1) || (colored == 1 && count > 0 && !rgb))
    return PWLOD_ERR_ARG;
  auto fd = std::make_shared<FlatData>();
  if (!fd) return PWLOD_ERR_NOMEM;
  fd->count = count;
  fd->colored = colored == 1;
  fd->xyz.assign(xyz, xyz + 3 * count);                     // copied before return
  if (rgb) fd->rgb.assign(rgb, rgb + 3 * count);
  if (visibility) fd->vis.assign(visibility, visibility + count);
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->pending_kind = kSourceFlat;
    v->pending_flat = std::move(fd);
    v->pending_oct.reset();
    v->source_gen++;
  }
  v->cv.notify_all();
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_set_camera(pwlod_viewer* v, const pwlod_camera* camera) {
  if (!v || !ValidCamera(camera)) return PWLOD_ERR_ARG;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->camera = *camera;
    v->camera_gen++;
  }
  v->cv.notify_all();
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_set_targets(pwlod_viewer* v, const pwlod_target* targets, uint32_t count,
                                      WGPUTextureFormat format, uint32_t width_px,
                                      uint32_t height_px) {
  if (!v || !targets || count != PWLOD_TARGET_COUNT || !ValidFormat(format) || width_px == 0 ||
      height_px == 0)
    return PWLOD_ERR_ARG;
  if (v->running) return PWLOD_ERR_STATE;
  for (uint32_t i = 0; i < count; ++i)
    if (!TargetMatches(targets[i].texture, format, width_px, height_px)) return PWLOD_ERR_ARG;
  std::lock_guard<std::mutex> lk(v->ring_mu);
  for (auto& vw : v->views)
    if (vw) { wgpuTextureViewRelease(vw); vw = nullptr; }
  for (uint32_t i = 0; i < count; ++i) {
    v->targets[i] = targets[i];
    v->views[i] = MakeView(targets[i].texture);
  }
  v->format = format;
  v->tw = width_px;
  v->th = height_px;
  v->have_targets = true;
  v->latest = -1;
  v->latest_frame = 0;
  v->held = -1;
  v->last_written = -1;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_start(pwlod_viewer* v, pwlod_frame_ready_fn on_frame, void* user) {
  if (!v) return PWLOD_ERR_ARG;
  if (v->running || !v->have_targets) return PWLOD_ERR_STATE;
  v->cb = on_frame;
  v->user = user;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->stop_req = false;
  }
  v->th_ = std::thread(RenderLoop, v);
  v->running = true;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_acquire_latest(pwlod_viewer* v, uint32_t* out_target_index,
                                         uint64_t* out_frame_number) {
  if (!v || !out_target_index || !out_frame_number) return PWLOD_ERR_ARG;
  std::lock_guard<std::mutex> lk(v->ring_mu);   // DefaultCamera.swift:1518-1529
  if (v->latest < 0) return PWLOD_ERR_STATE;
  v->held = v->latest;
  *out_target_index = (uint32_t)v->latest;
  *out_frame_number = v->latest_frame;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_stop(pwlod_viewer* v) {
  if (!v) return PWLOD_ERR_ARG;
  if (!v->running) return PWLOD_OK;
  {
    std::lock_guard<std::mutex> lk(v->mu);
    v->stop_req = true;
  }
  v->cv.notify_all();
  v->th_.join();
  v->running = false;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_get_stats(pwlod_viewer* v, pwlod_frame_stats* out_stats) {
  if (!v || !out_stats) return PWLOD_ERR_ARG;
  std::lock_guard<std::mutex> lk(v->ring_mu);
  if (v->latest < 0) return PWLOD_ERR_STATE;
  *out_stats = v->latest_stats;
  return PWLOD_OK;
}

pwlod_status pwlod_viewer_render_once(pwlod_viewer* v, const pwlod_target* target,
                                      WGPUTextureFormat format, uint32_t width_px,
                                      uint32_t height_px, pwlod_frame_stats* out_stats) {
  if (!v || !target || !ValidFormat(format) || width_px == 0 || height_px == 0) return PWLOD_ERR_ARG;
  if (v->running) return PWLOD_ERR_STATE;
  if (!TargetMatches(target->texture, format, width_px, height_px)) return PWLOD_ERR_ARG;
  plr::Target rt;
  rt.texture = target->texture;
  rt.memory = target->memory;
  rt.view = MakeView(target->texture);
  bool more = false;
  const pwlod_status s = FrameBody(v, rt, format, width_px, height_px, -1, out_stats, &more);
  wgpuTextureViewRelease(rt.view);
  return s;
}

void pwlod_viewer_destroy(pwlod_viewer* v) {
  if (!v) return;
  pwlod_viewer_stop(v);
  ReleaseLodAll(&v->rs.L);
  plr::ReleaseFlat(&v->rs.flat);
  plr::ReleasePipe(&v->rs.P);
  for (auto& vw : v->views)
    if (vw) wgpuTextureViewRelease(vw);
  delete v;
}

// "<engine git sha8> abi=<PWLOD_ABI_VERSION>" -- the ABI number comes from the frozen header.
const char* pwlod_version(void) { return PWLOD_ENGINE_SHA8 " abi=" PWLOD_STR(PWLOD_ABI_VERSION); }

}  // extern "C"
