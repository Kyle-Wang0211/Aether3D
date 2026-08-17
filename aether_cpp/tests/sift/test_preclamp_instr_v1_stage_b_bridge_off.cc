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
}

int main() {
  ::unsetenv("AETHER_PRECLAMP_INSTR_V1");
  ::unsetenv("AETHER_PRECLAMP_RUN_ID_V1");
  ::unsetenv("AETHER_PRECLAMP_SOURCE_SHA256_V1");
  int object = 0;
  void* session = &object;
  const int frame_id = 1;
  aether_preclamp_stage_b_bridge_create(session);
  aether_preclamp_stage_b_bridge_thermal(session, 2);
  aether_preclamp_stage_b_bridge_pre_add(session);
  aether_preclamp_stage_b_bridge_add(session, 0, &frame_id);
  aether_preclamp_stage_b_bridge_remove(session, 0);
  aether_preclamp_stage_b_bridge_finalize(session, 0);
  aether_preclamp_stage_b_bridge_free(session);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 0);
  std::puts("PASS Stage-B bridge OFF creates no map state");
}
