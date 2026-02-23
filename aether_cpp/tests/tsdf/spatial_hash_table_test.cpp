// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/spatial_hash_table.h"
#include "aether/tsdf/block_index.h"
#include <cstdio>

int main() {
    int failed = 0;
    aether::tsdf::SpatialHashTable tbl;
    tbl.init(32, 64);

    aether::tsdf::BlockIndex a(1, 2, 3);
    aether::tsdf::BlockIndex b(17, 2, 3);
    aether::tsdf::BlockIndex c(33, 2, 3);

    const int ia = tbl.insert(a);
    const int ib = tbl.insert(b);
    const int ic = tbl.insert(c);
    if (ia < 0 || ib < 0 || ic < 0) {
        std::fprintf(stderr, "insert failed\n");
        failed++;
    }

    if (tbl.find(a) != ia || tbl.find(b) != ib || tbl.find(c) != ic) {
        std::fprintf(stderr, "find failed\n");
        failed++;
    }

    if (!tbl.remove(b)) {
        std::fprintf(stderr, "remove failed\n");
        failed++;
    }
    if (tbl.find(b) >= 0) {
        std::fprintf(stderr, "removed key still found\n");
        failed++;
    }
    if (tbl.find(a) < 0 || tbl.find(c) < 0) {
        std::fprintf(stderr, "backward-shift chain broken\n");
        failed++;
    }

    const int before = tbl.capacity();
    for (int i = 0; i < 48; ++i) {
        tbl.insert(aether::tsdf::BlockIndex(i, i + 1, i + 2));
    }
    tbl.rehash_if_needed();
    if (tbl.capacity() <= before && tbl.load_factor() >= aether::tsdf::HASH_TABLE_MAX_LOAD_FACTOR) {
        std::fprintf(stderr, "rehash not triggered\n");
        failed++;
    }

    tbl.reset();
    if (tbl.find(a) >= 0) {
        std::fprintf(stderr, "reset/find failed\n");
        failed++;
    }
    return failed;
}
