// Cross-platform WGSL SIFT descriptor-matcher benchmark (Dawn / WebGPU).
//
// Runs the SAME WGSL compute shader that would run on iOS/Android/Web via Dawn,
// here on the host macOS Metal backend. Brute-force 128-d squared-L2 + Lowe
// ratio, one thread per query. Measures A->B + B->A (the two passes the
// production cross-check needs), at the real on-device feature scale
// (nA=nB=11568 × 128), to compare against the native Metal matcher (1.44s/pair
// on iPhone 14 Pro). NOTE: this runs on the Mac GPU, not the A16 — it validates
// the WGSL kernel + gives a cross-platform speed point, not the iPhone number.

#include <webgpu/webgpu_cpp.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <ostream>
#include <vector>

namespace {

std::ostream& operator<<(std::ostream& os, const wgpu::StringView& s) {
  if (s.data == nullptr) return os;
  if (s.length == WGPU_STRLEN) return os << s.data;
  return os.write(s.data, static_cast<std::streamsize>(s.length));
}

constexpr uint32_t kN = 11568;   // real on-device feature count (2048@8192)
constexpr uint32_t kD = 128;
constexpr uint32_t kWG = 64;

// ---------------------------------------------------------------------------
// Kernel 1: NAIVE — one thread per query, streams all of B from global memory.
// Apple GPUs cache the repeated B reads well, so this is the reference.
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Kernel 2: TILED — cooperatively stage a TILE-row block of B into workgroup
// memory, then every thread in the group reuses it from the (fast) shared
// scratchpad. WGSL workgroup storage is f32 and the portable cap is ~16 KB, so
// TILE=32 rows (32*128*4 = 16 KB exactly). The thread's own query is held in a
// per-thread var<f32,128> register/private array so it is read once from global.
// @workgroup_size(64) => 64 threads cooperatively load 32 rows (2 rows/thread).
// ---------------------------------------------------------------------------
constexpr const char* kWgslTiled = R"(
const D    : u32 = 128u;
const TILE : u32 = 32u;   // 32 * 128 * 4 = 16 KB workgroup storage
const WG   : u32 = 64u;
struct Params { numA:u32, numB:u32, ratioSq:f32, _pad:u32 };
@group(0) @binding(0) var<storage, read>       A   : array<f32>;
@group(0) @binding(1) var<storage, read>       B   : array<f32>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform>             U   : Params;

var<workgroup> Bsh : array<f32, 4096>;   // TILE * D

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>,
        @builtin(local_invocation_id)  lid : vec3<u32>) {
  let i   : u32 = gid.x;
  let lx  : u32 = lid.x;
  let valid : bool = (i < U.numA);

  // load this thread's query into private registers (read B-tiles many times,
  // read own query once).
  var q : array<f32, 128>;
  if (valid) {
    let aBase : u32 = i * D;
    for (var d : u32 = 0u; d < D; d = d + 1u) { q[d] = A[aBase + d]; }
  }

  var best   : f32 = 1e30;
  var second : f32 = 1e30;
  var bi     : i32 = -1;

  var t0 : u32 = 0u;
  loop {
    if (t0 >= U.numB) { break; }
    let tileRows : u32 = min(TILE, U.numB - t0);

    // cooperative stage: 64 threads load TILE(32) rows * 128 floats = 4096 floats.
    // each thread loads 4096/64 = 64 contiguous floats.
    workgroupBarrier();
    var e : u32 = lx;
    loop {
      if (e >= tileRows * D) { break; }
      Bsh[e] = B[(t0 * D) + e];
      e = e + WG;
    }
    workgroupBarrier();

    // consume the staged tile from workgroup memory
    if (valid) {
      for (var r : u32 = 0u; r < tileRows; r = r + 1u) {
        let bBase : u32 = r * D;
        var dist : f32 = 0.0;
        for (var d : u32 = 0u; d < D; d = d + 1u) {
          let df : f32 = q[d] - Bsh[bBase + d];
          dist = dist + df * df;
        }
        if (dist < best) { second = best; best = dist; bi = i32(t0 + r); }
        else if (dist < second) { second = dist; }
      }
    }
    t0 = t0 + TILE;
  }

  if (valid) {
    Out[i] = select(-1, bi, best < U.ratioSq * second);
  }
}
)";

