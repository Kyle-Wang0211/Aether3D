#include <cstdint>
#include <iostream>
#include <limits>
#include <vector>

namespace {

// Deliberately copied from the shipping loop as an executable semantics
// contract. This is not production linkage; the source-block SHA contract is
// the evidence that the actual shipping implementation remains unchanged.
size_t LegacyPostPushCount(const std::vector<int>& sorted_groups,
                           uint32_t max_features) {
  constexpr int kMaxOctaveResolution = 1000;
  int prev_os = std::numeric_limits<int32_t>::max();
  uint32_t kept = 0;
  for (const int os_key : sorted_groups) {
    ++kept;
    const int os = os_key * kMaxOctaveResolution;
    if (os != prev_os && kept >= max_features) {
      break;
    }
    prev_os = os;
  }
  return kept;
}

bool ExpectCount(const char* name,
                 const std::vector<int>& groups,
                 uint32_t cap,
                 size_t expected) {
  const size_t actual = LegacyPostPushCount(groups, cap);
  if (actual != expected) {
    std::cerr << "FAIL " << name << ": expected " << expected << ", got "
              << actual << "\n";
    return false;
  }
  std::cout << "PASS " << name << ": " << actual << "\n";
  return true;
}

}  // namespace

int main() {
  bool ok = true;
  // Two groups of two, cap at the first boundary: the first item of the next
  // group is pushed before the new-group break is evaluated.
  ok &= ExpectCount("cap2_groups_2_2", {9, 9, 8, 8}, 2, 3);
  // Cap falls inside the first group. The loop consumes the rest of that group
  // and also pushes the first item of the following group before stopping.
  ok &= ExpectCount("cap_inside_group", {9, 9, 9, 9, 8}, 3, 5);
  // Cap equals a later group boundary. The break still occurs only after the
  // first item from the following group has been pushed.
  ok &= ExpectCount("cap_at_group_boundary", {9, 9, 8, 8, 7}, 4, 5);
  return ok ? 0 : 1;
}
