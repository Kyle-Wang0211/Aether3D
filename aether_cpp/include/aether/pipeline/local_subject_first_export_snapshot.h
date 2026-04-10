// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_EXPORT_SNAPSHOT_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_EXPORT_SNAPSHOT_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <unordered_set>
#include <vector>

#include "aether/pipeline/pipeline_coordinator.h"
#include "aether/tsdf/tsdf_volume.h"

namespace aether {
namespace pipeline {
namespace local_subject_first_export_snapshot {

struct ExportSurfaceSnapshotCompactionResult {
    bool compacted{false};
    bool should_retry{false};
    std::size_t active_blocks{0};
    std::size_t assigned_block_count{0};
    std::size_t snapshot_count{0};
    std::size_t snapshot_bytes{0};
};

bool should_compact_export_surface_snapshot(
    bool export_surface_snapshot_compacted,
    bool scanning_active,
    bool features_frozen,
    bool tsdf_idle,
    bool training_started) noexcept;

void compact_export_surface_samples(
    const std::vector<tsdf::SurfacePoint>& input,
    std::vector<ExportSurfaceSample>* out) noexcept;

bool load_export_surface_samples_from_snapshot(
    const std::vector<ExportSurfaceSample>& snapshot,
    std::size_t max_points,
    std::vector<ExportSurfaceSample>& out) noexcept;

ExportSurfaceSnapshotCompactionResult compact_export_surface_snapshot(
    std::unique_ptr<tsdf::TSDFVolume>& tsdf_volume,
    std::unordered_set<std::int64_t>& assigned_blocks,
    std::vector<ExportSurfaceSample>& export_surface_snapshot) noexcept;

void log_compacted_export_surface_snapshot(
    const ExportSurfaceSnapshotCompactionResult& result) noexcept;

}  // namespace local_subject_first_export_snapshot
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_EXPORT_SNAPSHOT_H
