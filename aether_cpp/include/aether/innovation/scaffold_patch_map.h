// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_SCAFFOLD_PATCH_MAP_H
#define AETHER_INNOVATION_SCAFFOLD_PATCH_MAP_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"
#include "aether/tsdf/block_index.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace innovation {

struct ScaffoldPatchRecord {
    ScaffoldUnitId unit_id{0};
    std::uint32_t generation{0};
    std::uint8_t lod_level{0};
    std::string patch_id{};
    tsdf::BlockIndex block_index{};
};

class ScaffoldPatchMap {
public:
    ScaffoldPatchMap() = default;

    void reset();
    std::size_t unit_count() const { return units_.size(); }
    std::size_t binding_count() const { return gaussian_to_unit_.size(); }

    core::Status upsert_unit(
        const ScaffoldUnit& unit,
        const tsdf::BlockIndex& block_index);
    core::Status remove_unit(ScaffoldUnitId unit_id);

    core::Status bind_gaussian(
        GaussianId gaussian_id,
        ScaffoldUnitId unit_id);
    core::Status unbind_gaussian(GaussianId gaussian_id);
    core::Status bind_from_primitives(
        const GaussianPrimitive* gaussians,
        std::size_t gaussian_count);

    core::Status record_for_unit(
        ScaffoldUnitId unit_id,
        ScaffoldPatchRecord* out_record) const;
    core::Status unit_id_for_patch_id(
        const std::string& patch_id,
        ScaffoldUnitId* out_unit_id) const;
    core::Status block_index_for_patch_id(
        const std::string& patch_id,
        tsdf::BlockIndex* out_block_index) const;
    core::Status patch_id_for_unit(
        ScaffoldUnitId unit_id,
        std::string* out_patch_id) const;

    core::Status gaussian_ids_for_unit(
        ScaffoldUnitId unit_id,
        std::vector<GaussianId>* out_gaussian_ids) const;
    core::Status gaussian_ids_for_patch_id(
        const std::string& patch_id,
        std::vector<GaussianId>* out_gaussian_ids) const;
    core::Status unit_ids_for_patch_id(
        const std::string& patch_id,
        std::vector<ScaffoldUnitId>* out_unit_ids) const;

    static core::Status patch_id_from_block_index(
        const tsdf::BlockIndex& block_index,
        std::string* out_patch_id);
    static core::Status block_index_from_patch_id(
        const std::string& patch_id,
        tsdf::BlockIndex* out_block_index);

private:
    struct UnitEntry {
        ScaffoldUnitId unit_id{0};
        std::uint32_t generation{0};
        std::uint8_t lod_level{0};
        std::string patch_id{};
        tsdf::BlockIndex block_index{};
    };

    std::vector<UnitEntry> units_{};  // sorted by unit_id
    std::vector<std::pair<std::string, ScaffoldUnitId>> patch_to_unit_{};  // sorted by patch_id
    std::vector<std::pair<GaussianId, ScaffoldUnitId>> gaussian_to_unit_{};  // sorted by gaussian_id
};

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_SCAFFOLD_PATCH_MAP_H
