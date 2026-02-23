// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CORE_NUMERIC_GUARD_H
#define AETHER_CORE_NUMERIC_GUARD_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>

namespace aether {
namespace core {

struct NumericalHealthSnapshot {
    std::uint64_t nan_count{0};
    std::uint64_t inf_count{0};
    std::uint64_t guarded_scalar_count{0};
    std::uint64_t guarded_vector_count{0};
};

void reset_numerical_health_counters();
NumericalHealthSnapshot numerical_health_snapshot();
void commit_thread_local_numerical_counters();

bool guard_finite_scalar(float* value);
bool guard_finite_scalar(double* value);
bool guard_finite_vector(float* values, std::size_t count);
bool guard_finite_vector(double* values, std::size_t count);
bool all_finite_vector(const float* values, std::size_t count);
bool all_finite_vector(const double* values, std::size_t count);

}  // namespace core
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CORE_NUMERIC_GUARD_H
