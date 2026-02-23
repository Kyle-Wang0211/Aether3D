// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_DS_MASS_FUNCTION_H
#define AETHER_EVIDENCE_DS_MASS_FUNCTION_H

namespace aether {
namespace evidence {

struct DSMassFunction {
    double occupied{0.0};
    double free_{0.0};
    double unknown{1.0};

    DSMassFunction() = default;
    DSMassFunction(double occupied_in, double free_in, double unknown_in);

    static DSMassFunction vacuous();
    bool verify_invariant() const;
    DSMassFunction sealed() const;
};

struct DSMassCombineResult {
    DSMassFunction mass{};
    double conflict{0.0};
    bool used_yager{false};
};

class DSMassFusion {
public:
    static DSMassCombineResult dempster_combine(const DSMassFunction& m1, const DSMassFunction& m2);
    static DSMassFunction yager_combine(const DSMassFunction& m1, const DSMassFunction& m2);
    static DSMassFunction combine(const DSMassFunction& m1, const DSMassFunction& m2);
    static DSMassFunction discount(const DSMassFunction& mass, double reliability);
    static DSMassFunction from_delta_multiplier(double delta_multiplier);
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_DS_MASS_FUNCTION_H
