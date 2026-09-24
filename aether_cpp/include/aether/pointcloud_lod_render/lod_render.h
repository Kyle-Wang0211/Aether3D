// PocketWorld point-cloud LOD render pass (C++ side of pwlod_viewer.h).
//
// Moved, not written: Pipe, LodFrame, BuildVisibleNodeTable, CpuGetLOD, the
// WGSL (bench_cloud.mm's quad path + Potree's adaptive point size), Upload,
// EvictGpu and ResetLod are the PWLodBench code (pw_splat_ab_bench
// Sources/lod/pw_lod_bench.cpp @ b792d57, verified on the Mac: results_mac_
// 20260924_async_adaptive). Every change against that file is an R-numbered
// entry in src/pointcloud_lod_render/DEVIATIONS.md. Selection, streaming and
// the controller are aether::pointcloud_lod, called as-is.
//
// Platform: C++20 + webgpu.h only. The render target is a WGPUTexture the
// caller hands in; no OS header, no vendor graphics API, no per-OS branch.
#pragma once

#include <webgpu/webgpu.h>

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "aether/pointcloud_lod/octree.h"
#include "aether/pointcloud_lod/select.h"
#include "aether/pointcloud_lod/stream.h"
#include "aether/pointcloud_lod_render/viewer_look.h"

