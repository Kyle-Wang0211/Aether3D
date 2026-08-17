#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include "../../official_pipeline/include/official_sfm_c.h"

#include <cassert>
#include <cstdio>
#include <cstring>

extern "C" {
size_t aether_preclamp_stage_b_bridge_test_session_count() noexcept;
}

namespace {

const char* g_db_path = nullptr;
const aether_sfm_options_t* g_options = nullptr;
aether_sfm_session_t** g_out_session = nullptr;
aether_sfm_session_t* g_session = nullptr;
const uint8_t* g_gray = nullptr;
int g_width = 0;
int g_height = 0;
float g_fx = 0.0f;
float g_fy = 0.0f;
float g_cx = 0.0f;
float g_cy = 0.0f;
const double* g_pose_q = nullptr;
const double* g_pose_t = nullptr;
int* g_out_frame_id = nullptr;
int g_remove_frame_id = -1;
char* g_json = nullptr;
int g_json_cap = 0;
int g_thermal = -1;
int g_free_calls = 0;
int g_finalize_calls = 0;
aether_sfm_result_t g_create_result = AETHER_SFM_OK;
aether_sfm_result_t g_add_result = AETHER_SFM_OK;
aether_sfm_result_t g_remove_result = AETHER_SFM_OK;
aether_sfm_result_t g_finalize_result = AETHER_SFM_OK;
aether_sfm_session_t* g_created_value =
    reinterpret_cast<aether_sfm_session_t*>(0x12340);
int g_returned_frame_id = 321;
bool g_seal_candidate_during_add = false;

}  // namespace

extern "C" aether_sfm_result_t aether_sfm_create(
    const char* db_path, const aether_sfm_options_t* options,
    aether_sfm_session_t** out_session) {
  g_db_path = db_path;
  g_options = options;
  g_out_session = out_session;
  if (out_session != nullptr) *out_session = g_created_value;
  return g_create_result;
}

extern "C" aether_sfm_result_t aether_sfm_add_frame(
    aether_sfm_session_t* session, const uint8_t* gray, int width, int height,
    float fx, float fy, float cx, float cy, const double pose_qwxyz[4],
    const double pose_t[3], int* out_frame_id) {
  g_session = session;
  g_gray = gray;
  g_width = width;
  g_height = height;
  g_fx = fx;
  g_fy = fy;
  g_cx = cx;
  g_cy = cy;
  g_pose_q = pose_qwxyz;
  g_pose_t = pose_t;
  g_out_frame_id = out_frame_id;
  if (g_seal_candidate_during_add) {
    aether_preclamp_instr_v1::BeginLegacyClamp(10000);
    aether_preclamp_instr_v1::UpdateLegacyClampResult(9000);
    assert(aether_preclamp_instr_v1::SealAcceptedLegacyGpuResult(
        9000, aether_preclamp_instr_v1::FieldStatus::kValid, 1.5f));
  }
  if (out_frame_id != nullptr) *out_frame_id = g_returned_frame_id;
  return g_add_result;
}

extern "C" aether_sfm_result_t aether_sfm_remove_frame(
    aether_sfm_session_t* session, int frame_id, char* out_json, int out_cap) {
  g_session = session;
  g_remove_frame_id = frame_id;
  g_json = out_json;
  g_json_cap = out_cap;
  if (out_json != nullptr && out_cap >= 8) std::memcpy(out_json, "remove\0", 7);
  return g_remove_result;
}

extern "C" aether_sfm_result_t aether_sfm_finalize_async(
    aether_sfm_session_t* session, char* out_json, int out_cap) {
  g_session = session;
  g_json = out_json;
  g_json_cap = out_cap;
  ++g_finalize_calls;
  if (out_json != nullptr && out_cap >= 9) std::memcpy(out_json, "finalize\0", 9);
  return g_finalize_result;
}

extern "C" void aether_sfm_set_thermal_state(aether_sfm_session_t* session,
                                               int state) {
  g_session = session;
  g_thermal = state;
}

