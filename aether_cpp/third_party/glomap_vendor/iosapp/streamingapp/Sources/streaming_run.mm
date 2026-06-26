// streaming_run.mm — Step-3 SINGLE WALL-CLOCK INTERLEAVED streaming harness
// (iOS / A16). THE REALISTIC-UX ON-DEVICE TEST.
//
// Replays N captured frames (+ their REAL ARKit world poses) in TEMPORAL
// (capture-timestamp) order and runs ONE interleaved per-frame loop where the
// sparse cloud grows DURING capture, frame by frame:
//
//   per frame (temporal order):
//     ① GPU EXTRACT            GpuSiftExtractor (Dawn→Tint→Metal)
//     ② POSE-GUIDED MATCH      aether_sfm_add_frame_with_features — inject the GPU
//                              keypoints+descriptors into the LIVE COLMAP db +
//                              pose-guided match-persist (PosePriorAllowsMatch,
//                              ARKit 75° optical-axis prune) against the prev k.
//     ──  attach ARKit pose prior for this image (cam_from_world, COLMAP frame)
//     ③ LIVE POSE-PRIOR REGISTER
//                              aether_sfm_add_and_register_frame — adds the frame
//                              to the LIVE, GROWING graph (periodic bounded
//                              re-cache), registers it via RegisterNextImage and,
//                              when plain PnP lacks visible 3D structure,
//                              RegisterNextImageWithPosePrior (bypasses PnP using
//                              the ARKit prior) + fixed-window local BA + deferred
//                              triangulation. The sparse point cloud grows THIS
//                              frame (out_stats.total_points).
//
//   after the capture loop:
//     FINAL-FLUSH              aether_sfm_live_final_flush — one final recache over
//                              ALL fed frames, drains the entire pending frontier
//                              (no per-call cap), one global BA + filter. Coverage
//                              -> ~100%.
//
// This REPLACES the prior two-phase design (phase-A live ①②, phase-B post-hoc
// register loop) AND the older every-25 finalize cadence. There is now exactly
// ONE per-frame wall-clock loop: extract+match+register are interleaved per
// frame, the cloud grows per frame, and a single final-flush pass closes
// coverage after the loop.
//
// Host-verified equivalent flow: bench/sfm_live_verify.cc (full-414 temporal,
// coverage 0.97 w/ final-flush, per-frame WALL median 32-60ms / p95 680-1047ms,
// reproj 0.778 sub-pixel). This harness wires the SAME ABI calls on real GPU
// features streamed through add_frame_with_features (production path), not the
// bench's live_stage_db_image (host-only db-copy helper).
//
// ───────────────────────────────────────────────────────────────────────────
// HONEST NOTE — what is REAL end-to-end:
//   • ① GPU extract: REAL. The production GpuSiftExtractor runs on the iPhone GPU.
//   • ② match: REAL. add_frame_with_features injects the GPU feats (NO CPU
//     re-extraction), matches against the prev k_neighbors with the ARKit pose
//     prior pruning, persists matches + two-view geometry into the live db.
//   • ③ register: REAL COLMAP IncrementalMapper driven LIVE per frame via
//     add_and_register_frame (RegisterNextImage / RegisterNextImageWithPosePrior
//     + bounded local BA + deferred triangulation + amortized periodic recache).
//   • Pacing: a wall-clock realsim timer at ~2s (jitter optional). The loop is
//     synchronous (no orchestrator queue): each frame's extract→match→register
//     runs inline, so the per-frame line carries the TRUE interleaved wall cost.
//     A frame whose compute exceeds the capture cadence is counted as "dropped"
//     (real-time backpressure model) but still registered (we never silently
//     skip a frame's geometry).
//
// Entry: streaming_run_all(shader_root, frames_dir, manifest, max_frames, jitter,
//        register_every_n, max_edge, clear_cache, out, out_cap).
// Logs per-frame telemetry + a STREAM_SUMMARY via printf (mirrored to the on-
// screen console + Documents/aether_console.log by the AppDelegate).

