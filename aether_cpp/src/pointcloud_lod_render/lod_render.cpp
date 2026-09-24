// Portions of this file (the WGSL getLOD / numberOfOnes / isBitSet / adaptive
// point size, the visible-node table and LodByte) are transliterated from Potree
// (https://github.com/potree/potree @ 5636cd471d9eb464969e758be45c44d7613d3859:
// src/materials/shaders/pointcloud.vs, src/PointCloudOctree.js), used under this
// licence, reproduced verbatim as its clause 1 requires:
//
// Copyright (c) 2011-2020, Markus Schütz
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// The views and conclusions contained in the software and documentation are those
// of the authors and should not be interpreted as representing official policies,
// either expressed or implied, of the FreeBSD Project.
//
// PocketWorld point-cloud LOD render pass.
//
// This file is pw_splat_ab_bench Sources/lod/pw_lod_bench.cpp @ b792d57
// (sha256 50af752c...) moved into the engine: the WebGPU helpers, the WGSL,
// Pipe/MakePipe, the LOD renderer state, Upload, EvictGpu, the Potree
// visible-node table, CpuGetLOD and LodFrame. Code is kept line for line where
// the viewer does not need a change; each change is an R-number in
// src/pointcloud_lod_render/DEVIATIONS.md and is marked "R<n>" below.
//
// The quad shader is bench_cloud.mm's kWgslCloud (vertex expansion,
// perspective radius = baseScale * camDist / depth, opaque + depth write) with
// the view-projection from a per-node uniform, plus Potree's adaptive point size
// (potree @ 5636cd471d9eb464969e758be45c44d7613d3859 src/materials/shaders/
// pointcloud.vs, BSD-2-Clause) -- see the shader comment for line pins.
//
// Selection, streaming, controller: aether::pointcloud_lod, called as-is.
// Platform: C++20 + webgpu.h only. No OS header, no vendor graphics API, no
// per-OS branch; the adapter is requested with the default backend.
#include "aether/pointcloud_lod_render/lod_render.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace aether::pointcloud_lod_render {

using namespace aether::pointcloud_lod;

namespace {

constexpr double kPi = 3.14159265358979323846;

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::string SvStr(WGPUStringView v) {
  if (!v.data) return "";
  return std::string(v.data, v.length == WGPU_STRLEN ? std::strlen(v.data) : v.length);
}

// R1: the bench appended uncaptured errors to the global g.error_log. Several
// devices can exist now, so errors and device loss go to one process-wide log.
struct ErrorSink {
  std::mutex mu;
  std::string log;
  std::atomic<uint64_t> count{0};
  std::vector<WGPUDevice> lost;
};
ErrorSink& Sink() {
  static ErrorSink* s = new ErrorSink();   // never destroyed: callbacks may fire at exit
  return *s;
}

void OnUncapturedError(WGPUDevice const*, WGPUErrorType type, WGPUStringView msg, void*, void*) {
  ErrorSink& s = Sink();
  std::lock_guard<std::mutex> lk(s.mu);
  s.log += "[wgpu error " + std::to_string((int)type) + "] " + SvStr(msg) + "\n";
  s.count.fetch_add(1);
}

void OnDeviceLost(WGPUDevice const* device, WGPUDeviceLostReason reason, WGPUStringView msg, void*,
                  void*) {
  ErrorSink& s = Sink();
  std::lock_guard<std::mutex> lk(s.mu);
  // Destroyed / CallbackCancelled are our own release, not a loss.
  if (reason == WGPUDeviceLostReason_Destroyed || reason == WGPUDeviceLostReason_CallbackCancelled)
    return;
  s.log += "[device lost " + std::to_string((int)reason) + "] " + SvStr(msg) + "\n";
  s.count.fetch_add(1);
  if (device && *device) s.lost.push_back(*device);
}

}  // namespace

uint64_t GpuErrorCount() { return Sink().count.load(); }
std::string GpuErrorLog() {
  ErrorSink& s = Sink();
  std::lock_guard<std::mutex> lk(s.mu);
  return s.log;
}
bool GpuDeviceLost(WGPUDevice device) {
  ErrorSink& s = Sink();
  std::lock_guard<std::mutex> lk(s.mu);
  return std::find(s.lost.begin(), s.lost.end(), device) != s.lost.end();
}

// ─── WebGPU ──────────────────────────────────────────────────────────────
WGPUStringView SV(const char* s) { return WGPUStringView{s, WGPU_STRLEN}; }