namespace aether::pointcloud_lod_render {

namespace lod = aether::pointcloud_lod;

constexpr uint32_t kSlotBytes = 256;        // dynamic-offset stride
constexpr uint32_t kMaxDrawNodes = 16384;   // per-frame node uniform slots
constexpr uint32_t kMaxVN = 65536;          // visible-node table capacity (entries of 16 B)

// ─── device (R1: the bench's global `g`, now passed in) ─────────────────
struct GpuCtx {
  WGPUInstance instance = nullptr;
  WGPUAdapter adapter = nullptr;
  WGPUDevice device = nullptr;
  WGPUQueue queue = nullptr;
  bool has_timestamp = false;
  int backend = 0;
  std::string adapter_name;
};

// pw_lod_bench.cpp InitGpu, plus the caller's required features (R11).
// Returns false with `err` set; on success every handle is non-null.
bool CreateGpu(const WGPUFeatureName* extra_features, uint32_t extra_count, GpuCtx* out,
               std::string* err);
void ReleaseGpu(GpuCtx* g);

// Uncaptured errors and device loss of every device made by CreateGpu, in
// arrival order (the bench kept them in g.error_log).
uint64_t GpuErrorCount();
std::string GpuErrorLog();
bool GpuDeviceLost(WGPUDevice device);

WGPUStringView SV(const char* s);
void WaitFuture(const GpuCtx& g, WGPUFuture f);
WGPUBuffer MakeBuffer(const GpuCtx& g, uint64_t size, WGPUBufferUsage usage);
void WaitQueueIdle(const GpuCtx& g);

// ─── uniforms (WGSL FrameU / NodeU) ─────────────────────────────────────
struct FrameU {
  float img_size[2];
  float base_scale, cam_dist, r_min, r_max;
  float ortho_width;   // R6 (was pad0): Potree uOrthoWidth, pointcloud.vs:36, :692
  uint32_t ortho;      // R6 (was pad1): Potree uUseOrthographicCamera, pointcloud.vs:35, :690
  float tan_half_fov, octree_size, octree_spacing, psize, min_size, max_size;
  uint32_t mode;
  float pad2;
};
static_assert(sizeof(FrameU) == 64, "FrameU must be 64 bytes");

struct NodeU {
  float mvp[16];
  float level, vn_start, half_size, pad;
  float sel_off[3];   // R14: node origin - selection centre (double, then cast)
  float pad2;
};
static_assert(sizeof(NodeU) == 96, "NodeU must be 96 bytes");

// R14: the product viewer's look, per frame (WGSL ViewerU, binding 4).
struct ViewerU {
  float rot0[4], rot1[4], rot2[4];   // COLUMNS of the row-major selection rot (= rows of rot^T)
  float half[4];                     // selection size / 2
  float out_color[4];                // selection_out_argb as unorm rgba
  float base_scale, max_scale, disc_radius, sprite_half;
  float orbit_distance;
  uint32_t sel_mode;                 // 0 none, 1 tint, 2 cull
  uint32_t ortho_end;                // 1 iff orthoMix == 1 exactly
  float pad;
};
static_assert(sizeof(ViewerU) == 112, "ViewerU must be 112 bytes");

// R14: one point as the viewer shader computed it (the parity probe's output).
struct ViewerProbePoint {
  float x, y;          // screen px, origin top-left (the painter's canvas convention)
  float scale;         // sprite scale
  uint32_t rgba;       // pack4x8unorm of the drawn colour (r | g<<8 | b<<16 | a<<24)
  uint32_t culled;     // 1 = CULL_OUTSIDE removed it
  float w;             // clip.w (= the projection divisor)
  float pad[2];
};
static_assert(sizeof(ViewerProbePoint) == 32, "ViewerProbePoint must be 32 bytes");

struct CPoint { float x, y, z; uint32_t rgba; };
static_assert(sizeof(CPoint) == 16, "CPoint must be 16 bytes");

// The WGSL text. Exposed so a test can hash it / reuse getLOD in a compute check.
const char* WgslCommon();
const char* WgslRender();
const char* WgslLodCheck();

// ─── pipeline + per-size resources ──────────────────────────────────────
// R2: the colour target is the caller's texture; Pipe owns only the depth
// buffer (sized to the target) and the pipelines built for its format.
struct Pipe {
  WGPUBindGroupLayout bgl = nullptr;
  WGPURenderPipeline pipe = nullptr;
  WGPURenderPipeline viewer_core = nullptr;   // R14: VIEWER discs, covered texels, depth write
  WGPURenderPipeline viewer_rim = nullptr;    // R14: VIEWER discs, the AA rim, blended, no depth write
  WGPUComputePipeline lodcheck = nullptr;
  WGPUComputePipeline viewer_probe = nullptr; // R14: per-point parity probe
  WGPUBuffer viewer_u = nullptr;              // R14: ViewerU
  WGPUBuffer frame_u = nullptr;
  WGPUBuffer node_u = nullptr;   // kMaxDrawNodes * 256 B, dynamic offset
  WGPUBuffer vn = nullptr;       // visible-node table, kMaxVN * 16 B
  WGPUTexture depth = nullptr;
  WGPUTextureView depth_v = nullptr;
  WGPUTextureFormat color_format = WGPUTextureFormat_RGBA8Unorm;
  uint32_t w = 0, h = 0;
  WGPUQuerySet qs = nullptr;
  WGPUBuffer resolve = nullptr, qstage = nullptr;
  uint32_t qslots = 0;
};

bool MakePipe(const GpuCtx& g, Pipe* P, WGPUTextureFormat color_format, uint32_t w, uint32_t h,
              uint32_t qslots, std::string* err);
void ReleasePipe(Pipe* P);
// R17: change the colour format / size, keeping every GPU node valid.
bool RetargetPipe(const GpuCtx& g, Pipe* P, WGPUTextureFormat color_format, uint32_t w, uint32_t h,
                  std::string* err);

// One colour target (R2/R4). `memory` non-null => every use is bracketed by
// wgpuSharedTextureMemoryBeginAccess / EndAccess.
struct Target {
  WGPUTexture texture = nullptr;
  WGPUTextureView view = nullptr;
  WGPUSharedTextureMemory memory = nullptr;
};

// ─── camera ─────────────────────────────────────────────────────────────
struct CamState {
  lod::Camera cam;    // for selectVisible (row-major viewProj, D17 ortho fields)
  double vp[16];      // row-major
  double cam_dist = 1;
};

void Mul(const double a[16], const double b[16], double o[16]);

// ─── LOD renderer state ─────────────────────────────────────────────────
struct GpuNode {
  WGPUBuffer buf = nullptr;
  WGPUBindGroup bg = nullptr;
  uint32_t count = 0;
  uint64_t bytes = 0;
  uint64_t last_used = 0;
  lod::Vec3 origin;
  double density = 0;     // Potree's per-node density (NodePoints::density)
};

enum class LoadMode { Sync, Async };

struct Lod {
  const lod::Octree* oct = nullptr;
  std::string bin_path;
  LoadMode mode = LoadMode::Sync;
  std::unique_ptr<lod::NodeLoader> loader;          // Sync
  std::unique_ptr<lod::AsyncNodeLoader> aloader;    // Async
  int max_nodes_loading = 4;                        // Potree.js:104
  size_t cache_bytes = 0;
  std::unordered_map<int32_t, GpuNode> gpu;
  uint64_t gpu_bytes = 0, gpu_budget = 0;
  uint64_t frame_no = 0;
  // lifetime counters (reset per block)
  int64_t uploads = 0, evictions = 0;
};

void ReleaseNode(GpuNode& n);
void ResetLod(Lod* L, size_t cache_bytes, LoadMode mode = LoadMode::Sync);

// ─── Potree visible-node table (PointCloudOctree.js:321-391) ────────────
struct VNTable {
  std::vector<uint32_t> data;                    // 4 per entry
  std::unordered_map<int32_t, uint32_t> offset;  // node -> entry index
  bool truncated = false;
};

uint32_t LodByte(double density);
VNTable BuildVisibleNodeTable(const lod::Octree& oct, const std::vector<int32_t>& drawn,
                              const std::unordered_map<int32_t, GpuNode>& gpu);
float CpuGetLOD(const VNTable& t, float octreeSize, float uLevel, int uVNStart, const float pos[3]);

struct DrawOpts {
  int32_t skip_node = -1;     // negative control: leave one node out
  int32_t only_node = -1;     // leaf-only render
  bool no_origin = false;     // negative control: forget to add the origin back
  bool keep_depth = false;    // store the depth attachment (for readback)
  int psize_mode = 0;         // 0 production formula, 1 Potree ADAPTIVE, 2 product VIEWER (R14)
  std::vector<int32_t>* out_drawn = nullptr;   // receives the drawn node ids
};

struct FrameRec {
  double wall = 0, sel = 0, load = 0, upload = 0, render = 0, gpu = -1;
  int64_t pts_sel = 0, pts_drawn = 0;
  int nodes_sel = 0, nodes_drawn = 0, dropped = 0, max_level = 0;
  int64_t decoded = 0, reads = 0, bytes_read = 0, short_reads = 0;
  int uploads = 0;
  bool hit_budget = false;
  bool truncated = false;       // more nodes than kMaxDrawNodes / kMaxVN (must stay false)
  double px = 0;
  bool target_selected = false, target_drawn = false;
  // async only
  int pending_nodes = 0;        // visible but not drawable yet (Selection::unloaded)
  int64_t pending_pts = 0;
  int in_flight = 0;
  int vn_entries = 0;
  // R3/R4 (viewer bookkeeping, not in the bench)
  double submit_ms = 0;         // t0 -> wgpuQueueSubmit returned
  bool access_failed = false;   // BeginAccess refused: nothing was submitted
  // R13: Selection::lowestSpacing of this frame's selectVisible call, as computed
  // there (+infinity when nothing was accepted).
  double lowest_spacing = 0;
};

// Frame parameters that only the draw needs.
struct DrawParams {
  double base_scale = 1.5;
  double octree_size = 1, octree_spacing = 1;
  // R7: the bench wrote r_min = 0, r_max = 64 into FrameU unconditionally.
  double r_min = 0.0, r_max = 64.0;
  // R5: the bench cleared to (0,0,0,0).
  double clear_rgba[4] = {0, 0, 0, 0};
  // R14: non-null = the product viewer's look. Colours are baked with it at
  // upload (so the caller resets the GPU copies when its colour key changes,
  // ColourKeyDiffers), the selection box is applied per frame.
  const ViewerStyle* viewer = nullptr;
};

// R3: what happens between wgpuQueueSubmit and the sync-mode GPU eviction.
// The bench waited for the queue there (WaitQueueIdle); the viewer's render
// thread publishes / waits for OnSubmittedWorkDone instead. nullptr fn = the
// bench's WaitQueueIdle.
// `fr` is the frame record so far (selection, uploads, draws, submit_ms).
struct SubmitHook {
  void (*fn)(void* ctx, const FrameRec& fr) = nullptr;
  void* ctx = nullptr;
};

// R15: a point set drawn whole (ABI v3 pwlod_viewer_set_points): no octree, no
// budget. Chunks of <= kFlatChunkPoints points, positions relative to one
// origin (the set's box centre), colours baked like octree nodes.
constexpr uint32_t kFlatChunkPoints = 1u << 20;
struct FlatSet {
  lod::Vec3 origin;
  std::vector<GpuNode> chunks;
  int64_t points = 0;
};
// Uploads xyz / rgb (count points; visibility may be null; a visibility array
// of the wrong length is the caller's to drop) into `out` (released first).
void UploadFlat(const GpuCtx& g, const Pipe& P, const float* xyz, const uint8_t* rgb,
                const uint8_t* visibility, uint64_t count, bool colored, const ViewerStyle* viewer,
                FlatSet* out);
void ReleaseFlat(FlatSet* f);

// Draws a FlatSet (every chunk) with the same encoder / shaders as LodFrame.
FrameRec FlatFrame(const GpuCtx& g, const FlatSet& F, Pipe* P, const Target& rt, const CamState& cs,
                   const DrawParams& dp, const DrawOpts& opt, const SubmitHook& hook);

// Runs the VIEWER vertex math of every point of one GPU node / chunk in a
// compute pass and reads it back (the parity probe). mvp / sel_off as drawn.
std::vector<ViewerProbePoint> ProbeViewerPoints(const GpuCtx& g, Pipe* P, const GpuNode& gn,
                                                const lod::Vec3& origin, const CamState& cs,
                                                const DrawParams& dp);

// One LOD frame: select -> load -> upload -> draw -> submit -> hook. Every
// stage timed. `target` is the leaf the bench's probes watch (-1 = none).
FrameRec LodFrame(const GpuCtx& g, Lod* L, Pipe* P, const Target& rt, const CamState& cs,
                  const lod::SelectParams& sp, const DrawParams& dp, int32_t target, uint32_t qslot,
                  const DrawOpts& opt = DrawOpts(), const SubmitHook& hook = SubmitHook());

}  // namespace aether::pointcloud_lod_render