#include "gpu_sift_extractor.h"
#include "aether_sfm_c.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <os/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// READ-ONLY accessor (defined in aether_sfm_c.cc, not in the stable ABI header —
// declared here exactly like aether_sfm_dump_reg_failures). Resolves frame_id ->
// COLMAP image_id so we can attach the ARKit pose prior (keyed by image_id).
extern "C" int aether_sfm_frame_image_id(aether_sfm_session_t* s, int frame_id);

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
  double q_wxyz[4] = {1, 0, 0, 0};  // CamFromWorld rotation (ARKit world→cam)
  double t[3] = {0, 0, 0};          // CamFromWorld translation (ARKit frame)
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
// q/t are ARKit-frame CamFromWorld (world→cam) — the generator inverted the
// Camera-to-World cameraTransform but did NOT apply the COLMAP camera-axis flip.
// We apply F=diag(1,-1,-1) here when building the COLMAP cam_from_world prior
// (see ArkitToColmapCamFromWorld). If "q" is absent the frame has no pose.
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

// Convert an ARKit-frame CamFromWorld (quaternion wxyz + translation) into the
// COLMAP-convention cam_from_world as a row-major [R|t] (12 doubles), applying
// the camera-axis flip F=diag(1,-1,-1): ARKit camera looks down -Z (+X right,
// +Y up); COLMAP looks down +Z (+X right, +Y down). The manifest's q/t are the
// ARKit-frame CamFromWorld (R_wc^T and -R_wc^T*C), so the COLMAP cam_from_world
// is R_colmap = F * R_manifest, t_colmap = F * t_manifest — identical to the
// host-verify bench's conversion (sfm_live_verify.cc lines 199-225).
void ArkitToColmapCamFromWorld(const double q_wxyz[4], const double t[3],
                               double out_3x4[12]) {
  // Quaternion (w,x,y,z) -> rotation matrix R_manifest.
  const double w = q_wxyz[0], x = q_wxyz[1], y = q_wxyz[2], z = q_wxyz[3];
  const double n = std::sqrt(w * w + x * x + y * y + z * z);
  const double s = (n > 0) ? 1.0 / n : 1.0;
  const double qw = w * s, qx = x * s, qy = y * s, qz = z * s;
  double R[3][3];
  R[0][0] = 1 - 2 * (qy * qy + qz * qz);
  R[0][1] = 2 * (qx * qy - qz * qw);
  R[0][2] = 2 * (qx * qz + qy * qw);
  R[1][0] = 2 * (qx * qy + qz * qw);
  R[1][1] = 1 - 2 * (qx * qx + qz * qz);
  R[1][2] = 2 * (qy * qz - qx * qw);
  R[2][0] = 2 * (qx * qz - qy * qw);
  R[2][1] = 2 * (qy * qz + qx * qw);
  R[2][2] = 1 - 2 * (qx * qx + qy * qy);
  const double F[3] = {1.0, -1.0, -1.0};
  for (int i = 0; i < 3; ++i) {
    out_3x4[i * 4 + 0] = F[i] * R[i][0];
    out_3x4[i * 4 + 1] = F[i] * R[i][1];
    out_3x4[i * 4 + 2] = F[i] * R[i][2];
    out_3x4[i * 4 + 3] = F[i] * t[i];
  }
}

// Thermal-state name (NSProcessInfo): 0=nominal 1=fair 2=serious 3=critical.
long ThermalState() {
  return (long)[[NSProcessInfo processInfo] thermalState];
}

double Pctl(std::vector<double> v, double p) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  size_t idx = (size_t)(v.size() * p);
  if (idx >= v.size()) idx = v.size() - 1;
  return v[idx];
}

}  // namespace

