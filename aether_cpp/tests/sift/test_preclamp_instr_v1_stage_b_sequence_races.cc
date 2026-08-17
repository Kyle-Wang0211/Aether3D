#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>

#include <sys/wait.h>

int main() {
  using namespace aether_preclamp_instr_v1;
  using namespace preclamp_stage_b_test;

  TempHome ordered_home("ordered");
  ConfigureOn(ordered_home, "ordered");
  SessionRecords ordered;
  std::atomic<int> turn{0};
  std::thread first([&] {
    assert(AppendSessionRecord(&ordered, MakeAccepted(1, 10)));
    turn.store(1, std::memory_order_release);
  });
  std::thread second([&] {
    while (turn.load(std::memory_order_acquire) == 0) std::this_thread::yield();
    assert(AppendSessionRecord(&ordered, MakeAccepted(2, 11)));
  });
  first.join();
  second.join();
  assert(!AppendSessionRecord(&ordered, MakeAccepted(3, 10)));
  assert(!AppendSessionRecord(&ordered, MakeAccepted(2, 12)));
  StageBJournalSnapshot ordered_snapshot;
  assert(CopyStageBJournalSnapshot(&ordered, &ordered_snapshot));
  assert(ordered_snapshot.row_attempts == 2);
  assert(ordered_snapshot.writer_calls == 2);
  assert(ordered_snapshot.rows_written == 2);
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(ReadText(ordered_home.Journal("ordered"))),
                            "ordered", EmbeddedStageBSourceClosure(),
                            &parsed) == StageBArtifactStatus::kIncomplete);
  assert(parsed.rows.size() == 2);
  assert(parsed.rows[0].frame_ordinal == 1 &&
         parsed.rows[1].frame_ordinal == 2);

  TempHome process_home("same-process-race");
  ConfigureOn(process_home, "same-process-race");
  SessionRecords contender_a;
  SessionRecords contender_b;
  std::atomic<bool> go{false};
  std::thread a([&] {
    while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
    assert(AppendSessionRecord(&contender_a, MakeAccepted(1, 20)));
  });
  std::thread b([&] {
    while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
    assert(AppendSessionRecord(&contender_b, MakeAccepted(1, 20)));
  });
  go.store(true, std::memory_order_release);
  a.join();
  b.join();
  StageBJournalSnapshot snapshot_a;
  StageBJournalSnapshot snapshot_b;
  assert(CopyStageBJournalSnapshot(&contender_a, &snapshot_a));
  assert(CopyStageBJournalSnapshot(&contender_b, &snapshot_b));
  const int ready =
      (snapshot_a.status == StageBJournalStatus::kReady ? 1 : 0) +
      (snapshot_b.status == StageBJournalStatus::kReady ? 1 : 0);
  const int collided =
      (snapshot_a.first_failure == StageBFailureReason::kRunCollision ? 1 : 0) +
      (snapshot_b.first_failure == StageBFailureReason::kRunCollision ? 1 : 0);
  assert(ready == 1 && collided == 1);

  TempHome fork_home("fork-race");
  ConfigureOn(fork_home, "fork-race");
  int start_pipe[2];
  assert(::pipe(start_pipe) == 0);
  pid_t children[2];
  for (int i = 0; i < 2; ++i) {
    children[i] = ::fork();
    assert(children[i] >= 0);
    if (children[i] == 0) {
      (void)::close(start_pipe[1]);
      char token = 0;
      if (::read(start_pipe[0], &token, 1) != 1) ::_exit(40);
      SessionRecords child_records;
      if (!AppendSessionRecord(&child_records, MakeAccepted(1, 30))) {
        ::_exit(41);
      }
      StageBJournalSnapshot child_snapshot;
      if (!CopyStageBJournalSnapshot(&child_records, &child_snapshot)) {
        ::_exit(42);
      }
      ::_exit(child_snapshot.status == StageBJournalStatus::kReady ? 0 :
              child_snapshot.first_failure ==
                      StageBFailureReason::kRunCollision
                  ? 10
                  : 43);
    }
  }
  (void)::close(start_pipe[0]);
  const char tokens[2] = {'a', 'b'};
  assert(::write(start_pipe[1], tokens, sizeof(tokens)) == 2);
  (void)::close(start_pipe[1]);
  int winners = 0;
  int collisions = 0;
  for (pid_t child : children) {
    int wait_status = 0;
    assert(::waitpid(child, &wait_status, 0) == child);
    assert(WIFEXITED(wait_status));
    if (WEXITSTATUS(wait_status) == 0) ++winners;
    if (WEXITSTATUS(wait_status) == 10) ++collisions;
  }
  assert(winners == 1 && collisions == 1);
  std::puts("PASS Stage-B ordering, duplicate, thread, and fork ownership gates");
}
