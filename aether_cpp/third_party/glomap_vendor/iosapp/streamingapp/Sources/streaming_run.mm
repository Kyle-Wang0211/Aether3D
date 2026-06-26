// streaming_run.mm — Step-2 FULL-PIPELINE streaming device harness (iOS / A16).
//
// THE REALISTIC-UX ON-DEVICE TEST. Replays N captured frames (+ their REAL
// ARKit world poses) at a ~2s capture cadence and runs the full per-frame
// ①②③ pipeline through the StreamingOrchestrator:
//
//   frame ─▶ orchestrator.submit_frame
//              │  (bounded queue, drop-oldest, drain-after-stop)
//              ▼
//          ① GPU EXTRACT  (GpuSiftExtractor, Dawn→Tint→Metal, ~868ms warm A16)
//              ▼
//          ② POSE-GUIDED MATCH  (aether_sift_match_pairs + PosePriorAllowsMatch,
//                                 ARKit-prior 75° optical-axis prune) vs prev k
//              ▼  WriteMatches → EstimateTwoViewGeometry → WriteTwoViewGeometry
//          ③ REGISTER + LOCAL-BA  (COLMAP IncrementalPipeline; defer_global_ba)
//              ▼
//          sparse point cloud GROWS  (aether_sfm_get_points)
//
// ①② run EVERY frame (real GPU extract + real pose-guided match-persist into the
// session db). ③ (the COLMAP incremental register + LOCAL BA) is run every
// `register_every_n` frames AND once at the end, because aether_sfm_finalize
// re-runs the incremental mapper over the WHOLE accumulated db (O(N) — see the
// HONEST NOTE block below). Running it every frame would be both unrealistic
// (production registers periodically / post-capture, not every frame) and would
// take hours over 414 frames. The cadence is logged so the per-frame match cost
// and the periodic register cost are measured SEPARATELY.
//
// ───────────────────────────────────────────────────────────────────────────
// HONEST NOTE — what is REAL end-to-end vs simplified, and WHY:
//   • ① GPU extract: REAL. The production GpuSiftExtractor runs on the iPhone GPU.
//   • ② match: REAL. aether_sift_match_pairs (CPU brute force) emits index pairs;
//     PosePriorAllowsMatch prunes by the REAL ARKit pose prior; matches +
//     two-view geometry are PERSISTED into the COLMAP session db. This is the
//     real correspondence graph the incremental mapper consumes.
//   • ③ register + local-BA: REAL COLMAP colmap::IncrementalPipeline, but invoked
//     via aether_sfm_finalize which re-runs the mapper over the full db each call.
//     So it is run PERIODICALLY (register_every_n) not per-frame. The cloud still
//     GROWS across the run; we just don't pay O(N) on every single frame. The
//     final finalize over all injected frames is the authoritative cloud/reproj.
//   • Pacing: a wall-clock realsim timer at ~2s (jitter mode adds variance +
//     occasional pauses so the queue drains). The orchestrator's bounded queue /
//     drop-oldest / drain-after-stop run exactly as in production.
//
// Entry: streaming_run_all(shader_root, frames_dir, manifest_path, out, out_cap).
// Logs per-frame telemetry + a SUMMARY via printf (mirrored to the on-screen
// console + Documents/aether_console.log by the AppDelegate).

#include "gpu_sift_extractor.h"
#include "aether/gpu/streaming_orchestrator.h"
#include "aether_sfm_c.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <os/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

// CPU matcher that EMITS index pairs (dsp_sift_c.cc, same archive set). Used by
// the pose-guided match stage to build the correspondence graph.
extern "C" int aether_sift_match_pairs(const uint8_t* desc1, int n1,
                                       const uint8_t* desc2, int n2,
                                       double max_ratio, int* out_pairs,
                                       int out_cap_pairs, int* out_num_pairs);

// phys_footprint (the iOS jetsam metric) — sampled per frame so we can watch
// cumulative RSS as COLMAP + the growing cloud add onto Dawn's resident set.
#include <mach/mach.h>
static double FootprintMB() {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) ==
      KERN_SUCCESS)
    return (double)info.phys_footprint / (1024.0 * 1024.0);
  return -1.0;
}

