// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_extraction_scheduler.h"
#include "aether/tsdf/tsdf_constants.h"

#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    // -- Test 1: Default construction starts at MIN_BLOCKS_PER_EXTRACTION. --
    {
        MeshExtractionScheduler scheduler;
        int budget = scheduler.next_block_budget();
        if (budget != MIN_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "initial budget should be %d, got %d\n",
                         MIN_BLOCKS_PER_EXTRACTION, budget);
            failed++;
        }
        if (scheduler.current_blocks_per_cycle() != MIN_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "initial blocks_per_cycle should be %d, got %d\n",
                         MIN_BLOCKS_PER_EXTRACTION,
                         scheduler.current_blocks_per_cycle());
            failed++;
        }
    }

    // -- Test 2: Reporting fast cycles ramps up the budget. --
    {
        MeshExtractionScheduler scheduler;
        int initial = scheduler.current_blocks_per_cycle();

        // Report several fast (good) cycles to trigger ramp-up.
        for (int i = 0; i < CONSECUTIVE_GOOD_CYCLES_BEFORE_RAMP + 5; ++i) {
            scheduler.report_cycle(MESH_BUDGET_GOOD_MS * 0.5);
        }

        int after_ramp = scheduler.current_blocks_per_cycle();
        if (after_ramp <= initial) {
            std::fprintf(stderr,
                         "budget should ramp up after good cycles: was %d, now %d\n",
                         initial, after_ramp);
            failed++;
        }
    }

    // -- Test 3: Budget should never exceed MAX_BLOCKS_PER_EXTRACTION. --
    {
        MeshExtractionScheduler scheduler;

        // Report many fast cycles to push budget toward the max.
        for (int i = 0; i < 200; ++i) {
            scheduler.report_cycle(0.5);
        }

        int budget = scheduler.next_block_budget();
        if (budget > MAX_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "budget %d exceeds MAX_BLOCKS_PER_EXTRACTION %d\n",
                         budget, MAX_BLOCKS_PER_EXTRACTION);
            failed++;
        }
    }

    // -- Test 4: Reporting slow cycles keeps budget low or reduces it. --
    {
        MeshExtractionScheduler scheduler;

        // First ramp up.
        for (int i = 0; i < 30; ++i) {
            scheduler.report_cycle(MESH_BUDGET_GOOD_MS * 0.5);
        }
        int ramped = scheduler.current_blocks_per_cycle();

        // Then report slow (overrun) cycles.
        for (int i = 0; i < 10; ++i) {
            scheduler.report_cycle(MESH_BUDGET_OVERRUN_MS * 2.0);
        }

        int after_slow = scheduler.current_blocks_per_cycle();
        if (after_slow > ramped) {
            std::fprintf(stderr,
                         "budget should not increase after overrun cycles: was %d, now %d\n",
                         ramped, after_slow);
            failed++;
        }
    }

    // -- Test 5: Reset returns budget to initial state. --
    {
        MeshExtractionScheduler scheduler;

        // Ramp up.
        for (int i = 0; i < 30; ++i) {
            scheduler.report_cycle(0.5);
        }

        scheduler.reset();

        if (scheduler.current_blocks_per_cycle() != MIN_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "after reset, blocks_per_cycle should be %d, got %d\n",
                         MIN_BLOCKS_PER_EXTRACTION,
                         scheduler.current_blocks_per_cycle());
            failed++;
        }
        if (scheduler.next_block_budget() != MIN_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "after reset, budget should be %d, got %d\n",
                         MIN_BLOCKS_PER_EXTRACTION,
                         scheduler.next_block_budget());
            failed++;
        }
    }

    // -- Test 6: Budget stays at minimum if cycles are always slow. --
    {
        MeshExtractionScheduler scheduler;

        for (int i = 0; i < 50; ++i) {
            scheduler.report_cycle(MESH_BUDGET_OVERRUN_MS * 3.0);
        }

        int budget = scheduler.current_blocks_per_cycle();
        if (budget < MIN_BLOCKS_PER_EXTRACTION) {
            std::fprintf(stderr,
                         "budget %d fell below MIN_BLOCKS_PER_EXTRACTION %d\n",
                         budget, MIN_BLOCKS_PER_EXTRACTION);
            failed++;
        }
    }

    return failed;
}
