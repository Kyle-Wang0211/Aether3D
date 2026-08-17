#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace {

void FinalizeInto(aether_preclamp_instr_v1::SessionRecords* session,
                  int64_t frame_id, uint32_t ordinal,
                  uint32_t preclamp_count, uint32_t legacy_count) {
  using namespace aether_preclamp_instr_v1;
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(preclamp_count);
  UpdateLegacyClampResult(legacy_count);
  assert(SealAcceptedLegacyGpuResult(
      legacy_count, FieldStatus::kUnavailable, 0.0f));
  FrameCounts row;
  assert(FinalizeAcceptedFrame(
      frame_id, ordinal, FieldStatus::kValid, 1, &row));
  assert(AppendSessionRecord(session, row));
  // Finalization is a consume-once boundary for the caller-thread TLS.
  assert(!FinalizeAcceptedFrame(
      frame_id, ordinal, FieldStatus::kValid, 1, &row));
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  setenv("AETHER_PRECLAMP_INSTR_V1", "1", 1);
  assert(Enabled());

  // Two sequential sessions on one worker thread may both start at frame 0;
  // their records remain isolated and a reset affects only its owner.
  SessionRecords first_session;
  SessionRecords second_session;
  ResetSessionRecords(&first_session);
  ResetSessionRecords(&second_session);
  FinalizeInto(&first_session, 0, 1, 20000, 16570);
  FinalizeInto(&second_session, 0, 1, 9000, 8200);

  std::vector<FrameCounts> first_rows;
  std::vector<FrameCounts> second_rows;
  assert(CopySessionRecords(&first_session, &first_rows));
  assert(CopySessionRecords(&second_session, &second_rows));
  assert(first_rows.size() == 1 && first_rows[0].frame_id == 0);
  assert(first_rows[0].legacy_count == 16570);
  assert(second_rows.size() == 1 && second_rows[0].frame_id == 0);
  assert(second_rows[0].legacy_count == 8200);
  ResetSessionRecords(&second_session);
  assert(CopySessionRecords(&second_session, &second_rows));
  assert(second_rows.empty());
  assert(CopySessionRecords(&first_session, &first_rows));
  assert(first_rows.size() == 1);

  // One session may receive accepted rows finalized on different worker
  // threads. TLS stays per worker; the session-owned container stays coherent.
  SessionRecords shared_session;
  ResetSessionRecords(&shared_session);
  std::thread first([&] {
    FinalizeInto(&shared_session, 10, 1, 20000, 12290);
  });
  std::thread second([&] {
    FinalizeInto(&shared_session, 20, 2, 9000, 8200);
  });
  first.join();
  second.join();

  std::vector<FrameCounts> shared_rows;
  assert(CopySessionRecords(&shared_session, &shared_rows));
  assert(shared_rows.size() == 2);
  std::sort(shared_rows.begin(), shared_rows.end(),
            [](const FrameCounts& lhs, const FrameCounts& rhs) {
              return lhs.frame_id < rhs.frame_id;
            });
  assert(shared_rows[0].frame_id == 10);
  assert(shared_rows[0].frame_ordinal == 1);
  assert(shared_rows[1].frame_id == 20);
  assert(shared_rows[1].frame_ordinal == 2);

  std::vector<FrameCounts> drained;
  assert(DrainSessionRecords(&shared_session, &drained));
  assert(drained.size() == 2);
  assert(CopySessionRecords(&shared_session, &shared_rows));
  assert(shared_rows.empty());
  std::puts("PASS pending TLS with isolated cross-thread session records");
}
