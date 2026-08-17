#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <filesystem>

extern "C" {
void aether_preclamp_stage_b_bridge_create(void* session) noexcept;
void aether_preclamp_stage_b_bridge_pre_add(void* session) noexcept;
void aether_preclamp_stage_b_bridge_add(void* session, int result,
                                        const int* out_frame_id) noexcept;
void aether_preclamp_stage_b_bridge_finalize(void* session,
                                             int result) noexcept;
void aether_preclamp_stage_b_bridge_free(void* session) noexcept;
bool aether_preclamp_stage_b_bridge_test_snapshot(
    void* session, uint32_t* accepted_ordinal, int* thermal_state,
    bool* viable, bool* finalized,
    aether_preclamp_instr_v1::StageBJournalSnapshot* journal) noexcept;
}

namespace {

using namespace aether_preclamp_instr_v1;

void SeedCandidate() {
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(SealAcceptedLegacyGpuResult(9000, FieldStatus::kValid, 1.5f));
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("rework-stale-tls");
  ConfigureOn(home, "rework-stale-tls");
  int object = 0;
  void* session = &object;
  aether_preclamp_stage_b_bridge_create(session);

  SeedCandidate();  // stale sealed TLS from before this forwarded add call.
  aether_preclamp_stage_b_bridge_pre_add(session);
  uint32_t ordinal = 0;
  int thermal = -2;
  bool viable = true;
  bool finalized = false;
  StageBJournalSnapshot journal;
  assert(aether_preclamp_stage_b_bridge_test_snapshot(
      session, &ordinal, &thermal, &viable, &finalized, &journal));
  assert(!viable);

  // Even a new candidate produced by that same forwarded call cannot repair
  // or continue a session whose entry boundary was already contaminated.
  SeedCandidate();
  const int frame_id = 41;
  aether_preclamp_stage_b_bridge_add(session, 0, &frame_id);
  assert(aether_preclamp_stage_b_bridge_test_snapshot(
      session, &ordinal, &thermal, &viable, &finalized, &journal));
  assert(ordinal == 1 && !viable && journal.row_attempts == 0 &&
         journal.rows_written == 0);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  assert(!std::filesystem::exists(home.Journal("rework-stale-tls")));
  aether_preclamp_stage_b_bridge_free(session);

  std::puts("PASS Stage-B stale sealed TLS poisons the session before clear");
}
