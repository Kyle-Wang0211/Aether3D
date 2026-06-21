// On-device Dawn/WebGPU WGSL SIFT descriptor-matcher runner (iOS, Metal backend).
//
// Runs the SAME WGSL compute kernels as tools/aether_dawn_descriptor_matcher_bench.cpp,
// but on the iPhone's GPU (A16) via Dawn-iOS -> Tint -> Metal. Reports A->B + B->A
// (both passes) timing so it is directly comparable to the native Metal matcher
// (1437 ms/pair on iPhone 14 Pro) and to the Mac-host WGSL bench (~304 ms M3 Pro).
//
// The kernels are copied verbatim from the cross-platform bench. This file exposes
// a single C entry point `dawn_match_run_all(char* out, int out_cap)` callable from
// the Objective-C AppDelegate; it logs progress via printf (idevicesyslog/console)
// and returns a one-line result string.

#include <webgpu/webgpu_cpp.h>

#include <os/log.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

constexpr uint32_t kN  = 11568;  // real on-device feature count (2048@8192)
constexpr uint32_t kD  = 128;
constexpr uint32_t kWG = 64;

// ── Kernel: NAIVE one-thread-per-query (the reference; Apple GPUs cache B well) ──
constexpr const char* kWgsl = R"(
const D : u32 = 128u;
struct Params { numA:u32, numB:u32, ratioSq:f32, _pad:u32 };
@group(0) @binding(0) var<storage, read>       A   : array<f32>;
@group(0) @binding(1) var<storage, read>       B   : array<f32>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform>             U   : Params;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let i : u32 = gid.x;
  if (i >= U.numA) { return; }
  let aBase : u32 = i * D;
  var best : f32 = 1e30;
  var second : f32 = 1e30;
  var bi : i32 = -1;
  for (var j : u32 = 0u; j < U.numB; j = j + 1u) {
    let bBase : u32 = j * D;
    var dist : f32 = 0.0;
    for (var d : u32 = 0u; d < D; d = d + 1u) {
      let df : f32 = A[aBase + d] - B[bBase + d];
      dist = dist + df * df;
    }
    if (dist < best) { second = best; best = dist; bi = i32(j); }
    else if (dist < second) { second = dist; }
  }
  Out[i] = select(-1, bi, best < U.ratioSq * second);
}
)";

struct Params { uint32_t numA, numB; float ratioSq; uint32_t pad; };

void logline(const char* s) {
  printf("%s\n", s);
  fflush(stdout);
  os_log(OS_LOG_DEFAULT, "%{public}s", s);
}

}  // namespace

