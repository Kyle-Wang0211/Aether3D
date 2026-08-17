#include "feature_selection_environment_v1.h"

#include <string_view>

int main() {
    return std::string_view(
               aether::tools::detail::kFeatureSelectionPolicyEnvironmentV1)
                   .empty()
               ? 1
               : 0;
}
