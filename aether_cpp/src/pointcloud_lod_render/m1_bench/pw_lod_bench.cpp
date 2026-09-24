// PWLodBench -- the Aether3D point-cloud LOD core (PR #98, feat/pointcloud-lod-core
// @ d89b74f3, vendored verbatim under third_party/) wired into this bench's
// existing Dawn quad point path, so that a real device can answer:
//   "36M / 217M dense points through LOD: stable 30 fps? any detail lost?"
//
// What is NOT written here (by rule): selection, streaming, controller. Those
// are aether::pointcloud_lod::{selectVisible, NodeLoader, QualityController},
// called as-is. What IS written here is plumbing only:
//   - per-node GPU buffers (created on first draw, released when evicted)
//   - one draw per node, the node origin folded into a per-node matrix
//     (VP * T(origin) computed in double, then cast) -- what Potree does with
//     its per-node modelViewMatrix
//   - a deterministic camera trajectory, the A/B schedule and the probes.
//
// The quad shader is bench_cloud.mm's kWgslCloud (vertex expansion, perspective
// radius = baseScale * camDist / depth, opaque + depth write) with the single
// change that the view-projection comes from a per-node uniform.
//
// Platform: C++17 + webgpu.h only. No OS header, no vendor graphics API, no
// per-OS branch; the adapter is requested with the default backend.
#include "pw_lod_bench.h"

#include <webgpu/webgpu.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "aether/pointcloud_lod/octree.h"
#include "aether/pointcloud_lod/select.h"
#include "aether/pointcloud_lod/stream.h"

namespace {

using namespace aether::pointcloud_lod;

constexpr double kPi = 3.14159265358979323846;
constexpr double kTargetMs = 1000.0 / 30.0;
constexpr uint32_t kSlotBytes = 256;        // dynamic-offset stride
constexpr uint32_t kMaxDrawNodes = 16384;   // per-frame node uniform slots

// ─── args ────────────────────────────────────────────────────────────────
struct Args {
  std::string mode = "perf";      // perf | correct | both
  std::string tag;
  std::string arms = "C,F,C2";    // C = controller, F = fixed px, C2 = C again (noise floor)
  int frames = 900;               // frames per trajectory block (30 s at 30 Hz)
  int rounds = 3;
  int pace = 1;                   // 1: hold each frame to a 33.3 ms period (a 30 Hz display)
  int64_t budget = 3630000;       // hard ceiling: (33.3 - 0.20) / 9.12 ms per M on A16
  double cache_mult = 3.0;        // NodeCache = cache_mult * 15 B * budget  (floor is 1.0)
  double base_scale = 1.5;        // cost-line configuration (cloud_run1_fit.json)
  double fixed_px = 150.0;        // Potree PointCloudOctree.js:113
  int width = 1179, height = 2556;
  int cold_frames = 90;           // cold-start probe block length
  int pc = 1;                     // positive control block
  int64_t ref_budget = 20000000;  // correctness reference: px=1 up to this many points
  int ctrl_settle = 150;          // correctness: frames the controller runs at each pose
  int save_img = 1;
  int max_nodes_loading = 4;      // Potree.js:104 (async mode)
  std::string first = "S";        // config of the COLD and FIRST blocks (see ArmOf)
};

Args ParseArgs(const char* s) {
  Args a;
  if (!s) return a;
  std::string str(s);
  size_t i = 0;
  while (i < str.size()) {
    while (i < str.size() && str[i] == ' ') ++i;
    size_t j = str.find(' ', i);
    if (j == std::string::npos) j = str.size();
    const std::string kv = str.substr(i, j - i);
    i = j;
    const size_t eq = kv.find('=');
    if (eq == std::string::npos) continue;
    const std::string k = kv.substr(0, eq), v = kv.substr(eq + 1);
    if (k == "mode") a.mode = v;
    else if (k == "tag") a.tag = v;
    else if (k == "arms") a.arms = v;
    else if (k == "frames") a.frames = std::atoi(v.c_str());
    else if (k == "rounds") a.rounds = std::atoi(v.c_str());
    else if (k == "pace") a.pace = std::atoi(v.c_str());
    else if (k == "budget") a.budget = std::atoll(v.c_str());
    else if (k == "cache_mult") a.cache_mult = std::atof(v.c_str());
    else if (k == "base") a.base_scale = std::atof(v.c_str());
    else if (k == "fixed_px") a.fixed_px = std::atof(v.c_str());
    else if (k == "w") a.width = std::atoi(v.c_str());
    else if (k == "h") a.height = std::atoi(v.c_str());
    else if (k == "cold_frames") a.cold_frames = std::atoi(v.c_str());
    else if (k == "pc") a.pc = std::atoi(v.c_str());
    else if (k == "ref_budget") a.ref_budget = std::atoll(v.c_str());
    else if (k == "ctrl_settle") a.ctrl_settle = std::atoi(v.c_str());
    else if (k == "save_img") a.save_img = std::atoi(v.c_str());
    else if (k == "mnl") a.max_nodes_loading = std::atoi(v.c_str());
    else if (k == "first") a.first = v;
  }
  return a;
}

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// FNV-1a 64 -- image identity for determinism checks (not a security hash).
uint64_t Fnv1a(const uint8_t* p, size_t n) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}

std::string Hex64(uint64_t v) {
  char b[24];
  std::snprintf(b, sizeof b, "%016llx", (unsigned long long)v);
  return b;
}

// ─── WebGPU ──────────────────────────────────────────────────────────────
WGPUStringView SV(const char* s) { return WGPUStringView{s, WGPU_STRLEN}; }

std::string SvStr(WGPUStringView v) {
  if (!v.data) return "";
  return std::string(v.data, v.length == WGPU_STRLEN ? std::strlen(v.data) : v.length);
}

struct Gpu {
  WGPUInstance instance = nullptr;
  WGPUAdapter adapter = nullptr;
  WGPUDevice device = nullptr;
  WGPUQueue queue = nullptr;
  bool has_timestamp = false;
  std::string adapter_name;
  int backend = 0;
  std::string error_log;
};
Gpu g;

void OnUncapturedError(WGPUDevice const*, WGPUErrorType type, WGPUStringView msg,
                       void*, void*) {
  g.error_log += "[wgpu error " + std::to_string((int)type) + "] " + SvStr(msg) + "\n";
}

void WaitFuture(WGPUFuture f) {
  WGPUFutureWaitInfo w{f, false};
  wgpuInstanceWaitAny(g.instance, 1, &w, UINT64_MAX);
}

bool InitGpu(std::string* err) {
  if (g.device) return true;
  static const WGPUInstanceFeatureName kTimed = WGPUInstanceFeatureName_TimedWaitAny;
  WGPUInstanceDescriptor idesc = WGPU_INSTANCE_DESCRIPTOR_INIT;
  idesc.requiredFeatureCount = 1;
  idesc.requiredFeatures = &kTimed;
  g.instance = wgpuCreateInstance(&idesc);
  if (!g.instance) { *err = "wgpuCreateInstance failed"; return false; }

  // Default backend on purpose: the same line picks the native backend on
  // every OS. The chosen backend is recorded, and the Null backend is refused.
  WGPURequestAdapterOptions aopt = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
  aopt.powerPreference = WGPUPowerPreference_HighPerformance;
  WGPURequestAdapterCallbackInfo aci = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
  aci.mode = WGPUCallbackMode_WaitAnyOnly;
  aci.callback = [](WGPURequestAdapterStatus st, WGPUAdapter a, WGPUStringView, void*,
                    void*) {
    if (st == WGPURequestAdapterStatus_Success) g.adapter = a;
  };
  WaitFuture(wgpuInstanceRequestAdapter(g.instance, &aopt, aci));
  if (!g.adapter) { *err = "RequestAdapter failed"; return false; }

  WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
  if (wgpuAdapterGetInfo(g.adapter, &info) == WGPUStatus_Success) {
    g.adapter_name = SvStr(info.device) + " | " + SvStr(info.description);
    g.backend = (int)info.backendType;
  }
  if (g.backend == (int)WGPUBackendType_Null) {
    *err = "adapter is the Null backend -- refusing to measure it";
    return false;
  }

  WGPULimits alim = WGPU_LIMITS_INIT;
  wgpuAdapterGetLimits(g.adapter, &alim);
  WGPULimits req = WGPU_LIMITS_INIT;
  req.maxStorageBufferBindingSize = alim.maxStorageBufferBindingSize;
  req.maxBufferSize = alim.maxBufferSize;

  g.has_timestamp = wgpuAdapterHasFeature(g.adapter, WGPUFeatureName_TimestampQuery);
  WGPUFeatureName feats[1] = {WGPUFeatureName_TimestampQuery};
  WGPUDeviceDescriptor ddesc = WGPU_DEVICE_DESCRIPTOR_INIT;
  ddesc.requiredLimits = &req;
  ddesc.requiredFeatureCount = g.has_timestamp ? 1 : 0;
  ddesc.requiredFeatures = g.has_timestamp ? feats : nullptr;
  ddesc.uncapturedErrorCallbackInfo.callback = OnUncapturedError;
  WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  dci.mode = WGPUCallbackMode_WaitAnyOnly;
  dci.callback = [](WGPURequestDeviceStatus st, WGPUDevice d, WGPUStringView, void*,
                    void*) {
    if (st == WGPURequestDeviceStatus_Success) g.device = d;
  };
  WaitFuture(wgpuAdapterRequestDevice(g.adapter, &ddesc, dci));
  if (!g.device) { *err = "RequestDevice failed"; return false; }
  g.queue = wgpuDeviceGetQueue(g.device);
  return true;
}

WGPUBuffer MakeBuffer(uint64_t size, WGPUBufferUsage usage) {
  WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
  d.size = size;
  d.usage = usage;
  return wgpuDeviceCreateBuffer(g.device, &d);
}

void WaitQueueIdle() {
  WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
  wi.mode = WGPUCallbackMode_WaitAnyOnly;
  wi.callback = [](WGPUQueueWorkDoneStatus, WGPUStringView, void*, void*) {};
  WaitFuture(wgpuQueueOnSubmittedWorkDone(g.queue, wi));
}

// ─── shader ──────────────────────────────────────────────────────────────
// bench_cloud.mm kWgslCloud, identical vertex expansion / fragment; the view-
// projection comes from a per-node uniform (VP * T(node origin)).
//
// Point size has two modes (FrameU.mode):
//   0  the production formula (sparse_cloud_view.dart:1528): r = base * camDist / depth
//   1  Potree's PointSizeType.ADAPTIVE, transliterated GLSL -> WGSL from
//      potree @ 5636cd471d9eb464969e758be45c44d7613d3859
//        src/materials/shaders/pointcloud.vs
//          :158-175 numberOfOnes   :183-210 isBitSet   :216-254 getLOD
//          :301-303 getPointSizeAttenuation = pow(2, getLOD())
//          :666-705 getPointSize, adaptive_point_size, perspective branch
//        uniforms set by src/PotreeRenderer.js:1232-1233,1293-1300,815,730
//        material defaults src/materials/PointCloudMaterial.js:32-34 (size 1, min 2, max 50)
//        visible-node table src/PointCloudOctree.js:321-391 (built on the CPU below)
//   Deviations (P1-P6) are listed at BuildVisibleNodeTable.
const char* kWgslCommon = R"LODWGSL(
struct FrameU {
    img_size: vec2f,
    base_scale: f32,
    cam_dist: f32,
    r_min: f32,
    r_max: f32,
    pad0: f32,
    pad1: f32,
    tan_half_fov: f32,
    octree_size: f32,
    octree_spacing: f32,
    psize: f32,
    min_size: f32,
    max_size: f32,
    mode: u32,
    pad2: f32,
}
struct NodeU { mvp: mat4x4f, level: f32, vn_start: f32, half_size: f32, pad: f32 }
struct CPoint { x: f32, y: f32, z: f32, rgba: u32 }

// pointcloud.vs:158-175
fn numberOfOnes(number_in: i32, index: i32) -> i32 {
    var number = number_in;
    var numOnes = 0;
    var tmp = 128;
    for (var i = 7; i >= 0; i--) {
        if (number >= tmp) {
            number = number - tmp;
            if (i <= index) {
                numOnes++;
            }
        }
        tmp = tmp / 2;
    }
    return numOnes;
}

// pointcloud.vs:183-210 (the if-chain is WebGL 1.0's missing bit ops; same result)
fn isBitSet(number: i32, index: i32) -> bool {
    if (index < 0 || index > 7) {
        return false;
    }
    let powi = 1 << u32(index);
    let ndp = number / powi;
    return (ndp % 2) != 0;
}

// pointcloud.vs:216-254. `position` is relative to the node's box min (P2).
fn getLOD(position: vec3f, uLevel: f32, uVNStart: i32) -> f32 {
    var offset = vec3f(0.0, 0.0, 0.0);
    var iOffset = uVNStart;
    var depth = uLevel;
    for (var i = 0.0; i <= 30.0; i += 1.0) {
        let nodeSizeAtLevel = fu.octree_size / pow(2.0, i + uLevel + 0.0);
        var index3d = (position - offset) / nodeSizeAtLevel;
        index3d = floor(index3d + 0.5);
        let index = i32(round(4.0 * index3d.x + 2.0 * index3d.y + index3d.z));
        let value = vn[iOffset];                 // (mask, offsetToFirstChild, lodByte, 0)  (P1)
        let mask = i32(value.x);
        if (isBitSet(mask, index)) {
            let advanceChild = numberOfOnes(mask, index - 1);
            let advance = i32(value.y) + advanceChild;
            iOffset = iOffset + advance;
            depth += 1.0;
        } else {
            let lodOffset = f32(value.z) / 10.0 - 10.0;   // (255.0 * value.a) / 10.0 - 10.0
            return depth + lodOffset;
        }
        offset = offset + (vec3f(1.0, 1.0, 1.0) * nodeSizeAtLevel * 0.5) * index3d;
    }
    return depth;
}
)LODWGSL";

const char* kWgslRender = R"LODWGSL(
@group(0) @binding(0) var<uniform> fu: FrameU;
@group(0) @binding(1) var<uniform> nu: NodeU;
@group(0) @binding(2) var<storage, read> pts: array<CPoint>;
@group(0) @binding(3) var<storage, read> vn: array<vec4u>;

