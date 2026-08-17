#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>

#include <sys/stat.h>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

StageBJournalSnapshot AppendAndSnapshot(SessionRecords* records) {
  assert(AppendSessionRecord(records, MakeAccepted(1, 70)));
  assert(records->accepted_rows.size() == 1);
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed ||
         snapshot.status == StageBJournalStatus::kDisabledIdentity);
  assert(snapshot.rows_written == 0);
  return snapshot;
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome base("identity-base");
  ConfigureOn(base, "identity-base");

  ::unsetenv("AETHER_PRECLAMP_RUN_ID_V1");
  SessionRecords missing_run;
  assert(AppendAndSnapshot(&missing_run).first_failure ==
         StageBFailureReason::kIdentityMissing);

  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", "../escape", 1) == 0);
  SessionRecords traversal;
  assert(AppendAndSnapshot(&traversal).first_failure ==
         StageBFailureReason::kIdentityInvalid);

  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", ".", 1) == 0);
  SessionRecords dot;
  assert(AppendAndSnapshot(&dot).first_failure ==
         StageBFailureReason::kIdentityInvalid);

  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", "bad-source", 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_SOURCE_SHA256_V1", "not-a-sha", 1) == 0);
  SessionRecords invalid_source;
  assert(AppendAndSnapshot(&invalid_source).first_failure ==
         StageBFailureReason::kIdentityInvalid);

  assert(::setenv("AETHER_PRECLAMP_SOURCE_SHA256_V1",
                  std::string(64, 'd').c_str(), 1) == 0);
  SessionRecords mismatched_source;
  assert(AppendAndSnapshot(&mismatched_source).first_failure ==
         StageBFailureReason::kIdentityMismatch);

  assert(::setenv("AETHER_PRECLAMP_SOURCE_SHA256_V1",
                  EmbeddedStageBSourceClosure(), 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", "missing-home", 1) == 0);
  ::unsetenv("HOME");
  SessionRecords missing_home;
  assert(AppendAndSnapshot(&missing_home).first_failure ==
         StageBFailureReason::kIdentityMissing);

  assert(::setenv("HOME", "relative/home", 1) == 0);
  SessionRecords relative_home;
  assert(AppendAndSnapshot(&relative_home).first_failure ==
         StageBFailureReason::kHomeInvalid);

  TempHome target("symlink-target");
  TempHome carrier("symlink-carrier");
  const std::string linked_home = carrier.path + "/linked-home";
  assert(::symlink(target.path.c_str(), linked_home.c_str()) == 0);
  assert(::setenv("HOME", linked_home.c_str(), 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", "symlink-home", 1) == 0);
  SessionRecords symlink_home;
  assert(AppendAndSnapshot(&symlink_home).first_failure ==
         StageBFailureReason::kHomeInvalid);

  TempHome missing_application_support("missing-application-support");
  std::filesystem::remove_all(
      missing_application_support.path + "/Library/Application Support");
  ConfigureOn(missing_application_support, "missing-application-support");
  SessionRecords missing_application_support_records;
  assert(AppendSessionRecord(&missing_application_support_records,
                             MakeAccepted(1, 69)));
  StageBJournalSnapshot missing_application_support_snapshot;
  assert(CopyStageBJournalSnapshot(&missing_application_support_records,
                                   &missing_application_support_snapshot));
  assert(missing_application_support_snapshot.status ==
         StageBJournalStatus::kReady);
  assert(missing_application_support_snapshot.rows_written == 1);
  assert(std::filesystem::is_regular_file(
      missing_application_support.Journal("missing-application-support")));
  struct stat created_application_support {};
  const std::string created_application_support_path =
      missing_application_support.path + "/Library/Application Support";
  assert(::stat(created_application_support_path.c_str(),
                &created_application_support) == 0);
  assert((created_application_support.st_mode & 0777) == 0700);

  TempHome parent_fsync_failure("parent-fsync-failure");
  std::filesystem::remove_all(
      parent_fsync_failure.path + "/Library/Application Support");
  ConfigureOn(parent_fsync_failure, "parent-fsync-failure");
  SessionRecords parent_fsync_failure_records;
  // Numeric value reserved by this RED test for the missing parent-directory
  // fsync fault seam. The production implementation must name and handle it.
  ConfigureStageBTestFault(
      &parent_fsync_failure_records, static_cast<StageBTestFault>(19));
  const StageBJournalSnapshot parent_fsync_failure_snapshot =
      AppendAndSnapshot(&parent_fsync_failure_records);
  assert(parent_fsync_failure_snapshot.first_failure ==
         StageBFailureReason::kFsyncFailed);
  assert(!std::filesystem::exists(
      parent_fsync_failure.path +
      "/Library/Application Support/AetherDiagnostics"));
  assert(!std::filesystem::exists(
      parent_fsync_failure.Journal("parent-fsync-failure")));

  TempHome nonregular("nonregular");
  std::filesystem::remove_all(nonregular.path + "/Library/Application Support");
  {
    std::ofstream file(nonregular.path + "/Library/Application Support");
    file << "not-a-directory";
  }
  assert(::setenv("HOME", nonregular.path.c_str(), 1) == 0);
  assert(::setenv("AETHER_PRECLAMP_RUN_ID_V1", "nonregular", 1) == 0);
  SessionRecords nonregular_records;
  assert(AppendAndSnapshot(&nonregular_records).first_failure ==
         StageBFailureReason::kPathRejected);

  TempHome collision_home("collision");
  std::filesystem::create_directories(
      collision_home.path +
      "/Library/Application Support/AetherDiagnostics/collision");
  ConfigureOn(collision_home, "collision");
  SessionRecords collision;
  assert(AppendAndSnapshot(&collision).first_failure ==
         StageBFailureReason::kRunCollision);

  TempHome unexpected_home("unexpected");
  ConfigureOn(unexpected_home, "unexpected");
  SessionRecords unexpected;
  ConfigureStageBTestFault(&unexpected,
                           StageBTestFault::kUnexpectedEntryAfterClaim);
  assert(AppendAndSnapshot(&unexpected).first_failure ==
         StageBFailureReason::kUnexpectedEntry);

  TempHome replaced_home("replaced-claim");
  ConfigureOn(replaced_home, "replaced-claim");
  SessionRecords replaced;
  ConfigureStageBTestFault(&replaced, StageBTestFault::kReplaceRunAfterClaim);
  assert(AppendAndSnapshot(&replaced).first_failure ==
         StageBFailureReason::kPathRejected);
  const std::string run_root =
      replaced_home.path +
      "/Library/Application Support/AetherDiagnostics/replaced-claim";
  assert(!std::filesystem::exists(run_root + "/stage_b_counts.v1"));
  assert(!std::filesystem::exists(
      replaced_home.path +
      "/Library/Application Support/AetherDiagnostics/.displaced."
      "replaced-claim/stage_b_counts.v1"));

  std::puts("PASS Stage-B identity, HOME, path, replacement, collision, and "
            "residue gates");
}