extern "C" int dawn_match_run_all(char* out, int out_cap) {
  if (out && out_cap > 0) out[0] = 0;
  logline("DAWN_MATCH_BEGIN");

  static constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
  wgpu::InstanceDescriptor id{ .requiredFeatureCount = 1, .requiredFeatures = &kTimedWaitAny };
  wgpu::Instance instance = wgpu::CreateInstance(&id);
  if (!instance) { logline("DAWN_MATCH_FAIL CreateInstance"); return 1; }

  wgpu::Adapter adapter;
  { wgpu::RequestAdapterOptions o{};
    instance.WaitAny(instance.RequestAdapter(&o, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::RequestAdapterStatus s, wgpu::Adapter a, wgpu::StringView){
        if (s == wgpu::RequestAdapterStatus::Success) adapter = std::move(a); }), UINT64_MAX);
    if (!adapter) { logline("DAWN_MATCH_FAIL RequestAdapter"); return 1; } }
  { wgpu::AdapterInfo info{}; adapter.GetInfo(&info);
    char b[256];
    snprintf(b, sizeof(b), "DAWN_GPU device=%.*s",
             info.device.length == WGPU_STRLEN ? (int)strlen(info.device.data) : (int)info.device.length,
             info.device.data ? info.device.data : "");
    logline(b); }

  wgpu::Device device;
  { wgpu::DeviceDescriptor d{};
    instance.WaitAny(adapter.RequestDevice(&d, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::RequestDeviceStatus s, wgpu::Device dev, wgpu::StringView){
        if (s == wgpu::RequestDeviceStatus::Success) device = std::move(dev); }), UINT64_MAX);
    if (!device) { logline("DAWN_MATCH_FAIL RequestDevice"); return 1; } }
  wgpu::Queue queue = device.GetQueue();

  // synthetic descriptors at real scale: f32 in [0,255] (mimics uint8 widened)
  std::vector<float> A(static_cast<size_t>(kN) * kD), B(static_cast<size_t>(kN) * kD);
  uint64_t st = 0x9e3779b97f4a7c15ull;
  auto rnd = [&]{ st ^= st<<13; st ^= st>>7; st ^= st<<17; return float(st >> 40) * (255.0f / 16777216.0f); };
  for (auto& v : A) v = rnd();
  for (auto& v : B) v = rnd();

  const uint64_t descBytes = uint64_t(kN) * kD * sizeof(float);
  const uint64_t outBytes  = uint64_t(kN) * sizeof(int32_t);
  auto mkStorage = [&](const void* data, uint64_t bytes){
    wgpu::BufferDescriptor bd{ .usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst, .size = bytes };
    wgpu::Buffer b = device.CreateBuffer(&bd); queue.WriteBuffer(b, 0, data, bytes); return b; };
  wgpu::Buffer aBuf = mkStorage(A.data(), descBytes);
  wgpu::Buffer bBuf = mkStorage(B.data(), descBytes);
  wgpu::BufferDescriptor od{ .usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc, .size = outBytes };
  wgpu::Buffer outAB = device.CreateBuffer(&od);
  wgpu::Buffer outBA = device.CreateBuffer(&od);
  auto mkUniform = [&](Params p){
    wgpu::BufferDescriptor bd{ .usage = wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst, .size = sizeof(Params) };
    wgpu::Buffer b = device.CreateBuffer(&bd); queue.WriteBuffer(b, 0, &p, sizeof(Params)); return b; };
  wgpu::Buffer pAB = mkUniform({kN, kN, 0.49f, 0});
  wgpu::Buffer pBA = mkUniform({kN, kN, 0.49f, 0});

  wgpu::ShaderSourceWGSL src{}; src.code = kWgsl;
  wgpu::ShaderModuleDescriptor smd{}; smd.nextInChain = &src;
  wgpu::ShaderModule shader = device.CreateShaderModule(&smd);
  wgpu::ComputePipelineDescriptor pd{}; pd.compute.module = shader; pd.compute.entryPoint = "main";
  wgpu::ComputePipeline pipe = device.CreateComputePipeline(&pd);
  if (!pipe) { logline("DAWN_MATCH_FAIL CreateComputePipeline (WGSL->Tint->Metal compile)"); return 1; }

  auto mkBG = [&](wgpu::Buffer q, wgpu::Buffer db, wgpu::Buffer outb, wgpu::Buffer params){
    wgpu::BindGroupEntry e[4] = {
      {.binding=0,.buffer=q,.offset=0,.size=descBytes},
      {.binding=1,.buffer=db,.offset=0,.size=descBytes},
      {.binding=2,.buffer=outb,.offset=0,.size=outBytes},
      {.binding=3,.buffer=params,.offset=0,.size=sizeof(Params)} };
    wgpu::BindGroupDescriptor bd{ .layout = pipe.GetBindGroupLayout(0), .entryCount = 4, .entries = e };
    return device.CreateBindGroup(&bd); };
  wgpu::BindGroup bgAB = mkBG(aBuf, bBuf, outAB, pAB);
  wgpu::BindGroup bgBA = mkBG(bBuf, aBuf, outBA, pBA);
  const uint32_t groups = (kN + kWG - 1) / kWG;

  // MapRead staging buffer — copying outAB into it (as the LAST command, after
  // both compute passes) and then MapAsync'ing it gives a TRUE GPU sync: the map
  // only resolves once the GPU has finished the copy, which is ordered after both
  // dispatches. (OnSubmittedWorkDone does NOT reliably block on the iOS Dawn
  // backend — it returned ~immediately, giving a bogus 1.02ms.)
  wgpu::BufferDescriptor sd{ .usage = wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst,
                             .size = outBytes };
  wgpu::Buffer staging = device.CreateBuffer(&sd);

  auto runOnce = [&]{
    wgpu::CommandEncoder enc = device.CreateCommandEncoder();
    { wgpu::ComputePassEncoder p = enc.BeginComputePass();
      p.SetPipeline(pipe); p.SetBindGroup(0, bgAB); p.DispatchWorkgroups(groups);
      p.SetBindGroup(0, bgBA); p.DispatchWorkgroups(groups); p.End(); }
    enc.CopyBufferToBuffer(outAB, 0, staging, 0, outBytes);  // ordered after both passes
    wgpu::CommandBuffer cmd = enc.Finish();
    queue.Submit(1, &cmd);
    bool mapped = false;
    instance.WaitAny(staging.MapAsync(wgpu::MapMode::Read, 0, outBytes,
      wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::MapAsyncStatus, wgpu::StringView){ mapped = true; }), UINT64_MAX);
    staging.Unmap();
    (void)mapped; };

  { char b[160]; snprintf(b, sizeof(b), "DAWN_SCALE nA=nB=%u x%u (A->B + B->A per iter)", kN, kD); logline(b); }
  runOnce();  // warmup (pipeline JIT / first submit)
  double best = 1e30;
  for (int it = 0; it < 5; ++it) {
    auto t0 = std::chrono::high_resolution_clock::now();
    runOnce();
    double ms = std::chrono::duration<double, std::milli>(
        std::chrono::high_resolution_clock::now() - t0).count();
    char b[120]; snprintf(b, sizeof(b), "  iter %d: %.2f ms (both passes)", it, ms); logline(b);
    if (ms < best) best = ms;
  }
  char res[200];
  snprintf(res, sizeof(res),
           "DAWN_WGSL_MATCH_BEST both_passes_ms=%.2f per_pair_ms=%.2f (vs native Metal iPhone 1437ms)",
           best, best);
  logline(res);
  logline("DAWN_MATCH_DONE");
  if (out && out_cap > 0) { strncpy(out, res, out_cap - 1); out[out_cap - 1] = 0; }
  return 0;
}