struct VsOut {
    @builtin(position) clip: vec4f,
    @location(0) @interpolate(flat) color: vec4f,
}

@vertex fn vs_quad(@builtin(vertex_index) vi: u32) -> VsOut {
    var offsets = array<vec2f, 6>(
        vec2f(-1.0, -1.0),
        vec2f( 1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0,  1.0),
    );
    let ii = vi / 6u;
    let off = offsets[vi % 6u];
    let p = pts[ii];
    var clip = nu.mvp * vec4f(p.x, p.y, p.z, 1.0);
    let depth = max(clip.w, 1.0e-4);
    var r: f32;
    if (fu.mode == 1u) {
        // pointcloud.vs:666-705, adaptive_point_size, perspective branch.
        // :670 projFactor = -0.5 * uScreenHeight / (slope * vViewPosition.z); view z = -depth
        let projFactor = 0.5 * fu.img_size.y / (fu.tan_half_fov * depth);
        // :672-676 scale = 1: our node transform is a pure translation (P3)
        let rr = fu.octree_spacing * 1.7;                                          // :678
        let posMin = vec3f(p.x, p.y, p.z) + vec3f(nu.half_size);                    // P2
        let worldSpaceSize = 1.0 * fu.psize * rr / pow(2.0, getLOD(posMin, nu.level, i32(nu.vn_start)));  // :694, :301-303
        var pointSize = worldSpaceSize * projFactor;                                // :695
        pointSize = max(fu.min_size, pointSize);                                    // :699
        pointSize = min(fu.max_size, pointSize);                                    // :700
        r = 0.5 * pointSize;   // gl_PointSize is a diameter; this quad takes a half-size (P4)
    } else {
        r = clamp(fu.base_scale * fu.cam_dist / depth, fu.r_min, fu.r_max);
    }
    clip = vec4f(clip.xy + off * r * 2.0 / fu.img_size * clip.w, clip.z, clip.w);
    var o: VsOut;
    o.clip = clip;
    o.color = unpack4x8unorm(p.rgba);
    return o;
}

@fragment fn fs_opaque(in: VsOut) -> @location(0) vec4f {
    return in.color;
}
)LODWGSL";

// Same getLOD text run in a compute shader, so the GPU result can be compared
// with the CPU transliteration point by point (VerifyGetLOD).
const char* kWgslLodCheck = R"LODWGSL(
@group(0) @binding(0) var<uniform> fu: FrameU;
@group(0) @binding(1) var<uniform> nu: NodeU;
@group(0) @binding(2) var<storage, read> pts: array<CPoint>;
@group(0) @binding(3) var<storage, read> vn: array<vec4u>;
@group(0) @binding(4) var<storage, read_write> outLod: array<f32>;

@compute @workgroup_size(64) fn cs_lod(@builtin(global_invocation_id) gid: vec3u) {
    let i = gid.x;
    if (i >= arrayLength(&outLod)) { return; }
    let p = pts[i];
    outLod[i] = getLOD(vec3f(p.x, p.y, p.z) + vec3f(nu.half_size), nu.level, i32(nu.vn_start));
}
)LODWGSL";

struct FrameU {
  float img_size[2];
  float base_scale, cam_dist, r_min, r_max, pad0, pad1;
  float tan_half_fov, octree_size, octree_spacing, psize, min_size, max_size;
  uint32_t mode;
  float pad2;
};
static_assert(sizeof(FrameU) == 64, "FrameU must be 64 bytes");

struct NodeU {
  float mvp[16];
  float level, vn_start, half_size, pad;
};
static_assert(sizeof(NodeU) == 80, "NodeU must be 80 bytes");

constexpr uint32_t kMaxVN = 65536;   // visible-node table capacity (entries of 16 B)

struct CPoint { float x, y, z; uint32_t rgba; };
static_assert(sizeof(CPoint) == 16, "CPoint must be 16 bytes");

struct Pipe {
  WGPUBindGroupLayout bgl = nullptr;
  WGPURenderPipeline pipe = nullptr;
  WGPUComputePipeline lodcheck = nullptr;
  WGPUBuffer frame_u = nullptr;
  WGPUBuffer node_u = nullptr;   // kMaxDrawNodes * 256 B, dynamic offset
  WGPUBuffer vn = nullptr;       // visible-node table, kMaxVN * 16 B
  WGPUTexture color = nullptr, depth = nullptr;
  WGPUTextureView color_v = nullptr, depth_v = nullptr;
  uint32_t w = 0, h = 0;
  WGPUQuerySet qs = nullptr;
  WGPUBuffer resolve = nullptr, qstage = nullptr;
  uint32_t qslots = 0;
};

bool MakePipe(Pipe* P, uint32_t w, uint32_t h, uint32_t qslots, std::string* err) {
  P->w = w; P->h = h;
  const std::string render_src = std::string(kWgslCommon) + kWgslRender;
  WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
  src.code = SV(render_src.c_str());
  WGPUShaderModuleDescriptor md = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
  md.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&src);
  WGPUShaderModule mod = wgpuDeviceCreateShaderModule(g.device, &md);

  WGPUBindGroupLayoutEntry e[4];
  for (auto& x : e) x = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
  e[0].binding = 0; e[0].visibility = WGPUShaderStage_Vertex;
  e[0].buffer.type = WGPUBufferBindingType_Uniform;
  e[0].buffer.minBindingSize = sizeof(FrameU);
  e[1].binding = 1; e[1].visibility = WGPUShaderStage_Vertex;
  e[1].buffer.type = WGPUBufferBindingType_Uniform;
  e[1].buffer.hasDynamicOffset = 1;
  e[1].buffer.minBindingSize = sizeof(NodeU);
  e[2].binding = 2; e[2].visibility = WGPUShaderStage_Vertex;
  e[2].buffer.type = WGPUBufferBindingType_ReadOnlyStorage;
  e[2].buffer.minBindingSize = sizeof(CPoint);
  e[3].binding = 3; e[3].visibility = WGPUShaderStage_Vertex;
  e[3].buffer.type = WGPUBufferBindingType_ReadOnlyStorage;
  e[3].buffer.minBindingSize = 16;
  WGPUBindGroupLayoutDescriptor bld = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
  bld.entryCount = 4; bld.entries = e;
  P->bgl = wgpuDeviceCreateBindGroupLayout(g.device, &bld);
  WGPUPipelineLayoutDescriptor pld = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
  pld.bindGroupLayoutCount = 1; pld.bindGroupLayouts = &P->bgl;
  WGPUPipelineLayout pl = wgpuDeviceCreatePipelineLayout(g.device, &pld);

  WGPUColorTargetState ct = WGPU_COLOR_TARGET_STATE_INIT;
  ct.format = WGPUTextureFormat_RGBA8Unorm;
  ct.blend = nullptr;
  ct.writeMask = WGPUColorWriteMask_All;
  WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT;
  fs.module = mod; fs.entryPoint = SV("fs_opaque");
  fs.targetCount = 1; fs.targets = &ct;
  WGPUVertexState vs = WGPU_VERTEX_STATE_INIT;
  vs.module = mod; vs.entryPoint = SV("vs_quad"); vs.bufferCount = 0;
  WGPUDepthStencilState ds = WGPU_DEPTH_STENCIL_STATE_INIT;
  ds.format = WGPUTextureFormat_Depth32Float;
  ds.depthWriteEnabled = WGPUOptionalBool_True;
  ds.depthCompare = WGPUCompareFunction_Less;
  WGPURenderPipelineDescriptor pd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
  pd.layout = pl;
  pd.vertex = vs; pd.fragment = &fs;
  pd.primitive.topology = WGPUPrimitiveTopology_TriangleList;
  pd.primitive.cullMode = WGPUCullMode_None;
  pd.primitive.frontFace = WGPUFrontFace_CCW;
  pd.depthStencil = &ds;
  pd.multisample.count = 1;
  pd.multisample.mask = 0xFFFFFFFFu;
  P->pipe = wgpuDeviceCreateRenderPipeline(g.device, &pd);
  wgpuPipelineLayoutRelease(pl);
  wgpuShaderModuleRelease(mod);
  if (!P->pipe) { *err = "pipeline failed\n" + g.error_log; return false; }

  {   // compute check pipeline (auto layout)
    const std::string csrc = std::string(kWgslCommon) + kWgslLodCheck;
    WGPUShaderSourceWGSL cs = WGPU_SHADER_SOURCE_WGSL_INIT;
    cs.code = SV(csrc.c_str());
    WGPUShaderModuleDescriptor cmd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    cmd.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&cs);
    WGPUShaderModule cmod = wgpuDeviceCreateShaderModule(g.device, &cmd);
    WGPUComputePipelineDescriptor cpd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    cpd.compute.module = cmod;
    cpd.compute.entryPoint = SV("cs_lod");
    P->lodcheck = wgpuDeviceCreateComputePipeline(g.device, &cpd);
    wgpuShaderModuleRelease(cmod);
  }
  P->vn = MakeBuffer((uint64_t)kMaxVN * 16,
      (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));

  P->frame_u = MakeBuffer(sizeof(FrameU),
      (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));
  P->node_u = MakeBuffer((uint64_t)kMaxDrawNodes * kSlotBytes,
      (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));

  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.dimension = WGPUTextureDimension_2D;
  td.size = WGPUExtent3D{w, h, 1};
  td.format = WGPUTextureFormat_RGBA8Unorm;
  td.mipLevelCount = 1; td.sampleCount = 1;
  td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc);
  P->color = wgpuDeviceCreateTexture(g.device, &td);
  td.format = WGPUTextureFormat_Depth32Float;
  td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc);
  P->depth = wgpuDeviceCreateTexture(g.device, &td);
  WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
  P->color_v = wgpuTextureCreateView(P->color, &vd);
  P->depth_v = wgpuTextureCreateView(P->depth, &vd);

  P->qslots = qslots;
  if (g.has_timestamp && qslots > 0) {
    WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
    qd.type = WGPUQueryType_Timestamp; qd.count = 2;
    P->qs = wgpuDeviceCreateQuerySet(g.device, &qd);
    P->resolve = MakeBuffer((uint64_t)qslots * 256ull,
        (WGPUBufferUsage)(WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc));
    P->qstage = MakeBuffer((uint64_t)qslots * 256ull,
        (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  }
  return true;
}

// ─── camera (row-major, WebGPU clip z in [0,1]) ─────────────────────────
// lookAt / perspective are the LOD library's own test helpers
// (tests/pointcloud_lod/test_select.cpp), so the bench and the library's
// host tests hand selectVisible() the identical convention.
Vec3 Norm(Vec3 v) { const double l = v.length(); return l > 0 ? Vec3{v.x/l, v.y/l, v.z/l} : v; }
Vec3 Cross(Vec3 a, Vec3 b) { return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}; }
double Dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vec3 Lerp(Vec3 a, Vec3 b, double t) { return a + (b - a) * t; }

void Mul(const double a[16], const double b[16], double o[16]) {
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      double s = 0;
      for (int k = 0; k < 4; k++) s += a[r*4+k] * b[k*4+c];
      o[r*4+c] = s;
    }
}

struct Pose { Vec3 eye, target; };

struct CamState {
  Camera cam;         // for selectVisible
  double vp[16];      // row-major
  double cam_dist = 1;
};

CamState MakeCam(const Pose& ps, int w, int h, double zn, double zf) {
  CamState cs;
  const double fov = 60.0;
  const Vec3 f = Norm(ps.target - ps.eye);
  const Vec3 s = Norm(Cross(f, {0, 1, 0}));
  const Vec3 u = Cross(s, f);
  const double v[16] = { s.x,  s.y,  s.z, -Dot(s, ps.eye),
                         u.x,  u.y,  u.z, -Dot(u, ps.eye),
                        -f.x, -f.y, -f.z,  Dot(f, ps.eye),
                         0, 0, 0, 1};
  const double t = 1.0 / std::tan(fov * kPi / 180.0 / 2.0);
  const double aspect = double(w) / double(h);
  const double p[16] = { t/aspect, 0, 0, 0,
                         0, t, 0, 0,
                         0, 0, zf/(zn - zf), zn*zf/(zn - zf),
                         0, 0, -1, 0};
  Mul(p, v, cs.vp);
  cs.cam.position = ps.eye;
  cs.cam.fovYDegrees = fov;
  cs.cam.screenHeightPx = h;
  std::memcpy(cs.cam.viewProj, cs.vp, sizeof cs.vp);
  cs.cam_dist = (ps.target - ps.eye).length();
  return cs;
}

// ─── trajectory ──────────────────────────────────────────────────────────
// Deterministic in the FRAME INDEX (not wall time), so every arm sees exactly
// the same sequence of poses no matter how fast it renders. c / R are the
// content frame (ContentFrame below), not the root cube.
//   [0.00,0.10) hold overview          eye = c + (0,0,2R)
//   [0.10,0.30) push in to target leaf  log-distance, smoothstep
//   [0.30,0.40) hold at the leaf        eye = leaf + (0,0,3 r_leaf)  (S2's pose)
//   [0.40,0.48) pull out to orbit start eye = c + (0,0,0.6R)
//   [0.48,0.73) orbit 360 deg about +y  radius 0.6R
//   [0.73,0.78) move to pan start       eye = c + (-0.5R, 0, 0.35R)
//   [0.78,0.93) pan along +x            to c + (+0.5R, 0, 0.35R), looking -z
//   [0.93,1.00) back to overview
struct Traj {
  Vec3 c; double R = 1;
  Vec3 leaf_c; double leaf_r = 0.01;
  int32_t leaf = -1;
};

double Smooth(double t) { t = std::min(std::max(t, 0.0), 1.0); return t*t*(3 - 2*t); }

Pose LogDolly(Vec3 t0, double d0, Vec3 t1, double d1, double s) {
  const Vec3 tg = Lerp(t0, t1, s);
  const double d = std::exp(std::log(d0) + (std::log(d1) - std::log(d0)) * s);
  return {tg + Vec3{0, 0, d}, tg};
}

