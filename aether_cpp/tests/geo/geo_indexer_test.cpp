// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_indexer.h"
#include "aether/core/status.h"

#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Create and destroy
    {
        auto* idx = aether::geo::geo_indexer_create(1000);
        if (!idx) { std::fprintf(stderr, "geo_indexer_create null\n"); ++failed; }
        else {
            if (aether::geo::geo_indexer_size(idx) != 0) {
                std::fprintf(stderr, "new indexer size != 0\n"); ++failed;
            }
            aether::geo::geo_indexer_destroy(idx);
        }
    }

    // Test 2: Insert with admission gate
    {
        auto* idx = aether::geo::geo_indexer_create(100);
        aether::geo::AdmissionResult ar{};

        // Valid insert
        aether::geo::GeoRecord rec{};
        rec.lat = 51.5074; rec.lon = -0.1278; rec.id = 1; rec.evidence_weight = 0.9f;
        auto s = aether::geo::geo_indexer_insert(idx, rec, &ar);
        if (s != aether::core::Status::kOk || ar != aether::geo::AdmissionResult::kAccepted) {
            std::fprintf(stderr, "valid insert rejected\n"); ++failed;
        }

        // Duplicate
        s = aether::geo::geo_indexer_insert(idx, rec, &ar);
        if (ar != aether::geo::AdmissionResult::kRejectedDuplicate) {
            std::fprintf(stderr, "duplicate not rejected\n"); ++failed;
        }

        // Out of bounds
        aether::geo::GeoRecord bad{};
        bad.lat = 100.0; bad.lon = 0.0; bad.id = 2; bad.evidence_weight = 1.0f;
        s = aether::geo::geo_indexer_insert(idx, bad, &ar);
        if (ar != aether::geo::AdmissionResult::kRejectedBounds) {
            std::fprintf(stderr, "out-of-bounds not rejected\n"); ++failed;
        }

        // Low evidence
        aether::geo::GeoRecord low{};
        low.lat = 50.0; low.lon = 0.0; low.id = 3; low.evidence_weight = 0.001f;
        s = aether::geo::geo_indexer_insert(idx, low, &ar);
        if (ar != aether::geo::AdmissionResult::kRejectedLowEvidence) {
            std::fprintf(stderr, "low evidence not rejected\n"); ++failed;
        }

        if (aether::geo::geo_indexer_size(idx) != 1) {
            std::fprintf(stderr, "size should be 1, got %zu\n", aether::geo::geo_indexer_size(idx));
            ++failed;
        }

        aether::geo::geo_indexer_destroy(idx);
    }

    // Test 3: Capacity limit
    {
        auto* idx = aether::geo::geo_indexer_create(3);
        aether::geo::AdmissionResult ar{};
        for (int i = 0; i < 3; ++i) {
            aether::geo::GeoRecord rec{};
            rec.lat = 50.0 + i; rec.lon = 10.0 + i;
            rec.id = static_cast<std::uint64_t>(i + 10);
            rec.evidence_weight = 1.0f;
            aether::geo::geo_indexer_insert(idx, rec, &ar);
        }

        // 4th should be rejected
        aether::geo::GeoRecord rec{};
        rec.lat = 55.0; rec.lon = 15.0; rec.id = 99; rec.evidence_weight = 1.0f;
        aether::geo::geo_indexer_insert(idx, rec, &ar);
        if (ar != aether::geo::AdmissionResult::kRejectedCapacity) {
            std::fprintf(stderr, "capacity not rejected\n"); ++failed;
        }

        aether::geo::geo_indexer_destroy(idx);
    }

    // Test 4: Range query
    {
        auto* idx = aether::geo::geo_indexer_create(100);
        aether::geo::AdmissionResult ar{};

        struct { double lat; double lon; const char* name; } cities[] = {
            {51.5074, -0.1278, "London"},
            {48.8566, 2.3522, "Paris"},
            {52.5200, 13.4050, "Berlin"},
            {40.7128, -74.0060, "NYC"},
        };
        for (int i = 0; i < 4; ++i) {
            aether::geo::GeoRecord rec{};
            rec.lat = cities[i].lat; rec.lon = cities[i].lon;
            rec.id = static_cast<std::uint64_t>(i);
            rec.evidence_weight = 1.0f;
            aether::geo::geo_indexer_insert(idx, rec, &ar);
        }

        // Query Europe
        aether::geo::MBR range{40.0, 55.0, -5.0, 15.0};
        aether::geo::GeoRecord results[10];
        std::size_t count = 0;
        auto s = aether::geo::geo_indexer_query_range(idx, range, results, 10, &count);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "range query failed\n"); ++failed;
        }
        if (count != 3) {
            std::fprintf(stderr, "range query: expected 3, got %zu\n", count);
            ++failed;
        }

        aether::geo::geo_indexer_destroy(idx);
    }

    // Test 5: Scored query
    {
        auto* idx = aether::geo::geo_indexer_create(100);
        aether::geo::AdmissionResult ar{};

        for (int i = 0; i < 10; ++i) {
            aether::geo::GeoRecord rec{};
            rec.lat = 51.5 + i * 0.01;
            rec.lon = -0.13 + i * 0.01;
            rec.id = static_cast<std::uint64_t>(i);
            rec.evidence_weight = 1.0f - i * 0.08f;
            aether::geo::geo_indexer_insert(idx, rec, &ar);
        }

        aether::geo::GeoRecord results[5];
        std::size_t count = 0;
        auto s = aether::geo::geo_indexer_query_scored(idx, 51.5, -0.13, 5000.0,
                                                        results, 5, &count);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "scored query failed\n"); ++failed;
        }
        // Should get results sorted by combined score
        if (count == 0) {
            std::fprintf(stderr, "scored query returned 0 results\n"); ++failed;
        }

        aether::geo::geo_indexer_destroy(idx);
    }

    return failed;
}
