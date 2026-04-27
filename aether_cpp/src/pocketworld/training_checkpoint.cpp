// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pocketworld/training_checkpoint.h"

#include <cstdio>

namespace aether::pocketworld {

TrainingCheckpointHandle save_training_checkpoint(
    const std::string& checkpoint_path) {
    std::fprintf(stderr,
                 "[training_checkpoint] STUB - Phase 7 will implement checkpoint save "
                 "(path=%s)\n",
                 checkpoint_path.c_str());
    return TrainingCheckpointHandle{0};
}

TrainingCheckpointStatus query_training_checkpoint_status(
    TrainingCheckpointHandle handle) {
    std::fprintf(stderr,
                 "[training_checkpoint] STUB - query handle=%llu\n",
                 static_cast<unsigned long long>(handle.id));
    return TrainingCheckpointStatus::kFailed;
}

bool load_training_checkpoint(const std::string& checkpoint_path) {
    std::fprintf(stderr,
                 "[training_checkpoint] STUB - Phase 7 will implement checkpoint load "
                 "(path=%s)\n",
                 checkpoint_path.c_str());
    return false;
}

}  // namespace aether::pocketworld