Pose PoseAt(const Traj& T, double t, const char** seg) {
  const Vec3 c = T.c; const double R = T.R;
  const Pose over{c + Vec3{0, 0, 2.0 * R}, c};
  const Pose leafp{T.leaf_c + Vec3{0, 0, 3.0 * T.leaf_r}, T.leaf_c};
  const Pose orb0{c + Vec3{0, 0, 0.6 * R}, c};
  const Pose pan0{c + Vec3{-0.5 * R, 0, 0.35 * R}, c + Vec3{-0.5 * R, 0, 0}};
  const Pose pan1{c + Vec3{ 0.5 * R, 0, 0.35 * R}, c + Vec3{ 0.5 * R, 0, 0}};
  auto seg_t = [&](double a, double b) { return (t - a) / (b - a); };
  if (t < 0.10) { *seg = "hold_overview"; return over; }
  if (t < 0.30) { *seg = "push_in";
    return LogDolly(c, 2.0 * R, T.leaf_c, 3.0 * T.leaf_r, Smooth(seg_t(0.10, 0.30))); }
  if (t < 0.40) { *seg = "hold_leaf"; return leafp; }
  if (t < 0.48) { *seg = "pull_out";
    return LogDolly(T.leaf_c, 3.0 * T.leaf_r, c, 0.6 * R, Smooth(seg_t(0.40, 0.48))); }
  if (t < 0.73) { *seg = "orbit";
    const double th = 2.0 * kPi * seg_t(0.48, 0.73);
    return {c + Vec3{0.6 * R * std::sin(th), 0, 0.6 * R * std::cos(th)}, c}; }
  if (t < 0.78) { *seg = "to_pan";
    const double s = Smooth(seg_t(0.73, 0.78));
    return {Lerp(orb0.eye, pan0.eye, s), Lerp(orb0.target, pan0.target, s)}; }
  if (t < 0.93) { *seg = "pan";
    const double s = seg_t(0.78, 0.93);
    return {Lerp(pan0.eye, pan1.eye, s), Lerp(pan0.target, pan1.target, s)}; }
  *seg = "back_to_overview";
  const double s = Smooth(seg_t(0.93, 1.0));
  return {Lerp(pan1.eye, over.eye, s), Lerp(pan1.target, over.target, s)};
}

void NearFar(const Traj& T, const Pose& p, double* zn, double* zf) {
  const double d = (p.target - p.eye).length();
  *zn = std::max(1e-4 * T.R, 0.01 * d);
  *zf = 20.0 * T.R;                                 // test_select.cpp's R*20
}

// ─── LOD renderer state ─────────────────────────────────────────────────
struct GpuNode {
  WGPUBuffer buf = nullptr;
  WGPUBindGroup bg = nullptr;
  uint32_t count = 0;
  uint64_t bytes = 0;
  uint64_t last_used = 0;
  Vec3 origin;
  double density = 0;     // Potree's per-node density (NodePoints::density)
};

enum class LoadMode { Sync, Async };

struct Lod {
  const Octree* oct = nullptr;
  std::string bin_path;
  LoadMode mode = LoadMode::Sync;
  std::unique_ptr<NodeLoader> loader;          // Sync
  std::unique_ptr<AsyncNodeLoader> aloader;    // Async
  int max_nodes_loading = 4;                   // Potree.js:104
  size_t cache_bytes = 0;
  std::unordered_map<int32_t, GpuNode> gpu;
  uint64_t gpu_bytes = 0, gpu_budget = 0;
  uint64_t frame_no = 0;
  // lifetime counters (reset per block)
  int64_t uploads = 0, evictions = 0;
};

void ReleaseNode(GpuNode& n) {
  if (n.bg) wgpuBindGroupRelease(n.bg);
  if (n.buf) { wgpuBufferDestroy(n.buf); wgpuBufferRelease(n.buf); }
  n.bg = nullptr; n.buf = nullptr;
}

void ResetLod(Lod* L, size_t cache_bytes, LoadMode mode = LoadMode::Sync) {
  L->aloader.reset();                          // joins its workers first
  L->loader.reset();
  for (auto& kv : L->gpu) ReleaseNode(kv.second);
  L->gpu.clear();
  L->gpu_bytes = 0;
  L->cache_bytes = cache_bytes;
  L->mode = mode;
  // Sync: GPU record is 16 B/point vs the decoded 15 B/point; scale the mirror
  // budget so the GPU ledger evicts at the same point count as NodeCache does.
  // Async: GPU copies follow the library's drainEvicted() exactly (no mirror).
  L->gpu_budget = (uint64_t)((double)cache_bytes * 16.0 / 15.0);
  if (mode == LoadMode::Sync) {
    L->loader.reset(new NodeLoader(*L->oct, L->bin_path, cache_bytes));
  } else {
    AsyncNodeLoader::Config cfg;
    cfg.cacheBytes = cache_bytes;
    cfg.maxNodesLoading = L->max_nodes_loading;
    cfg.workers = L->max_nodes_loading;
    L->aloader.reset(new AsyncNodeLoader(*L->oct, L->bin_path, cfg));
  }
  L->uploads = 0; L->evictions = 0;
}

