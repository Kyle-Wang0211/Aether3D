// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/ds_mass_function.h"
#include "aether/evidence/evidence_constants.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::evidence;

    // Basic combine invariant
    {
        DSMassFunction m1(0.6, 0.1, 0.3);
        DSMassFunction m2(0.5, 0.2, 0.3);
        DSMassCombineResult out = DSMassFusion::dempster_combine(m1, m2);
        if (!out.mass.verify_invariant()) {
            std::fprintf(stderr, "dempster invariant failed\n");
            failed++;
        }
        if (out.conflict < 0.0 || out.conflict >= 1.0) {
            std::fprintf(stderr, "conflict range invalid\n");
            failed++;
        }
    }

    // Commutativity
    {
        DSMassFunction m1(0.6, 0.2, 0.2);
        DSMassFunction m2(0.5, 0.3, 0.2);
        DSMassCombineResult a = DSMassFusion::dempster_combine(m1, m2);
        DSMassCombineResult b = DSMassFusion::dempster_combine(m2, m1);
        if (std::fabs(a.mass.occupied - b.mass.occupied) > DS_EPSILON ||
            std::fabs(a.mass.free_ - b.mass.free_) > DS_EPSILON ||
            std::fabs(a.mass.unknown - b.mass.unknown) > DS_EPSILON ||
            std::fabs(a.conflict - b.conflict) > DS_EPSILON) {
            std::fprintf(stderr, "dempster commutativity failed\n");
            failed++;
        }
    }

    // Reliability discount boundaries
    {
        DSMassFunction mass(0.7, 0.2, 0.1);
        DSMassFunction r0 = DSMassFusion::discount(mass, 0.0);
        DSMassFunction r1 = DSMassFusion::discount(mass, 1.0);
        if (std::fabs(r0.occupied) > DS_EPSILON || std::fabs(r0.free_) > DS_EPSILON ||
            std::fabs(r0.unknown - 1.0) > DS_EPSILON) {
            std::fprintf(stderr, "discount r=0 failed\n");
            failed++;
        }
        if (std::fabs(r1.occupied - mass.occupied) > DS_EPSILON ||
            std::fabs(r1.free_ - mass.free_) > DS_EPSILON ||
            std::fabs(r1.unknown - mass.unknown) > DS_EPSILON) {
            std::fprintf(stderr, "discount r=1 failed\n");
            failed++;
        }
    }

    // Deterministic >= tie-break for conflict switch
    {
        DSMassFunction m1(0.85, 0.1, 0.05);
        DSMassFunction m2(0.1, 0.85, 0.05);
        const double conflict = m1.occupied * m2.free_ + m1.free_ * m2.occupied;
        DSMassFunction combined = DSMassFusion::combine(m1, m2);
        if (!combined.verify_invariant()) {
            std::fprintf(stderr, "combine invariant failed\n");
            failed++;
        }
        if (conflict >= DS_CONFLICT_SWITCH && combined.unknown <= 0.0) {
            std::fprintf(stderr, "expected yager branch with non-zero unknown\n");
            failed++;
        }
    }

    // Delta multiplier mapping
    {
        DSMassFunction good = DSMassFusion::from_delta_multiplier(1.0);
        DSMassFunction suspect = DSMassFusion::from_delta_multiplier(0.5);
        DSMassFunction bad = DSMassFusion::from_delta_multiplier(0.0);
        if (good.occupied <= 0.7 || suspect.unknown <= 0.5 || bad.free_ <= 0.0) {
            std::fprintf(stderr, "delta multiplier mapping invalid\n");
            failed++;
        }

        DSMassFunction near_good = DSMassFusion::from_delta_multiplier(1.0 - 1e-10);
        DSMassFunction near_mid = DSMassFusion::from_delta_multiplier(0.3 + 1e-10);
        DSMassFunction near_bad = DSMassFusion::from_delta_multiplier(1e-10);
        if (std::fabs(near_good.occupied - good.occupied) > DS_EPSILON ||
            std::fabs(near_mid.occupied - 0.3) > DS_EPSILON ||
            std::fabs(near_bad.free_ - bad.free_) > DS_EPSILON) {
            std::fprintf(stderr, "delta multiplier epsilon handling invalid\n");
            failed++;
        }
    }

    return failed;
}
