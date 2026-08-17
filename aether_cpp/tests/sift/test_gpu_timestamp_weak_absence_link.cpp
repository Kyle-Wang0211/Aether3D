// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "official_gpu_timestamp_diagnostics_v1.h"

int main() {
    AetherGpuTimestampProbeV1 probe{};
    probe.struct_size = sizeof(probe);
    AetherGpuTimestampFrameV1 frame{};
    frame.struct_size = sizeof(frame);
    return aether_sed_gpu_timestamp_probe_v1(&probe) ==
                       AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1 &&
                   aether_sed_last_gpu_timestamp_frame_v1(&frame) ==
                       AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1 &&
                   aether_dsp_sift_take_last_gpu_timestamp_frame_v1(&frame) ==
                       AETHER_GPU_TIMESTAMP_PULL_NOT_READY_V1
               ? 0
               : 1;
}
