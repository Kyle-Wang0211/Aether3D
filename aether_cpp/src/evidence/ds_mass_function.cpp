// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/ds_mass_function.h"
#include "aether/evidence/evidence_constants.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace evidence {
namespace {

double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

DSMassFunction normalize_or_vacuous(double occupied, double free_mass, double unknown) {
    DSMassFunction out;
    const double sum = occupied + free_mass + unknown;
    if (!(sum > DS_EPSILON) || !std::isfinite(sum)) {
        out.occupied = 0.0;
        out.free_ = 0.0;
        out.unknown = 1.0;
        return out;
    }
    out.occupied = occupied / sum;
    out.free_ = free_mass / sum;
    out.unknown = unknown / sum;
    return out;
}

}  // namespace

DSMassFunction::DSMassFunction(double occupied_in, double free_in, double unknown_in) {
    // L1 FIX: Clamp negative inputs before normalization. Mass function values
    // must be non-negative by definition (Shafer 1976). Without this, negative
    // inputs from floating-point arithmetic could produce negative mass values.
    const DSMassFunction normalized = normalize_or_vacuous(
        clamp01(occupied_in), clamp01(free_in), std::max(0.0, unknown_in));
    occupied = normalized.occupied;
    free_ = normalized.free_;
    unknown = normalized.unknown;
}

DSMassFunction DSMassFunction::vacuous() {
    DSMassFunction out;
    out.occupied = 0.0;
    out.free_ = 0.0;
    out.unknown = 1.0;
    return out;
}

bool DSMassFunction::verify_invariant() const {
    if (!std::isfinite(occupied) || !std::isfinite(free_) || !std::isfinite(unknown)) return false;
    const double sum = occupied + free_ + unknown;
    return std::fabs(sum - 1.0) < DS_EPSILON;
}

DSMassFunction DSMassFunction::sealed() const {
    if (!std::isfinite(occupied) || !std::isfinite(free_) || !std::isfinite(unknown)) {
        return DSMassFunction::vacuous();
    }
    return normalize_or_vacuous(clamp01(occupied), clamp01(free_), clamp01(unknown));
}

DSMassCombineResult DSMassFusion::dempster_combine(const DSMassFunction& m1, const DSMassFunction& m2) {
    const double conflict = m1.occupied * m2.free_ + m1.free_ * m2.occupied;
    DSMassCombineResult out{};
    out.conflict = conflict;

    if (conflict >= 1.0 - DS_EPSILON) {
        out.mass = yager_combine(m1, m2);
        out.used_yager = true;
        return out;
    }

    const double normalization = 1.0 / (1.0 - conflict);
    const double combined_occupied = normalization * (
        m1.occupied * m2.occupied +
        m1.occupied * m2.unknown +
        m1.unknown * m2.occupied);
    const double combined_free = normalization * (
        m1.free_ * m2.free_ +
        m1.free_ * m2.unknown +
        m1.unknown * m2.free_);
    const double combined_unknown = normalization * (m1.unknown * m2.unknown);

    out.mass = DSMassFunction(combined_occupied, combined_free, combined_unknown).sealed();
    out.used_yager = false;
    return out;
}

DSMassFunction DSMassFusion::yager_combine(const DSMassFunction& m1, const DSMassFunction& m2) {
    const double conflict = m1.occupied * m2.free_ + m1.free_ * m2.occupied;
    const double combined_occupied =
        m1.occupied * m2.occupied + m1.occupied * m2.unknown + m1.unknown * m2.occupied;
    const double combined_free =
        m1.free_ * m2.free_ + m1.free_ * m2.unknown + m1.unknown * m2.free_;
    const double combined_unknown = m1.unknown * m2.unknown + conflict;
    return DSMassFunction(combined_occupied, combined_free, combined_unknown).sealed();
}

DSMassFunction DSMassFusion::combine(const DSMassFunction& m1, const DSMassFunction& m2) {
    const double conflict = m1.occupied * m2.free_ + m1.free_ * m2.occupied;
    if (conflict >= DS_CONFLICT_SWITCH) {
        return yager_combine(m1, m2);
    }
    return dempster_combine(m1, m2).mass;
}

DSMassFunction DSMassFusion::discount(const DSMassFunction& mass, double reliability) {
    const double r = clamp01(reliability);
    const double occupied = r * mass.occupied;
    const double free_mass = r * mass.free_;
    const double unknown = mass.unknown + (1.0 - r) * (mass.occupied + mass.free_);
    return DSMassFunction(occupied, free_mass, unknown).sealed();
}

DSMassFunction DSMassFusion::from_delta_multiplier(double delta_multiplier) {
    const double delta = clamp01(delta_multiplier);
    if (std::fabs(delta - 1.0) <= DS_EPSILON) {
        return DSMassFunction(DS_DEFAULT_OCCUPIED_GOOD, 0.0, DS_DEFAULT_UNKNOWN_GOOD);
    }
    if (std::fabs(delta - 0.3) <= DS_EPSILON) {
        return DSMassFunction(0.3, 0.0, 0.7);
    }
    if (std::fabs(delta) <= DS_EPSILON) {
        return DSMassFunction(0.0, DS_DEFAULT_FREE_BAD, 0.7);
    }

    if (delta > 0.3) {
        const double t = (delta - 0.3) / 0.7;
        return DSMassFunction(
            0.3 + t * (DS_DEFAULT_OCCUPIED_GOOD - 0.3),
            0.0,
            0.7 - t * (0.7 - DS_DEFAULT_UNKNOWN_GOOD));
    }

    const double t = delta / 0.3;
    return DSMassFunction(
        t * 0.3,
        DS_DEFAULT_FREE_BAD * (1.0 - t),
        0.7);
}

}  // namespace evidence
}  // namespace aether
