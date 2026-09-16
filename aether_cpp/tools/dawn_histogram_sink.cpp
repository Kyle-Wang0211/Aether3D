// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// [PIPE-BD 2026-09-11] 判词见 dawn_histogram_sink.h。**本文件必须以 -fno-rtti 编译。**
#include "dawn_histogram_sink.h"

#include <chrono>
#include <map>
#include <mutex>
#include <string>
#include <utility>

#include "dawn/platform/DawnPlatform.h"

namespace aether {
namespace tools {

const char kDawnHistMslLibrary[] = "Metal.newLibraryWithSource.CacheMiss";
const char kDawnHistPipelineState[] =
    "Metal.newComputePipelineStateWithDescriptor.CacheMiss";

namespace {
class HistogramSink final : public dawn::platform::Platform {
  public:
    // 🔴 这个覆写不是可选的。`DawnHistogramTimer::RecordMicroseconds` 在
    // `mConstructed == 0` 时**直接 return**(platform/metrics/HistogramMacros.cpp:36-44),
    // 而 mConstructed 来自本方法,**基类默认返回 0**(platform/DawnPlatform.cpp:50-52)。
    // 只覆写 Histogram* 的话回调**永远不响且不报错** —— 典型静默出口。
    double MonotonicallyIncreasingTime() override {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    }
    void HistogramCustomCountsHPC(const char* name, int sample, int, int, int) override {
        if (name == nullptr) return;
        std::lock_guard<std::mutex> lk(mu_);
        auto& e = bins_[name];
        e.first += static_cast<double>(sample) / 1000.0;  // µs → ms
        e.second += 1u;
    }
    void HistogramCustomCounts(const char* name, int sample, int a, int b, int c) override {
        HistogramCustomCountsHPC(name, sample, a, b, c);
    }
    void Get(const char* name, double* ms, uint32_t* n) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = bins_.find(name);
        if (it == bins_.end()) { if (ms) *ms = 0.0; if (n) *n = 0u; return; }
        if (ms) *ms = it->second.first;
        if (n) *n = it->second.second;
    }
  private:
    std::mutex mu_;
    std::map<std::string, std::pair<double, uint32_t>> bins_;
};
HistogramSink g_sink;   // 进程级:Dawn instance 的生命期比任何一次提取都长
}  // namespace

void* dawn_histogram_sink_platform() {
    return static_cast<dawn::platform::Platform*>(&g_sink);
}

void dawn_histogram_get(const char* name, double* out_ms, uint32_t* out_n) {
    if (out_ms) *out_ms = 0.0;
    if (out_n) *out_n = 0u;
    if (name == nullptr) return;
    g_sink.Get(name, out_ms, out_n);
}

}  // namespace tools
}  // namespace aether
