// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary

#include "official_gpu_timestamp_diagnostics_v1.h"

extern "C" const char* aether_gpu_timestamp_selected_env_key_contract_v1() {
    return aether::tools::gpu_timestamp_internal::
        AETHER_GPU_TIMESTAMP_ENV_KEY_V1;
}
