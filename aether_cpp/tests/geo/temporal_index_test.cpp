// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/temporal_index.h"

#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::geo;

    // -- Test 1: Create and destroy temporal index. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            temporal_index_destroy(index);
        }
    }

    // -- Test 2: Insert a single entry. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            TemporalEntry entry{};
            entry.spatial_cell = 100;
            entry.temporal_bucket = 5;
            entry.record_id = 1;
            entry.value = 3.14f;
            entry.timestamp_s = 1000.0;

            auto st = temporal_index_insert(index, entry);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_index_insert returned error\n");
                failed++;
            }

            if (temporal_index_size(index) != 1) {
                std::fprintf(stderr,
                             "size should be 1 after insert, got %zu\n",
                             temporal_index_size(index));
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 3: Insert and query back. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            TemporalEntry entry{};
            entry.spatial_cell = 42;
            entry.temporal_bucket = 10;
            entry.record_id = 7;
            entry.value = 2.71f;
            entry.timestamp_s = 500.0;
            temporal_index_insert(index, entry);

            TemporalEntry results[8]{};
            std::size_t out_count = 0;
            auto st = temporal_index_query(
                index, 42, 5, 15, results, 8, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_index_query returned error\n");
                failed++;
            }
            if (out_count != 1) {
                std::fprintf(stderr,
                             "query should return 1 entry, got %zu\n",
                             out_count);
                failed++;
            }
            if (out_count > 0 && results[0].record_id != 7) {
                std::fprintf(stderr,
                             "queried entry record_id mismatch: expected 7, got %llu\n",
                             static_cast<unsigned long long>(results[0].record_id));
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 4: Query for non-existent spatial cell returns 0 results. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            TemporalEntry entry{};
            entry.spatial_cell = 10;
            entry.temporal_bucket = 5;
            entry.record_id = 1;
            entry.value = 1.0f;
            entry.timestamp_s = 100.0;
            temporal_index_insert(index, entry);

            TemporalEntry results[4]{};
            std::size_t out_count = 0;
            auto st = temporal_index_query(
                index, 999, 0, 100, results, 4, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "query for missing cell returned error\n");
                failed++;
            }
            if (out_count != 0) {
                std::fprintf(stderr,
                             "query for non-existent cell should return 0, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 5: Query for bucket range outside entry's bucket returns 0. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            TemporalEntry entry{};
            entry.spatial_cell = 50;
            entry.temporal_bucket = 20;
            entry.record_id = 3;
            entry.value = 5.0f;
            entry.timestamp_s = 200.0;
            temporal_index_insert(index, entry);

            TemporalEntry results[4]{};
            std::size_t out_count = 0;
            temporal_index_query(index, 50, 0, 10, results, 4, &out_count);
            if (out_count != 0) {
                std::fprintf(stderr,
                             "query outside bucket range should return 0, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 6: WAL size tracking. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            if (temporal_index_wal_size(index) != 0) {
                std::fprintf(stderr,
                             "initial WAL size should be 0\n");
                failed++;
            }

            TemporalEntry entry{};
            entry.spatial_cell = 1;
            entry.temporal_bucket = 1;
            entry.record_id = 1;
            entry.value = 1.0f;
            entry.timestamp_s = 1.0;
            temporal_index_insert(index, entry);

            if (temporal_index_wal_size(index) != 1) {
                std::fprintf(stderr,
                             "WAL size should be 1 after insert, got %zu\n",
                             temporal_index_wal_size(index));
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 7: Compact moves entries from WAL to sorted store. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            for (int i = 0; i < 5; ++i) {
                TemporalEntry entry{};
                entry.spatial_cell = 1;
                entry.temporal_bucket = static_cast<uint32_t>(i);
                entry.record_id = static_cast<uint64_t>(i);
                entry.value = static_cast<float>(i);
                entry.timestamp_s = static_cast<double>(i);
                temporal_index_insert(index, entry);
            }

            std::size_t wal_before = temporal_index_wal_size(index);
            auto st = temporal_index_compact(index);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_index_compact returned error\n");
                failed++;
            }

            std::size_t wal_after = temporal_index_wal_size(index);
            if (wal_after >= wal_before && wal_before > 0) {
                std::fprintf(stderr,
                             "WAL size should decrease after compact: before=%zu, after=%zu\n",
                             wal_before, wal_after);
                failed++;
            }

            // Total size should remain 5.
            if (temporal_index_size(index) != 5) {
                std::fprintf(stderr,
                             "total size should still be 5 after compact, got %zu\n",
                             temporal_index_size(index));
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 8: Query still works after compaction. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            TemporalEntry entry{};
            entry.spatial_cell = 77;
            entry.temporal_bucket = 15;
            entry.record_id = 42;
            entry.value = 9.9f;
            entry.timestamp_s = 300.0;
            temporal_index_insert(index, entry);

            temporal_index_compact(index);

            TemporalEntry results[4]{};
            std::size_t out_count = 0;
            temporal_index_query(index, 77, 10, 20, results, 4, &out_count);
            if (out_count != 1) {
                std::fprintf(stderr,
                             "query after compact should return 1, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    // -- Test 9: Multiple entries for same cell, different buckets. --
    {
        TemporalIndex* index = temporal_index_create(1024);
        if (index == nullptr) {
            std::fprintf(stderr, "temporal_index_create returned null\n");
            failed++;
        } else {
            for (uint32_t b = 0; b < 10; ++b) {
                TemporalEntry entry{};
                entry.spatial_cell = 5;
                entry.temporal_bucket = b;
                entry.record_id = b;
                entry.value = static_cast<float>(b);
                entry.timestamp_s = static_cast<double>(b) * 10.0;
                temporal_index_insert(index, entry);
            }

            // Query bucket range [3, 7] should return 5 entries.
            TemporalEntry results[16]{};
            std::size_t out_count = 0;
            temporal_index_query(index, 5, 3, 7, results, 16, &out_count);
            if (out_count != 5) {
                std::fprintf(stderr,
                             "query [3,7] should return 5, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_index_destroy(index);
        }
    }

    return failed;
}