// Plumbing only: turn one decoded node into a 16-B/point storage buffer.
GpuNode Upload(const Pipe& P, const NodePoints& np) {
  GpuNode gn;
  const size_t n = np.count();
  gn.count = (uint32_t)n;
  gn.origin = np.origin;
  gn.density = np.density;
  std::vector<CPoint> tmp(std::max<size_t>(n, 1));
  for (size_t i = 0; i < n; ++i) {
    tmp[i].x = np.xyz[i*3+0]; tmp[i].y = np.xyz[i*3+1]; tmp[i].z = np.xyz[i*3+2];
    tmp[i].rgba = (uint32_t)np.rgb[i*3+0] | ((uint32_t)np.rgb[i*3+1] << 8) |
                  ((uint32_t)np.rgb[i*3+2] << 16) | (255u << 24);
  }
  gn.bytes = (uint64_t)tmp.size() * sizeof(CPoint);
  gn.buf = MakeBuffer(gn.bytes, (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
  wgpuQueueWriteBuffer(g.queue, gn.buf, 0, tmp.data(), gn.bytes);
  WGPUBindGroupEntry be[4];
  for (auto& x : be) x = WGPU_BIND_GROUP_ENTRY_INIT;
  be[0].binding = 0; be[0].buffer = P.frame_u; be[0].size = sizeof(FrameU);
  be[1].binding = 1; be[1].buffer = P.node_u;  be[1].size = sizeof(NodeU);
  be[2].binding = 2; be[2].buffer = gn.buf;    be[2].size = gn.bytes;
  be[3].binding = 3; be[3].buffer = P.vn;      be[3].size = (uint64_t)kMaxVN * 16;
  WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
  bd.layout = P.bgl; bd.entryCount = 4; bd.entries = be;
  gn.bg = wgpuDeviceCreateBindGroup(g.device, &bd);
  return gn;
}

// Sync mode only: evict GPU nodes least-recently drawn first, never one drawn
// this frame (mirror of NodeCache's LRU, which exposes no eviction events there).
void EvictGpu(Lod* L) {
  if (L->gpu_bytes <= L->gpu_budget) return;
  std::vector<std::pair<uint64_t, int32_t>> cand;
  for (auto& kv : L->gpu)
    if (kv.second.last_used < L->frame_no) cand.push_back({kv.second.last_used, kv.first});
  std::sort(cand.begin(), cand.end());
  for (auto& c : cand) {
    if (L->gpu_bytes <= L->gpu_budget) break;
    auto it = L->gpu.find(c.second);
    L->gpu_bytes -= it->second.bytes;
    ReleaseNode(it->second);
    L->gpu.erase(it);
    L->evictions++;
  }
}

// ─── Potree visible-node table (PointCloudOctree.js:321-391) ───────────────
// Deviations of the adaptive point size port:
//   P1  a storage buffer of vec4<u32> (mask, offsetToFirstChild, lodByte, 0)
//       instead of a 2048x1 RGBA8 texture: exact integers, no 2048-node cap,
//       no 16-bit wrap of the child offset (:364-365 store it in two bytes).
//   P2  our points are stored relative to the node CENTRE (PR #98 D-float);
//       Potree's are relative to the node's box min (DecoderWorker.js:69-71,
//       PointCloudOctree.js:213) -- the shader adds half the node size back.
//   P3  pointcloud.vs:672-676 `scale` is 1 here (node transform = translation).
//   P4  gl_PointSize is a diameter; this quad path takes a half-size -> /2.
//   P5  the table covers the drawn nodes AND their ancestors: our selection
//       leaves out 0-point nodes, which Potree keeps as tree nodes; without
//       them a child could not be found from its grandparent.
//   P6  getLOD runs per quad VERTEX (6x per point) -- Potree runs it once per
//       GL point. Same value; 6x the arithmetic.
struct VNTable {
  std::vector<uint32_t> data;                    // 4 per entry
  std::unordered_map<int32_t, uint32_t> offset;  // node -> entry index
  bool truncated = false;
};

uint32_t LodByte(double density) {
  // :368-378 -- NaN / non-number density -> 100; else Uint8 of (lodOffset+10)*10
  if (!(density > 0) || std::isnan(density)) return 100;
  const double lodOffset = std::log2(density) / 2.0 - 1.5;           // :371
  const double v = (lodOffset + 10.0) * 10.0;                         // :373
  // Uint8Array store: ToUint8 truncates toward zero, then modulo 256
  const long long t = (long long)std::trunc(v);
  return (uint32_t)(((t % 256) + 256) % 256);
}

VNTable BuildVisibleNodeTable(const Octree& oct, const std::vector<int32_t>& drawn,
                              const std::unordered_map<int32_t, GpuNode>& gpu) {
  VNTable t;
  std::vector<int32_t> nodes;
  {
    std::unordered_map<int32_t, bool> seen;
    for (int32_t n : drawn)
      for (int32_t a = n; a >= 0 && !seen.count(a); a = oct.nodes[(size_t)a].parent) {
        seen[a] = true;
        nodes.push_back(a);
      }
  }
  // :332-340 sort by name length, then name
  std::sort(nodes.begin(), nodes.end(), [&](int32_t a, int32_t b) {
    const std::string& na = oct.nodes[(size_t)a].name;
    const std::string& nb = oct.nodes[(size_t)b].name;
    if (na.size() != nb.size()) return na.size() < nb.size();
    return na < nb;
  });
  if (nodes.size() > kMaxVN) { nodes.resize(kMaxVN); t.truncated = true; }
  t.data.assign(nodes.size() * 4, 0u);
  std::vector<uint32_t> offsetsToChild(nodes.size(), 0xFFFFFFFFu);    // :345 Infinity
  for (size_t i = 0; i < nodes.size(); ++i) {
    const int32_t n = nodes[i];
    t.offset[n] = (uint32_t)i;                                         // :351
    if (i > 0) {                                                       // :353
      const std::string& name = oct.nodes[(size_t)n].name;
      const int index = name.back() - '0';                             // :354
      const auto pit = t.offset.find(oct.nodes[(size_t)n].parent);     // :355-357
      if (pit != t.offset.end() && index >= 0 && index < 8) {
        const uint32_t po = pit->second;
        const uint32_t parentOffsetToChild = (uint32_t)i - po;         // :359
        offsetsToChild[po] = std::min(offsetsToChild[po], parentOffsetToChild);   // :361
        t.data[po * 4 + 0] |= (1u << index);                           // :363
        t.data[po * 4 + 1] = offsetsToChild[po];                       // :364-365 (P1: not split)
      }
    }
    const auto git = gpu.find(n);
    t.data[i * 4 + 2] = LodByte(git != gpu.end() ? git->second.density : 0.0);   // :368-378
  }
  return t;
}

// CPU transliteration of the WGSL getLOD (same float32 arithmetic order).
float CpuGetLOD(const VNTable& t, float octreeSize, float uLevel, int uVNStart, const float pos[3]) {
  auto numberOfOnes = [](int number, int index) {
    int numOnes = 0, tmp = 128;
    for (int i = 7; i >= 0; i--) {
      if (number >= tmp) { number -= tmp; if (i <= index) numOnes++; }
      tmp /= 2;
    }
    return numOnes;
  };
  auto isBitSet = [](int number, int index) {
    if (index < 0 || index > 7) return false;
    return ((number / (1 << index)) % 2) != 0;
  };
  float offset[3] = {0, 0, 0};
  int iOffset = uVNStart;
  float depth = uLevel;
  for (float i = 0.0f; i <= 30.0f; i += 1.0f) {
    const float nodeSizeAtLevel = octreeSize / std::pow(2.0f, i + uLevel + 0.0f);
    float idx3[3];
    for (int k = 0; k < 3; ++k) idx3[k] = std::floor((pos[k] - offset[k]) / nodeSizeAtLevel + 0.5f);
    const int index = (int)std::round(4.0f * idx3[0] + 2.0f * idx3[1] + idx3[2]);
    if (iOffset < 0 || (size_t)iOffset * 4 + 3 >= t.data.size()) return -1000.0f;
    const int mask = (int)t.data[(size_t)iOffset * 4 + 0];
    if (isBitSet(mask, index)) {
      iOffset += (int)t.data[(size_t)iOffset * 4 + 1] + numberOfOnes(mask, index - 1);
      depth += 1.0f;
    } else {
      return depth + ((float)t.data[(size_t)iOffset * 4 + 2] / 10.0f - 10.0f);
    }
    for (int k = 0; k < 3; ++k) offset[k] += nodeSizeAtLevel * 0.5f * idx3[k];
  }
  return depth;
}

struct DrawOpts {
  int32_t skip_node = -1;     // negative control: leave one node out
  int32_t only_node = -1;     // leaf-only render
  bool no_origin = false;     // negative control: forget to add the origin back
  bool keep_depth = false;    // store the depth attachment (for readback)
  int psize_mode = 0;         // 0 production formula, 1 Potree ADAPTIVE
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
};

struct FrameCtx { Lod* L; };
NodeState ResidencyState(int32_t n, void* ctx) {
  Lod* L = static_cast<Lod*>(ctx);
  if (L->gpu.count(n)) return NodeState::Drawable;
  return L->aloader->state(n);
}

// Frame parameters that only the draw needs.
struct DrawParams {
  double base_scale = 1.5;
  double octree_size = 1, octree_spacing = 1;
};

// One LOD frame: select -> load -> upload -> draw. Every stage timed.
FrameRec LodFrame(Lod* L, Pipe* P, const CamState& cs, const SelectParams& sp,
                  const DrawParams& dp, int32_t target, uint32_t qslot,
                  const DrawOpts& opt = DrawOpts()) {
  FrameRec fr;
  fr.px = sp.minimumNodePixelSize;
  L->frame_no++;
  const double t0 = NowMs();
  double t1 = t0, t2 = t0, t3 = t0;
  std::vector<int32_t> drawIds;

  if (L->mode == LoadMode::Sync) {
    const Selection sel = selectVisible(*L->oct, cs.cam, sp);
    t1 = NowMs();
    NodeLoader::Stats st;
    const std::vector<const NodePoints*> nodes = L->loader->load(sel, &st);
    t2 = NowMs();
    fr.nodes_sel = (int)sel.nodes.size();
    fr.pts_sel = sel.numPoints;
    fr.hit_budget = sel.hitBudget;
    fr.dropped = (int)st.droppedForCache;          // library now reports the silent drop
    fr.decoded = st.nodesDecoded; fr.reads = st.reads;
    fr.bytes_read = st.bytesRead; fr.short_reads = st.shortReads;
    for (int32_t n : sel.nodes) {
      fr.max_level = std::max(fr.max_level, L->oct->nodes[(size_t)n].level);
      if (n == target) fr.target_selected = true;
    }
    for (const NodePoints* np : nodes) {
      auto it = L->gpu.find(np->node);
      if (it == L->gpu.end()) {
        GpuNode gn = Upload(*P, *np);
        L->gpu_bytes += gn.bytes;
        it = L->gpu.emplace(np->node, gn).first;
        fr.uploads++; L->uploads++;
      }
      drawIds.push_back(np->node);
    }
    t3 = NowMs();
  } else {
    // Potree order: finished loads arrive (promise resolution), evicted
    // geometry is disposed, then updateVisibility, then the loads it asked for.
    const auto& st0 = L->aloader->stats();
    const int64_t done0 = st0.loadsCompleted, bytes0 = st0.bytesRead;
    L->aloader->poll();
    for (int32_t n : L->aloader->drainEvicted()) {
      auto it = L->gpu.find(n);
      if (it != L->gpu.end()) {
        L->gpu_bytes -= it->second.bytes;
        ReleaseNode(it->second);
        L->gpu.erase(it);
        L->evictions++;
      }
    }
    fr.decoded = L->aloader->stats().loadsCompleted - done0;
    fr.bytes_read = L->aloader->stats().bytesRead - bytes0;
    t1 = NowMs();
    Residency res;
    res.state = &ResidencyState;
    res.ctx = L;
    const Selection sel = selectVisible(*L->oct, cs.cam, sp, res);
    t2 = NowMs();
    for (int32_t n : sel.promoted) {               // <= 2 per frame
      const NodePoints* np = L->aloader->touch(n);
      if (!np) continue;
      GpuNode gn = Upload(*P, *np);
      L->gpu_bytes += gn.bytes;
      L->gpu.emplace(n, gn);
      fr.uploads++; L->uploads++;
    }
    for (int32_t n : sel.nodes) {
      L->aloader->touch(n);                        // Potree_update_visibility.js:310
      if (L->gpu.count(n)) drawIds.push_back(n);
    }
    L->aloader->request(sel.unloaded);
    fr.nodes_sel = (int)sel.nodes.size();
    fr.pts_sel = sel.numPoints;
    fr.hit_budget = sel.hitBudget;
    fr.dropped = (int)sel.nodes.size() - (int)drawIds.size();   // must stay 0
    fr.pending_nodes = (int)sel.unloaded.size();
    for (int32_t n : sel.unloaded) fr.pending_pts += L->oct->nodes[(size_t)n].numPoints;
    fr.in_flight = L->aloader->numNodesLoading();
    for (int32_t n : sel.nodes) {
      fr.max_level = std::max(fr.max_level, L->oct->nodes[(size_t)n].level);
      if (n == target) fr.target_selected = true;
    }
    t3 = NowMs();
  }

  std::vector<std::pair<int32_t, GpuNode*>> draw;
  draw.reserve(drawIds.size());
  for (int32_t n : drawIds) {
    if (opt.skip_node >= 0 && n == opt.skip_node) continue;
    if (opt.only_node >= 0 && n != opt.only_node) continue;
    GpuNode& gn = L->gpu[n];
    gn.last_used = L->frame_no;
    draw.push_back({n, &gn});
    if (n == target) fr.target_drawn = true;
  }
  if (draw.size() > kMaxDrawNodes) { draw.resize(kMaxDrawNodes); fr.truncated = true; }
  if (opt.out_drawn) { opt.out_drawn->clear(); for (auto& d : draw) opt.out_drawn->push_back(d.first); }

  // visible-node table for the adaptive point size (PointCloudOctree.js:321-391)
  VNTable vt;
  if (opt.psize_mode == 1) {
    std::vector<int32_t> ids;
    for (auto& d : draw) ids.push_back(d.first);
    vt = BuildVisibleNodeTable(*L->oct, ids, L->gpu);
    if (vt.truncated) fr.truncated = true;
    fr.vn_entries = (int)(vt.data.size() / 4);
    if (!vt.data.empty()) wgpuQueueWriteBuffer(g.queue, P->vn, 0, vt.data.data(), vt.data.size() * 4);
  }

  // per-frame uniforms
  FrameU fu{};
  fu.img_size[0] = (float)P->w; fu.img_size[1] = (float)P->h;
  fu.base_scale = (float)dp.base_scale; fu.cam_dist = (float)cs.cam_dist;
  fu.r_min = 0.0f; fu.r_max = 64.0f;
  fu.tan_half_fov = (float)std::tan(cs.cam.fovYDegrees * kPi / 180.0 / 2.0);
  fu.octree_size = (float)dp.octree_size;
  fu.octree_spacing = (float)dp.octree_spacing;
  fu.psize = 1.0f; fu.min_size = 2.0f; fu.max_size = 50.0f;   // PointCloudMaterial.js:32-34
  fu.mode = (uint32_t)opt.psize_mode;
  wgpuQueueWriteBuffer(g.queue, P->frame_u, 0, &fu, sizeof fu);
  if (!draw.empty()) {
    std::vector<uint8_t> slots(draw.size() * kSlotBytes, 0);
    for (size_t i = 0; i < draw.size(); ++i) {
      const int32_t n = draw[i].first;
      const Node& nd = L->oct->nodes[(size_t)n];
      const Vec3 o = opt.no_origin ? Vec3{0, 0, 0} : draw[i].second->origin;
      const double T[16] = {1, 0, 0, o.x,  0, 1, 0, o.y,  0, 0, 1, o.z,  0, 0, 0, 1};
      double M[16];
      Mul(cs.vp, T, M);                     // double precision, then cast
      NodeU nu{};
      for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) nu.mvp[c*4 + r] = (float)M[r*4 + c];   // WGSL is column-major
      nu.level = (float)nd.level;                                          // PotreeRenderer.js:815
      const auto vit = vt.offset.find(n);
      nu.vn_start = vit != vt.offset.end() ? (float)vit->second : 0.0f;    // PotreeRenderer.js:729-730
      nu.half_size = (float)(0.5 * nd.box.size().x);
      std::memcpy(slots.data() + i * kSlotBytes, &nu, sizeof nu);
    }
    wgpuQueueWriteBuffer(g.queue, P->node_u, 0, slots.data(), slots.size());
  }

  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
  ca.view = P->color_v;
  ca.loadOp = WGPULoadOp_Clear; ca.storeOp = WGPUStoreOp_Store;
  ca.clearValue = WGPUColor{0, 0, 0, 0};
  ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
  WGPURenderPassDepthStencilAttachment da = WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
  da.view = P->depth_v;
  da.depthLoadOp = WGPULoadOp_Clear;
  da.depthStoreOp = opt.keep_depth ? WGPUStoreOp_Store : WGPUStoreOp_Discard;
  da.depthClearValue = 1.0f;
  da.depthReadOnly = 0;
  const bool timed = P->qs && qslot < P->qslots;
  WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT;
  if (timed) { tw.querySet = P->qs; tw.beginningOfPassWriteIndex = 0; tw.endOfPassWriteIndex = 1; }
  WGPURenderPassDescriptor pd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
  pd.colorAttachmentCount = 1; pd.colorAttachments = &ca;
  pd.depthStencilAttachment = &da;
  pd.timestampWrites = timed ? &tw : nullptr;
  WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &pd);
  wgpuRenderPassEncoderSetPipeline(pass, P->pipe);
  for (size_t i = 0; i < draw.size(); ++i) {
    const uint32_t off = (uint32_t)(i * kSlotBytes);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, draw[i].second->bg, 1, &off);
    wgpuRenderPassEncoderDraw(pass, 6u * draw[i].second->count, 1, 0, 0);
    fr.pts_drawn += draw[i].second->count;
  }
  fr.nodes_drawn = (int)draw.size();
  wgpuRenderPassEncoderEnd(pass);
  wgpuRenderPassEncoderRelease(pass);
  if (timed) wgpuCommandEncoderResolveQuerySet(enc, P->qs, 0, 2, P->resolve, (uint64_t)qslot * 256ull);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  WaitQueueIdle();
  const double t4 = NowMs();

  if (L->mode == LoadMode::Sync) EvictGpu(L);
  const double t5 = NowMs();

  fr.sel = t1 - t0; fr.load = t2 - t1; fr.upload = t3 - t2; fr.render = t4 - t3;
  if (L->mode == LoadMode::Async) { fr.load = t1 - t0; fr.sel = t2 - t1; }   // load = poll + dispose
  fr.wall = t5 - t0;
  return fr;
}

std::vector<double> ReadGpuMs(Pipe* P, uint32_t count) {
  std::vector<double> out(count, -1.0);
  if (!P->qs || count == 0) return out;
  count = std::min(count, P->qslots);
  const uint64_t bytes = (uint64_t)count * 256ull;
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  wgpuCommandEncoderCopyBufferToBuffer(enc, P->resolve, 0, P->qstage, 0, bytes);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  bool ok = false;
  WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  mi.mode = WGPUCallbackMode_WaitAnyOnly;
  mi.callback = [](WGPUMapAsyncStatus st, WGPUStringView, void* u, void*) {
    *static_cast<bool*>(u) = (st == WGPUMapAsyncStatus_Success);
  };
  mi.userdata1 = &ok;
  WaitFuture(wgpuBufferMapAsync(P->qstage, WGPUMapMode_Read, 0, bytes, mi));
  if (ok) {
    const uint8_t* p = static_cast<const uint8_t*>(wgpuBufferGetConstMappedRange(P->qstage, 0, bytes));
    if (p) for (uint32_t i = 0; i < count; ++i) {
      uint64_t a, b;
      std::memcpy(&a, p + (size_t)i * 256 + 0, 8);
      std::memcpy(&b, p + (size_t)i * 256 + 8, 8);
      if (b > a) out[i] = (double)(b - a) / 1.0e6;
    }
    wgpuBufferUnmap(P->qstage);
  }
  return out;
}

// ─── image readback + criteria that can fail ─────────────────────────────
// Coverage alone lets a flat grey frame pass; so mean saturation and the
// per-channel standard deviation are reported and judged too.
struct Img {
  std::vector<uint8_t> px;   // tightly packed RGBA, w*h*4
  uint32_t w = 0, h = 0;
};
struct ImgStat {
  uint64_t hash = 0;
  double cover = 0, sat_mean = 0;
  double mean[3] = {0, 0, 0}, sd[3] = {0, 0, 0};
};

