// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "official_gpu_timestamp_diagnostics_v1.h"

#if defined(__GNUC__) || defined(__clang__)
#define AETHER_GPU_TIMESTAMP_WEAK_STUB \
    __attribute__((weak, visibility("hidden")))
#else
#define AETHER_GPU_TIMESTAMP_WEAK_STUB
#endif

extern "C" AETHER_GPU_TIMESTAMP_WEAK_STUB int
aether_sed_gpu_timestamp_probe_v1(
        AetherGpuTimestampProbeV1* /*out_probe*/) {
    return AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1;
}

extern "C" AETHER_GPU_TIMESTAMP_WEAK_STUB int
aether_sed_last_gpu_timestamp_frame_v1(
        AetherGpuTimestampFrameV1* /*out_frame*/) {
    return AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1;
}

extern "C" AETHER_GPU_TIMESTAMP_WEAK_STUB int
aether_dsp_sift_take_last_gpu_timestamp_frame_v1(
        AetherGpuTimestampFrameV1* /*out_frame*/) {
    return AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1;
}

#undef AETHER_GPU_TIMESTAMP_WEAK_STUB
