#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdint>
#include <cstdio>

int main() {
  using namespace aether_preclamp_instr_v1;
  ExactParityArtifact off{{1, 2, 3}, {4, 5, 6}, {7, 8, 9},
                          {'p', 'l', 'y', '\n'}};
  ExactParityArtifact on = off;

  ExactParityResult result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kP3PendingExactHostParity);
  assert(result.mismatch_mask == 0);

  on = off;
  on.ordered_outputs[0] ^= 1;
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask == kOrderedOutputsMismatch);

  on = off;
  on.database_bytes.push_back(0);
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask == kDatabaseMismatch);

  on = off;
  on.ordered_matches_digest[1] ^= 1;
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask == kOrderedMatchesMismatch);

  on = off;
  on.final_ply_bytes[0] ^= 1;
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask == kFinalPlyMismatch);

  on = off;
  on.ordered_outputs.clear();
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert((result.mismatch_mask & kOrderedOutputsMismatch) != 0);

  ExactParityArtifact empty;
  result = CompareExactOffOnArtifacts(empty, empty);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask ==
         (kOrderedOutputsMismatch | kDatabaseMismatch |
          kOrderedMatchesMismatch | kFinalPlyMismatch));

  on = off;
  on.ordered_outputs[0] ^= 1;
  on.database_bytes[0] ^= 1;
  on.final_ply_bytes[0] ^= 1;
  result = CompareExactOffOnArtifacts(off, on);
  assert(result.status == ExactParityStatus::kInvalid);
  assert(result.mismatch_mask ==
         (kOrderedOutputsMismatch | kDatabaseMismatch | kFinalPlyMismatch));

  std::puts("PASS R15 exact OFF/ON comparator stays P3_PENDING on host parity");
}
