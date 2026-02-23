// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/scaffold_patch_map.h"

#include <algorithm>
#include <cstdio>

namespace aether {
namespace innovation {
namespace {

const char* kPatchPrefix = "blk:";

template <typename T>
std::size_t lower_bound_pair_second(
    const std::vector<std::pair<T, ScaffoldUnitId>>& entries,
    const T& key) {
    std::size_t left = 0u;
    std::size_t right = entries.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (entries[mid].first < key) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    return left;
}

template <typename UnitEntryT>
std::size_t lower_bound_unit(
    const std::vector<UnitEntryT>& units,
    ScaffoldUnitId unit_id) {
    std::size_t left = 0u;
    std::size_t right = units.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (units[mid].unit_id < unit_id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    return left;
}

std::size_t lower_bound_gaussian(
    const std::vector<std::pair<GaussianId, ScaffoldUnitId>>& entries,
    GaussianId gaussian_id) {
    std::size_t left = 0u;
    std::size_t right = entries.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (entries[mid].first < gaussian_id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    return left;
}

}  // namespace

void ScaffoldPatchMap::reset() {
    units_.clear();
    patch_to_unit_.clear();
    gaussian_to_unit_.clear();
}

core::Status ScaffoldPatchMap::patch_id_from_block_index(
    const tsdf::BlockIndex& block_index,
    std::string* out_patch_id) {
    if (out_patch_id == nullptr) {
        return core::Status::kInvalidArgument;
    }
    char buffer[96];
    const int written = std::snprintf(
        buffer,
        sizeof(buffer),
        "%s%d_%d_%d",
        kPatchPrefix,
        static_cast<int>(block_index.x),
        static_cast<int>(block_index.y),
        static_cast<int>(block_index.z));
    if (written <= 0 || static_cast<std::size_t>(written) >= sizeof(buffer)) {
        return core::Status::kOutOfRange;
    }
    *out_patch_id = buffer;
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::block_index_from_patch_id(
    const std::string& patch_id,
    tsdf::BlockIndex* out_block_index) {
    if (out_block_index == nullptr || patch_id.empty()) {
        return core::Status::kInvalidArgument;
    }
    if (patch_id.rfind(kPatchPrefix, 0u) != 0u) {
        return core::Status::kInvalidArgument;
    }
    int bx = 0;
    int by = 0;
    int bz = 0;
    if (std::sscanf(patch_id.c_str() + 4, "%d_%d_%d", &bx, &by, &bz) != 3) {
        return core::Status::kInvalidArgument;
    }
    out_block_index->x = static_cast<std::int32_t>(bx);
    out_block_index->y = static_cast<std::int32_t>(by);
    out_block_index->z = static_cast<std::int32_t>(bz);
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::upsert_unit(
    const ScaffoldUnit& unit,
    const tsdf::BlockIndex& block_index) {
    if (unit.unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }

    std::string patch_id = unit.patch_id;
    if (patch_id.empty()) {
        const core::Status id_status = patch_id_from_block_index(block_index, &patch_id);
        if (id_status != core::Status::kOk) {
            return id_status;
        }
    }

    const std::size_t unit_pos = lower_bound_unit(units_, unit.unit_id);
    UnitEntry entry{};
    entry.unit_id = unit.unit_id;
    entry.generation = unit.generation;
    entry.lod_level = unit.lod_level;
    entry.patch_id = patch_id;
    entry.block_index = block_index;
    if (unit_pos < units_.size() && units_[unit_pos].unit_id == unit.unit_id) {
        const std::string old_patch_id = units_[unit_pos].patch_id;
        units_[unit_pos] = entry;
        if (old_patch_id != patch_id) {
            const std::size_t old_pos = lower_bound_pair_second(patch_to_unit_, old_patch_id);
            if (old_pos < patch_to_unit_.size() &&
                patch_to_unit_[old_pos].first == old_patch_id &&
                patch_to_unit_[old_pos].second == unit.unit_id) {
                patch_to_unit_.erase(patch_to_unit_.begin() + static_cast<std::ptrdiff_t>(old_pos));
            }
        }
    } else {
        units_.insert(units_.begin() + static_cast<std::ptrdiff_t>(unit_pos), entry);
    }

    const std::size_t patch_pos = lower_bound_pair_second(patch_to_unit_, patch_id);
    if (patch_pos < patch_to_unit_.size() && patch_to_unit_[patch_pos].first == patch_id) {
        patch_to_unit_[patch_pos].second = unit.unit_id;
    } else {
        patch_to_unit_.insert(
            patch_to_unit_.begin() + static_cast<std::ptrdiff_t>(patch_pos),
            std::make_pair(patch_id, unit.unit_id));
    }
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::remove_unit(ScaffoldUnitId unit_id) {
    if (unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t unit_pos = lower_bound_unit(units_, unit_id);
    if (unit_pos >= units_.size() || units_[unit_pos].unit_id != unit_id) {
        return core::Status::kOutOfRange;
    }
    const std::string patch_id = units_[unit_pos].patch_id;
    units_.erase(units_.begin() + static_cast<std::ptrdiff_t>(unit_pos));

    const std::size_t patch_pos = lower_bound_pair_second(patch_to_unit_, patch_id);
    if (patch_pos < patch_to_unit_.size() &&
        patch_to_unit_[patch_pos].first == patch_id &&
        patch_to_unit_[patch_pos].second == unit_id) {
        patch_to_unit_.erase(patch_to_unit_.begin() + static_cast<std::ptrdiff_t>(patch_pos));
    }

    gaussian_to_unit_.erase(
        std::remove_if(
            gaussian_to_unit_.begin(),
            gaussian_to_unit_.end(),
            [unit_id](const std::pair<GaussianId, ScaffoldUnitId>& item) {
                return item.second == unit_id;
            }),
        gaussian_to_unit_.end());
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::bind_gaussian(
    GaussianId gaussian_id,
    ScaffoldUnitId unit_id) {
    if (gaussian_id == 0u || unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t unit_pos = lower_bound_unit(units_, unit_id);
    if (unit_pos >= units_.size() || units_[unit_pos].unit_id != unit_id) {
        return core::Status::kOutOfRange;
    }
    const std::size_t bind_pos = lower_bound_gaussian(gaussian_to_unit_, gaussian_id);
    if (bind_pos < gaussian_to_unit_.size() && gaussian_to_unit_[bind_pos].first == gaussian_id) {
        gaussian_to_unit_[bind_pos].second = unit_id;
        return core::Status::kOk;
    }
    gaussian_to_unit_.insert(
        gaussian_to_unit_.begin() + static_cast<std::ptrdiff_t>(bind_pos),
        std::make_pair(gaussian_id, unit_id));
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::unbind_gaussian(GaussianId gaussian_id) {
    if (gaussian_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t bind_pos = lower_bound_gaussian(gaussian_to_unit_, gaussian_id);
    if (bind_pos >= gaussian_to_unit_.size() || gaussian_to_unit_[bind_pos].first != gaussian_id) {
        return core::Status::kOutOfRange;
    }
    gaussian_to_unit_.erase(gaussian_to_unit_.begin() + static_cast<std::ptrdiff_t>(bind_pos));
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::bind_from_primitives(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count) {
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        const core::Status status = bind_gaussian(gaussians[i].id, gaussians[i].host_unit_id);
        if (status != core::Status::kOk && status != core::Status::kOutOfRange) {
            return status;
        }
    }
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::record_for_unit(
    ScaffoldUnitId unit_id,
    ScaffoldPatchRecord* out_record) const {
    if (out_record == nullptr || unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t unit_pos = lower_bound_unit(units_, unit_id);
    if (unit_pos >= units_.size() || units_[unit_pos].unit_id != unit_id) {
        return core::Status::kOutOfRange;
    }
    const UnitEntry& src = units_[unit_pos];
    out_record->unit_id = src.unit_id;
    out_record->generation = src.generation;
    out_record->lod_level = src.lod_level;
    out_record->patch_id = src.patch_id;
    out_record->block_index = src.block_index;
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::unit_id_for_patch_id(
    const std::string& patch_id,
    ScaffoldUnitId* out_unit_id) const {
    if (out_unit_id == nullptr || patch_id.empty()) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t pos = lower_bound_pair_second(patch_to_unit_, patch_id);
    if (pos >= patch_to_unit_.size() || patch_to_unit_[pos].first != patch_id) {
        return core::Status::kOutOfRange;
    }
    *out_unit_id = patch_to_unit_[pos].second;
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::block_index_for_patch_id(
    const std::string& patch_id,
    tsdf::BlockIndex* out_block_index) const {
    if (out_block_index == nullptr || patch_id.empty()) {
        return core::Status::kInvalidArgument;
    }
    ScaffoldUnitId unit_id = 0u;
    core::Status status = unit_id_for_patch_id(patch_id, &unit_id);
    if (status != core::Status::kOk) {
        return status;
    }
    ScaffoldPatchRecord record{};
    status = record_for_unit(unit_id, &record);
    if (status != core::Status::kOk) {
        return status;
    }
    *out_block_index = record.block_index;
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::patch_id_for_unit(
    ScaffoldUnitId unit_id,
    std::string* out_patch_id) const {
    if (out_patch_id == nullptr || unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    ScaffoldPatchRecord record{};
    const core::Status status = record_for_unit(unit_id, &record);
    if (status != core::Status::kOk) {
        return status;
    }
    *out_patch_id = record.patch_id;
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::gaussian_ids_for_unit(
    ScaffoldUnitId unit_id,
    std::vector<GaussianId>* out_gaussian_ids) const {
    if (out_gaussian_ids == nullptr || unit_id == 0u) {
        return core::Status::kInvalidArgument;
    }
    out_gaussian_ids->clear();
    for (const auto& pair : gaussian_to_unit_) {
        if (pair.second == unit_id) {
            out_gaussian_ids->push_back(pair.first);
        }
    }
    return core::Status::kOk;
}

core::Status ScaffoldPatchMap::gaussian_ids_for_patch_id(
    const std::string& patch_id,
    std::vector<GaussianId>* out_gaussian_ids) const {
    if (out_gaussian_ids == nullptr || patch_id.empty()) {
        return core::Status::kInvalidArgument;
    }
    ScaffoldUnitId unit_id = 0u;
    const core::Status status = unit_id_for_patch_id(patch_id, &unit_id);
    if (status != core::Status::kOk) {
        return status;
    }
    return gaussian_ids_for_unit(unit_id, out_gaussian_ids);
}

core::Status ScaffoldPatchMap::unit_ids_for_patch_id(
    const std::string& patch_id,
    std::vector<ScaffoldUnitId>* out_unit_ids) const {
    if (out_unit_ids == nullptr || patch_id.empty()) {
        return core::Status::kInvalidArgument;
    }
    out_unit_ids->clear();
    const std::size_t pos = lower_bound_pair_second(patch_to_unit_, patch_id);
    if (pos >= patch_to_unit_.size() || patch_to_unit_[pos].first != patch_id) {
        return core::Status::kOutOfRange;
    }
    out_unit_ids->push_back(patch_to_unit_[pos].second);
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
