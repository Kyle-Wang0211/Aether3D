#include "pair_policy_v2_c.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "FAIL " << message << '\n';
  std::exit(1);
}

void Expect(const bool condition, const std::string& message) {
  if (!condition) Fail(message);
}

void TestDefaultIsSpatialK20TemporalT2AndFutureFieldsAreExplicit() {
  aether_pair_policy_config_v2 config{};
  aether_pair_policy_config_v2_default(&config);
  Expect(config.struct_size == sizeof(config), "default struct size");
  Expect(config.version == AETHER_PAIR_POLICY_CONFIG_V2_VERSION,
         "default version");
  Expect(config.mode == AETHER_PAIR_POLICY_MODE_S20_T2_CANDIDATE,
         "S20/T2 is the persistent product default");
  Expect(config.spatial_k == 20, "S20 default is explicit");
  Expect(config.temporal_lookback == 2, "T2 default is explicit");
  Expect(config.spatial_recent_exclusion == 2,
         "S20 recent exclusion is explicit");
  Expect(config.visual_loop_enabled == 1,
         "L4/P10 visual loop insurance is default-ON");
  Expect(config.visual_loop_period == 10, "P10 default is explicit");
  Expect(config.visual_loop_topup == 4, "L4 default is explicit");
  Expect(config.visual_loop_retrieve_cap == 50,
         "visual retrieve cap is explicit");
  Expect(config.visual_loop_recent_exclusion == 20,
         "visual recent exclusion is explicit");
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_OK,
         "default config validates");
}

void TestSizeVersionAndNullFailClosed() {
  Expect(aether_pair_policy_config_v2_validate(nullptr) ==
             AETHER_PAIR_POLICY_V2_ERR_NULL,
         "null config rejected");

  aether_pair_policy_config_v2 config{};
  aether_pair_policy_config_v2_default(&config);
  config.struct_size -= 1;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_SIZE,
         "wrong size rejected");
  aether_pair_policy_config_v2_default(&config);
  config.version += 1;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_VERSION,
         "unknown version rejected");
}

void TestModesAndRangesFailClosed() {
  aether_pair_policy_config_v2 config{};
  aether_pair_policy_config_v2_default(&config);

  config.mode = 99;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_MODE,
         "unknown mode rejected");

  aether_pair_policy_config_v2_default(&config);
  config.mode = AETHER_PAIR_POLICY_MODE_S20_T2_SHADOW;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_OK,
         "shadow mode validates");
  config.mode = AETHER_PAIR_POLICY_MODE_S20_T2_CANDIDATE;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_OK,
         "candidate mode validates");

  config.spatial_k = 65;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_RANGE,
         "oversized spatial budget rejected");
  aether_pair_policy_config_v2_default(&config);
  config.temporal_lookback = -1;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_RANGE,
         "negative temporal budget rejected");
  aether_pair_policy_config_v2_default(&config);
  config.visual_loop_enabled = 2;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_RANGE,
         "non-boolean loop flag rejected");
}

void TestReservedBytesMustRemainZero() {
  aether_pair_policy_config_v2 config{};
  aether_pair_policy_config_v2_default(&config);
  config.reserved[3] = 1;
  Expect(aether_pair_policy_config_v2_validate(&config) ==
             AETHER_PAIR_POLICY_V2_ERR_RESERVED,
         "reserved words are fail-closed");
}

}  // namespace

int main() {
  TestDefaultIsSpatialK20TemporalT2AndFutureFieldsAreExplicit();
  TestSizeVersionAndNullFailClosed();
  TestModesAndRangesFailClosed();
  TestReservedBytesMustRemainZero();
  std::cout << "PASS pair_policy_v2 C ABI contract\n";
  return 0;
}