// ════════════════════════════════════════════════════════════════════════════
// streaming_run_all — the harness entry. Loads frames+poses (temporal order),
// inits the GPU extractor + the LIVE COLMAP session, then runs the SINGLE
// interleaved per-frame loop (extract → match → live pose-prior register), and a
// FINAL-FLUSH pass after the loop. Logs per-frame telemetry + a STREAM_SUMMARY.
//
//   shader_root    : bundle resourcePath (holds shaders/wgsl/*.wgsl)
//   frames_dir     : dir on device holding the JPEGs (Documents/frames)
//   manifest_path  : the harness manifest JSON (Documents/streaming_manifest.json)
//   max_frames     : cap N for a smaller run (0 = all)
//   jitter         : 0 = fixed 2s pacing; 1 = 2s ± variance + occasional pauses
//   register_every_n : global-BA SPIKE cadence MARKER only (the deferred design
//                      runs NO in-loop global BA; recache/global-BA frames are
//                      flagged distinctly in the log instead).
//   max_edge       : downsample longest image edge (production downsamples 4K→2K)
// ════════════════════════════════════════════════════════════════════════════
extern "C" int streaming_run_all(const char* shader_root, const char* frames_dir,
                                 const char* manifest_path, int max_frames,
                                 int jitter, int register_every_n, int max_edge,
                                 int clear_cache, char* out, int out_cap) {
  if (out && out_cap > 0) out[0] = 0;
  char b[1024];

  snprintf(b, sizeof(b),
           "STREAM_BEGIN [INTERLEAVED 1+2+3 per-frame + final-flush] "
           "shader_root=%s frames_dir=%s manifest=%s max_frames=%d jitter=%d "
           "register_every_n=%d max_edge=%d thermal_before=%ld",
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

  // ── create the LIVE COLMAP streaming session (private temp db) ──
  std::string docs =
      [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask,
                                           YES).firstObject UTF8String];
  std::string db_path = docs + "/stream_sfm.db";
  std::remove(db_path.c_str());
  std::remove((db_path + "-shm").c_str());
  std::remove((db_path + "-wal").c_str());
  aether_sfm_options_t opts;
  aether_sfm_options_default(&opts);
  opts.max_features = 8192;     // production GPU extractor cap
  opts.k_neighbors = 6;         // sequential match window
  opts.match_max_ratio = 0.7f;

  aether_sfm_session_t* session = nullptr;
  if (aether_sfm_create(db_path.c_str(), &opts, &session) != AETHER_SFM_OK ||
      !session) {
    logline("STREAM_FAIL aether_sfm_create");
    return 2;
  }
  logline("STREAM_SFM_SESSION_OK");

  // ── live-path params + ARKit pose-prior fallback ENABLED. recache_every=8,
  //    bootstrap_k=6 (the host-verified live defaults); pose prior lets frames
  //    whose 2D-3D visibility is too low for plain PnP register via the known
  //    ARKit pose instead (RegisterNextImageWithPosePrior). ──
  aether_sfm_set_live_params(session, /*recache_every=*/8, /*bootstrap_k=*/6,
                             /*max_register_per_call=*/0 /*default 4*/);
  aether_sfm_set_pose_prior_enabled(session, 1);
  logline("STREAM_LIVE_PARAMS recache_every=8 bootstrap_k=6 pose_prior=ON "
          "(RegisterNextImageWithPosePrior fallback)");

  // ── ① init the GPU DSP-SIFT extractor ONCE (Tint→Metal pipeline compiles).
  //    A disk-backed Dawn persistent pipeline cache serializes the compiled
  //    blobs so a WARM launch skips the recompile. COLD launch (empty cache) is
  //    the ~30s A16 cost — logged loudly. Run the app TWICE: run1 cold (writes
  //    cache), run2 warm (init drops). ──
  std::string cache_dir = docs + "/dawn_pipeline_cache";
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
    aether_sfm_free(session);
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

  // ── per-run telemetry accumulators ──
  std::vector<double> per_frame_total_ms;  // ext+match+register interleaved wall
  std::vector<double> register_ms_samples; // O(local) register-only sub-term
  double peak_rss = 0.0;
  long thermal_max = ThermalState();
  long thermal_log = ThermalState();
  int over_2s = 0, dropped = 0;
  int recache_count = 0;
  double recache_ms_total = 0.0, recache_ms_max = 0.0;
  int bootstrap_frame = -1;
  int final_total_pts = 0;
  double final_reproj = 0.0;
  int registered_running = 0;
  int prev_total = -1, grew_count = 0, growth_eligible = 0;
  const int global_ba_marker = register_every_n > 0 ? register_every_n : 25;

  logline("STREAM_LOOP_START single wall-clock interleaved per-frame "
          "①extract ②match ③live-pose-prior-register; cloud grows per frame");

  srand(1789);
  auto t_run0 = clk::now();

  // ════════════════════════════════════════════════════════════════════════
  // THE SINGLE INTERLEAVED PER-FRAME LOOP. Each iteration runs ①②③ inline so
  // the per-frame line carries the TRUE interleaved wall cost; the cloud grows
  // this frame. NO orchestrator queue, NO two-phase, NO every-25 finalize.
  // ════════════════════════════════════════════════════════════════════════
  for (size_t i = 0; i < frames.size(); ++i) {
    ReplayFrame& rf = frames[i];
    auto t_frame = clk::now();

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
    float fx = rf.fx * sx, fy = rf.fy * sy, cx = rf.cx * sx, cy = rf.cy * sy;

    // ── ① GPU EXTRACT ──
    auto t_ext = clk::now();
    const size_t n = (size_t)w * h;
    std::vector<float> grayf(n);
    for (size_t k = 0; k < n; ++k) grayf[k] = (float)gray[k];
    free(gray);
    aether::gpu::GpuSiftFrame gframe;
    bool ext_ok = ex.extract(grayf.data(), w, h, &gframe);
    double extract_ms = ms_since(t_ext);
    if (!ext_ok || gframe.count == 0) {
      snprintf(b, sizeof(b), "STREAM_FRAME f=%zu EXTRACT_FAIL extract_ms=%.0f",
               i, extract_ms);
      logline(b);
      continue;
    }
    int nk = (int)gframe.count;

    // GpuSiftFrame layout (separate x[],y[],sigma[],octave[] + desc 128*count)
    // → injection ABI's stride-4 {x,y,sigma,octave} + 128*count uint8 desc.
    std::vector<float> kp4((size_t)nk * 4, 0.f);
    for (int k = 0; k < nk; ++k) {
      kp4[k * 4 + 0] = gframe.x[k];
      kp4[k * 4 + 1] = gframe.y[k];
    }

    // ── ② POSE-GUIDED MATCH-PERSIST (inject GPU feats into the live db) ──
    auto t_match = clk::now();
    int frame_id = -1;
    aether_sfm_result_t arc = aether_sfm_add_frame_with_features(
        session, w, h, fx, fy, cx, cy, kp4.data(), gframe.descriptors.data(),
        (unsigned)nk, rf.has_pose ? rf.q_wxyz : nullptr,
        rf.has_pose ? rf.t : nullptr, &frame_id);
    double match_ms = ms_since(t_match);
    if (arc != AETHER_SFM_OK || frame_id < 0) {
      snprintf(b, sizeof(b),
               "STREAM_FRAME f=%zu ADD_FRAME_FAIL rc=%d (%s) extract_ms=%.0f "
               "match_ms=%.0f kp=%d",
               i, arc, aether_sfm_result_str(arc), extract_ms, match_ms, nk);
      logline(b);
      continue;
    }

    // ── attach the ARKit pose prior (COLMAP cam_from_world) for THIS image so
    //    the live register can fall back to RegisterNextImageWithPosePrior. ──
    if (rf.has_pose) {
      int image_id = aether_sfm_frame_image_id(session, frame_id);
      if (image_id > 0) {
        double cfw[12];
        ArkitToColmapCamFromWorld(rf.q_wxyz, rf.t, cfw);
        aether_sfm_set_image_pose_prior(session, image_id, cfw);
      }
    }

    // ── ③ LIVE POSE-PRIOR REGISTER (cloud grows THIS frame) ──
    aether_sfm_live_stats_t lst;
    auto t_reg = clk::now();
    aether_sfm_result_t rrc =
        aether_sfm_add_and_register_frame(session, frame_id, &lst);
    double register_ms = ms_since(t_reg);
    if (rrc != AETHER_SFM_OK) {
      snprintf(b, sizeof(b),
               "STREAM_FRAME f=%zu REGISTER_FAIL rc=%d (%s) extract_ms=%.0f "
               "match_ms=%.0f register_ms=%.0f",
               i, rrc, aether_sfm_result_str(rrc), extract_ms, match_ms,
               register_ms);
      logline(b);
      continue;
    }

    // bookkeeping
    if (lst.did_bootstrap && bootstrap_frame < 0) bootstrap_frame = (int)i;
    if (lst.did_recache && lst.recache_ms > 0) {
      ++recache_count;
      recache_ms_total += lst.recache_ms;
      if (lst.recache_ms > recache_ms_max) recache_ms_max = lst.recache_ms;
    }
    registered_running = lst.total_registered;
    final_total_pts = lst.total_points;
    if (lst.reproj_px > 0) final_reproj = lst.reproj_px;

    // cumulative cloud-growth stat (post-bootstrap)
    if (bootstrap_frame >= 0) {
      if (prev_total >= 0) {
        ++growth_eligible;
        if (lst.total_points > prev_total) ++grew_count;
        register_ms_samples.push_back(register_ms);
      }
      prev_total = lst.total_points;
    }

    // total interleaved per-frame compute (what the device/UI actually pays)
    double compute_ms = extract_ms + match_ms + register_ms;
    per_frame_total_ms.push_back(compute_ms);

    // mem/thermal sample
    double rss = FootprintMB();
    if (rss > peak_rss) peak_rss = rss;
    long thermal = ThermalState();
    if (thermal > thermal_max) thermal_max = thermal;
    if (thermal != thermal_log) {
      snprintf(b, sizeof(b), "STREAM_THERMAL_RAMP f=%zu state %ld→%ld at t=%.0fs",
               i, thermal_log, thermal, ms_since(t_run0) / 1000.0);
      logline(b);
      thermal_log = thermal;
    }

    // real-time backpressure model: a synchronous loop has no queue, but a frame
    // whose interleaved compute exceeds the capture cadence would have forced a
    // drop in a live bounded-queue capture. Count it (geometry still registered).
    double cadence_ms = 2000.0;
    int queue_depth = 0;  // synchronous interleaved loop: no pending backlog
    if (compute_ms > cadence_ms) { ++over_2s; ++dropped; }

    // distinct flags for recache / global-BA-cadence / bootstrap frames
    bool ba_marker = (global_ba_marker > 0) &&
                     registered_running > 0 &&
                     (registered_running % global_ba_marker) == 0;
    char flags[160];
    flags[0] = 0;
    if (lst.did_bootstrap) strncat(flags, " *BOOTSTRAP_SEED", sizeof(flags) - 1);
    if (lst.did_recache)
      snprintf(flags + strlen(flags), sizeof(flags) - strlen(flags),
               " *RECACHE(%.0fms,off-loop)", lst.recache_ms);
    if (ba_marker)
      strncat(flags, " *GLOBAL_BA_CADENCE(deferred,off-loop)",
              sizeof(flags) - strlen(flags) - 1);

    snprintf(b, sizeof(b),
             "STREAM_FRAME f=%zu extract_ms=%.0f match_ms=%.0f register_ms=%.0f "
             "total_ms=%.0f registered=%d new_points=%d total_cloud_points=%d "
             "reproj=%.4f queue_depth=%d dropped=%d thermalState=%ld rss_mb=%.0f "
             "kp=%d t=%.0fs%s",
             i, extract_ms, match_ms, register_ms, compute_ms, lst.registered,
             lst.new_points, lst.total_points, lst.reproj_px, queue_depth,
             dropped, thermal, rss, nk, ms_since(t_run0) / 1000.0, flags);
    logline(b);

    // ── pace to ~2s capture cadence (replays the real capture rate). The work
    //    already consumed compute_ms; only sleep the remainder. ──
    double pace_ms = 2000.0;
    if (jitter) {
      pace_ms = 2000.0 + ((rand() % 1200) - 600);
      if ((i % 17) == 16) pace_ms += 4000.0;  // occasional "hold still" pause
    }
    double remain = pace_ms - compute_ms;
    while (remain > 0) {
      double slice = std::min(200.0, remain);
      [NSThread sleepForTimeInterval:slice / 1000.0];
      remain -= slice;
      double r2 = FootprintMB();
      if (r2 > peak_rss) peak_rss = r2;
      long th = ThermalState();
      if (th > thermal_max) thermal_max = th;
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // FINAL-FLUSH — one pass after the capture loop. Recache over ALL fed frames,
  // drain the entire pending frontier (no per-call cap), one global BA + filter.
  // Coverage -> ~100%. Explicitly OFF the per-frame critical path.
  // ════════════════════════════════════════════════════════════════════════
  logline("STREAM_FINAL_FLUSH_BEGIN draining pending frontier + global BA "
          "(off the per-frame path)...");
  aether_sfm_live_stats_t flush_st;
  auto t_flush = clk::now();
  aether_sfm_result_t frc = aether_sfm_live_final_flush(session, &flush_st);
  double flush_ms = ms_since(t_flush);
  if (frc == AETHER_SFM_OK) {
    snprintf(b, sizeof(b),
             "STREAM_FINAL_FLUSH rc=%d registered_this_call=%d new_points=%d "
             "total_registered=%d total_cloud_points=%d reproj=%.4f "
             "flush_wall_ms=%.0f (recache_ms=%.0f) *FINAL_FLUSH",
             frc, flush_st.registered, flush_st.new_points,
             flush_st.total_registered, flush_st.total_points,
             flush_st.reproj_px, flush_ms, flush_st.recache_ms);
    logline(b);
    if (flush_st.total_points > 0) final_total_pts = flush_st.total_points;
    if (flush_st.reproj_px > 0) final_reproj = flush_st.reproj_px;
    if (flush_st.total_registered > 0) registered_running = flush_st.total_registered;
  } else {
    snprintf(b, sizeof(b), "STREAM_FINAL_FLUSH rc=%d (%s) — flush failed", frc,
             aether_sfm_result_str(frc));
    logline(b);
  }

  // ── authoritative final readback from the live incremental model ──
  int final_pts = 0;
  aether_sfm_get_points(session, nullptr, &final_pts);
  int pose_total = 0;
  aether_sfm_get_poses(session, nullptr, 0, &pose_total);
  std::vector<aether_sfm_pose_t> poses(pose_total > 0 ? pose_total : 1);
  int pc = 0;
  aether_sfm_get_poses(session, poses.data(), pose_total, &pc);
  int final_reg = 0;
  for (int i = 0; i < pc; ++i) final_reg += poses[i].registered ? 1 : 0;

  // ── per-frame stats ──
  double total_p50 = Pctl(per_frame_total_ms, 0.50);
  double total_p95 = Pctl(per_frame_total_ms, 0.95);
  double reg_p50 = Pctl(register_ms_samples, 0.50);
  double reg_p95 = Pctl(register_ms_samples, 0.95);
  double growth_ratio =
      growth_eligible > 0 ? (double)grew_count / growth_eligible : 0.0;
  double coverage = !frames.empty() ? (double)final_reg / frames.size() : 0.0;
  double recache_ms_avg =
      recache_count > 0 ? recache_ms_total / recache_count : 0.0;

  snprintf(b, sizeof(b),
           "STREAM_SUMMARY mode=INTERLEAVED_1+2+3_perframe+final_flush "
           "frames=%zu coverage=%.4f (%d/%zu) "
           "perframe_total_p50_ms=%.0f perframe_total_p95_ms=%.0f over_2s=%d "
           "dropped=%d register_p50_ms=%.0f register_p95_ms=%.0f "
           "cloud_grew_frac=%.2f bootstrap_frame=%d "
           "recache_count=%d recache_ms_avg=%.0f recache_ms_max=%.0f "
           "init_ms=%.0f cache=%s cache_load_hits=%ld cache_stores=%ld "
           "thermal_ramp=%ld→%ld peak_rss_mb=%.0f "
           "final_cloud_pts=%d final_reproj_px=%.4f flush_wall_ms=%.0f",
           frames.size(), coverage, final_reg, frames.size(), total_p50,
           total_p95, over_2s, dropped, reg_p50, reg_p95, growth_ratio,
           bootstrap_frame, recache_count, recache_ms_avg, recache_ms_max,
           init_ms, cache_state, cache_hits, cache_stores, ThermalState(),
           thermal_max, peak_rss, final_pts, final_reproj, flush_ms);
  logline(b);
  if (out && out_cap > 0) {
    strncpy(out, b, out_cap - 1);
    out[out_cap - 1] = 0;
  }
  (void)registered_running;

  aether_sfm_free(session);
  logline("STREAM_DONE (log saved to Documents/aether_console.log)");
  return frc == AETHER_SFM_OK ? 0 : 4;
}