Img Readback(Pipe* P) {
  Img im; im.w = P->w; im.h = P->h;
  const uint32_t bpr = ((P->w * 4u) + 255u) / 256u * 256u;
  const uint64_t bytes = (uint64_t)bpr * P->h;
  WGPUBuffer stage = MakeBuffer(bytes, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
  src.texture = P->color;
  WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
  dst.buffer = stage; dst.layout.offset = 0;
  dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = P->h;
  WGPUExtent3D ext{P->w, P->h, 1};
  wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  bool ok = false;
  WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  mi.mode = WGPUCallbackMode_WaitAnyOnly;
  mi.callback = [](WGPUMapAsyncStatus s, WGPUStringView, void* u, void*) {
    *static_cast<bool*>(u) = (s == WGPUMapAsyncStatus_Success);
  };
  mi.userdata1 = &ok;
  WaitFuture(wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
  if (ok) {
    const uint8_t* p = static_cast<const uint8_t*>(wgpuBufferGetConstMappedRange(stage, 0, bytes));
    if (p) {
      im.px.resize((size_t)P->w * P->h * 4);
      for (uint32_t y = 0; y < P->h; ++y)
        std::memcpy(im.px.data() + (size_t)y * P->w * 4, p + (size_t)y * bpr, (size_t)P->w * 4);
    }
    wgpuBufferUnmap(stage);
  }
  wgpuBufferDestroy(stage);
  wgpuBufferRelease(stage);
  return im;
}

ImgStat Stat(const Img& im) {
  ImgStat s;
  if (im.px.empty()) return s;
  s.hash = Fnv1a(im.px.data(), im.px.size());
  const size_t n = (size_t)im.w * im.h;
  double s1[3] = {0, 0, 0}, s2[3] = {0, 0, 0}, sat = 0;
  size_t cov = 0;
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* q = &im.px[i * 4];
    for (int c = 0; c < 3; ++c) { s1[c] += q[c]; s2[c] += (double)q[c] * q[c]; }
    if (q[3]) {
      ++cov;
      const int mx = std::max(q[0], std::max(q[1], q[2]));
      const int mn = std::min(q[0], std::min(q[1], q[2]));
      if (mx > 0) sat += double(mx - mn) / double(mx);
    }
  }
  s.cover = double(cov) / double(n);
  s.sat_mean = cov ? sat / double(cov) : 0.0;
  for (int c = 0; c < 3; ++c) {
    s.mean[c] = s1[c] / double(n);
    const double v = s2[c] / double(n) - s.mean[c] * s.mean[c];
    s.sd[c] = v > 0 ? std::sqrt(v) : 0.0;
  }
  return s;
}

// frac: pixels differing by >8 in any channel (or in coverage); psnr: full
// resolution; psnr4: after 4x4 box averaging (structure, not 1-px sprite noise).
struct Diff { double frac = 0; double psnr = 0; double psnr4 = 0; uint64_t pixels = 0; };
Diff ImgDiff(const Img& a, const Img& b) {
  Diff d;
  if (a.px.size() != b.px.size() || a.px.empty()) { d.frac = 1; return d; }
  const size_t n = (size_t)a.w * a.h;
  {
    const uint32_t bw = a.w / 4, bh = a.h / 4;
    double se4 = 0;
    for (uint32_t by = 0; by < bh; ++by)
      for (uint32_t bx = 0; bx < bw; ++bx)
        for (int c = 0; c < 3; ++c) {
          double sa = 0, sb = 0;
          for (uint32_t y = 0; y < 4; ++y)
            for (uint32_t x = 0; x < 4; ++x) {
              const size_t o = ((size_t)(by * 4 + y) * a.w + bx * 4 + x) * 4 + c;
              sa += a.px[o]; sb += b.px[o];
            }
          const double v = (sa - sb) / 16.0;
          se4 += v * v;
        }
    const double mse4 = se4 / (double(bw) * bh * 3);
    d.psnr4 = mse4 > 0 ? 10.0 * std::log10(255.0 * 255.0 / mse4) : 99.0;
  }
  double se = 0;
  for (size_t i = 0; i < n; ++i) {
    bool any = false;
    for (int c = 0; c < 3; ++c) {
      const int v = (int)a.px[i*4+c] - (int)b.px[i*4+c];
      se += double(v) * v;
      if (std::abs(v) > 8) any = true;
    }
    if (a.px[i*4+3] != b.px[i*4+3]) any = true;
    if (any) ++d.pixels;
  }
  d.frac = double(d.pixels) / double(n);
  const double mse = se / double(n * 3);
  d.psnr = mse > 0 ? 10.0 * std::log10(255.0 * 255.0 / mse) : 99.0;
  return d;
}

bool DetailPreserved(const Diff& lod, const Diff& fl) {
  return lod.frac <= std::max(1.25 * fl.frac, fl.frac + 0.005) && lod.psnr >= fl.psnr - 1.0;
}

// Depth32Float readback (aspect DepthOnly) -> NDC depth per pixel.
std::vector<float> ReadDepth(Pipe* P) {
  std::vector<float> out;
  const uint32_t bpr = ((P->w * 4u) + 255u) / 256u * 256u;
  const uint64_t bytes = (uint64_t)bpr * P->h;
  WGPUBuffer stage = MakeBuffer(bytes, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
  src.texture = P->depth;
  src.aspect = WGPUTextureAspect_DepthOnly;
  WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
  dst.buffer = stage; dst.layout.offset = 0;
  dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = P->h;
  WGPUExtent3D ext{P->w, P->h, 1};
  wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  bool ok = false;
  WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  mi.mode = WGPUCallbackMode_WaitAnyOnly;
  mi.callback = [](WGPUMapAsyncStatus s2, WGPUStringView, void* u, void*) {
    *static_cast<bool*>(u) = (s2 == WGPUMapAsyncStatus_Success);
  };
  mi.userdata1 = &ok;
  WaitFuture(wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
  if (ok) {
    const uint8_t* p = static_cast<const uint8_t*>(wgpuBufferGetConstMappedRange(stage, 0, bytes));
    if (p) {
      out.resize((size_t)P->w * P->h);
      for (uint32_t y = 0; y < P->h; ++y)
        std::memcpy(out.data() + (size_t)y * P->w, p + (size_t)y * bpr, (size_t)P->w * 4);
    }
    wgpuBufferUnmap(stage);
  }
  wgpuBufferDestroy(stage);
  wgpuBufferRelease(stage);
  return out;
}

// "See-through" judge. Over the pixels the REFERENCE covers: a hole = the test
// frame has nothing there; see-through = the test frame shows a surface more
// than 5% farther than the reference's (i.e. something behind the true front
// surface). Depth is linearised from NDC with the pose's near/far.
struct SeeThrough { double hole = 0, farther = 0, bad = 0; uint64_t ref_px = 0; };
SeeThrough SeeThroughVs(const Img& ti, const std::vector<float>& td, const Img& ri,
                        const std::vector<float>& rd, double zn, double zf) {
  SeeThrough r;
  if (ti.px.size() != ri.px.size() || td.size() != rd.size() || rd.empty()) { r.bad = 1; return r; }
  auto lin = [&](float ndc) { return zf * zn / (zf - (double)ndc * (zf - zn)); };
  uint64_t hole = 0, far = 0;
  for (size_t i = 0; i < rd.size(); ++i) {
    if (!ri.px[i * 4 + 3]) continue;
    r.ref_px++;
    if (!ti.px[i * 4 + 3]) { hole++; continue; }
    if (lin(td[i]) > lin(rd[i]) * 1.05) far++;
  }
  if (r.ref_px) {
    r.hole = double(hole) / double(r.ref_px);
    r.farther = double(far) / double(r.ref_px);
    r.bad = double(hole + far) / double(r.ref_px);
  }
  return r;
}

std::string SeeJson(const SeeThrough& s) {
  char b[160];
  std::snprintf(b, sizeof b, "{\"hole\": %.4f, \"farther\": %.4f, \"bad\": %.4f, \"ref_px\": %llu}",
                s.hole, s.farther, s.bad, (unsigned long long)s.ref_px);
  return b;
}

void SavePpm(const std::string& path, const Img& im) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return;
  std::fprintf(f, "P6\n%u %u\n255\n", im.w, im.h);
  std::vector<uint8_t> row((size_t)im.w * 3);
  for (uint32_t y = 0; y < im.h; ++y) {
    for (uint32_t x = 0; x < im.w; ++x)
      for (int c = 0; c < 3; ++c) row[x*3+c] = im.px[((size_t)y * im.w + x) * 4 + c];
    std::fwrite(row.data(), 1, row.size(), f);
  }
  std::fclose(f);
}

std::string StatJson(const ImgStat& s) {
  char b[400];
  std::snprintf(b, sizeof b,
      "{\"hash\":\"%s\",\"coverage\":%.6f,\"sat_mean\":%.4f,\"mean_rgb\":[%.2f,%.2f,%.2f],"
      "\"sd_rgb\":[%.2f,%.2f,%.2f]}",
      Hex64(s.hash).c_str(), s.cover, s.sat_mean, s.mean[0], s.mean[1], s.mean[2],
      s.sd[0], s.sd[1], s.sd[2]);
  return b;
}

double SdMin(const ImgStat& s) { return std::min(s.sd[0], std::min(s.sd[1], s.sd[2])); }

// Pre-registered image criteria (see LOD_DEVICE_PLAN_20260923.md §4.2)
bool ImageNonTrivial(const ImgStat& s) {
  return s.cover > 0.01 && s.sat_mean > 0.05 && SdMin(s) > 10.0;
}
// NOTE (measured on the Mac, 36M, orbit_mid): this global colour check PASSES a
// px=150 frame whose full-res crop visibly loses the print on a box -- it
// cannot see detail loss. It is kept only as a same-scene / not-grey sanity
// check; detail is judged by DetailPreserved() below.
bool ImageMatchesRef(const ImgStat& s, const ImgStat& ref) {
  auto ratio_ok = [](double a, double b) { return b > 0 && a / b >= 0.8 && a / b <= 1.25; };
  return ratio_ok(s.sat_mean, ref.sat_mean) && ratio_ok(SdMin(s), SdMin(ref));
}
// Detail criterion, calibrated per pose by a floor that means "no visible
// change": the reference itself re-rendered with the camera moved 0.25 px.
// A LOD frame preserves detail iff it is no further from the reference than
// that jitter is (frac within 1.25x or +0.5 pp, PSNR within 1 dB). Defined
// next to Diff above.

// ─── getLOD verification ────────────────────────────────────────────────
// Three-way check of the adaptive point size's LOD lookup on real drawn nodes:
//   cpu_vs_bruteforce  CPU transliteration of getLOD (table + index arithmetic)
//                      vs walking the octree's own child boxes and asking the
//                      drawn set directly -- independent formulations
//   gpu_vs_cpu         the WGSL getLOD run in a compute shader vs the CPU copy
//   neg_masks_zeroed   the same CPU check with every child mask cleared: must
//                      disagree with the brute force (the judge can fail)
struct LodCheck {
  int64_t points = 0, cpu_bf_mismatch = 0, gpu_cpu_mismatch = 0, neg_mismatch = 0, gpu_checked = 0;
  double gpu_max_abs = 0;
  int nodes = 0;
};

LodCheck VerifyGetLOD(Lod* L, Pipe* P, const std::vector<int32_t>& drawn, const DrawParams& dp) {
  LodCheck out;
  const Octree& oct = *L->oct;
  const VNTable t = BuildVisibleNodeTable(oct, drawn, L->gpu);
  VNTable neg = t;
  for (size_t i = 0; i < neg.data.size(); i += 4) neg.data[i] = 0;
  std::unordered_map<int32_t, bool> inTable;
  for (auto& kv : t.offset) inTable[kv.first] = true;
  if (!t.data.empty()) wgpuQueueWriteBuffer(g.queue, P->vn, 0, t.data.data(), t.data.size() * 4);

  WGPUBuffer nub = MakeBuffer(sizeof(NodeU), (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));
  const size_t kNodes = std::min<size_t>(drawn.size(), 24);
  for (size_t k = 0; k < kNodes; ++k) {
    const int32_t n = drawn[k];
    const Node& nd = oct.nodes[(size_t)n];
    const NodePoints* np = L->loader ? L->loader->cache().get(n) : L->aloader->touch(n);
    auto git = L->gpu.find(n);
    if (!np || git == L->gpu.end() || np->count() == 0) continue;
    out.nodes++;
    const float half = (float)(0.5 * nd.box.size().x);
    const int vnStart = (int)t.offset.at(n);
    const size_t cnt = np->count();
    std::vector<float> cpu(cnt);
    for (size_t i = 0; i < cnt; ++i) {
      const float pm[3] = {np->xyz[i*3+0] + half, np->xyz[i*3+1] + half, np->xyz[i*3+2] + half};
      cpu[i] = CpuGetLOD(t, (float)dp.octree_size, (float)nd.level, vnStart, pm);
      const float cneg = CpuGetLOD(neg, (float)dp.octree_size, (float)nd.level, vnStart, pm);
      // brute force: descend through the octree's own child boxes while the
      // child that contains the point is in the drawn set (table).
      const Vec3 w{np->origin.x + np->xyz[i*3+0], np->origin.y + np->xyz[i*3+1], np->origin.z + np->xyz[i*3+2]};
      int32_t cur = n;
      for (;;) {
        const Node& cn = oct.nodes[(size_t)cur];
        const Vec3 c = cn.box.center();
        const int oc = ((w.x >= c.x) ? 4 : 0) | ((w.y >= c.y) ? 2 : 0) | ((w.z >= c.z) ? 1 : 0);
        const int32_t ch = cn.children[(size_t)oc];
        if (ch >= 0 && inTable.count(ch)) cur = ch; else break;
      }
      const float bf = (float)oct.nodes[(size_t)cur].level +
                       ((float)t.data[(size_t)t.offset.at(cur) * 4 + 2] / 10.0f - 10.0f);
      if (std::fabs(cpu[i] - bf) > 1e-4f) out.cpu_bf_mismatch++;
      if (std::fabs(cneg - bf) > 1e-4f) out.neg_mismatch++;
      out.points++;
    }
    // GPU: same getLOD text in a compute shader
    NodeU nu{};
    nu.level = (float)nd.level; nu.vn_start = (float)vnStart; nu.half_size = half;
    wgpuQueueWriteBuffer(g.queue, nub, 0, &nu, sizeof nu);
    const uint64_t ob = (uint64_t)cnt * 4;
    WGPUBuffer outb = MakeBuffer(ob, (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc));
    WGPUBuffer stg = MakeBuffer(ob, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
    WGPUBindGroupEntry be[5];
    for (auto& x : be) x = WGPU_BIND_GROUP_ENTRY_INIT;
    be[0].binding = 0; be[0].buffer = P->frame_u; be[0].size = sizeof(FrameU);
    be[1].binding = 1; be[1].buffer = nub;        be[1].size = sizeof(NodeU);
    be[2].binding = 2; be[2].buffer = git->second.buf; be[2].size = git->second.bytes;
    be[3].binding = 3; be[3].buffer = P->vn;      be[3].size = (uint64_t)kMaxVN * 16;
    be[4].binding = 4; be[4].buffer = outb;       be[4].size = ob;
    WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    WGPUBindGroupLayout bgl = wgpuComputePipelineGetBindGroupLayout(P->lodcheck, 0);
    bd.layout = bgl; bd.entryCount = 5; bd.entries = be;
    WGPUBindGroup bg = wgpuDeviceCreateBindGroup(g.device, &bd);
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
    WGPUComputePassDescriptor cpd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
    WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(enc, &cpd);
    wgpuComputePassEncoderSetPipeline(cp, P->lodcheck);
    wgpuComputePassEncoderSetBindGroup(cp, 0, bg, 0, nullptr);
    wgpuComputePassEncoderDispatchWorkgroups(cp, (uint32_t)((cnt + 63) / 64), 1, 1);
    wgpuComputePassEncoderEnd(cp);
    wgpuComputePassEncoderRelease(cp);
    wgpuCommandEncoderCopyBufferToBuffer(enc, outb, 0, stg, 0, ob);
    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(g.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);
    bool ok = false;
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mi.mode = WGPUCallbackMode_WaitAnyOnly;
    mi.callback = [](WGPUMapAsyncStatus st, WGPUStringView, void* u, void*) {
      *static_cast<bool*>(u) = (st == WGPUMapAsyncStatus_Success);
    };
    mi.userdata1 = &ok;
    WaitFuture(wgpuBufferMapAsync(stg, WGPUMapMode_Read, 0, ob, mi));
    if (ok) {
      const float* gp = static_cast<const float*>(wgpuBufferGetConstMappedRange(stg, 0, ob));
      if (gp) for (size_t i = 0; i < cnt; ++i) {
        const double d = std::fabs((double)gp[i] - (double)cpu[i]);
        out.gpu_max_abs = std::max(out.gpu_max_abs, d);
        if (d > 1e-4) out.gpu_cpu_mismatch++;
        out.gpu_checked++;
      }
      wgpuBufferUnmap(stg);
    }
    wgpuBindGroupRelease(bg);
    wgpuBindGroupLayoutRelease(bgl);
    wgpuBufferDestroy(outb); wgpuBufferRelease(outb);
    wgpuBufferDestroy(stg); wgpuBufferRelease(stg);
  }
  wgpuBufferDestroy(nub); wgpuBufferRelease(nub);
  return out;
}

// ─── json helpers ───────────────────────────────────────────────────────
template <typename T>
std::string Arr(const std::vector<T>& v, const char* fmt) {
  std::string o = "[";
  char b[48];
  for (size_t i = 0; i < v.size(); ++i) {
    std::snprintf(b, sizeof b, fmt, v[i]);
    if (i) o += ",";
    o += b;
  }
  return o + "]";
}

std::string Q(const std::string& s) { return "\"" + s + "\""; }

// ─── content frame for the trajectory ──────────────────────────────────
// The root box is a cube that also encloses outliers (216M: R 22.9 vs 16.2
// for the same scene at 36M), so framing on it points orbit/pan at empty
// space. Frame on the content instead, from the hierarchy alone: every node's
// points are credited to its level-4 ancestor; centre = per-axis point-weighted
// median of those ancestors' box centres; radius = point-weighted 90th
// percentile of (distance to centre + ancestor box radius). Bench scaffolding
// only -- nothing here feeds selection.
void ContentFrame(const Octree& oct, Vec3* c, double* R) {
  int L = 0;
  for (const Node& n : oct.nodes) L = std::max(L, n.level);
  L = std::min(L, 4);
  std::unordered_map<int32_t, double> w;
  for (size_t i = 0; i < oct.nodes.size(); ++i) {
    int32_t a = (int32_t)i;
    while (a >= 0 && oct.nodes[(size_t)a].level > L) a = oct.nodes[(size_t)a].parent;
    if (a >= 0 && oct.nodes[(size_t)a].level == L) w[a] += oct.nodes[i].numPoints;
  }
  std::vector<std::pair<int32_t, double>> v(w.begin(), w.end());
  double tot = 0;
  for (auto& x : v) tot += x.second;
  auto wmedian = [&](int axis) {
    std::vector<std::pair<double, double>> s;
    for (auto& x : v) {
      const Vec3 cc = oct.nodes[(size_t)x.first].box.center();
      s.push_back({axis == 0 ? cc.x : axis == 1 ? cc.y : cc.z, x.second});
    }
    std::sort(s.begin(), s.end());
    double acc = 0;
    for (auto& e : s) { acc += e.second; if (acc >= 0.5 * tot) return e.first; }
    return s.empty() ? 0.0 : s.back().first;
  };
  *c = {wmedian(0), wmedian(1), wmedian(2)};
  std::vector<std::pair<double, double>> dist;
  for (auto& x : v) {
    const Node& n = oct.nodes[(size_t)x.first];
    dist.push_back({(n.box.center() - *c).length() + n.box.boundingSphereRadius(), x.second});
  }
  std::sort(dist.begin(), dist.end());
  double acc = 0; *R = dist.empty() ? 1.0 : dist.back().first;
  for (auto& e : dist) { acc += e.second; if (acc >= 0.9 * tot) { *R = e.first; break; } }
}

// ─── target leaf ────────────────────────────────────────────────────────
// Deepest level, most points; ties broken by node index. Deterministic.
int32_t PickLeaf(const Octree& oct) {
  int best = -1; int best_lv = -1; uint32_t best_n = 0;
  for (size_t i = 0; i < oct.nodes.size(); ++i) {
    const Node& n = oct.nodes[i];
    const bool has_child = std::any_of(n.children.begin(), n.children.end(),
                                       [](int32_t x) { return x >= 0; });
    if (has_child || n.numPoints == 0) continue;
    if (n.level > best_lv || (n.level == best_lv && n.numPoints > best_n)) {
      best = (int)i; best_lv = n.level; best_n = n.numPoints;
    }
  }
  return best;
}

}  // namespace

// ─── entry ───────────────────────────────────────────────────────────────
extern "C" const char* pwlod_run(const char* octree_dir, const char* out_dir,
                                 const char* args_str, PwLodProbeFn probe, void* probe_ctx) {
  static std::string result;
  result.clear();
  const Args A = ParseArgs(args_str);
  std::string err;
  if (!InitGpu(&err)) { result = "init failed: " + err; return result.c_str(); }

  const double t_load0 = NowMs();
  Octree oct = loadOctree(octree_dir);
  const double t_load_ms = NowMs() - t_load0;
  if (!oct.error.empty()) { result = "loadOctree failed: " + oct.error; return result.c_str(); }
  const std::string bin = std::string(octree_dir) + "/octree.bin";

  // NodeCache floor: 15 B/point * budget, below it nodes are SILENTLY dropped.
  const double mult = std::max(A.cache_mult, 1.0);
  const size_t cache_bytes = (size_t)(mult * 15.0 * (double)A.budget);

  Traj T;
  ContentFrame(oct, &T.c, &T.R);
  T.leaf = PickLeaf(oct);
  if (T.leaf < 0) { result = "no leaf found"; return result.c_str(); }
  T.leaf_c = oct.nodes[(size_t)T.leaf].box.center();
  T.leaf_r = oct.nodes[(size_t)T.leaf].box.boundingSphereRadius();

  const uint32_t W = (uint32_t)A.width, H = (uint32_t)A.height;
  Pipe P;
  const uint32_t qslots = (uint32_t)std::max({A.frames, A.cold_frames, A.ctrl_settle, 120}) + 8u;
  if (!MakePipe(&P, W, H, qslots, &err)) { result = err; return result.c_str(); }

  Lod L;
  L.oct = &oct;
  L.bin_path = bin;
  L.max_nodes_loading = A.max_nodes_loading;
  DrawParams DP;
  DP.base_scale = A.base_scale;
  DP.octree_size = oct.nodes[0].box.size().x;       // PointCloudOctree.js:318
  DP.octree_spacing = oct.meta.spacing;              // PointCloudOctree.js:315

  auto sample = [&](PwLodProbeSample* s) {
    s->thermal_state = -1; s->footprint_mb = -1; s->avail_mb = -1;
    if (probe) probe(s, probe_ctx);
  };

  std::string j = "{\n";
  j += "  \"bench\": \"pw_lod\",\n  \"date\": \"2026-09-23\",\n";
  j += "  \"tag\": " + Q(A.tag) + ",\n";
  j += "  \"lod_lib\": \"Aether3D feat/pointcloud-lod-core d89b74f34081904f2ece5b9bccca4c3384d4da28 (vendored verbatim)\",\n";
  j += "  \"adapter\": " + Q(g.adapter_name) + ", \"backend\": " + std::to_string(g.backend) + ",\n";
  j += "  \"timestamp_query\": " + std::string(g.has_timestamp ? "true" : "false") + ",\n";
  j += "  \"octree_dir\": " + Q(octree_dir) + ",\n";
  {
    char b[1024];
    std::snprintf(b, sizeof b,
        "  \"octree\": {\"points_meta\": %lld, \"points_in_nodes\": %lld, \"nodes\": %zu, "
        "\"load_ms\": %.2f, \"content_center\": [%.4f,%.4f,%.4f], \"content_R\": %.4f, "
        "\"root_R\": %.4f},\n"
        "  \"target_leaf\": {\"index\": %d, \"name\": \"%s\", \"level\": %d, \"points\": %u, "
        "\"center\": [%.5f,%.5f,%.5f], \"radius\": %.6f},\n",
        (long long)oct.meta.points, (long long)oct.totalPointsInNodes(), oct.nodes.size(),
        t_load_ms, T.c.x, T.c.y, T.c.z, T.R, oct.nodes[0].box.boundingSphereRadius(), T.leaf,
        oct.nodes[(size_t)T.leaf].name.c_str(), oct.nodes[(size_t)T.leaf].level,
        oct.nodes[(size_t)T.leaf].numPoints, T.leaf_c.x, T.leaf_c.y, T.leaf_c.z, T.leaf_r);
    j += b;
    std::snprintf(b, sizeof b,
        "  \"config\": {\"mode\": \"%s\", \"arms\": \"%s\", \"frames\": %d, \"rounds\": %d, "
        "\"pace\": %d, \"budget\": %lld, \"cache_bytes\": %zu, \"cache_floor_bytes\": %lld, "
        "\"base_scale\": %.3f, \"fixed_px\": %.1f, \"w\": %u, \"h\": %u, \"cold_frames\": %d, "
        "\"target_ms\": %.4f},\n",
        A.mode.c_str(), A.arms.c_str(), A.frames, A.rounds, A.pace, (long long)A.budget,
        cache_bytes, (long long)(15 * A.budget), A.base_scale, A.fixed_px, W, H,
        A.cold_frames, kTargetMs);
    j += b;
  }
  {
    const std::string ws = std::string(kWgslCommon) + kWgslRender;
    j += "  \"wgsl_fnv64\": " + Q(Hex64(Fnv1a((const uint8_t*)ws.data(), ws.size()))) + ",\n";
  }

  const bool do_correct = (A.mode == "correct" || A.mode == "both");
  const bool do_perf = (A.mode == "perf" || A.mode == "both");

  // ─── correctness ──────────────────────────────────────────────────────
  if (do_correct) {
    struct PoseDef { const char* name; double t; };
    const PoseDef poses[4] = {{"overview", 0.05}, {"leaf", 0.35}, {"orbit_mid", 0.605}, {"pan_mid", 0.855}};
    const size_t ref_cache = (size_t)(15.0 * 1.1 * (double)A.ref_budget);
    j += "  \"correctness\": {\n";
    j += "    \"criteria\": \"nontrivial: coverage>0.01 && sat_mean>0.05 && min channel sd>10; "
         "matches_ref: sat_mean and min-sd within [0.8,1.25]x of the px=1 reference\",\n";
    // negative control 0: a flat grey frame must FAIL the non-trivial criterion
    {
      Img gray; gray.w = 64; gray.h = 64; gray.px.assign(64 * 64 * 4, 128);
      for (size_t i = 0; i < 64 * 64; ++i) gray.px[i*4+3] = 255;
      const ImgStat gs = Stat(gray);
      j += "    \"neg_flat_grey\": {\"stat\": " + StatJson(gs) + ", \"nontrivial\": " +
           (ImageNonTrivial(gs) ? "true" : "false") + ", \"expected\": false},\n";
    }
    j += "    \"poses\": [\n";
    for (int pi = 0; pi < 4; ++pi) {
      const char* segname = "";
      const Pose ps = PoseAt(T, poses[pi].t, &segname);
      double zn, zf; NearFar(T, ps, &zn, &zf);
      const CamState cs = MakeCam(ps, (int)W, (int)H, zn, zf);
      const bool is_leaf = (std::strcmp(poses[pi].name, "leaf") == 0);
      std::string pj = "      {\"pose\": " + Q(poses[pi].name) + ", \"segment\": " + Q(segname) + ",\n";
      char b[2048];
      std::snprintf(b, sizeof b, "       \"eye\": [%.5f,%.5f,%.5f], \"target\": [%.5f,%.5f,%.5f],\n",
                    ps.eye.x, ps.eye.y, ps.eye.z, ps.target.x, ps.target.y, ps.target.z);
      pj += b;

      // reference: px=1, big budget (own cache sized for it)
      ResetLod(&L, ref_cache);
      SelectParams spr; spr.pointBudget = A.ref_budget; spr.minimumNodePixelSize = 1.0;
      const FrameRec fref = LodFrame(&L, &P, cs, spr, DP, T.leaf, 0);
      const Img iref = Readback(&P);
      const ImgStat sref = Stat(iref);
      if (A.save_img) SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_ref.ppm", iref);
      // floor: the same reference, camera moved 0.25 px sideways
      Diff floor_d;
      {
        const Vec3 f = Norm(ps.target - ps.eye);
        const Vec3 right = Norm(Cross(f, {0, 1, 0}));
        const double d = (ps.target - ps.eye).length();
        const double wpp = 2.0 * d * std::tan(30.0 * kPi / 180.0) / double(H);
        const Pose pj2{ps.eye + right * (0.25 * wpp), ps.target + right * (0.25 * wpp)};
        const CamState csj = MakeCam(pj2, (int)W, (int)H, zn, zf);
        LodFrame(&L, &P, csj, spr, DP, T.leaf, 0);
        floor_d = ImgDiff(Readback(&P), iref);
      }
      std::snprintf(b, sizeof b,
          "       \"ref\": {\"px\": 1, \"pts\": %lld, \"nodes\": %d, \"max_level\": %d, \"hit_budget\": %s, "
          "\"dropped\": %d, \"truncated\": %s, \"stat\": %s},\n"
          "       \"jitter_floor_0p25px\": {\"frac\": %.4f, \"psnr\": %.2f, \"psnr4\": %.2f},\n",
          (long long)fref.pts_drawn, fref.nodes_drawn, fref.max_level, fref.hit_budget ? "true" : "false",
          fref.dropped, fref.truncated ? "true" : "false", StatJson(sref).c_str(), floor_d.frac, floor_d.psnr,
          floor_d.psnr4);
      pj += b;

      // fixed thresholds under the real budget / real cache
      ResetLod(&L, cache_bytes);
      pj += "       \"fixed\": [";
      const double pxs[3] = {A.fixed_px, 60.0, 30.0};
      for (int k = 0; k < 3; ++k) {
        SelectParams sp; sp.pointBudget = A.budget; sp.minimumNodePixelSize = pxs[k];
        const FrameRec fr = LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
        const Img im = Readback(&P);
        const ImgStat st = Stat(im);
        const Diff d = ImgDiff(im, iref);
        char nm[32]; std::snprintf(nm, sizeof nm, "px%.0f", pxs[k]);
        if (A.save_img && k == 0) SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_" + nm + ".ppm", im);
        std::snprintf(b, sizeof b,
            "%s{\"px\": %.1f, \"pts\": %lld, \"nodes\": %d, \"max_level\": %d, \"dropped\": %d, "
            "\"stat\": %s, \"nontrivial\": %s, \"matches_ref\": %s, "
            "\"diff_vs_ref\": {\"frac\": %.4f, \"psnr\": %.2f, \"psnr4\": %.2f}, \"detail_preserved\": %s}",
            k ? ",\n                  " : "", pxs[k], (long long)fr.pts_drawn, fr.nodes_drawn, fr.max_level,
            fr.dropped, StatJson(st).c_str(), ImageNonTrivial(st) ? "true" : "false",
            ImageMatchesRef(st, sref) ? "true" : "false", d.frac, d.psnr, d.psnr4,
            DetailPreserved(d, floor_d) ? "true" : "false");
        pj += b;
      }
      pj += "],\n";

      // determinism: same pose, same px, twice -> identical image
      {
        SelectParams sp; sp.pointBudget = A.budget; sp.minimumNodePixelSize = A.fixed_px;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
        const Img a = Readback(&P);
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
        const Img bb = Readback(&P);
        pj += std::string("       \"deterministic\": ") + (Stat(a).hash == Stat(bb).hash ? "true" : "false") + ",\n";
      }

      // controller: run it here with the real measured frame time
      double ctrl_px = A.fixed_px;
      {
        ResetLod(&L, cache_bytes);
        QualityController qc;
        FrameRec fr;
        for (int f = 0; f < A.ctrl_settle; ++f) {
          SelectParams sp; sp.pointBudget = A.budget; sp.minimumNodePixelSize = qc.pixelSize();
          fr = LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
          qc.onFrame(fr.wall);
        }
        ctrl_px = fr.px;
        const Img im = Readback(&P);
        const ImgStat st = Stat(im);
        const Diff d = ImgDiff(im, iref);
        if (A.save_img) SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_ctrl.ppm", im);
        std::snprintf(b, sizeof b,
            "       \"controller\": {\"frames\": %d, \"px_final\": %.2f, \"last_wall_ms\": %.2f, \"pts\": %lld, "
            "\"nodes\": %d, \"max_level\": %d, \"dropped\": %d, \"stat\": %s, \"nontrivial\": %s, "
            "\"matches_ref\": %s, \"diff_vs_ref\": {\"frac\": %.4f, \"psnr\": %.2f, \"psnr4\": %.2f}, "
            "\"detail_preserved\": %s}",
            A.ctrl_settle, fr.px, fr.wall, (long long)fr.pts_drawn, fr.nodes_drawn, fr.max_level, fr.dropped,
            StatJson(st).c_str(), ImageNonTrivial(st) ? "true" : "false",
            ImageMatchesRef(st, sref) ? "true" : "false", d.frac, d.psnr, d.psnr4,
            DetailPreserved(d, floor_d) ? "true" : "false");
        pj += b;
      }

      // ── point size: production formula vs Potree ADAPTIVE, same selection ──
      // The LOD frame is the controller's settled px from the block above.
      {
        DrawOpts dk; dk.keep_depth = true;
        DrawOpts da = dk; da.psize_mode = 1;
        // references (px=1, ref budget), each with its own 0.25 px jitter floor
        ResetLod(&L, ref_cache);
        const Vec3 f = Norm(ps.target - ps.eye);
        const Vec3 right = Norm(Cross(f, {0, 1, 0}));
        const double d = (ps.target - ps.eye).length();
        const double wpp = 2.0 * d * std::tan(30.0 * kPi / 180.0) / double(H);
        const CamState csj = MakeCam(Pose{ps.eye + right * (0.25 * wpp), ps.target + right * (0.25 * wpp)},
                                     (int)W, (int)H, zn, zf);
        SelectParams spr2; spr2.pointBudget = A.ref_budget; spr2.minimumNodePixelSize = 1.0;
        LodFrame(&L, &P, cs, spr2, DP, T.leaf, 0, dk);
        const Img rF = Readback(&P); const std::vector<float> rFd = ReadDepth(&P);
        LodFrame(&L, &P, csj, spr2, DP, T.leaf, 0, dk);
        const Img rFj = Readback(&P); const std::vector<float> rFjd = ReadDepth(&P);
        LodFrame(&L, &P, cs, spr2, DP, T.leaf, 0, da);
        const Img rA = Readback(&P); const std::vector<float> rAd = ReadDepth(&P);
        LodFrame(&L, &P, csj, spr2, DP, T.leaf, 0, da);
        const Img rAj = Readback(&P);
        // LOD frames at the controller's px, real budget / cache
        ResetLod(&L, cache_bytes);
        SelectParams spc; spc.pointBudget = A.budget; spc.minimumNodePixelSize = ctrl_px;
        LodFrame(&L, &P, cs, spc, DP, T.leaf, 0, dk);
        const Img lF = Readback(&P); const std::vector<float> lFd = ReadDepth(&P);
        std::vector<int32_t> drawnA;
        DrawOpts da2 = da; da2.out_drawn = &drawnA;
        const FrameRec frA = LodFrame(&L, &P, cs, spc, DP, T.leaf, 0, da2);
        const Img lA = Readback(&P); const std::vector<float> lAd = ReadDepth(&P);
        const SeeThrough stFloor = SeeThroughVs(rFj, rFjd, rF, rFd, zn, zf);
        const SeeThrough stF = SeeThroughVs(lF, lFd, rF, rFd, zn, zf);
        const SeeThrough stA = SeeThroughVs(lA, lAd, rF, rFd, zn, zf);
        const SeeThrough stAvsA = SeeThroughVs(lA, lAd, rA, rAd, zn, zf);
        const Diff dFA = ImgDiff(lA, rA), floorA = ImgDiff(rAj, rA);
        const Diff dFF = ImgDiff(lF, rF), floorF = ImgDiff(rFj, rF);
        const ImgStat sA = Stat(lA);
        const LodCheck lc = VerifyGetLOD(&L, &P, drawnA, DP);
        if (A.save_img && (is_leaf || std::strcmp(poses[pi].name, "pan_mid") == 0)) {
          SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_lod_fixedsize.ppm", lF);
          SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_lod_adaptive.ppm", lA);
          SavePpm(std::string(out_dir) + "/img_" + A.tag + "_" + poses[pi].name + "_ref_adaptive.ppm", rA);
        }
        std::snprintf(b, sizeof b,
            ",\n       \"point_size\": {\"px\": %.2f, \"pts\": %lld, \"vn_entries\": %d,\n"
            "          \"see_through_vs_fixed_ref\": {\"floor_jitter\": %s, \"fixed\": %s, \"adaptive\": %s},\n"
            "          \"adaptive_vs_adaptive_ref\": %s,\n"
            "          \"color_fixed_vs_fixed_ref\": {\"frac\": %.4f, \"psnr\": %.2f, \"floor_frac\": %.4f, \"floor_psnr\": %.2f, \"detail_preserved\": %s},\n"
            "          \"color_adaptive_vs_adaptive_ref\": {\"frac\": %.4f, \"psnr\": %.2f, \"floor_frac\": %.4f, \"floor_psnr\": %.2f, \"detail_preserved\": %s},\n"
            "          \"adaptive_stat\": %s, \"adaptive_nontrivial\": %s,\n"
            "          \"getlod_check\": {\"nodes\": %d, \"points\": %lld, \"cpu_vs_bruteforce_mismatch\": %lld, "
            "\"gpu_checked\": %lld, \"gpu_vs_cpu_mismatch\": %lld, \"gpu_max_abs\": %.3g, \"neg_masks_zeroed_mismatch\": %lld}}",
            ctrl_px, (long long)frA.pts_drawn, frA.vn_entries,
            SeeJson(stFloor).c_str(), SeeJson(stF).c_str(), SeeJson(stA).c_str(), SeeJson(stAvsA).c_str(),
            dFF.frac, dFF.psnr, floorF.frac, floorF.psnr, DetailPreserved(dFF, floorF) ? "true" : "false",
            dFA.frac, dFA.psnr, floorA.frac, floorA.psnr, DetailPreserved(dFA, floorA) ? "true" : "false",
            StatJson(sA).c_str(), ImageNonTrivial(sA) ? "true" : "false",
            lc.nodes, (long long)lc.points, (long long)lc.cpu_bf_mismatch, (long long)lc.gpu_checked,
            (long long)lc.gpu_cpu_mismatch, lc.gpu_max_abs, (long long)lc.neg_mismatch);
        pj += b;
      }

      // ── async loading: converges to the synchronous frame, never drops ──
      {
        SelectParams sp; sp.pointBudget = A.budget; sp.minimumNodePixelSize = A.fixed_px;
        ResetLod(&L, cache_bytes);
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
        const Img syncImg = Readback(&P);
        ResetLod(&L, cache_bytes, LoadMode::Async);
        int frames = 0, quiet = 0, maxPromo = 0, maxFly = 0, dropped = 0;
        bool ancestorsOk = true;
        FrameRec fr;
        const double ta = NowMs();
        for (; frames < 20000 && quiet < 3; ++frames) {
          fr = LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
          maxPromo = std::max(maxPromo, fr.uploads);
          maxFly = std::max(maxFly, fr.in_flight);
          dropped += fr.dropped;
          for (auto& kv : L.gpu)
            for (int32_t a = oct.nodes[(size_t)kv.first].parent; a >= 0; a = oct.nodes[(size_t)a].parent)
              if (!L.gpu.count(a)) ancestorsOk = false;
          const bool idle = fr.pending_nodes == 0 && fr.uploads == 0 && fr.in_flight == 0;
          quiet = idle ? quiet + 1 : 0;
          if (fr.in_flight > 0) L.aloader->waitAndPoll(20);
        }
        const double convMs = NowMs() - ta;
        const Img asyncImg = Readback(&P);
        // negative control: the converged async frame minus one node must differ
        std::vector<int32_t> drawnNow;
        DrawOpts od; od.out_drawn = &drawnNow;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, od);
        // The removed node must be visible: the lowest-priority drawn node can be
        // a pinned level<=2 node outside the frustum (select.cpp :182) and the
        // deepest one can be occluded. Remove the front-most node whose centre
        // projects into the middle of the screen.
        int32_t pick = -1; double bestW = 1e300;
        for (int32_t n : drawnNow) {
          const Vec3 c = oct.nodes[(size_t)n].box.center();
          const double* m = cs.vp;
          const double cx = m[0]*c.x + m[1]*c.y + m[2]*c.z + m[3];
          const double cy = m[4]*c.x + m[5]*c.y + m[6]*c.z + m[7];
          const double cw = m[12]*c.x + m[13]*c.y + m[14]*c.z + m[15];
          if (cw <= 0 || std::fabs(cx / cw) > 0.5 || std::fabs(cy / cw) > 0.5) continue;
          if (oct.nodes[(size_t)n].numPoints == 0) continue;
          if (cw < bestW) { bestW = cw; pick = n; }
        }
        DrawOpts sk; sk.skip_node = pick;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, sk);
        const Img minusOne = Readback(&P);
        std::snprintf(b, sizeof b,
            ",\n       \"async\": {\"px\": %.1f, \"frames_to_converge\": %d, \"ms_to_converge\": %.1f, "
            "\"converged\": %s, \"equals_sync_image\": %s, \"max_uploads_per_frame\": %d, "
            "\"max_in_flight\": %d, \"dropped_total\": %d, \"gpu_set_ancestor_closed\": %s, "
            "\"neg_minus_one_node_differs\": %s, \"stat\": %s}",
            A.fixed_px, frames, convMs, quiet >= 3 ? "true" : "false",
            Stat(asyncImg).hash == Stat(syncImg).hash ? "true" : "false", maxPromo, maxFly, dropped,
            ancestorsOk ? "true" : "false",
            Stat(minusOne).hash != Stat(syncImg).hash ? "true" : "false", StatJson(Stat(asyncImg)).c_str());
        pj += b;
      }

      if (is_leaf) {
        // "拉近到某个叶节点能看到它的点": (a) the leaf is selected and drawn,
        // (b) drawing everything minus the leaf changes pixels (the leaf is
        // actually visible, not just submitted), (c) the leaf alone covers
        // pixels. Negative controls: (b') minus-leaf vs minus-leaf must be 0,
        // (d) forgetting the node origin must break the match with the reference.
        ResetLod(&L, cache_bytes);
        SelectParams sp; sp.pointBudget = A.budget; sp.minimumNodePixelSize = A.fixed_px;
        const FrameRec ffull = LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);
        const Img full = Readback(&P);
        DrawOpts skip; skip.skip_node = T.leaf;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, skip);
        const Img noleaf = Readback(&P);
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, skip);
        const Img noleaf2 = Readback(&P);
        DrawOpts only; only.only_node = T.leaf;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, only);
        const Img leafonly = Readback(&P);
        DrawOpts noo; noo.no_origin = true;
        LodFrame(&L, &P, cs, sp, DP, T.leaf, 0, noo);
        const Img noorig = Readback(&P);
        const Diff dleaf = ImgDiff(full, noleaf);
        const Diff dneg = ImgDiff(noleaf, noleaf2);
        const ImgStat sonly = Stat(leafonly);
        const ImgStat snoo = Stat(noorig);
        const Diff dnoo = ImgDiff(noorig, iref);
        const Diff dfull = ImgDiff(full, iref);
        if (A.save_img) {
          SavePpm(std::string(out_dir) + "/img_" + A.tag + "_leaf_only.ppm", leafonly);
          SavePpm(std::string(out_dir) + "/img_" + A.tag + "_leaf_no_origin.ppm", noorig);
        }
        std::snprintf(b, sizeof b,
            ",\n       \"leaf_check\": {\"selected\": %s, \"drawn\": %s, "
            "\"pixels_changed_by_leaf\": %llu, \"neg_same_minus_leaf_pixels\": %llu, "
            "\"leaf_only_coverage\": %.6f, \"leaf_only_px\": %.0f,\n"
            "          \"neg_no_origin\": {\"stat\": %s, \"diff_vs_ref_frac\": %.4f, \"matches_ref\": %s}, "
            "\"with_origin_diff_vs_ref_frac\": %.4f}",
            ffull.target_selected ? "true" : "false", ffull.target_drawn ? "true" : "false",
            (unsigned long long)dleaf.pixels, (unsigned long long)dneg.pixels, sonly.cover,
            sonly.cover * W * H, StatJson(snoo).c_str(), dnoo.frac,
            ImageMatchesRef(snoo, sref) ? "true" : "false", dfull.frac);
        pj += b;
      }
      pj += std::string("\n      }") + (pi < 3 ? ",\n" : "\n");
      j += pj;
    }
    j += "    ]\n  },\n";
    ResetLod(&L, cache_bytes);
  }

  // ─── performance ──────────────────────────────────────────────────────
  if (do_perf) {
    struct Block {
      std::string label; int round = -1; int order = -1;
      std::string mode; int psize = 0;
      std::vector<FrameRec> fr;
      std::vector<double> gpu;
      std::vector<int> probe_frame, probe_thermal;
      std::vector<double> probe_fp, probe_avail;
      int64_t uploads = 0, evictions = 0;
      size_t cpu_nodes = 0, cpu_bytes = 0, gpu_nodes = 0; uint64_t gpu_bytes = 0;
      double t_start_ms = 0;
    };
    std::vector<Block> blocks;
    const double t_run0 = NowMs();

    // Arm table. A trailing "2" repeats an arm in another in-round position
    // (noise floor). COLD/FIRST use `first=`.
    //   C, S  : sync load,  controller, production point size
    //   F     : sync load,  fixed px (Potree 150), production point size
    //   A     : async load (Potree limits), controller, production point size
    //   AP    : async load, controller, Potree ADAPTIVE point size
    //   SP    : sync load,  controller, Potree ADAPTIVE point size
    struct Arm { LoadMode mode = LoadMode::Sync; bool ctrl = true; int psize = 0; };
    auto ArmOf = [&](std::string lab) {
      if (lab == "COLD" || lab == "FIRST") lab = A.first;
      if (lab.size() > 1 && lab.back() == '2') lab.pop_back();
      Arm a;
      if (lab == "F") a.ctrl = false;
      if (lab == "A" || lab == "AP") a.mode = LoadMode::Async;
      if (lab == "AP" || lab == "SP") a.psize = 1;
      return a;
    };
    auto run_block = [&](const std::string& label, int frames, bool static_overview, Block* B) {
      const Arm arm = ArmOf(label);
      ResetLod(&L, cache_bytes, arm.mode);             // every block starts with empty caches
      QualityController qc;
      const bool ctrl = arm.ctrl;
      DrawOpts dopt; dopt.psize_mode = arm.psize;
      B->label = label;
      B->mode = arm.mode == LoadMode::Async ? "async" : "sync";
      B->psize = arm.psize;
      B->t_start_ms = NowMs() - t_run0;
      B->fr.reserve((size_t)frames);
      for (int f = 0; f < frames; ++f) {
        const double tf0 = NowMs();
        const char* segname = "";
        const double t = static_overview ? 0.0 : double(f) / double(frames);
        const Pose ps = PoseAt(T, t, &segname);
        double zn, zf; NearFar(T, ps, &zn, &zf);
        const CamState cs = MakeCam(ps, (int)W, (int)H, zn, zf);
        SelectParams sp; sp.pointBudget = A.budget;
        sp.minimumNodePixelSize = ctrl ? qc.pixelSize() : A.fixed_px;
        const FrameRec fr = LodFrame(&L, &P, cs, sp, DP, T.leaf, (uint32_t)f, dopt);
        if (ctrl) qc.onFrame(fr.wall);                 // the real measured frame time
        B->fr.push_back(fr);
        if (f % 30 == 0 || f == frames - 1) {
          PwLodProbeSample s; sample(&s);
          B->probe_frame.push_back(f); B->probe_thermal.push_back(s.thermal_state);
          B->probe_fp.push_back(s.footprint_mb); B->probe_avail.push_back(s.avail_mb);
        }
        if (A.pace) {
          const double rest = kTargetMs - (NowMs() - tf0);
          if (rest > 0) std::this_thread::sleep_for(std::chrono::microseconds((int64_t)(rest * 1000.0)));
        }
      }
      B->gpu = ReadGpuMs(&P, (uint32_t)frames);
      B->uploads = L.uploads; B->evictions = L.evictions;
      if (L.loader) { B->cpu_nodes = L.loader->cache().size(); B->cpu_bytes = L.loader->cache().bytes(); }
      else { B->cpu_nodes = L.aloader->cache().size(); B->cpu_bytes = L.aloader->cache().bytes(); }
      B->gpu_nodes = L.gpu.size(); B->gpu_bytes = L.gpu_bytes;
    };

    // 1) cold start: the first thing this process draws, static overview, controller on
    { Block B; run_block("COLD", A.cold_frames, true, &B); B.round = -1; B.order = 0; blocks.push_back(std::move(B)); }

    // 2) first flight: the controller arm over the full trajectory, the first
    //    traversal in this process. Reported on its own (cold disk: what a user
    //    sees the first time) and it warms the OS page cache so that the A/B
    //    rounds below compare arms, not cold-vs-warm disk. (Mac smoke on 216M:
    //    without it, round 0's first block had p95 123 ms vs 27 ms for the
    //    same arm two blocks later.)
    { Block B; run_block("FIRST", A.frames, false, &B); B.round = -1; B.order = 1; blocks.push_back(std::move(B)); }

    // 2b) sequential pre-read of octree.bin (portable ifstream): puts as much of
    //     the file in the OS page cache as the OS keeps, so the A/B rounds are
    //     not decided by which arm happened to touch a region first. Timed:
    //     it is also the device's sequential read throughput.
    {
      const double t0 = NowMs();
      std::ifstream f(bin, std::ios::binary);
      std::vector<char> buf((size_t)16 << 20);
      uint64_t total = 0;
      while (f) {
        f.read(buf.data(), (std::streamsize)buf.size());
        total += (uint64_t)f.gcount();
      }
      const double ms = NowMs() - t0;
      char b[256];
      std::snprintf(b, sizeof b, "  \"prewarm\": {\"bytes\": %llu, \"ms\": %.1f, \"mb_per_s\": %.1f},\n",
                    (unsigned long long)total, ms, ms > 0 ? (double)total / 1.0e6 / (ms / 1000.0) : -1.0);
      j += b;
    }

    // 3) A/B rounds, labels rotated inside each round (thermal drift balanced)
    std::vector<std::string> labels;
    {
      std::string s = A.arms; size_t i = 0;
      while (i <= s.size()) {
        size_t k = s.find(',', i); if (k == std::string::npos) k = s.size();
        if (k > i) labels.push_back(s.substr(i, k - i));
        i = k + 1;
      }
    }
    const int nl = (int)labels.size();
    bool thermal_stop = false;
    for (int r = 0; r < A.rounds && !thermal_stop; ++r)
      for (int pos = 0; pos < nl; ++pos) {
        Block B; run_block(labels[(size_t)((pos + r) % nl)], A.frames, false, &B);
        B.round = r; B.order = pos; blocks.push_back(std::move(B));
        PwLodProbeSample s; sample(&s);
        if (s.thermal_state >= 3) { thermal_stop = true; break; }   // stop rule: critical
      }
    j += std::string("  \"thermal_stop\": ") + (thermal_stop ? "true" : "false") + ",\n";

    // 4) positive control: same static pose, the ruler must see half the work
    std::string pcj;
    if (A.pc) {
      const char* segname = "";
      const Pose ps = PoseAt(T, 0.605, &segname);      // orbit_mid: plenty of points
      double zn, zf; NearFar(T, ps, &zn, &zf);
      const CamState cs = MakeCam(ps, (int)W, (int)H, zn, zf);
      const int K = 60;
      auto measure = [&](int64_t budget, double* gpu_p50, double* wall_p50, int64_t* pts) {
        ResetLod(&L, (size_t)(15.0 * 1.1 * (double)std::max(budget, A.budget)));
        SelectParams sp; sp.pointBudget = budget; sp.minimumNodePixelSize = 1.0;
        for (int f = 0; f < 5; ++f) LodFrame(&L, &P, cs, sp, DP, T.leaf, 0);   // load + warm
        std::vector<double> w;
        FrameRec fr;
        for (int f = 0; f < K; ++f) { fr = LodFrame(&L, &P, cs, sp, DP, T.leaf, (uint32_t)f); w.push_back(fr.render); }
        std::vector<double> gm = ReadGpuMs(&P, (uint32_t)K);
        std::sort(w.begin(), w.end()); std::sort(gm.begin(), gm.end());
        *gpu_p50 = gm[gm.size() / 2]; *wall_p50 = w[w.size() / 2]; *pts = fr.pts_drawn;
      };
      double g1, w1, g2, w2; int64_t p1, p2;
      measure(A.budget, &g1, &w1, &p1);
      measure(A.budget / 2, &g2, &w2, &p2);
      char b[400];
      std::snprintf(b, sizeof b,
          "  \"positive_control\": {\"pose\": \"orbit_mid\", \"px\": 1, \"full\": {\"pts\": %lld, \"gpu_p50\": %.3f, "
          "\"render_p50\": %.3f}, \"half\": {\"pts\": %lld, \"gpu_p50\": %.3f, \"render_p50\": %.3f}, "
          "\"gpu_ratio\": %.4f, \"pts_ratio\": %.4f},\n",
          (long long)p1, g1, w1, (long long)p2, g2, w2, g1 > 0 ? g2 / g1 : -1.0,
          p1 > 0 ? double(p2) / double(p1) : -1.0);
      pcj = b;
    }

    // ─── write blocks ───
    j += pcj;
    j += "  \"blocks\": [\n";
    for (size_t bi = 0; bi < blocks.size(); ++bi) {
      const Block& B = blocks[bi];
      std::vector<double> wall, sel, load, up, ren, px;
      std::vector<long long> pts, bytes_read;
      std::vector<int> nodes, dec, drop, lvl, upl, tsel, tdrw, hitb, trunc, pend, fly;
      std::vector<long long> pendpts;
      for (const FrameRec& f : B.fr) {
        wall.push_back(f.wall); sel.push_back(f.sel); load.push_back(f.load); up.push_back(f.upload);
        ren.push_back(f.render); px.push_back(f.px); pts.push_back((long long)f.pts_drawn);
        bytes_read.push_back((long long)f.bytes_read); nodes.push_back(f.nodes_drawn);
        dec.push_back((int)f.decoded); drop.push_back(f.dropped); lvl.push_back(f.max_level);
        upl.push_back(f.uploads); tsel.push_back(f.target_selected); tdrw.push_back(f.target_drawn);
        hitb.push_back(f.hit_budget); trunc.push_back(f.truncated);
        pend.push_back(f.pending_nodes); fly.push_back(f.in_flight); pendpts.push_back((long long)f.pending_pts);
      }
      char b[512];
      std::snprintf(b, sizeof b,
          "    {\"label\": \"%s\", \"mode\": \"%s\", \"psize\": %d, \"round\": %d, \"order\": %d, \"index\": %zu, \"t_start_s\": %.2f, "
          "\"uploads\": %lld, \"evictions\": %lld, \"end_cache\": {\"cpu_nodes\": %zu, \"cpu_bytes\": %zu, "
          "\"gpu_nodes\": %zu, \"gpu_bytes\": %llu},\n",
          B.label.c_str(), B.mode.c_str(), B.psize, B.round, B.order, bi, B.t_start_ms / 1000.0, (long long)B.uploads,
          (long long)B.evictions, B.cpu_nodes, B.cpu_bytes, B.gpu_nodes, (unsigned long long)B.gpu_bytes);
      j += b;
      j += "     \"wall_ms\": " + Arr(wall, "%.3f") + ",\n";
      j += "     \"gpu_ms\": " + Arr(B.gpu, "%.3f") + ",\n";
      j += "     \"sel_ms\": " + Arr(sel, "%.3f") + ",\n";
      j += "     \"load_ms\": " + Arr(load, "%.3f") + ",\n";
      j += "     \"upload_ms\": " + Arr(up, "%.3f") + ",\n";
      j += "     \"render_ms\": " + Arr(ren, "%.3f") + ",\n";
      j += "     \"px\": " + Arr(px, "%.2f") + ",\n";
      j += "     \"pts\": " + Arr(pts, "%lld") + ",\n";
      j += "     \"nodes\": " + Arr(nodes, "%d") + ",\n";
      j += "     \"max_level\": " + Arr(lvl, "%d") + ",\n";
      j += "     \"decoded\": " + Arr(dec, "%d") + ",\n";
      j += "     \"bytes_read\": " + Arr(bytes_read, "%lld") + ",\n";
      j += "     \"uploads_f\": " + Arr(upl, "%d") + ",\n";
      j += "     \"dropped\": " + Arr(drop, "%d") + ",\n";
      j += "     \"hit_budget\": " + Arr(hitb, "%d") + ",\n";
      j += "     \"truncated\": " + Arr(trunc, "%d") + ",\n";
      j += "     \"pending_nodes\": " + Arr(pend, "%d") + ",\n";
      j += "     \"pending_pts\": " + Arr(pendpts, "%lld") + ",\n";
      j += "     \"in_flight\": " + Arr(fly, "%d") + ",\n";
      j += "     \"target_selected\": " + Arr(tsel, "%d") + ",\n";
      j += "     \"target_drawn\": " + Arr(tdrw, "%d") + ",\n";
      j += "     \"probe_frame\": " + Arr(B.probe_frame, "%d") + ",\n";
      j += "     \"thermal\": " + Arr(B.probe_thermal, "%d") + ",\n";
      j += "     \"footprint_mb\": " + Arr(B.probe_fp, "%.1f") + ",\n";
      j += "     \"avail_mb\": " + Arr(B.probe_avail, "%.1f") + "}";
      j += (bi + 1 < blocks.size()) ? ",\n" : "\n";
    }
    j += "  ],\n";
  }

  j += "  \"wgpu_errors\": " + Q([&] {
    std::string e;
    for (char ch : g.error_log) e += (ch == '"' || ch == '\\') ? '\'' : (ch == '\n' ? ' ' : ch);
    return e;
  }()) + "\n}\n";

  ResetLod(&L, 0);
  const std::string path = std::string(out_dir) + "/lod_" + (A.tag.empty() ? "run" : A.tag) + ".json";
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) { result = "cannot write " + path; return result.c_str(); }
  std::fwrite(j.data(), 1, j.size(), f);
  std::fclose(f);
  result = path;
  return result.c_str();
}
