// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
#ifndef AETHER_CPP_TOOLS_DAWN_HISTOGRAM_SINK_H
#define AETHER_CPP_TOOLS_DAWN_HISTOGRAM_SINK_H

#include <cstdint>

// [PIPE-BD 2026-09-11] Dawn 自带分段计时器的接收端。
//
// 为什么单独一个 TU:`dawn::platform::Platform` 的 **typeinfo 不存在** ——
// `libdawn_platform.a` 里只有 vtable(`_ZTVN4dawn8platform8PlatformE`),没有
// `_ZTI…`,即 Dawn 是 **-fno-rtti** 编的。我们的 TU 带 RTTI,继承它就会引用一个
// 不存在的符号(实测:`Undefined symbols: typeinfo for dawn::platform::Platform`)。
// 所以把**唯一一处继承**关进这个文件,并只给它加 `-fno-rtti`,别的 TU 一律不动。
// 头里不出现任何 Dawn 类型,平台指针以 void* 过界。
namespace aether {
namespace tools {

// 进程级单例,返回 dawn::platform::Platform*(调用方转型后挂到
// DawnInstanceDescriptor::platform 上)。
void* dawn_histogram_sink_platform();

// 读某个 bin 的累计毫秒与**采样次数**。
// n 单独给:0 毫秒与「根本没被调用」必须分得开(静默出口是本仓头号复发缺陷)。
void dawn_histogram_get(const char* name, double* out_ms, uint32_t* out_n);

// Dawn Metal 后端埋好的两个名字(照抄源码,别手打):
//   metal/ShaderModuleMTL.mm:549 / metal/ComputePipelineMTL.mm:87
extern const char kDawnHistMslLibrary[];   // "Metal.newLibraryWithSource.CacheMiss"
extern const char kDawnHistPipelineState[];// "Metal.newComputePipelineStateWithDescriptor.CacheMiss"

}  // namespace tools
}  // namespace aether
#endif
