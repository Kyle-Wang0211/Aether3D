#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#define AETHER_PRECLAMP_INSTR_TEST_HOOKS 1
#include "test_preclamp_instr_v1_stage_b_fixture.h"

#include <cassert>
#include <cstdio>
#include <string>

namespace {

using namespace aether_preclamp_instr_v1;
using namespace preclamp_stage_b_test;

const std::string kRun = "parser-reject";

std::string Header() {
  return "STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=" + kRun +
         "|source_sha256=" + EmbeddedStageBSourceClosure() + "\n";
}

std::string Row(uint32_t ordinal, int64_t frame_id) {
  return "frame|ordinal=" + std::to_string(ordinal) +
         "|id=" + std::to_string(frame_id) +
         "|preclamp=10000|legacy=9000|strict=8192|overflow=808"
         "|descriptor_rows=9000|gpu_ms_status=1|gpu_ms_bits=3fc00000"
         "|thermal_status=1|thermal=2|backlog_status=2|backlog=0\n";
}

std::string Sealed(const std::string& prefix, uint32_t rows,
                   uint32_t last_ordinal) {
  return prefix + "seal|rows=" + std::to_string(rows) +
         "|last_ordinal=" + std::to_string(last_ordinal) +
         "|journal_sha256=" + Sha256Hex(Bytes(prefix)) + "\n";
}

std::string ReplaceOnce(std::string text, const std::string& from,
                        const std::string& to) {
  const size_t at = text.find(from);
  assert(at != std::string::npos);
  text.replace(at, from.size(), to);
  return text;
}

void AssertRejected(const std::string& bytes) {
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(bytes), kRun, EmbeddedStageBSourceClosure(),
                            &parsed) != StageBArtifactStatus::kSealed);
}

void AssertRejectedPrefix(const std::string& prefix) {
  AssertRejected(Sealed(prefix, 1, 1));
}

}  // namespace

int main() {
  const std::string row = Row(1, 7);
  const std::string prefix = Header() + row;
  StageBParsedJournal parsed;
  assert(ParseStageBJournal(Bytes(Sealed(prefix, 1, 1)), kRun,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kSealed);

  AssertRejected("");
  AssertRejected(row);
  AssertRejected(ReplaceOnce(Sealed(prefix, 1, 1),
                             "run_id=parser-reject", "run_id=other"));
  AssertRejected(ReplaceOnce(Sealed(prefix, 1, 1),
                             EmbeddedStageBSourceClosure(),
                             std::string(64, 'b')));
  AssertRejected(ReplaceOnce(Sealed(prefix, 1, 1), "schema=1", "schema=01"));
  AssertRejected(ReplaceOnce(Sealed(prefix, 1, 1), "\n", "\r\n"));
  std::string non_ascii = Sealed(prefix, 1, 1);
  non_ascii[0] = static_cast<char>(0x80);
  AssertRejected(non_ascii);

  AssertRejectedPrefix(ReplaceOnce(prefix, "ordinal=1", "ordinal=01"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "ordinal=1", "ordinal=+1"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "id=7", "id=-0"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "id=7", "id=+7"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "preclamp=10000", "preclamp=4294967296"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "id=7", "id=9223372036854775808"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "gpu_ms_bits=3fc00000", "gpu_ms_bits=3FC00000"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "gpu_ms_bits=3fc00000", "gpu_ms_bits=7f800000"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "gpu_ms_status=1", "gpu_ms_status=0"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "thermal_status=1", "thermal_status=0"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "thermal=2", "thermal=4"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "preclamp=10000", "preclamp=0"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "legacy=9000", "legacy=10001"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "strict=8192", "strict=8191"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "overflow=808", "overflow=807"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "descriptor_rows=9000", "descriptor_rows=8999"));
  AssertRejectedPrefix(
      ReplaceOnce(prefix, "backlog_status=2", "backlog_status=1"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "backlog=0", "backlog=1"));

  AssertRejectedPrefix(ReplaceOnce(
      prefix, "|preclamp=10000|legacy=9000",
      "|legacy=9000|preclamp=10000"));
  AssertRejectedPrefix(ReplaceOnce(prefix, "|backlog=0\n",
                                   "|backlog=0|unknown=1\n"));

  const std::string duplicate_id_prefix = Header() + Row(1, 7) + Row(2, 7);
  AssertRejected(Sealed(duplicate_id_prefix, 2, 2));
  const std::string duplicate_ordinal_prefix =
      Header() + Row(1, 7) + Row(1, 8);
  AssertRejected(Sealed(duplicate_ordinal_prefix, 2, 1));
  const std::string descending_prefix = Header() + Row(2, 7) + Row(1, 8);
  AssertRejected(Sealed(descending_prefix, 2, 1));

  AssertRejected(prefix);
  AssertRejected(Sealed(prefix, 2, 1));
  AssertRejected(Sealed(prefix, 1, 2));
  AssertRejected(ReplaceOnce(Sealed(prefix, 1, 1), Sha256Hex(Bytes(prefix)),
                             std::string(64, '0')));
  AssertRejected(Sealed(prefix, 1, 1) + "extra\n");
  std::string no_final_lf = Sealed(prefix, 1, 1);
  no_final_lf.pop_back();
  AssertRejected(no_final_lf);

  const std::string first_row = Header() + Row(1, 7);
  const std::string second = Row(2, 8);
  const std::string partial = first_row + second.substr(0, second.size() / 2);
  assert(ParseStageBJournal(Bytes(partial), kRun,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  assert(parsed.complete_prefix_rows == 1 && parsed.rows.size() == 1);
  const std::string partial_seal =
      first_row + "seal|rows=1|last_ordinal=1|journal_sha";
  assert(ParseStageBJournal(Bytes(partial_seal), kRun,
                            EmbeddedStageBSourceClosure(), &parsed) ==
         StageBArtifactStatus::kIncomplete);
  assert(parsed.complete_prefix_rows == 1);

  std::puts("PASS Stage-B parser rejects noncanonical, corrupt, duplicate, "
            "drifted, invariant-violating, and unsealed artifacts");
}
