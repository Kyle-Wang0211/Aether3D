// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/scaffold_patch_map.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

aether::innovation::ScaffoldUnit make_unit(
    aether::innovation::ScaffoldUnitId unit_id,
    std::uint32_t generation,
    std::uint8_t lod_level,
    const char* patch_id) {
    aether::innovation::ScaffoldUnit unit{};
    unit.unit_id = unit_id;
    unit.generation = generation;
    unit.lod_level = lod_level;
    if (patch_id != nullptr) {
        unit.patch_id = patch_id;
    }
    return unit;
}

int test_roundtrip_mapping() {
    using namespace aether::innovation;

    int failed = 0;
    ScaffoldPatchMap map{};

    const auto st_u1 = map.upsert_unit(make_unit(101u, 3u, 1u, "blk:0_0_0"), aether::tsdf::BlockIndex(0, 0, 0));
    const auto st_u2 = map.upsert_unit(make_unit(202u, 5u, 2u, nullptr), aether::tsdf::BlockIndex(-1, 2, 9));
    if (st_u1 != aether::core::Status::kOk || st_u2 != aether::core::Status::kOk) {
        std::fprintf(stderr, "upsert unit failed\n");
        return 1;
    }

    if (map.bind_gaussian(11u, 101u) != aether::core::Status::kOk ||
        map.bind_gaussian(22u, 101u) != aether::core::Status::kOk ||
        map.bind_gaussian(33u, 202u) != aether::core::Status::kOk) {
        std::fprintf(stderr, "bind gaussian failed\n");
        return 1;
    }

    ScaffoldPatchRecord record{};
    if (map.record_for_unit(202u, &record) != aether::core::Status::kOk) {
        std::fprintf(stderr, "record_for_unit failed\n");
        failed++;
    } else {
        if (record.patch_id != "blk:-1_2_9") {
            std::fprintf(stderr, "auto patch_id generation mismatch\n");
            failed++;
        }
        if (record.generation != 5u || record.lod_level != 2u) {
            std::fprintf(stderr, "record metadata mismatch\n");
            failed++;
        }
    }

    std::vector<GaussianId> ids{};
    if (map.gaussian_ids_for_patch_id("blk:0_0_0", &ids) != aether::core::Status::kOk) {
        std::fprintf(stderr, "gaussian_ids_for_patch_id failed\n");
        failed++;
    } else if (ids.size() != 2u) {
        std::fprintf(stderr, "unexpected gaussian binding count\n");
        failed++;
    }

    aether::tsdf::BlockIndex parsed{};
    if (ScaffoldPatchMap::block_index_from_patch_id("blk:-1_2_9", &parsed) != aether::core::Status::kOk) {
        std::fprintf(stderr, "block index parse failed\n");
        failed++;
    } else if (parsed.x != -1 || parsed.y != 2 || parsed.z != 9) {
        std::fprintf(stderr, "block index parse mismatch\n");
        failed++;
    }

    std::string patch_id{};
    if (ScaffoldPatchMap::patch_id_from_block_index(aether::tsdf::BlockIndex(7, -2, 3), &patch_id) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "patch id generation failed\n");
        failed++;
    } else if (patch_id != "blk:7_-2_3") {
        std::fprintf(stderr, "patch id generation mismatch\n");
        failed++;
    }

    if (map.remove_unit(101u) != aether::core::Status::kOk) {
        std::fprintf(stderr, "remove unit failed\n");
        failed++;
    }
    if (map.gaussian_ids_for_patch_id("blk:0_0_0", &ids) != aether::core::Status::kOutOfRange) {
        std::fprintf(stderr, "removed patch should be out-of-range\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    using namespace aether::innovation;

    int failed = 0;
    ScaffoldPatchMap map{};
    if (map.upsert_unit(make_unit(0u, 0u, 0u, nullptr), aether::tsdf::BlockIndex(0, 0, 0)) !=
        aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "zero unit id should fail\n");
        failed++;
    }
    if (map.bind_gaussian(0u, 1u) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "zero gaussian id should fail\n");
        failed++;
    }
    if (map.unit_id_for_patch_id("missing", nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null unit output should fail\n");
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_roundtrip_mapping();
    failed += test_invalid_paths();
    return failed;
}