// ---------------------------------------------------------------------------
// Kernel 3: register-BLOCKED — each thread handles QPT=4 queries at once. The
// inner loop loads each B row's 128 dims ONCE and updates 4 running distances,
// so the (global-memory) B traffic is amortized 4x across queries while the
// queries stay resident in private registers. Higher arithmetic intensity per
// B read; no workgroup memory needed. @workgroup_size(64), grid covers
// ceil(numA / (64*4)) workgroups.
// ---------------------------------------------------------------------------
constexpr const char* kWgslBlocked = R"(
const D   : u32 = 128u;
const QPT : u32 = 4u;     // queries per thread
struct Params { numA:u32, numB:u32, ratioSq:f32, _pad:u32 };
@group(0) @binding(0) var<storage, read>       A   : array<f32>;
@group(0) @binding(1) var<storage, read>       B   : array<f32>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform>             U   : Params;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let q0 : u32 = gid.x * QPT;   // first query this thread owns
  if (q0 >= U.numA) { return; }

  // load up to QPT queries into private registers
  var q : array<f32, 512>;      // QPT * D = 4 * 128
  var act : array<bool, 4>;
  for (var k : u32 = 0u; k < QPT; k = k + 1u) {
    let qi : u32 = q0 + k;
    act[k] = (qi < U.numA);
    if (act[k]) {
      let aBase : u32 = qi * D;
      let kBase : u32 = k * D;
      for (var d : u32 = 0u; d < D; d = d + 1u) { q[kBase + d] = A[aBase + d]; }
    }
  }

  var best   : array<f32, 4>;
  var second : array<f32, 4>;
  var bi     : array<i32, 4>;
  for (var k : u32 = 0u; k < QPT; k = k + 1u) {
    best[k] = 1e30; second[k] = 1e30; bi[k] = -1;
  }

  for (var j : u32 = 0u; j < U.numB; j = j + 1u) {
    let bBase : u32 = j * D;
    var dist : array<f32, 4>;
    dist[0] = 0.0; dist[1] = 0.0; dist[2] = 0.0; dist[3] = 0.0;
    // read each B dim once, fan it out across the 4 resident queries
    for (var d : u32 = 0u; d < D; d = d + 1u) {
      let bv : f32 = B[bBase + d];
      let d0 : f32 = q[d]        - bv; dist[0] = dist[0] + d0 * d0;
      let d1 : f32 = q[128u + d] - bv; dist[1] = dist[1] + d1 * d1;
      let d2 : f32 = q[256u + d] - bv; dist[2] = dist[2] + d2 * d2;
      let d3 : f32 = q[384u + d] - bv; dist[3] = dist[3] + d3 * d3;
    }
    for (var k : u32 = 0u; k < QPT; k = k + 1u) {
      let dk : f32 = dist[k];
      if (dk < best[k]) { second[k] = best[k]; best[k] = dk; bi[k] = i32(j); }
      else if (dk < second[k]) { second[k] = dk; }
    }
  }

  for (var k : u32 = 0u; k < QPT; k = k + 1u) {
    if (act[k]) {
      Out[q0 + k] = select(-1, bi[k], best[k] < U.ratioSq * second[k]);
    }
  }
}
)";

struct Params { uint32_t numA, numB; float ratioSq; uint32_t pad; };

}  // namespace

