#pragma once

#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL) && \
    defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)
#error "Define exactly one feature-selection environment namespace"
#elif !defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL) && \
    !defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)
#error "Define exactly one feature-selection environment namespace"
#endif

namespace aether::tools::detail {

#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL)
inline constexpr char kFeatureSelectionPolicyEnvironmentV1[] =
    "OFFICIAL_AETHER_FEATURE_SELECTION_POLICY";
#else
inline constexpr char kFeatureSelectionPolicyEnvironmentV1[] =
    "AETHER_FEATURE_SELECTION_POLICY";
#endif

}  // namespace aether::tools::detail
