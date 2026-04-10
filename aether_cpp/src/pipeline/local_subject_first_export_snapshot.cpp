// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_export_snapshot.h"

#include <algorithm>
#include <cstdio>

namespace aether {
namespace pipeline {
namespace local_subject_first_export_snapshot {

bool should_compact_export_surface_snapshot(
    bool export_surface_snapshot_compacted,
    bool scanning_active,
    bool features_frozen,
    bool tsdf_idle,
    bool training_started) noexcept
{
    return !export_surface_snapshot_compacted &&
           !scanning_active &&
           features_frozen &&
           tsdf_idle &&
           training_started;
}

void compact_export_surface_samples(
    const std::vector<tsdf::SurfacePoint>& input,
    std::vector<ExportSurfaceSample>* out) noexcept
{
    if (!out) {
        return;
    }
    out->clear();
    if (input.empty()) {
        return;
    }

    out->reserve(input.size());
    for (const auto& point : input) {
        ExportSurfaceSample sample;
        sample.position[0] = point.position[0];
        sample.position[1] = point.position[1];
        sample.position[2] = point.position[2];
        sample.confidence = point.confidence;
        sample.weight = point.weight;
        out->push_back(sample);
    }
}

bool load_export_surface_samples_from_snapshot(
    const std::vector<ExportSurfaceSample>& snapshot,
    std::size_t max_points,
    std::vector<ExportSurfaceSample>& out) noexcept
{
    out.clear();
    if (max_points == 0 || snapshot.empty()) {
        return false;
    }

    const std::size_t count = std::min(max_points, snapshot.size());
    out.insert(
        out.end(),
        snapshot.begin(),
        snapshot.begin() + static_cast<std::ptrdiff_t>(count));
    return !out.empty();
}

ExportSurfaceSnapshotCompactionResult compact_export_surface_snapshot(
    std::unique_ptr<tsdf::TSDFVolume>& tsdf_volume,
    std::unordered_set<std::int64_t>& assigned_blocks,
    std::vector<ExportSurfaceSample>& export_surface_snapshot) noexcept
{
    ExportSurfaceSnapshotCompactionResult result;
    if (!tsdf_volume) {
        result.compacted = true;
        return result;
    }

    result.active_blocks = tsdf_volume->active_block_count();
    std::vector<tsdf::SurfacePoint> live_surface_points;
    tsdf_volume->extract_surface_points(live_surface_points, 250000);
    if (live_surface_points.empty() && result.active_blocks > 0) {
        result.should_retry = true;
        return result;
    }

    result.assigned_block_count = assigned_blocks.size();
    compact_export_surface_samples(live_surface_points, &export_surface_snapshot);
    export_surface_snapshot.shrink_to_fit();
    result.snapshot_count = export_surface_snapshot.size();
    result.snapshot_bytes =
        export_surface_snapshot.size() * sizeof(ExportSurfaceSample);

    tsdf_volume.reset();
    assigned_blocks.clear();
    assigned_blocks.rehash(0);
    result.compacted = true;
    return result;
}

void log_compacted_export_surface_snapshot(
    const ExportSurfaceSnapshotCompactionResult& result) noexcept
{
    if (!result.compacted) {
        return;
    }
    std::fprintf(
        stderr,
        "[Aether3D][CaptureBudget] compacted export surface snapshot "
        "samples=%zu active_blocks=%zu snapshot_bytes=%zu assigned_blocks=%zu released_tsdf=YES\n",
        result.snapshot_count,
        result.active_blocks,
        result.snapshot_bytes,
        result.assigned_block_count);
}

}  // namespace local_subject_first_export_snapshot
}  // namespace pipeline
}  // namespace aether