int main() {
  static constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
  wgpu::InstanceDescriptor id{ .requiredFeatureCount = 1, .requiredFeatures = &kTimedWaitAny };
  wgpu::Instance instance = wgpu::CreateInstance(&id);
  if (!instance) { std::cerr << "CreateInstance failed\n"; return 1; }

  wgpu::Adapter adapter;
  { wgpu::RequestAdapterOptions o{};
    instance.WaitAny(instance.RequestAdapter(&o, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::RequestAdapterStatus s, wgpu::Adapter a, wgpu::StringView m){
        if (s==wgpu::RequestAdapterStatus::Success) adapter=std::move(a); else std::cerr<<"adapter: "<<m<<'\n';}), UINT64_MAX);
    if (!adapter) return 1; }
  { wgpu::AdapterInfo info{}; adapter.GetInfo(&info);
    std::cout << "GPU: " << info.device << "\n"; }

  wgpu::Device device;
  { wgpu::DeviceDescriptor d{};
    instance.WaitAny(adapter.RequestDevice(&d, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::RequestDeviceStatus s, wgpu::Device dev, wgpu::StringView m){
        if (s==wgpu::RequestDeviceStatus::Success) device=std::move(dev); else std::cerr<<"device: "<<m<<'\n';}), UINT64_MAX);
    if (!device) return 1; }
  wgpu::Queue queue = device.GetQueue();

  // synthetic descriptors: f32 in [0,255] (mimics uint8 widened), real scale
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

  // ---- compile a WGSL module + compute pipeline, tolerating failure --------
  auto mkPipeline = [&](const char* code, const char* label) -> wgpu::ComputePipeline {
    wgpu::ShaderSourceWGSL src{}; src.code = code;
    wgpu::ShaderModuleDescriptor smd{}; smd.nextInChain = &src; smd.label = label;
    wgpu::ShaderModule shader = device.CreateShaderModule(&smd);
    // surface any WGSL compile diagnostics synchronously
    bool ok = true;
    instance.WaitAny(shader.GetCompilationInfo(wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::CompilationInfoRequestStatus, const wgpu::CompilationInfo* info){
        if (!info) return;
        for (size_t m = 0; m < info->messageCount; ++m) {
          const auto& msg = info->messages[m];
          if (msg.type == wgpu::CompilationMessageType::Error) {
            ok = false;
            std::cerr << "[" << label << "] WGSL error: " << msg.message << '\n';
          }
        }
      }), UINT64_MAX);
    if (!ok) return wgpu::ComputePipeline();
    wgpu::ComputePipelineDescriptor pd{}; pd.label = label;
    pd.compute.module = shader; pd.compute.entryPoint = "main";
    return device.CreateComputePipeline(&pd);
  };

  auto mkBG = [&](wgpu::ComputePipeline pipe, wgpu::Buffer q, wgpu::Buffer db,
                  wgpu::Buffer out, wgpu::Buffer params){
    wgpu::BindGroupEntry e[4] = {
      {.binding=0,.buffer=q,.offset=0,.size=descBytes},
      {.binding=1,.buffer=db,.offset=0,.size=descBytes},
      {.binding=2,.buffer=out,.offset=0,.size=outBytes},
      {.binding=3,.buffer=params,.offset=0,.size=sizeof(Params)} };
    wgpu::BindGroupDescriptor bd{ .layout = pipe.GetBindGroupLayout(0), .entryCount = 4, .entries = e };
    return device.CreateBindGroup(&bd); };

  // bench one pipeline over both passes; returns best ms across iters, or -1.
  auto benchPipeline = [&](wgpu::ComputePipeline pipe, uint32_t groups,
                           const char* tag) -> double {
    if (!pipe) { std::cout << tag << " both_passes_ms=-1  (compile failed)\n"; return -1.0; }
    wgpu::BindGroup bgAB = mkBG(pipe, aBuf, bBuf, outAB, pAB);
    wgpu::BindGroup bgBA = mkBG(pipe, bBuf, aBuf, outBA, pBA);
    auto runOnce = [&]{
      wgpu::CommandEncoder enc = device.CreateCommandEncoder();
      { wgpu::ComputePassEncoder p = enc.BeginComputePass();
        p.SetPipeline(pipe); p.SetBindGroup(0, bgAB); p.DispatchWorkgroups(groups);
        p.SetBindGroup(0, bgBA); p.DispatchWorkgroups(groups); p.End(); }
      wgpu::CommandBuffer cmd = enc.Finish();
      queue.Submit(1, &cmd);
      bool done = false;
      instance.WaitAny(queue.OnSubmittedWorkDone(wgpu::CallbackMode::WaitAnyOnly,
        [&](wgpu::QueueWorkDoneStatus, wgpu::StringView){ done = true; }), UINT64_MAX);
      (void)done; };
    runOnce();  // warmup (pipeline JIT / first submit)
    double best = 1e30;
    for (int it = 0; it < 5; ++it) {
      auto t0 = std::chrono::high_resolution_clock::now();
      runOnce();
      double ms = std::chrono::duration<double, std::milli>(
          std::chrono::high_resolution_clock::now() - t0).count();
      std::cout << "  iter " << it << ": " << ms << " ms (both passes)\n";
      if (ms < best) best = ms;
    }
    std::cout << tag << " both_passes_ms=" << best << "\n";
    return best;
  };

  std::cout << "scale: nA=nB=" << kN << " x" << kD << "  (A->B + B->A per iter)\n";

  const uint32_t groupsNaive   = (kN + kWG - 1) / kWG;           // 1 query / thread
  const uint32_t groupsTiled   = (kN + kWG - 1) / kWG;           // 1 query / thread
  const uint32_t groupsBlocked = (kN + (kWG * 4u) - 1) / (kWG * 4u); // 4 queries / thread

  std::cout << "\n[naive]  one thread / query, B streamed from global:\n";
  double naive = benchPipeline(mkPipeline(kWgsl, "naive"), groupsNaive,
                               "WGSL_MATCH_BEST");

  std::cout << "\n[tiled]  TILE=32 rows of B staged in workgroup memory:\n";
  double tiled = benchPipeline(mkPipeline(kWgslTiled, "tiled"), groupsTiled,
                               "WGSL_TILED_BEST");

  std::cout << "\n[blocked]  4 queries / thread, B dim read once + fanned out:\n";
  double blocked = benchPipeline(mkPipeline(kWgslBlocked, "blocked"), groupsBlocked,
                                 "WGSL_BLOCKED_BEST");

  std::cout << "\n==== SUMMARY (M3 Pro, WGSL/Dawn, both passes ms) ====\n";
  std::cout << "  naive   = " << naive   << " ms\n";
  std::cout << "  tiled   = " << tiled   << " ms"
            << (tiled   > 0 ? (tiled   < naive ? "  (faster)" : "  (slower)") : "") << "\n";
  std::cout << "  blocked = " << blocked << " ms"
            << (blocked > 0 ? (blocked < naive ? "  (faster)" : "  (slower)") : "") << "\n";
  std::cout << "  vs native Metal iPhone A16 naive=1437ms tiled=1550ms\n";
  return 0;
}