namespace {

using clk = std::chrono::high_resolution_clock;
double ms_since(std::chrono::time_point<clk> t0) {
  return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}
void logline(const char* s) {
  printf("%s\n", s);
  fflush(stdout);
  os_log(OS_LOG_DEFAULT, "%{public}s", s);
}

// ─── one replay frame: path + REAL ARKit pose (world→cam) + intrinsics ──
struct ReplayFrame {
  std::string path;       // absolute path to the JPEG on device
  double timestamp = 0;   // capture timestamp (s); defines pacing + ordering
  int width = 0, height = 0;
  float fx = 0, fy = 0, cx = 0, cy = 0;
  bool has_pose = false;
  double q_wxyz[4] = {1, 0, 0, 0};  // CamFromWorld rotation (world→cam)
  double t[3] = {0, 0, 0};          // CamFromWorld translation
};

// Decode a JPEG to row-major top-down uint8 grayscale (CGImage convention,
// matches aether_dsp_sift_extract / the SfM ABI). maxEdge downsamples via the
// ImageIO thumbnail path (cheap). Returns malloc'd uint8[w*h]; caller frees.
uint8_t* DecodeGray8(const std::string& path, int maxEdge, int* outW, int* outH) {
  NSString* p = [NSString stringWithUTF8String:path.c_str()];
  CGImageSourceRef src = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:p], NULL);
  if (!src) return nullptr;
  NSDictionary* opts = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize : @(maxEdge),
    (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
  };
  CGImageRef cg =
      CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
  CFRelease(src);
  if (!cg) return nullptr;
  int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
  uint8_t* gray8 = (uint8_t*)calloc((size_t)w * h, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray8, w, h, 8, w, cs,
                                           (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) { free(gray8); CGImageRelease(cg); return nullptr; }
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx);
  CGImageRelease(cg);
  *outW = w;
  *outH = h;
  return gray8;
}

// Parse the harness manifest (a JSON array written by gen_streaming_manifest.py)
// in timestamp order. Each element:
//   {"file","timestamp","w","h","fx","fy","cx","cy","q":[qw,qx,qy,qz],"t":[..]}
// q/t are CamFromWorld (world→cam) — already inverted from the bundle's
// Camera-to-World cameraTransform by the generator (see that script). If "q"
// is absent the frame has no pose (unguided matching).
bool LoadManifest(const std::string& manifest_path, const std::string& frames_dir,
                  std::vector<ReplayFrame>* out) {
  NSString* mp = [NSString stringWithUTF8String:manifest_path.c_str()];
  NSData* data = [NSData dataWithContentsOfFile:mp];
  if (!data) { logline("MANIFEST_FAIL cannot read manifest"); return false; }
  NSError* err = nil;
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (!root || ![root isKindOfClass:[NSArray class]]) {
    logline("MANIFEST_FAIL not a JSON array");
    return false;
  }
  for (NSDictionary* e in (NSArray*)root) {
    ReplayFrame f;
    NSString* file = e[@"file"];
    if (!file) continue;
    f.path = frames_dir + "/" + std::string([file UTF8String]);
    f.timestamp = [e[@"timestamp"] doubleValue];
    f.width = [e[@"w"] intValue];
    f.height = [e[@"h"] intValue];
    f.fx = [e[@"fx"] floatValue];
    f.fy = [e[@"fy"] floatValue];
    f.cx = [e[@"cx"] floatValue];
    f.cy = [e[@"cy"] floatValue];
    NSArray* q = e[@"q"];
    NSArray* t = e[@"t"];
    if (q && t && [q count] == 4 && [t count] == 3) {
      f.has_pose = true;
      for (int i = 0; i < 4; ++i) f.q_wxyz[i] = [q[i] doubleValue];
      for (int i = 0; i < 3; ++i) f.t[i] = [t[i] doubleValue];
    }
    out->push_back(std::move(f));
  }
  std::stable_sort(out->begin(), out->end(),
                   [](const ReplayFrame& a, const ReplayFrame& b) {
                     return a.timestamp < b.timestamp;
                   });
  return !out->empty();
}

// Thermal-state name (NSProcessInfo): 0=nominal 1=fair 2=serious 3=critical.
long ThermalState() {
  return (long)[[NSProcessInfo processInfo] thermalState];
}

}  // namespace

