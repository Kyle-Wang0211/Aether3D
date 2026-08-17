#include "aether/sfm/descriptor_residency_policy_v1.h"

#include <cstdlib>
#include <iostream>
#include <string_view>

namespace {

using aether::sfm::DescriptorFormatV1;
using aether::sfm::DescriptorResidencyKeyV1;
using aether::sfm::DescriptorResidencyMetadataV1;
using aether::sfm::DescriptorResidencyPolicyV1;

[[noreturn]] void Fail(std::string_view message) {
    std::cerr << "FAIL descriptor_residency_policy_v1: " << message << "\n";
    std::abort();
}

void Check(bool condition, std::string_view message) {
    if (!condition) Fail(message);
}

DescriptorResidencyKeyV1 Key(uint64_t session,
                             uint32_t frame,
                             uint32_t generation = 1) {
    return {session, frame, generation};
}

DescriptorResidencyMetadataV1 Meta(uint64_t bytes,
                                   uint32_t count = 8,
                                   DescriptorFormatV1 format =
                                       DescriptorFormatV1::kRawU8) {
    return {count, format, bytes};
}

void TestHitMissAndByteBudgetLru() {
    DescriptorResidencyPolicyV1 policy(300);
    const auto a = Key(7, 0);
    const auto b = Key(7, 1);
    const auto c = Key(7, 2);
    const auto d = Key(7, 3);

    auto result = policy.Access(a, Meta(100));
    Check(!result.hit && result.admitted, "first access is not an admitted miss");
    Check(result.evicted.empty(), "first access evicted an entry");
    result = policy.Access(a, Meta(100));
    Check(result.hit && result.admitted, "second identical access is not a hit");

    policy.Access(b, Meta(100));
    policy.Access(c, Meta(100));
    Check(policy.resident_bytes() == 300, "byte accounting at budget is wrong");
    policy.Access(a, Meta(100));  // A becomes MRU; B is now LRU.
    result = policy.Access(d, Meta(100));
    Check(result.admitted && !result.hit, "new entry was not admitted");
    Check(result.evicted.size() == 1 && result.evicted[0] == b,
          "byte-budget eviction did not choose the LRU key");
    Check(policy.Contains(a) && !policy.Contains(b) && policy.Contains(c) &&
              policy.Contains(d),
          "post-eviction membership is wrong");
    Check(policy.resident_bytes() == 300, "eviction exceeded byte budget");
}

void TestOversizeEntryIsNotAdmitted() {
    DescriptorResidencyPolicyV1 policy(128);
    const auto result = policy.Access(Key(1, 0), Meta(129));
    Check(!result.hit && !result.admitted, "oversize entry was admitted");
    Check(result.evicted.empty(), "oversize miss evicted useful entries");
    Check(policy.empty() && policy.resident_bytes() == 0,
          "oversize miss changed policy state");
}

void TestMetadataAndGenerationReplacement() {
    DescriptorResidencyPolicyV1 policy(1024);
    const auto old_key = Key(11, 4, 1);
    const auto new_generation = Key(11, 4, 2);
    policy.Access(old_key, Meta(128, 1));

    auto result = policy.Access(old_key, Meta(256, 2));
    Check(!result.hit && result.admitted && result.replaced_stale,
          "same-key metadata mismatch was not replaced as a miss");
    Check(result.evicted.size() == 1 && result.evicted[0] == old_key,
          "metadata replacement did not return the stale backend key");
    Check(policy.resident_bytes() == 256, "replacement leaked byte accounting");

    result = policy.Access(new_generation, Meta(256, 2));
    Check(!result.hit && result.admitted && result.replaced_stale,
          "new generation did not replace the prior frame generation");
    Check(result.evicted.size() == 1 && result.evicted[0] == old_key,
          "generation replacement did not expose the old backend key");
    Check(!policy.Contains(old_key) && policy.Contains(new_generation),
          "generation replacement retained stale membership");
}

void TestFrameSessionAndDeviceInvalidation() {
    DescriptorResidencyPolicyV1 policy(4096);
    const auto a = Key(21, 0);
    const auto b = Key(21, 1);
    const auto c = Key(22, 0);
    policy.Access(a, Meta(100));
    policy.Access(b, Meta(100));
    policy.Access(c, Meta(100));

    auto removed = policy.InvalidateFrame(21, 0);
    Check(removed.size() == 1 && removed[0] == a,
          "remove-frame invalidation returned the wrong keys");
    Check(!policy.Contains(a) && policy.Contains(b) && policy.Contains(c),
          "remove-frame invalidation crossed ownership boundaries");

    removed = policy.ClearSession(21);
    Check(removed.size() == 1 && removed[0] == b,
          "session clear returned the wrong keys");
    Check(policy.size() == 1 && policy.Contains(c),
          "session clear removed another session");

    removed = policy.ClearAll();  // device-loss/reset barrier
    Check(removed.size() == 1 && removed[0] == c,
          "device clear returned the wrong keys");
    Check(policy.empty() && policy.resident_bytes() == 0,
          "device clear retained resident state");
}

void TestCounters() {
    DescriptorResidencyPolicyV1 policy(200);
    const auto a = Key(31, 0);
    const auto b = Key(31, 1);
    const auto c = Key(31, 2);
    policy.Access(a, Meta(100));  // miss
    policy.Access(a, Meta(100));  // hit
    policy.Access(b, Meta(100));  // miss
    policy.Access(c, Meta(100));  // miss + eviction
    const auto stats = policy.stats();
    Check(stats.hits == 1 && stats.misses == 3 && stats.evictions == 1,
          "policy counters do not match the access sequence");
}

}  // namespace

int main() {
    TestHitMissAndByteBudgetLru();
    TestOversizeEntryIsNotAdmitted();
    TestMetadataAndGenerationReplacement();
    TestFrameSessionAndDeviceInvalidation();
    TestCounters();
    std::cout << "PASS descriptor_residency_policy_v1\n";
    return 0;
}
