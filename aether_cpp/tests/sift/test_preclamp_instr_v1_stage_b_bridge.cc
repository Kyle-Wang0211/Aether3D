#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>

extern "C" {
void aether_preclamp_stage_b_bridge_create(void* session) noexcept;
void aether_preclamp_stage_b_bridge_thermal(void* session, int state) noexcept;
void aether_preclamp_stage_b_bridge_pre_add(void* session) noexcept;
void aether_preclamp_stage_b_bridge_add(void* session, int result,
                                        const int* out_frame_id) noexcept;
void aether_preclamp_stage_b_bridge_remove(void* session, int result) noexcept;
void aether_preclamp_stage_b_bridge_finalize(void* session,
                                             int result) noexcept;
void aether_preclamp_stage_b_bridge_free(void* session) noexcept;
size_t aether_preclamp_stage_b_bridge_test_session_count() noexcept;
bool aether_preclamp_stage_b_bridge_test_snapshot(
    void* session, uint32_t* accepted_ordinal, int* thermal_state,
    bool* viable, bool* finalized,
    aether_preclamp_instr_v1::StageBJournalSnapshot* journal) noexcept;
}

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

void SeedLegacyGpuCandidate() {
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(SealAcceptedLegacyGpuResult(9000, FieldStatus::kValid, 1.5f));
}

StageBJournalSnapshot Snapshot(void* session, uint32_t* ordinal = nullptr,
                               bool* viable = nullptr,
                               bool* finalized = nullptr) {
  uint32_t local_ordinal = 0;
  int thermal = -2;
  bool local_viable = false;
  bool local_finalized = false;
  StageBJournalSnapshot journal;
  assert(aether_preclamp_stage_b_bridge_test_snapshot(
      session, &local_ordinal, &thermal, &local_viable, &local_finalized,
      &journal));
  if (ordinal != nullptr) *ordinal = local_ordinal;
  if (viable != nullptr) *viable = local_viable;
  if (finalized != nullptr) *finalized = local_finalized;
  return journal;
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  int object = 0;
  void* session = &object;
  TempHome success_home("bridge-success");
  ConfigureOn(success_home, "bridge-success");
  aether_preclamp_stage_b_bridge_create(session);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 1);
  aether_preclamp_stage_b_bridge_thermal(session, 2);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int frame_id = 41;
  aether_preclamp_stage_b_bridge_add(session, 0, &frame_id);
  uint32_t ordinal = 0;
  bool viable = false;
  bool finalized = false;
  StageBJournalSnapshot journal =
      Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 1 && viable && !finalized);
  assert(journal.rows_written == 1);

  aether_preclamp_stage_b_bridge_finalize(session, 6);
  journal = Snapshot(session, &ordinal, &viable, &finalized);
  assert(!finalized && journal.seal_attempts == 0);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  journal = Snapshot(session, &ordinal, &viable, &finalized);
  assert(finalized && journal.status == StageBJournalStatus::kSealed &&
         journal.seal_attempts == 1);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  journal = Snapshot(session, &ordinal, &viable, &finalized);
  assert(journal.seal_attempts == 1);
  aether_preclamp_stage_b_bridge_free(session);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 0);

  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(success_home.Journal("bridge-success"))),
                            "bridge-success", EmbeddedStageBSourceClosure(),
                            &parsed) == StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1 && parsed.rows[0].frame_id == frame_id &&
         parsed.rows[0].frame_ordinal == 1 &&
         parsed.rows[0].thermal_state == 2);

  TempHome reuse_home("bridge-reuse");
  ConfigureOn(reuse_home, "bridge-reuse");
  aether_preclamp_stage_b_bridge_create(session);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 0 && viable && !finalized);
  aether_preclamp_stage_b_bridge_thermal(session, 99);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int reuse_id = 52;
  aether_preclamp_stage_b_bridge_add(session, 0, &reuse_id);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(ParseStageBJournal(Bytes(ReadText(reuse_home.Journal("bridge-reuse"))),
                            "bridge-reuse", EmbeddedStageBSourceClosure(),
                            &parsed) == StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1 &&
         parsed.rows[0].thermal_state_status == FieldStatus::kUnavailable &&
         parsed.rows[0].thermal_state == -1);

  TempHome failed_add_home("bridge-failed-add");
  ConfigureOn(failed_add_home, "bridge-failed-add");
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int untouched_id = 70;
  aether_preclamp_stage_b_bridge_add(session, 3, &untouched_id);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 0 && viable);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int accepted_id = 71;
  aether_preclamp_stage_b_bridge_add(session, 0, &accepted_id);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(ParseStageBJournal(
             Bytes(ReadText(failed_add_home.Journal("bridge-failed-add"))),
             "bridge-failed-add", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1 && parsed.rows[0].frame_ordinal == 1);

  TempHome ineligible_home("bridge-ineligible");
  ConfigureOn(ineligible_home, "bridge-ineligible");
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_pre_add(session);
  const int ineligible_id = 80;
  aether_preclamp_stage_b_bridge_add(session, 0, &ineligible_id);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 1 && !viable);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(finalized && !viable);
  assert(!std::filesystem::exists(
      ineligible_home.Journal("bridge-ineligible")));
  aether_preclamp_stage_b_bridge_free(session);

  TempHome invalid_identity_home("bridge-invalid-output");
  ConfigureOn(invalid_identity_home, "bridge-invalid-output");
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  aether_preclamp_stage_b_bridge_add(session, 0, nullptr);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 1 && !viable);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(!std::filesystem::exists(
      invalid_identity_home.Journal("bridge-invalid-output")));

  TempHome removed_home("bridge-remove");
  ConfigureOn(removed_home, "bridge-remove");
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int removed_id = 90;
  aether_preclamp_stage_b_bridge_add(session, 0, &removed_id);
  aether_preclamp_stage_b_bridge_remove(session, 0);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(!viable);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(ParseStageBJournal(
             Bytes(ReadText(removed_home.Journal("bridge-remove"))),
             "bridge-remove", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);

  TempHome free_home("bridge-free-unsealed");
  ConfigureOn(free_home, "bridge-free-unsealed");
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_pre_add(session);
  SeedLegacyGpuCandidate();
  const int free_id = 100;
  aether_preclamp_stage_b_bridge_add(session, 0, &free_id);
  aether_preclamp_stage_b_bridge_free(session);
  assert(ParseStageBJournal(
             Bytes(ReadText(free_home.Journal("bridge-free-unsealed"))),
             "bridge-free-unsealed", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 0);

  TempHome stale_home("bridge-stale-entry");
  ConfigureOn(stale_home, "bridge-stale-entry");
  aether_preclamp_stage_b_bridge_create(session);
  SeedLegacyGpuCandidate();
  aether_preclamp_stage_b_bridge_pre_add(session);
  const int stale_id = 110;
  aether_preclamp_stage_b_bridge_add(session, 0, &stale_id);
  Snapshot(session, &ordinal, &viable, &finalized);
  assert(ordinal == 1 && !viable);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(!std::filesystem::exists(
      stale_home.Journal("bridge-stale-entry")));

  std::puts("PASS Stage-B bridge lifecycle, invalidation, and pointer reuse");
}
