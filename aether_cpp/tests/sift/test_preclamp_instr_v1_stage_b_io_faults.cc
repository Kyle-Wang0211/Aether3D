#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <string>

#include <sys/wait.h>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

void AssertNotSealed(const TempHome& home, const std::string& run_id) {
  const std::string path = home.Journal(run_id);
  if (!std::filesystem::exists(path)) return;
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(path)), run_id,
                            EmbeddedStageBSourceClosure(), &parsed) !=
         StageBArtifactStatus::kSealed);
}

void RunAppendFault(const char* label, StageBTestFault fault,
                    StageBFailureReason expected, uint32_t writer_calls) {
  TempHome home(label);
  ConfigureOn(home, label);
  SessionRecords records;
  ConfigureStageBTestFault(&records, fault);
  assert(AppendSessionRecord(&records, MakeAccepted(1, 100)));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed);
  assert(snapshot.first_failure == expected);
  assert(snapshot.row_attempts == 1);
  assert(snapshot.writer_calls == writer_calls);
  assert(snapshot.rows_written == 0);
  assert(AppendSessionRecord(&records, MakeAccepted(2, 101)));
  StageBJournalSnapshot retry;
  assert(CopyStageBJournalSnapshot(&records, &retry));
  assert(retry.first_failure == expected);
  assert(retry.row_attempts == 2);
  assert(retry.writer_calls == writer_calls);
  assert(retry.rows_written == 0);
  assert(!SealStageBJournal(&records));
  AssertNotSealed(home, label);
}

void RunTransient(const char* label, StageBTestFault fault) {
  TempHome home(label);
  ConfigureOn(home, label);
  SessionRecords records;
  ConfigureStageBTestFault(&records, fault);
  assert(AppendSessionRecord(&records, MakeAccepted(1, 200)));
  assert(SealStageBJournal(&records));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kSealed);
  assert(snapshot.first_failure == StageBFailureReason::kNone);
  assert(snapshot.rows_written == 1);
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(home.Journal(label))), label,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);
}

void RunSealFault(const char* label, StageBTestFault fault,
                  StageBFailureReason expected) {
  TempHome home(label);
  ConfigureOn(home, label);
  SessionRecords records;
  assert(AppendSessionRecord(&records, MakeAccepted(1, 300)));
  ConfigureStageBTestFault(&records, fault);
  assert(!SealStageBJournal(&records));
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed);
  assert(snapshot.first_failure == expected);
  assert(snapshot.seal_attempts == 1);
  assert(!SealStageBJournal(&records));
  StageBJournalSnapshot retry;
  assert(CopyStageBJournalSnapshot(&records, &retry));
  assert(retry.seal_attempts == 1);
  AssertNotSealed(home, label);
}

void WaitClean(pid_t child) {
  int status = 0;
  assert(::waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  RunTransient("eintr", StageBTestFault::kInterruptWriteOnce);
  RunTransient("short-write", StageBTestFault::kShortWriteOnce);

  RunAppendFault("header-open", StageBTestFault::kHeaderOpen,
                 StageBFailureReason::kOpenFailed, 0);
  RunAppendFault("header-partial", StageBTestFault::kHeaderPartialWrite,
                 StageBFailureReason::kWriteFailed, 0);
  RunAppendFault("header-fsync", StageBTestFault::kHeaderFsync,
                 StageBFailureReason::kFsyncFailed, 0);
  RunAppendFault("header-close", StageBTestFault::kHeaderClose,
                 StageBFailureReason::kCloseFailed, 0);
  RunAppendFault("header-publish", StageBTestFault::kHeaderPublish,
                 StageBFailureReason::kPublishFailed, 0);
  RunAppendFault("header-dir-fsync",
                 StageBTestFault::kHeaderDirectoryFsync,
                 StageBFailureReason::kFsyncFailed, 0);
  RunAppendFault("row-open", StageBTestFault::kRowOpen,
                 StageBFailureReason::kOpenFailed, 1);
  RunAppendFault("row-enospc", StageBTestFault::kRowEnospc,
                 StageBFailureReason::kWriteFailed, 1);
  RunAppendFault("row-partial", StageBTestFault::kRowPartialWrite,
                 StageBFailureReason::kWriteFailed, 1);
  RunAppendFault("row-close", StageBTestFault::kRowClose,
                 StageBFailureReason::kCloseFailed, 1);

  RunSealFault("seal-open", StageBTestFault::kSealOpen,
               StageBFailureReason::kOpenFailed);
  RunSealFault("seal-partial", StageBTestFault::kSealPartialWrite,
               StageBFailureReason::kWriteFailed);
  RunSealFault("seal-fsync", StageBTestFault::kSealFsync,
               StageBFailureReason::kFsyncFailed);

  TempHome warning_home("seal-close-warning");
  ConfigureOn(warning_home, "seal-close-warning");
  SessionRecords warning;
  assert(AppendSessionRecord(&warning, MakeAccepted(1, 400)));
  ConfigureStageBTestFault(&warning,
                           StageBTestFault::kSealCloseAfterFsync);
  assert(SealStageBJournal(&warning));
  StageBJournalSnapshot warning_snapshot;
  assert(CopyStageBJournalSnapshot(&warning, &warning_snapshot));
  assert(warning_snapshot.status ==
         StageBJournalStatus::kSealedWithCloseWarning);
  assert(warning_snapshot.post_seal_close_warning);
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(
             Bytes(ReadText(warning_home.Journal("seal-close-warning"))),
             "seal-close-warning", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);

  TempHome killed_home("kill-prefix");
  ConfigureOn(killed_home, "kill-prefix");
  const pid_t killed = ::fork();
  assert(killed >= 0);
  if (killed == 0) {
    SessionRecords records;
    if (!AppendSessionRecord(&records, MakeAccepted(1, 500))) ::_exit(2);
    ::_exit(0);
  }
  WaitClean(killed);
  assert(ParseStageBJournal(
             Bytes(ReadText(killed_home.Journal("kill-prefix"))),
             "kill-prefix", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  assert(parsed.complete_prefix_rows == 1);

  TempHome sealed_kill_home("kill-after-seal");
  ConfigureOn(sealed_kill_home, "kill-after-seal");
  const pid_t sealed_kill = ::fork();
  assert(sealed_kill >= 0);
  if (sealed_kill == 0) {
    SessionRecords records;
    if (!AppendSessionRecord(&records, MakeAccepted(1, 600))) ::_exit(3);
    if (!SealStageBJournal(&records)) ::_exit(4);
    ::_exit(0);
  }
  WaitClean(sealed_kill);
  assert(ParseStageBJournal(
             Bytes(ReadText(sealed_kill_home.Journal("kill-after-seal"))),
             "kill-after-seal", EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);

  std::puts("PASS Stage-B EINTR, short write, I/O failures, seal boundary, "
            "and process-kill recovery");
}
