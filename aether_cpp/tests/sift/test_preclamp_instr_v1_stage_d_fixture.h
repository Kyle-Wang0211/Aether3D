#pragma once

#include "../../official_pipeline/src/official_preclamp_instr_v1.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

namespace preclamp_stage_d_test {

using aether_preclamp_instr_v1::ArtifactBlockPlan;
using aether_preclamp_instr_v1::ArtifactIdentity;
using aether_preclamp_instr_v1::ArtifactPlan;
using aether_preclamp_instr_v1::BlockPayload;

struct TempRoot {
  std::string path;

  explicit TempRoot(const char* label) {
    std::string pattern = std::string("/private/tmp/preclamp-") + label +
                          ".XXXXXX";
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char* made = mkdtemp(writable.data());
    assert(made != nullptr);
    path = made;
  }

  TempRoot(const TempRoot&) = delete;
  TempRoot& operator=(const TempRoot&) = delete;

  ~TempRoot() {
    assert(path.rfind("/private/tmp/preclamp-", 0) == 0);
    std::error_code error;
    std::filesystem::remove_all(path, error);
  }
};

inline std::vector<BlockPayload> MakePayloads(size_t count) {
  std::vector<BlockPayload> payloads;
  for (size_t i = 0; i < count; ++i) {
    std::vector<uint8_t> bytes(17 + i * 13);
    for (size_t j = 0; j < bytes.size(); ++j) {
      bytes[j] = static_cast<uint8_t>((31 * i + 7 * j + 11) & 0xffu);
    }
    payloads.push_back(
        {static_cast<uint32_t>(100 + i), std::move(bytes)});
  }
  return payloads;
}

inline ArtifactPlan MakePlan(const std::vector<BlockPayload>& payloads) {
  ArtifactPlan plan;
  plan.identity = {1,
                   "run-r10-r15",
                   std::string(64, 'a'),
                   std::string(64, 'b'),
                   std::string(64, 'c')};
  for (size_t i = 0; i < payloads.size(); ++i) {
    const BlockPayload& payload = payloads[i];
    char filename[32];
    std::snprintf(filename, sizeof(filename), "block_%03zu.bin", i);
    plan.blocks.push_back(
        {payload.block_id, filename,
         static_cast<uint64_t>(payload.bytes.size()),
         aether_preclamp_instr_v1::Sha256Hex(payload.bytes)});
  }
  return plan;
}

inline std::string ReadText(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  assert(input.good());
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

inline std::vector<uint8_t> ReadBytes(const std::string& path) {
  const std::string text = ReadText(path);
  return std::vector<uint8_t>(text.begin(), text.end());
}

inline void WriteText(const std::string& path, const std::string& text) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  assert(output.good());
  output.write(text.data(), static_cast<std::streamsize>(text.size()));
  assert(output.good());
}

inline void ReplaceOnce(std::string* text, const std::string& from,
                        const std::string& to) {
  const size_t at = text->find(from);
  assert(at != std::string::npos);
  text->replace(at, from.size(), to);
}

struct FileSnapshot {
  ino_t inode = 0;
  timespec modified{};
  std::vector<uint8_t> bytes;
};

inline FileSnapshot Snapshot(const std::string& path) {
  struct stat info {};
  assert(stat(path.c_str(), &info) == 0);
  FileSnapshot snapshot;
  snapshot.inode = info.st_ino;
#if defined(__APPLE__)
  snapshot.modified = info.st_mtimespec;
#else
  snapshot.modified = info.st_mtim;
#endif
  snapshot.bytes = ReadBytes(path);
  return snapshot;
}

inline bool SameSnapshot(const FileSnapshot& lhs, const FileSnapshot& rhs) {
  return lhs.inode == rhs.inode &&
         lhs.modified.tv_sec == rhs.modified.tv_sec &&
         lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
         lhs.bytes == rhs.bytes;
}

inline std::string Child(const std::string& root, const std::string& name) {
  return root + "/" + name;
}

}  // namespace preclamp_stage_d_test

