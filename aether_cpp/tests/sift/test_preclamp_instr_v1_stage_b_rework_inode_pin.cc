#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <csignal>
#include <cstdio>
#include <filesystem>
#include <fstream>

#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

void ReplaceWithRegularCopy(const std::string& path,
                            const std::string& displaced) {
  const std::string bytes = ReadText(path);
  std::filesystem::rename(path, displaced);
  std::ofstream replacement(path, std::ios::binary | std::ios::trunc);
  assert(replacement.good());
  replacement.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  replacement.close();
  assert(replacement.good());
}

enum class ReplacementKind { kFifo, kSymlink };

void ExerciseBlockingReplacement(const char* label, ReplacementKind kind,
                                 bool seal) {
  TempHome home(label);
  ConfigureOn(home, label);
  SessionRecords records;
  assert(AppendSessionRecord(&records, MakeAccepted(1, 100)));
  const std::string path = home.Journal(label);
  const std::string displaced = path + ".displaced";
  std::filesystem::rename(path, displaced);
  if (kind == ReplacementKind::kFifo) {
    assert(::mkfifo(path.c_str(), 0600) == 0);
  } else {
    assert(::symlink(displaced.c_str(), path.c_str()) == 0);
  }

  if (seal) {
    assert(!SealStageBJournal(&records));
  } else {
    assert(AppendSessionRecord(&records, MakeAccepted(2, 101)));
  }
  StageBJournalSnapshot snapshot;
  assert(CopyStageBJournalSnapshot(&records, &snapshot));
  assert(snapshot.status == StageBJournalStatus::kFailed);
  assert(snapshot.first_failure == StageBFailureReason::kOpenFailed ||
         snapshot.first_failure == StageBFailureReason::kPathRejected);
}

void AssertReplacementFailsBounded(const char* label, ReplacementKind kind,
                                   bool seal) {
  const pid_t child = ::fork();
  assert(child >= 0);
  if (child == 0) {
    ::alarm(2);
    ExerciseBlockingReplacement(label, kind, seal);
    ::alarm(0);
    ::_exit(0);
  }
  int status = 0;
  assert(::waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status));
  assert(WEXITSTATUS(status) == 0);
}

}  // namespace

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome append_home("rework-inode-append");
  ConfigureOn(append_home, "rework-inode-append");
  SessionRecords append_records;
  assert(AppendSessionRecord(&append_records, MakeAccepted(1, 10)));
  const std::string append_path = append_home.Journal("rework-inode-append");
  ReplaceWithRegularCopy(append_path, append_path + ".displaced");
  assert(AppendSessionRecord(&append_records, MakeAccepted(2, 11)));
  StageBJournalSnapshot append_snapshot;
  assert(CopyStageBJournalSnapshot(&append_records, &append_snapshot));
  assert(append_snapshot.status == StageBJournalStatus::kFailed);
  assert(append_snapshot.first_failure == StageBFailureReason::kPathRejected);
  assert(append_snapshot.rows_written == 1);

  TempHome seal_home("rework-inode-seal");
  ConfigureOn(seal_home, "rework-inode-seal");
  SessionRecords seal_records;
  assert(AppendSessionRecord(&seal_records, MakeAccepted(1, 20)));
  const std::string seal_path = seal_home.Journal("rework-inode-seal");
  ReplaceWithRegularCopy(seal_path, seal_path + ".displaced");
  assert(!SealStageBJournal(&seal_records));
  StageBJournalSnapshot seal_snapshot;
  assert(CopyStageBJournalSnapshot(&seal_records, &seal_snapshot));
  assert(seal_snapshot.status == StageBJournalStatus::kFailed);
  assert(seal_snapshot.first_failure == StageBFailureReason::kPathRejected);
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(seal_path)), "rework-inode-seal",
                            EmbeddedStageBSourceClosure(), &parsed) !=
         StageBArtifactStatus::kSealed);

  AssertReplacementFailsBounded("rework-fifo-append", ReplacementKind::kFifo,
                                false);
  AssertReplacementFailsBounded("rework-fifo-seal", ReplacementKind::kFifo,
                                true);
  AssertReplacementFailsBounded("rework-symlink-append",
                                ReplacementKind::kSymlink, false);
  AssertReplacementFailsBounded("rework-symlink-seal",
                                ReplacementKind::kSymlink, true);

  std::puts("PASS Stage-B append and seal reject replaced inode, FIFO, and "
            "symlink without blocking");
}