void WaitFuture(const GpuCtx& g, WGPUFuture f) {
  WGPUFutureWaitInfo w{f, false};
  wgpuInstanceWaitAny(g.instance, 1, &w, UINT64_MAX);
}

bool CreateGpu(const WGPUFeatureName* extra_features, uint32_t extra_count, GpuCtx* out,
               std::string* err) {
  GpuCtx g;
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
  aci.callback = [](WGPURequestAdapterStatus st, WGPUAdapter a, WGPUStringView, void* u,
                    void*) {
    if (st == WGPURequestAdapterStatus_Success) static_cast<GpuCtx*>(u)->adapter = a;
  };
  aci.userdata1 = &g;
  WaitFuture(g, wgpuInstanceRequestAdapter(g.instance, &aopt, aci));
  if (!g.adapter) { *err = "RequestAdapter failed"; ReleaseGpu(&g); return false; }

  WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
  if (wgpuAdapterGetInfo(g.adapter, &info) == WGPUStatus_Success) {
    g.adapter_name = SvStr(info.device) + " | " + SvStr(info.description);
    g.backend = (int)info.backendType;
    wgpuAdapterInfoFreeMembers(info);   // R8
  }
  if (g.backend == (int)WGPUBackendType_Null) {
    *err = "adapter is the Null backend -- refusing to measure it";
    ReleaseGpu(&g);
    return false;
  }

  WGPULimits alim = WGPU_LIMITS_INIT;
  wgpuAdapterGetLimits(g.adapter, &alim);
  WGPULimits req = WGPU_LIMITS_INIT;
  req.maxStorageBufferBindingSize = alim.maxStorageBufferBindingSize;
  req.maxBufferSize = alim.maxBufferSize;

  g.has_timestamp = wgpuAdapterHasFeature(g.adapter, WGPUFeatureName_TimestampQuery);
  // R11: TimestampQuery when available, then the caller's features (the shell's
  // texture-sharing feature). A feature the adapter lacks is an error, not a
  // silent drop: the shell cannot work without it.
  std::vector<WGPUFeatureName> feats;
  if (g.has_timestamp) feats.push_back(WGPUFeatureName_TimestampQuery);
  for (uint32_t i = 0; i < extra_count; ++i) {
    if (!wgpuAdapterHasFeature(g.adapter, extra_features[i])) {
      *err = "adapter lacks required feature " + std::to_string((int)extra_features[i]);
      ReleaseGpu(&g);
      return false;
    }
    if (std::find(feats.begin(), feats.end(), extra_features[i]) == feats.end())
      feats.push_back(extra_features[i]);
  }
  WGPUDeviceDescriptor ddesc = WGPU_DEVICE_DESCRIPTOR_INIT;
  ddesc.requiredLimits = &req;
  ddesc.requiredFeatureCount = feats.size();
  ddesc.requiredFeatures = feats.empty() ? nullptr : feats.data();
  ddesc.uncapturedErrorCallbackInfo.callback = OnUncapturedError;
  ddesc.deviceLostCallbackInfo.mode = WGPUCallbackMode_AllowSpontaneous;
  ddesc.deviceLostCallbackInfo.callback = OnDeviceLost;
  WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  dci.mode = WGPUCallbackMode_WaitAnyOnly;
  dci.callback = [](WGPURequestDeviceStatus st, WGPUDevice d, WGPUStringView, void* u,
                    void*) {
    if (st == WGPURequestDeviceStatus_Success) static_cast<GpuCtx*>(u)->device = d;
  };
  dci.userdata1 = &g;
  WaitFuture(g, wgpuAdapterRequestDevice(g.adapter, &ddesc, dci));
  if (!g.device) { *err = "RequestDevice failed"; ReleaseGpu(&g); return false; }
  g.queue = wgpuDeviceGetQueue(g.device);
  *out = g;
  return true;
}

void ReleaseGpu(GpuCtx* g) {   // R8
  if (g->queue) wgpuQueueRelease(g->queue);
  if (g->device) wgpuDeviceRelease(g->device);
  if (g->adapter) wgpuAdapterRelease(g->adapter);
  if (g->instance) wgpuInstanceRelease(g->instance);
  *g = GpuCtx();
}

WGPUBuffer MakeBuffer(const GpuCtx& g, uint64_t size, WGPUBufferUsage usage) {
  WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
  d.size = size;
  d.usage = usage;
  return wgpuDeviceCreateBuffer(g.device, &d);
}

