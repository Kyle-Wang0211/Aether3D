// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_POCKETWORLD_TRAINING_CHECKPOINT_H
#define AETHER_CPP_POCKETWORLD_TRAINING_CHECKPOINT_H

#include <cstdint>
#include <string>

namespace aether::pocketworld {

enum class TrainingCheckpointStatus : std::uint8_t {
    kNotStarted,
    kSaving,
    kSaved,
    kLoading,
    kLoaded,
    kFailed,
};

struct TrainingCheckpointHandle {
    std::uint64_t id{0};
};

TrainingCheckpointHandle save_training_checkpoint(
    const std::string& checkpoint_path);

TrainingCheckpointStatus query_training_checkpoint_status(
    TrainingCheckpointHandle handle);

bool load_training_checkpoint(const std::string& checkpoint_path);

}  // namespace aether::pocketworld

#endif  // AETHER_CPP_POCKETWORLD_TRAINING_CHECKPOINT_H