// ── Streaming SfM ingest state shared with the AppDelegate-driven loop ──
// Owns the COLMAP session; the orchestrator's IngestFn closes over it. Splits
// the per-frame work into ② match (always) and ③ register/local-BA (periodic).
struct StreamSfmState {
  aether_sfm_session_t* session = nullptr;
  int register_every_n = 25;     // run COLMAP incremental register every N frames
  std::atomic<uint64_t> ingested{0};
  std::atomic<int> last_registered{0};
  std::atomic<int> last_points{0};
  std::atomic<double> last_reproj{0.0};
  // per-frame timings published for the telemetry line (guarded by mu)
  std::mutex mu;
  double match_ms = 0, register_ms = 0;
  bool did_register = false;
};

// Per-frame ingest: inject GPU features → pose-guided match-persist (②, every
// frame) → periodic COLMAP register + local-BA (③). Fills the cloud snapshot.
static bool StreamIngest(StreamSfmState* st, const aether::gpu::CaptureFrame& f,
                         const aether::gpu::FrameFeatures& feats,
                         aether::gpu::CloudSnapshot* out) {
  if (feats.count <= 0) return false;
  // GPU stride-2 {x,y} → injection ABI's stride-4 {x,y,sigma,octave}.
  std::vector<float> kp4((size_t)feats.count * 4, 0.f);
  for (int i = 0; i < feats.count; ++i) {
    kp4[i * 4 + 0] = feats.xy[2 * i];
    kp4[i * 4 + 1] = feats.xy[2 * i + 1];
  }
  auto t_match = clk::now();
  int frame_id = -1;
  // ② inject + pose-guided match-persist (WriteMatches + TwoViewGeometry). The
  // ARKit pose in `f` drives PosePriorAllowsMatch (75° optical-axis prune).
  aether_sfm_result_t rc = aether_sfm_add_frame_with_features(
      st->session, f.width, f.height, f.fx, f.fy, f.cx, f.cy, kp4.data(),
      feats.desc.data(), (unsigned)feats.count,
      f.has_pose ? f.pose_qwxyz : nullptr, f.has_pose ? f.pose_t : nullptr,
      &frame_id);
  double match_ms = ms_since(t_match);
  if (rc != AETHER_SFM_OK) return false;

  uint64_t n = ++st->ingested;
  bool do_register =
      (st->register_every_n > 0) && ((n % (uint64_t)st->register_every_n) == 0);

  double register_ms = 0;
  if (do_register) {
    // ③ COLMAP incremental register + LOCAL BA over the accumulated db. NOTE
    // this re-runs the mapper over ALL frames so far (O(N)); that is why it is
    // periodic, not per-frame. defer_global_ba keeps it local-BA-only.
    auto t_reg = clk::now();
    char json[256] = {0};
    aether_sfm_result_t frc = aether_sfm_finalize(st->session, json, sizeof(json));
    register_ms = ms_since(t_reg);
    if (frc == AETHER_SFM_OK || frc == AETHER_SFM_ERR_NOT_REGISTERED) {
      // read back the growing cloud
      int npts = 0;
      aether_sfm_get_points(st->session, nullptr, &npts);
      st->last_points = npts;
      int pose_total = 0;
      aether_sfm_get_poses(st->session, nullptr, 0, &pose_total);
      // count registered
      std::vector<aether_sfm_pose_t> poses(pose_total > 0 ? pose_total : 1);
      int pc = 0;
      aether_sfm_get_poses(st->session, poses.data(), pose_total, &pc);
      int reg = 0;
      for (int i = 0; i < pc; ++i) reg += poses[i].registered ? 1 : 0;
      st->last_registered = reg;
      // parse reproj_px out of json (best-effort)
      const char* rp = std::strstr(json, "\"reproj_px\":");
      if (rp) st->last_reproj = std::atof(rp + 12);
      if (out) {
        out->registered_frames = reg;
        out->reproj_px = st->last_reproj.load();
        out->last_frame_index = f.frame_index;
      }
    }
  }
  {
    std::lock_guard<std::mutex> lk(st->mu);
    st->match_ms = match_ms;
    st->register_ms = register_ms;
    st->did_register = do_register;
  }
  return true;
}