extern "C" void aether_sfm_free(aether_sfm_session_t* session) {
  g_session = session;
  ++g_free_calls;
}

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome home("shim-forward");
  ConfigureOn(home, "shim-forward");
  aether_sfm_options_t options{};
  aether_sfm_session_t* session = nullptr;
  const char db_path[] = "/private/tmp/forward.db";
  assert(pwofficial_create(db_path, &options, &session) == AETHER_SFM_OK);
  assert(g_db_path == db_path && g_options == &options &&
         g_out_session == &session && session == g_created_value);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 1);

  pwofficial_set_thermal_state(session, 3);
  assert(g_session == session && g_thermal == 3);

  uint8_t gray[6] = {1, 2, 3, 4, 5, 6};
  const double pose_q[4] = {1.0, 0.0, 0.0, 0.0};
  const double pose_t[3] = {4.0, 5.0, 6.0};
  int out_frame_id = -1;
  g_add_result = AETHER_SFM_ERR_EXTRACT;
  g_returned_frame_id = 876;
  assert(pwofficial_add_frame(session, gray, 3, 2, 10.0f, 11.0f, 1.0f,
                              2.0f, pose_q, pose_t, &out_frame_id) ==
         AETHER_SFM_ERR_EXTRACT);
  assert(g_session == session && g_gray == gray && g_width == 3 &&
         g_height == 2 && g_fx == 10.0f && g_fy == 11.0f && g_cx == 1.0f &&
         g_cy == 2.0f && g_pose_q == pose_q && g_pose_t == pose_t &&
         g_out_frame_id == &out_frame_id && out_frame_id == 876);

  g_add_result = AETHER_SFM_OK;
  g_seal_candidate_during_add = true;
  g_returned_frame_id = 321;
  out_frame_id = -1;
  assert(pwofficial_add_frame(session, gray, 3, 2, 10.0f, 11.0f, 1.0f,
                              2.0f, pose_q, pose_t, &out_frame_id) ==
         AETHER_SFM_OK);
  assert(out_frame_id == 321);
  g_seal_candidate_during_add = false;

  char json[32] = {};
  g_remove_result = AETHER_SFM_ERR_DB;
  assert(pwofficial_remove_frame(session, 321, json, sizeof(json)) ==
         AETHER_SFM_ERR_DB);
  assert(g_session == session && g_remove_frame_id == 321 && g_json == json &&
         g_json_cap == static_cast<int>(sizeof(json)) &&
         std::strcmp(json, "remove") == 0);

  g_finalize_result = AETHER_SFM_ERR_INTERNAL;
  std::memset(json, 0, sizeof(json));
  assert(pwofficial_finalize_async(session, json, sizeof(json)) ==
         AETHER_SFM_ERR_INTERNAL);
  assert(g_session == session && g_json == json &&
         g_json_cap == static_cast<int>(sizeof(json)) &&
         std::strcmp(json, "finalize") == 0);
  g_finalize_result = AETHER_SFM_OK;
  std::memset(json, 0, sizeof(json));
  assert(pwofficial_finalize_async(session, json, sizeof(json)) ==
         AETHER_SFM_OK);
  assert(std::strcmp(json, "finalize") == 0);
  assert(pwofficial_finalize_async(session, json, sizeof(json)) ==
         AETHER_SFM_OK);
  assert(g_finalize_calls == 3);

  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(home.Journal("shim-forward"))),
                            "shim-forward", EmbeddedStageBSourceClosure(),
                            &parsed) == StageBArtifactStatus::kSealed);
  assert(parsed.rows.size() == 1 && parsed.rows[0].frame_id == 321 &&
         parsed.rows[0].thermal_state == 3);

  pwofficial_free(session);
  assert(g_session == session && g_free_calls == 1 &&
         aether_preclamp_stage_b_bridge_test_session_count() == 0);

  TempHome stale_home("shim-stale-entry");
  ConfigureOn(stale_home, "shim-stale-entry");
  g_created_value = reinterpret_cast<aether_sfm_session_t*>(0x23450);
  session = nullptr;
  assert(pwofficial_create(db_path, &options, &session) == AETHER_SFM_OK);
  ClearPendingAtGpuEntry();
  BeginLegacyClamp(10000);
  UpdateLegacyClampResult(9000);
  assert(SealAcceptedLegacyGpuResult(9000, FieldStatus::kValid, 1.5f));
  g_seal_candidate_during_add = false;
  g_returned_frame_id = 654;
  out_frame_id = -1;
  assert(pwofficial_add_frame(session, gray, 3, 2, 10.0f, 11.0f, 1.0f,
                              2.0f, pose_q, pose_t, &out_frame_id) ==
         AETHER_SFM_OK);
  assert(out_frame_id == 654);
  assert(pwofficial_finalize_async(session, json, sizeof(json)) ==
         AETHER_SFM_OK);
  assert(!std::filesystem::exists(stale_home.Journal("shim-stale-entry")));
  pwofficial_free(session);

  TempHome removed_home("shim-remove");
  ConfigureOn(removed_home, "shim-remove");
  g_created_value = reinterpret_cast<aether_sfm_session_t*>(0x34560);
  session = nullptr;
  assert(pwofficial_create(db_path, &options, &session) == AETHER_SFM_OK);
  g_seal_candidate_during_add = true;
  g_returned_frame_id = 765;
  out_frame_id = -1;
  assert(pwofficial_add_frame(session, gray, 3, 2, 10.0f, 11.0f, 1.0f,
                              2.0f, pose_q, pose_t, &out_frame_id) ==
         AETHER_SFM_OK);
  g_seal_candidate_during_add = false;
  g_remove_result = AETHER_SFM_OK;
  std::memset(json, 0, sizeof(json));
  assert(pwofficial_remove_frame(session, 765, json, sizeof(json)) ==
         AETHER_SFM_OK);
  assert(g_session == session && g_remove_frame_id == 765 &&
         std::strcmp(json, "remove") == 0);
  assert(pwofficial_finalize_async(session, json, sizeof(json)) ==
         AETHER_SFM_OK);
  assert(ParseStageBJournal(
             Bytes(ReadText(removed_home.Journal("shim-remove"))),
             "shim-remove", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  pwofficial_free(session);

  g_create_result = AETHER_SFM_ERR_DB;
  session = nullptr;
  assert(pwofficial_create(db_path, &options, &session) == AETHER_SFM_ERR_DB);
  assert(session == g_created_value);
  assert(aether_preclamp_stage_b_bridge_test_session_count() == 0);

  std::puts("PASS Stage-B export shim preserves forwarding and observes only "
            "successful lifecycle calls");
}