void WaitQueueIdle(const GpuCtx& g) {
  WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
  wi.mode = WGPUCallbackMode_WaitAnyOnly;
  wi.callback = [](WGPUQueueWorkDoneStatus, WGPUStringView, void*, void*) {};
  WaitFuture(g, wgpuQueueOnSubmittedWorkDone(g.queue, wi));
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
//          :690-692 adaptive_point_size, orthographic branch (R6)
//        uniforms set by src/PotreeRenderer.js:1232-1233,1293-1300,815,730
//          orthographic uniforms :1237-1240 (uOrthoWidth = camera.right - camera.left)
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
    ortho_width: f32,
    ortho: u32,
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
        if (fu.ortho == 1u) {
            pointSize = (worldSpaceSize / fu.ortho_width) * fu.img_size.x;          // :690-692 (R6)
        }
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

const char* WgslCommon() { return kWgslCommon; }
const char* WgslRender() { return kWgslRender; }
const char* WgslLodCheck() { return kWgslLodCheck; }

bool MakePipe(const GpuCtx& g, Pipe* P, WGPUTextureFormat color_format, uint32_t w, uint32_t h,
              uint32_t qslots, std::string* err) {
  P->w = w; P->h = h;
  P->color_format = color_format;   // R2
  const uint64_t errors0 = GpuErrorCount();
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
  ct.format = color_format;   // R2 (bench: RGBA8Unorm)
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
  if (!P->pipe) { *err = "pipeline failed\n" + GpuErrorLog(); return false; }

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
  P->vn = MakeBuffer(g, (uint64_t)kMaxVN * 16,
      (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));

  P->frame_u = MakeBuffer(g, sizeof(FrameU),
      (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));
  P->node_u = MakeBuffer(g, (uint64_t)kMaxDrawNodes * kSlotBytes,
      (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));

  // R2: only the depth buffer is ours; the colour target comes from the caller.
  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.dimension = WGPUTextureDimension_2D;
  td.size = WGPUExtent3D{w, h, 1};
  td.mipLevelCount = 1; td.sampleCount = 1;
  td.format = WGPUTextureFormat_Depth32Float;
  td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc);
  P->depth = wgpuDeviceCreateTexture(g.device, &td);
  WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
  P->depth_v = wgpuTextureCreateView(P->depth, &vd);

  P->qslots = qslots;
  if (g.has_timestamp && qslots > 0) {
    WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
    qd.type = WGPUQueryType_Timestamp; qd.count = 2;
    P->qs = wgpuDeviceCreateQuerySet(g.device, &qd);
    P->resolve = MakeBuffer(g, (uint64_t)qslots * 256ull,
        (WGPUBufferUsage)(WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc));
    P->qstage = MakeBuffer(g, (uint64_t)qslots * 256ull,
        (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  }
  // R10: Dawn returns an error object rather than nullptr for an invalid
  // pipeline, so the bench's `!P->pipe` never fires. Flush and check the
  // uncaptured-error count instead.
  WaitQueueIdle(g);
  if (GpuErrorCount() != errors0) { *err = "pipeline creation raised errors\n" + GpuErrorLog(); return false; }
  return true;
}

void ReleasePipe(Pipe* P) {   // R8
  if (P->bgl) wgpuBindGroupLayoutRelease(P->bgl);
  if (P->pipe) wgpuRenderPipelineRelease(P->pipe);
  if (P->lodcheck) wgpuComputePipelineRelease(P->lodcheck);
  for (WGPUBuffer b : {P->frame_u, P->node_u, P->vn, P->resolve, P->qstage})
    if (b) { wgpuBufferDestroy(b); wgpuBufferRelease(b); }
  if (P->depth_v) wgpuTextureViewRelease(P->depth_v);
  if (P->depth) { wgpuTextureDestroy(P->depth); wgpuTextureRelease(P->depth); }
  if (P->qs) { wgpuQuerySetDestroy(P->qs); wgpuQuerySetRelease(P->qs); }
  *P = Pipe();
}

// ─── camera (row-major, WebGPU clip z in [0,1]) ─────────────────────────
void Mul(const double a[16], const double b[16], double o[16]) {
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      double s = 0;
      for (int k = 0; k < 4; k++) s += a[r*4+k] * b[k*4+c];
      o[r*4+c] = s;
    }
}

// ─── LOD renderer state ─────────────────────────────────────────────────
void ReleaseNode(GpuNode& n) {
  if (n.bg) wgpuBindGroupRelease(n.bg);
  if (n.buf) { wgpuBufferDestroy(n.buf); wgpuBufferRelease(n.buf); }
  n.bg = nullptr; n.buf = nullptr;
}

void ResetLod(Lod* L, size_t cache_bytes, LoadMode mode) {
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
  if (!L->oct) return;   // R12: ResetLod(L, 0) with no octree only releases
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

namespace {

// Plumbing only: turn one decoded node into a 16-B/point storage buffer.
GpuNode Upload(const GpuCtx& g, const Pipe& P, const NodePoints& np) {
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
  gn.buf = MakeBuffer(g, gn.bytes, (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
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

NodeState ResidencyState(int32_t n, void* ctx) {
  Lod* L = static_cast<Lod*>(ctx);
  if (L->gpu.count(n)) return NodeState::Drawable;
  return L->aloader->state(n);
}

// R4: wgpuSharedTextureMemoryBeginAccess / EndAccess, the pattern of
// src/render/dawn_gpu_device.cpp iosurface_begin_access / iosurface_end_access:
// initialized = true (the pass clears anyway), no fences in, fences out freed.
bool BeginAccess(const Target& rt) {
  if (!rt.memory) return true;
  WGPUSharedTextureMemoryBeginAccessDescriptor desc = WGPU_SHARED_TEXTURE_MEMORY_BEGIN_ACCESS_DESCRIPTOR_INIT;
  desc.initialized = 1;
  return wgpuSharedTextureMemoryBeginAccess(rt.memory, rt.texture, &desc) == WGPUStatus_Success;
}
void EndAccess(const Target& rt) {
  if (!rt.memory) return;
  WGPUSharedTextureMemoryEndAccessState state = WGPU_SHARED_TEXTURE_MEMORY_END_ACCESS_STATE_INIT;
  wgpuSharedTextureMemoryEndAccess(rt.memory, rt.texture, &state);
  wgpuSharedTextureMemoryEndAccessStateFreeMembers(state);
}

}  // namespace

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

// One LOD frame: select -> load -> upload -> draw. Every stage timed.
FrameRec LodFrame(const GpuCtx& g, Lod* L, Pipe* P, const Target& rt, const CamState& cs,
                  const SelectParams& sp, const DrawParams& dp, int32_t target, uint32_t qslot,
                  const DrawOpts& opt, const SubmitHook& hook) {
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
        GpuNode gn = Upload(g, *P, *np);
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
      GpuNode gn = Upload(g, *P, *np);
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
  fu.r_min = (float)dp.r_min; fu.r_max = (float)dp.r_max;                     // R7
  // R6: Potree's orthographic uniforms (PotreeRenderer.js:1237-1240). The
  // perspective factor is not used then; tan_half_fov = 1 keeps it finite.
  fu.ortho = cs.cam.orthographic ? 1u : 0u;
  fu.ortho_width = (float)cs.cam.orthoWidth;
  fu.tan_half_fov = cs.cam.orthographic ? 1.0f
                                        : (float)std::tan(cs.cam.fovYDegrees * kPi / 180.0 / 2.0);
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

  // R4: the target is ours from BeginAccess until EndAccess after the hook.
  if (!BeginAccess(rt)) {
    fr.access_failed = true;
    fr.nodes_drawn = 0;
    fr.wall = NowMs() - t0;
    return fr;
  }
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
  ca.view = rt.view;                                                           // R2
  ca.loadOp = WGPULoadOp_Clear; ca.storeOp = WGPUStoreOp_Store;
  ca.clearValue = WGPUColor{dp.clear_rgba[0], dp.clear_rgba[1], dp.clear_rgba[2],
                            dp.clear_rgba[3]};                                 // R5
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
  fr.submit_ms = NowMs() - t0;
  // R3: the bench waited for the queue here; the hook does (or publishes first).
  if (hook.fn) hook.fn(hook.ctx, fr); else WaitQueueIdle(g);
  EndAccess(rt);
  const double t4 = NowMs();

  if (L->mode == LoadMode::Sync) EvictGpu(L);
  const double t5 = NowMs();

  fr.sel = t1 - t0; fr.load = t2 - t1; fr.upload = t3 - t2; fr.render = t4 - t3;
  if (L->mode == LoadMode::Async) { fr.load = t1 - t0; fr.sel = t2 - t1; }   // load = poll + dispose
  fr.wall = t5 - t0;
  return fr;
}

}  // namespace aether::pointcloud_lod_render
