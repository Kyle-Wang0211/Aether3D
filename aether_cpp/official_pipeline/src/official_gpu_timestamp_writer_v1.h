// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_WRITER_V1_H
#define AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_WRITER_V1_H

#include "official_gpu_timestamp_diagnostics_v1.h"

#include <cstdint>
#include <string>

namespace aether::official::gpu_timestamp_writer_v1 {

// Product/session identity is intentionally attached only at the writer. The
// native extractor POD contains only probe_instance_id/extraction_ordinal.
struct RecordIdentityV1 {
  uint64_t run_id;
  int64_t frame_id;
  uint64_t frame_ordinal;
  uint64_t probe_record_id;
};

// These are private C++ helpers compiled into pwofficial_core. They are not
// declared by aether_sfm_c.h and are hidden with the rest of the official core.
// On failure, out_json is left unchanged.
bool SerializeProbeRecordV1(const AetherGpuTimestampProbeV1& probe,
                            const RecordIdentityV1& identity,
                            int64_t epoch_ms, std::string* out_json);
bool SerializeFrameRecordV1(const AetherGpuTimestampFrameV1& frame,
                            const RecordIdentityV1& identity,
                            int64_t epoch_ms, std::string* out_json);

}  // namespace aether::official::gpu_timestamp_writer_v1

#endif  // AETHER_CPP_OFFICIAL_PIPELINE_SRC_OFFICIAL_GPU_TIMESTAMP_WRITER_V1_H