// ════════════════════════════════════════════════════════════════════════════
// streaming_run_all — the harness entry. Loads frames+poses, builds the
// orchestrator with REAL GPU extract + REAL SfM ingest, replays at ~2s pacing
// (jitter optional), logs per-frame telemetry + a SUMMARY.
//
//   shader_root   : bundle resourcePath (holds shaders/wgsl/*.wgsl)
//   frames_dir    : dir on device holding the JPEGs (Documents/frames)
//   manifest_path : the harness manifest JSON (Documents/streaming_manifest.json)
//   max_frames    : cap N for a smaller run (0 = all)
//   jitter        : 0 = fixed 2s pacing; 1 = 2s ± variance + occasional pauses
//   register_every_n : COLMAP register cadence (frames)
//   max_edge      : downsample longest image edge (production downsamples 4K→2K)
// ════════════════════════════════════════════════════════════════════════════
extern "C" int streaming_run_all(const char* shader_root, const char* frames_dir,
                                 const char* manifest_path, int max_frames,
                                 int jitter, int register_every_n, int max_edge,
                                 int clear_cache, char* out, int out_cap) {
  if (out && out_cap > 0) out[0] = 0;
  char b[1024];

  snprintf(b, sizeof(b),
           "STREAM_BEGIN shader_root=%s frames_dir=%s manifest=%s max_frames=%d "
           "jitter=%d register_every_n=%d max_edge=%d thermal_before=%ld",
           shader_root, frames_dir, manifest_path, max_frames, jitter,
           register_every_n, max_edge, ThermalState());
  logline(b);

  // ── load frames + REAL ARKit poses (timestamp order) ──
  std::vector<ReplayFrame> frames;
  if (!LoadManifest(manifest_path, frames_dir, &frames)) {
    logline("STREAM_FAIL manifest load");
    return 1;
  }
  if (max_frames > 0 && (int)frames.size() > max_frames)
    frames.resize(max_frames);
  snprintf(b, sizeof(b), "STREAM_LOADED %zu frames (timestamp order)",
           frames.size());
  logline(b);

  // ── ③ create the COLMAP streaming session (private temp db) ──
  std::string docs =
      [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask,
                                           YES).firstObject UTF8String];
  std::string db_path = docs + "/stream_sfm.db";
  std::remove(db_path.c_str());
  aether_sfm_options_t opts;
  aether_sfm_options_default(&opts);
  opts.max_features = 8192;     // production GPU extractor cap
  opts.k_neighbors = 6;         // sequential match window
  opts.match_max_ratio = 0.7f;

  StreamSfmState st;
  st.register_every_n = register_every_n > 0 ? register_every_n : 25;
  if (aether_sfm_create(db_path.c_str(), &opts, &st.session) != AETHER_SFM_OK ||
      !st.session) {
    logline("STREAM_FAIL aether_sfm_create");
    return 2;
  }
  logline("STREAM_SFM_SESSION_OK");

  // ── ① init the GPU DSP-SIFT extractor ONCE (11 Tint→Metal pipeline compiles).
  //    A disk-backed Dawn persistent pipeline cache (DawnCacheDeviceDescriptor)
  //    serializes the compiled blobs so a WARM launch skips the recompile. On a
  //    COLD launch (empty cache) this is the ~31.7s A16 cost — logged loudly so
  //    the user doesn't think it hung. Run the app TWICE: run1 cold (writes
  //    cache), run2 warm (init should drop). ──
  std::string cache_dir = docs + "/dawn_pipeline_cache";
  // count blobs already on disk BEFORE init → cold vs warm classification.
  int blobs_before = 0;
  {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* cd = [NSString stringWithUTF8String:cache_dir.c_str()];
    if (clear_cache) {
      [fm removeItemAtPath:cd error:nil];
      logline("STREAM_CACHE cleared (forced cold run)");
    }
    NSArray* items = [fm contentsOfDirectoryAtPath:cd error:nil];
    blobs_before = items ? (int)[items count] : 0;
  }
  const char* cache_state = blobs_before > 0 ? "warm" : "cold";
  snprintf(b, sizeof(b),
           "STREAM_INIT compiling GPU shaders — cache=%s (%d blobs on disk). "
           "COLD ≈30s on A16 (one-time); WARM should be far less...",
           cache_state, blobs_before);
  logline(b);

  aether::gpu::GpuSiftExtractor ex;
  aether::gpu::GpuSiftExtractor::Config cfg{};
  cfg.shader_root = shader_root;
  cfg.cache_dir = cache_dir.c_str();
  cfg.cache_isolation_key = "gpusift-v1";  // bump to invalidate on shader change
  auto t_init = clk::now();
  if (!ex.init(cfg)) {
    logline("STREAM_FAIL GPU extractor init (Dawn/WGSL→Tint→Metal/buffer limits)");
    aether_sfm_free(st.session);
    return 3;
  }
  double init_ms = ms_since(t_init);
  long cache_hits = ex.cache_load_hits();
  long cache_stores = ex.cache_store_count();
  snprintf(b, sizeof(b),
           "STREAM_INIT_OK init_ms=%.0f (%.1fs) tint_compile_ms=%.0f cache=%s "
           "blobs_on_disk_before=%d cache_load_hits=%ld cache_stores=%ld",
           init_ms, init_ms / 1000.0, ex.init_compile_ms(), cache_state,
           blobs_before, cache_hits, cache_stores);
  logline(b);

  // ── extract stage: REAL GPU extract on the orchestrator's GPU thread.
  //    CaptureFrame.gray is uint8; the extractor wants float intensity. ──
  aether::gpu::ExtractFn extract_fn =
      [&ex](const aether::gpu::CaptureFrame& f,
            aether::gpu::FrameFeatures* o) -> bool {
    if (!f.gray || f.width <= 0 || f.height <= 0) return false;
    const size_t n = (size_t)f.width * f.height;
    std::vector<float> grayf(n);
    for (size_t i = 0; i < n; ++i) grayf[i] = (float)f.gray[i];
    aether::gpu::GpuSiftFrame frame;
    if (!ex.extract(grayf.data(), f.width, f.height, &frame)) return false;
    int nk = (int)frame.count;
    o->count = nk;
    o->xy.resize((size_t)nk * 2);
    o->desc.resize((size_t)nk * 128);
    // GpuSiftFrame layout: separate x[], y[], sigma[], octave[] + desc 128*count.
    for (int i = 0; i < nk; ++i) {
      o->xy[2 * i] = frame.x[i];
      o->xy[2 * i + 1] = frame.y[i];
    }
    if (nk > 0) std::memcpy(o->desc.data(), frame.descriptors.data(),
                            (size_t)nk * 128);
    return nk > 0;
  };

  // ── ingest stage: REAL pose-guided match (②) + periodic register (③). ──
  aether::gpu::IngestFn ingest_fn =
      [&st](const aether::gpu::CaptureFrame& f,
            const aether::gpu::FrameFeatures& feats,
            aether::gpu::CloudSnapshot* o) -> bool {
    return StreamIngest(&st, f, feats, o);
  };

  // ── per-frame telemetry, published by the cloud sink (runs on SfM thread) ──
  struct Telemetry {
    std::atomic<uint64_t> frames_done{0};
    std::atomic<int> over_2s{0};
    std::atomic<double> peak_rss{0};
    std::atomic<long> thermal_max{0};
    std::vector<double> per_frame_total_ms;  // for mean/p95 (guarded by mu)
    std::mutex mu;
  } tel;

  aether::gpu::OrchestratorConfig ocfg;
  ocfg.max_queue_depth = 12;
  ocfg.drop_policy = aether::gpu::OrchestratorConfig::DropPolicy::kDropOldest;
  ocfg.max_features = 8192;

  aether::gpu::StreamingOrchestrator orch(extract_fn, ingest_fn,
                                          /*sink=*/nullptr, ocfg);
  orch.start();
  logline("STREAM_ORCH_START extract∥ingest, queue=12 drop=oldest");

  // ── replay loop: submit each frame at ~2s pacing; log per-frame telemetry.
  //    We measure END-TO-END per-frame wall (submit → that frame's ingest done)
  //    via the orchestrator stats deltas + the StreamSfmState timings. Because
  //    the pipeline overlaps stages, we report the orchestrator's instantaneous
  //    queue depth + the just-completed frame's extract/match/register split. ──
  srand(1789);
  auto t_run0 = clk::now();
  long thermal_log = ThermalState();
  uint64_t prev_ingested = 0;
  uint64_t prev_extracted = 0;

  for (size_t i = 0; i < frames.size(); ++i) {
    ReplayFrame& rf = frames[i];

    // decode (downsample to max_edge; production downsamples 4K→2K)
    int w = 0, h = 0;
    uint8_t* gray = DecodeGray8(rf.path, max_edge > 0 ? max_edge : 2112, &w, &h);
    if (!gray) {
      snprintf(b, sizeof(b), "STREAM_FRAME f=%zu DECODE_FAIL %s", i,
               rf.path.c_str());
      logline(b);
      continue;
    }
    // scale intrinsics to the decoded resolution
    float sx = rf.width > 0 ? (float)w / rf.width : 1.f;
    float sy = rf.height > 0 ? (float)h / rf.height : 1.f;

    aether::gpu::CaptureFrame cf;
    cf.gray = gray;
    cf.width = w;
    cf.height = h;
    cf.fx = rf.fx * sx;
    cf.fy = rf.fy * sy;
    cf.cx = rf.cx * sx;
    cf.cy = rf.cy * sy;
    cf.has_pose = rf.has_pose;
    for (int k = 0; k < 4; ++k) cf.pose_qwxyz[k] = rf.q_wxyz[k];
    for (int k = 0; k < 3; ++k) cf.pose_t[k] = rf.t[k];
    cf.timestamp = rf.timestamp;
    cf.frame_index = i;

    auto t_frame = clk::now();
    bool accepted = orch.submit_frame(cf);  // copies gray into the queue envelope
    free(gray);

    // Pace BEFORE polling so the pipeline has the cadence window to work. The
    // orchestrator overlaps extract(N+1) with ingest(N); at steady state the
    // per-frame service ≈ max(extract,match) which should fit under ~2s with
    // headroom — UNTIL a periodic register (③) or thermal throttle stretches it.
    double pace_ms = 2000.0;
    if (jitter) {
      // 2s ± up to 600ms; every ~17th frame a 4s "hold still" pause → drain.
      pace_ms = 2000.0 + ((rand() % 1200) - 600);
      if ((i % 17) == 16) pace_ms += 4000.0;
    }
    // Busy-wait-free sleep in small slices so we can sample mem/thermal mid-pace.
    double waited = 0;
    while (waited < pace_ms) {
      double slice = std::min(200.0, pace_ms - waited);
      [NSThread sleepForTimeInterval:slice / 1000.0];
      waited += slice;
      double rss = FootprintMB();
      if (rss > tel.peak_rss.load()) tel.peak_rss = rss;
      long th = ThermalState();
      if (th > tel.thermal_max.load()) tel.thermal_max = th;
    }

    // snapshot orchestrator stats AFTER the pacing window
    aether::gpu::OrchestratorStats s = orch.stats();
    double frame_wall_ms = ms_since(t_frame);

    // pull the just-completed frame's stage split from StreamSfmState
    double match_ms, register_ms;
    bool did_reg;
    {
      std::lock_guard<std::mutex> lk(st.mu);
      match_ms = st.match_ms;
      register_ms = st.register_ms;
      did_reg = st.did_register;
    }
    double rss = FootprintMB();
    if (rss > tel.peak_rss.load()) tel.peak_rss = rss;
    long thermal = ThermalState();
    if (thermal > tel.thermal_max.load()) tel.thermal_max = thermal;
    if (thermal != thermal_log) {
      snprintf(b, sizeof(b), "STREAM_THERMAL_RAMP f=%zu state %ld→%ld at t=%.0fs",
               i, thermal_log, thermal, ms_since(t_run0) / 1000.0);
      logline(b);
      thermal_log = thermal;
    }

    // The dominant per-frame compute (the thing that must fit the cadence) is
    // the extract+match service time. register_ms is the periodic (every-N)
    // COLMAP cost, reported separately. "total" here = the compute on the
    // critical path for THIS frame (extract is overlapped; the SfM thread cost
    // is match + any periodic register).
    double compute_ms = match_ms + register_ms;
    if (compute_ms > 2000.0) tel.over_2s++;
    {
      std::lock_guard<std::mutex> lk(tel.mu);
      tel.per_frame_total_ms.push_back(compute_ms);
    }

    snprintf(b, sizeof(b),
             "STREAM_FRAME f=%zu accepted=%d ext_done=%llu match_ms=%.0f "
             "reg_ms=%.0f%s compute_ms=%.0f qdepth=%zu peakq=%zu "
             "drop_old=%llu reg_frames=%d cloud_pts=%d reproj_px=%.3f "
             "thermal=%ld rss_mb=%.0f t=%.0fs",
             i, accepted ? 1 : 0, (unsigned long long)s.extracted, match_ms,
             register_ms, did_reg ? "*REG" : "", compute_ms, s.queue_depth,
             s.peak_queue_depth, (unsigned long long)s.dropped_oldest,
             st.last_registered.load(), st.last_points.load(),
             st.last_reproj.load(), thermal, rss, ms_since(t_run0) / 1000.0);
    logline(b);
    (void)prev_ingested; (void)prev_extracted;
  }

  // ── stop + DRAIN: process every accepted-but-pending frame before joining ──
  logline("STREAM_STOP draining queue...");
  orch.stop_capture();  // blocks until the backlog is fully consumed

  // ── FINAL authoritative register over ALL injected frames (③ full finalize) ──
  logline("STREAM_FINAL_REGISTER running COLMAP incremental over all frames...");
  auto t_final = clk::now();
  char json[512] = {0};
  aether_sfm_result_t frc = aether_sfm_finalize(st.session, json, sizeof(json));
  double final_ms = ms_since(t_final);
  int final_pts = 0;
  aether_sfm_get_points(st.session, nullptr, &final_pts);
  int pose_total = 0;
  aether_sfm_get_poses(st.session, nullptr, 0, &pose_total);
  std::vector<aether_sfm_pose_t> poses(pose_total > 0 ? pose_total : 1);
  int pc = 0;
  aether_sfm_get_poses(st.session, poses.data(), pose_total, &pc);
  int final_reg = 0;
  for (int i = 0; i < pc; ++i) final_reg += poses[i].registered ? 1 : 0;

  aether::gpu::OrchestratorStats fs = orch.stats();

  // ── SUMMARY ──
  double mean_ms = 0, p95_ms = 0;
  {
    std::lock_guard<std::mutex> lk(tel.mu);
    if (!tel.per_frame_total_ms.empty()) {
      std::vector<double> v = tel.per_frame_total_ms;
      double sum = 0;
      for (double x : v) sum += x;
      mean_ms = sum / v.size();
      std::sort(v.begin(), v.end());
      p95_ms = v[(size_t)(v.size() * 0.95)];
    }
  }
  snprintf(b, sizeof(b), "STREAM_FINAL_REGISTER_DONE final_ms=%.0f json=%s", final_ms,
           json);
  logline(b);

  snprintf(b, sizeof(b),
           "STREAM_SUMMARY frames=%zu submitted=%llu enqueued=%llu "
           "extracted=%llu ingested=%llu dropped_oldest=%llu queue_highwater=%zu "
           "init_ms=%.0f cache=%s cache_load_hits=%ld cache_stores=%ld "
           "mean_compute_ms=%.0f p95_compute_ms=%.0f over_2000ms=%d "
           "final_registered=%d final_cloud_pts=%d final_reproj_px=%s "
           "thermal_max=%ld peak_rss_mb=%.0f",
           frames.size(), (unsigned long long)fs.submitted,
           (unsigned long long)fs.enqueued, (unsigned long long)fs.extracted,
           (unsigned long long)fs.ingested,
           (unsigned long long)fs.dropped_oldest, fs.peak_queue_depth, init_ms,
           cache_state, cache_hits, cache_stores, mean_ms, p95_ms,
           tel.over_2s.load(), final_reg, final_pts,
           (std::strstr(json, "reproj_px") ? std::strstr(json, "reproj_px") + 11
                                           : "n/a"),
           tel.thermal_max.load(), tel.peak_rss.load());
  logline(b);
  if (out && out_cap > 0) {
    strncpy(out, b, out_cap - 1);
    out[out_cap - 1] = 0;
  }

  aether_sfm_free(st.session);
  logline("STREAM_DONE (log saved to Documents/aether_console.log)");
  return frc == AETHER_SFM_OK ? 0 : 4;
}
