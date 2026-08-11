#if !defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL) && \
    !defined(AETHER_PRECLAMP_INSTR_ENV_SELFTEST)
#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL)
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#elif defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#endif
#endif
#include "official_preclamp_instr_v1.h"

#include "aether/crypto/sha256.h"

#if !defined(AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1)
#define AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1 ""
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
#include <unordered_set>
#include <utility>

#include <dirent.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace aether_preclamp_instr_v1 {

void ResetStageBLocked(SessionRecords* records) noexcept;
void AppendStageBAcceptedLocked(SessionRecords* records,
                                const FrameCounts& row) noexcept;

namespace {

enum class PendingPhase : uint32_t {
  kEmpty = 0,
  kClampBegun = 1,
  kClampUpdated = 2,
  kGpuSealed = 3,
};

struct ThreadState {
  FrameCounts pending{};
  PendingPhase phase = PendingPhase::kEmpty;
};

// Implementation-owned TLS: there is no inline/header state and no public ABI.
ThreadState& State() {
  static thread_local ThreadState state;
  return state;
}

void ClearPending(ThreadState* state) {
  state->pending = FrameCounts{};
  state->phase = PendingPhase::kEmpty;
}

uint32_t StrictShadow(uint32_t preclamp_count) {
  return std::min(preclamp_count, 8192u);
}

uint32_t FloatBits(float value) {
  uint32_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

bool HasSealedPendingCandidate() {
  return State().phase == PendingPhase::kGpuSealed;
}

template <typename Metric>
void AppendMetricRole(
    ReplayFrameRole role, size_t rank,
    const std::vector<const ReplayFrame*>& frames, Metric metric,
    std::set<int64_t>* selected_ids, ReplaySelectionManifest* out) {
  std::vector<uint32_t> ranked_values;
  ranked_values.reserve(frames.size());
  for (const ReplayFrame* frame : frames) ranked_values.push_back(metric(*frame));
  std::sort(ranked_values.begin(), ranked_values.end());
  const uint32_t frozen_value = ranked_values[std::min(rank, frames.size() - 1)];

  std::vector<uint32_t> distinct_values = ranked_values;
  distinct_values.erase(
      std::unique(distinct_values.begin(), distinct_values.end()),
      distinct_values.end());
  auto value = std::lower_bound(distinct_values.begin(), distinct_values.end(),
                                frozen_value);
  for (; value != distinct_values.end(); ++value) {
    int64_t smallest_frame_id = -1;
    for (const ReplayFrame* frame : frames) {
      if (metric(*frame) != *value) continue;
      if (smallest_frame_id < 0 || frame->frame_id < smallest_frame_id) {
        smallest_frame_id = frame->frame_id;
      }
    }
    if (selected_ids->insert(smallest_frame_id).second) {
      out->selected.push_back({role, smallest_frame_id});
      return;
    }
  }
  out->omissions.push_back(
      {role, ReplayOmissionReason::kNoHigherDistinctMetric});
}

}  // namespace

const char* EnvKey() {
#if defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL)
  return "OFFICIAL_AETHER_PRECLAMP_INSTR_V1";
#else
  return "AETHER_PRECLAMP_INSTR_V1";
#endif
}

bool Enabled() {
  static const bool enabled = [] {
    const char* value = std::getenv(EnvKey());
    return value != nullptr && value[0] == '1' && value[1] == '\0';
  }();
  return enabled;
}

bool ShouldCreateCandidateGpuBuffer(uint32_t candidate_count) {
  return candidate_count != 0;
}

PhaseBHeadroomStatus AnalyzePhaseBHeadroom(
    const std::vector<FrameCounts>& rows, PhaseBHeadroomReport* out) {
  if (out == nullptr || rows.empty()) return PhaseBHeadroomStatus::kInvalidInput;
  *out = PhaseBHeadroomReport{};

  std::unordered_set<uint32_t> ordinals;
  std::unordered_set<int64_t> frame_ids;
  auto add_checked = [](uint64_t value, uint64_t* total) {
    if (total == nullptr ||
        value > std::numeric_limits<uint64_t>::max() - *total) {
      return false;
    }
    *total += value;
    return true;
  };

  for (const FrameCounts& row : rows) {
    const uint32_t canonical_rows = std::min(row.preclamp_count, 8192u);
    const uint32_t coverage_rows = std::min(row.legacy_count, 8192u);
    const uint32_t expected_overflow =
        row.legacy_count > canonical_rows
            ? row.legacy_count - canonical_rows
            : 0u;
    if (row.accepted_status != AcceptedFrameStatus::kAccepted ||
        row.frame_ordinal == 0 || row.frame_id < 0 ||
        row.count_status != FieldStatus::kValid ||
        row.preclamp_count == 0 || row.legacy_count == 0 ||
        row.strict_shadow_count != canonical_rows ||
        row.strict_shadow_count > row.legacy_count ||
        row.legacy_count > row.preclamp_count ||
        row.overflow_group_size != expected_overflow ||
        row.descriptor_rows_status != FieldStatus::kValid ||
        row.descriptor_rows != row.legacy_count ||
        !ordinals.insert(row.frame_ordinal).second ||
        !frame_ids.insert(row.frame_id).second) {
      *out = PhaseBHeadroomReport{};
      return PhaseBHeadroomStatus::kInvalidInput;
    }
    if (!add_checked(row.descriptor_rows,
                     &out->legacy_descriptor_rows_total) ||
        !add_checked(coverage_rows, &out->coverage8192_rows_total) ||
        !add_checked(canonical_rows, &out->canonical8192_rows_total)) {
      *out = PhaseBHeadroomReport{};
      return PhaseBHeadroomStatus::kArithmeticOverflow;
    }
    ++out->accepted_frames;
    if (row.descriptor_rows > 8192u) ++out->frames_descriptor_gt_8192;
  }

  if (out->legacy_descriptor_rows_total == 0) {
    *out = PhaseBHeadroomReport{};
    return PhaseBHeadroomStatus::kInvalidInput;
  }
  const double legacy =
      static_cast<double>(out->legacy_descriptor_rows_total);
  out->coverage_row_headroom =
      1.0 - static_cast<double>(out->coverage8192_rows_total) / legacy;
  out->canonical_row_headroom =
      1.0 - static_cast<double>(out->canonical8192_rows_total) / legacy;
  return out->frames_descriptor_gt_8192 == 0
             ? PhaseBHeadroomStatus::kParkNoComputeHeadroom
             : PhaseBHeadroomStatus::kComputeHeadroomPresent;
}

void ClearPendingAtGpuEntry() noexcept {
  if (!Enabled()) return;
  ClearPending(&State());
}

void BeginLegacyClamp(uint32_t preclamp_count) noexcept {
  if (!Enabled()) return;
  ThreadState& state = State();
  ClearPending(&state);
  if (preclamp_count == 0) return;
  state.pending.count_status = FieldStatus::kValid;
  state.pending.preclamp_count = preclamp_count;
  state.pending.strict_shadow_count = StrictShadow(preclamp_count);
  state.phase = PendingPhase::kClampBegun;
}

void UpdateLegacyClampResult(uint32_t legacy_count) noexcept {
  if (!Enabled()) return;
  ThreadState& state = State();
  if (state.phase != PendingPhase::kClampBegun || legacy_count == 0) {
    ClearPending(&state);
    return;
  }
  state.pending.legacy_count = legacy_count;
  state.pending.overflow_group_size =
      legacy_count > state.pending.strict_shadow_count
          ? legacy_count - state.pending.strict_shadow_count
          : 0u;
  state.phase = PendingPhase::kClampUpdated;
}

void DiscardPending(PendingDiscardReason reason) noexcept {
  (void)reason;
  if (!Enabled()) return;
  ClearPending(&State());
}

bool SealAcceptedLegacyGpuResult(uint32_t descriptor_rows,
                                 FieldStatus gpu_ms_status,
                                 float gpu_ms) noexcept {
  if (!Enabled()) return false;
  ThreadState& state = State();
  const bool valid_gpu_measurement =
      (gpu_ms_status == FieldStatus::kValid && std::isfinite(gpu_ms) &&
       gpu_ms > 0.0f) ||
      (gpu_ms_status == FieldStatus::kUnavailable &&
       FloatBits(gpu_ms) == 0u);
  if (state.phase != PendingPhase::kClampUpdated || descriptor_rows == 0 ||
      descriptor_rows != state.pending.legacy_count ||
      !valid_gpu_measurement) {
    ClearPending(&state);
    return false;
  }
  state.pending.descriptor_rows_status = FieldStatus::kValid;
  state.pending.descriptor_rows = descriptor_rows;
  state.pending.gpu_ms_status = gpu_ms_status;
  state.pending.gpu_ms = gpu_ms;
  state.phase = PendingPhase::kGpuSealed;
  return true;
}

bool FinalizeAcceptedFrame(int64_t frame_id, uint32_t frame_ordinal,
                           FieldStatus thermal_state_status,
                           int32_t thermal_state,
                           FrameCounts* out) noexcept {
  if (!Enabled()) return false;
  ThreadState& state = State();
  if (out == nullptr) {
    ClearPending(&state);
    return false;
  }
  const bool valid_thermal =
      (thermal_state_status == FieldStatus::kValid && thermal_state >= 0 &&
       thermal_state <= 3) ||
      (thermal_state_status == FieldStatus::kUnavailable &&
       thermal_state == -1);
  if (state.phase != PendingPhase::kGpuSealed || frame_id < 0 ||
      frame_ordinal == 0 || !valid_thermal) {
    ClearPending(&state);
    return false;
  }
  state.pending.frame_id = frame_id;
  state.pending.frame_ordinal = frame_ordinal;
  state.pending.accepted_status = AcceptedFrameStatus::kAccepted;
  state.pending.thermal_state_status = thermal_state_status;
  state.pending.thermal_state = thermal_state;
  state.pending.queue_backlog_status = FieldStatus::kPendingExternalJoin;
  state.pending.queue_backlog = 0;
  *out = state.pending;
  ClearPending(&state);
  return true;
}

void ResetSessionRecords(SessionRecords* records) noexcept {
  if (records == nullptr) return;
  std::lock_guard<std::mutex> lock(records->mutex);
  ResetStageBLocked(records);
  records->accepted_rows.clear();
}

bool AppendSessionRecord(SessionRecords* records,
                         const FrameCounts& row) noexcept {
  if (!Enabled() || records == nullptr ||
      row.schema_version != 2 ||
      row.accepted_status != AcceptedFrameStatus::kAccepted ||
      row.frame_id < 0 || row.frame_ordinal == 0 ||
      row.count_status != FieldStatus::kValid ||
      row.descriptor_rows_status != FieldStatus::kValid ||
      row.descriptor_rows != row.legacy_count) {
    return false;
  }
  std::lock_guard<std::mutex> lock(records->mutex);
  for (const FrameCounts& accepted : records->accepted_rows) {
    if (accepted.frame_id == row.frame_id ||
        accepted.frame_ordinal == row.frame_ordinal) {
      return false;
    }
  }
  try {
    records->accepted_rows.push_back(row);
  } catch (...) {
    return false;
  }
  AppendStageBAcceptedLocked(records, row);
  return true;
}

bool CopySessionRecords(const SessionRecords* records,
                        std::vector<FrameCounts>* out) {
  if (!Enabled() || records == nullptr || out == nullptr) return false;
  std::lock_guard<std::mutex> lock(records->mutex);
  *out = records->accepted_rows;
  return true;
}

bool DrainSessionRecords(SessionRecords* records,
                         std::vector<FrameCounts>* out) noexcept {
  if (!Enabled() || records == nullptr || out == nullptr) return false;
  std::lock_guard<std::mutex> lock(records->mutex);
  std::vector<FrameCounts> drained;
  drained.swap(records->accepted_rows);
  out->swap(drained);
  return true;
}

FixtureStatus SelectReplayFrames(
    const std::vector<int64_t>& ordered_accepted_frame_ids,
    const std::vector<ReplayFrame>& frames,
    ReplaySelectionManifest* out) {
  if (out == nullptr) return FixtureStatus::kInvalidInput;
  *out = ReplaySelectionManifest{};
  if (ordered_accepted_frame_ids.empty() ||
      ordered_accepted_frame_ids.size() != frames.size()) {
    return FixtureStatus::kInvalidInput;
  }

  std::map<int64_t, const ReplayFrame*> by_id;
  for (const ReplayFrame& frame : frames) {
    if (frame.frame_id < 0 || !by_id.emplace(frame.frame_id, &frame).second) {
      return FixtureStatus::kInvalidInput;
    }
  }
  std::set<int64_t> ordered_unique;
  std::vector<const ReplayFrame*> accepted;
  accepted.reserve(ordered_accepted_frame_ids.size());
  for (int64_t frame_id : ordered_accepted_frame_ids) {
    const auto found = by_id.find(frame_id);
    if (found == by_id.end() || !ordered_unique.insert(frame_id).second) {
      return FixtureStatus::kInvalidInput;
    }
    accepted.push_back(found->second);
  }

  std::set<int64_t> selected_ids;
  selected_ids.insert(ordered_accepted_frame_ids.front());
  out->selected.push_back(
      {ReplayFrameRole::kFirst, ordered_accepted_frame_ids.front()});
  const size_t n = accepted.size();
  AppendMetricRole(
      ReplayFrameRole::kPreclampMedian, (n - 1) / 2, accepted,
      [](const ReplayFrame& frame) { return frame.preclamp_count; },
      &selected_ids, out);
  AppendMetricRole(
      ReplayFrameRole::kOverflowP90, (9 * (n - 1)) / 10, accepted,
      [](const ReplayFrame& frame) { return frame.overflow_group_size; },
      &selected_ids, out);
  AppendMetricRole(
      ReplayFrameRole::kOverflowMaximum, n - 1, accepted,
      [](const ReplayFrame& frame) { return frame.overflow_group_size; },
      &selected_ids, out);

  const size_t final_third = (2 * n) / 3;
  for (size_t index = final_third; index < n; ++index) {
    const int64_t frame_id = ordered_accepted_frame_ids[index];
    if (selected_ids.insert(frame_id).second) {
      out->selected.push_back({ReplayFrameRole::kFinalThird, frame_id});
      return FixtureStatus::kOk;
    }
  }
  out->omissions.push_back(
      {ReplayFrameRole::kFinalThird,
       ReplayOmissionReason::kNoLaterAcceptedFrame});
  return FixtureStatus::kOk;
}

FixtureStatus ValidateLegacyReplayIdentity(
    const LegacyReplayIdentity& stored,
    const LegacyReplayIdentity& replayed) {
  return stored.keypoints == replayed.keypoints &&
                 stored.descriptors == replayed.descriptors
             ? FixtureStatus::kOk
             : FixtureStatus::kLegacyIdentityMismatch;
}

bool ShouldCollapseFixed12288(const std::vector<uint32_t>& legacy_counts) {
  return !legacy_counts.empty() &&
         std::all_of(legacy_counts.begin(), legacy_counts.end(),
                     [](uint32_t count) { return count <= 12288u; });
}

FixtureStatus BuildDescriptorUnion(
    const DescriptorArmSelections& arms,
    const std::vector<CandidateDescriptor>& available,
    DescriptorUnionManifest* out) {
  if (out == nullptr) return FixtureStatus::kInvalidInput;
  *out = DescriptorUnionManifest{};

  std::map<SourceCandidateId, std::vector<uint8_t>> available_by_id;
  for (const CandidateDescriptor& descriptor : available) {
    if (descriptor.bytes.empty()) continue;
    const auto inserted = available_by_id.emplace(
        descriptor.source_candidate_id, descriptor.bytes);
    if (!inserted.second && inserted.first->second != descriptor.bytes) {
      return FixtureStatus::kConflictingDescriptor;
    }
  }

  std::map<SourceCandidateId, uint32_t> union_index;
  const auto append_arm = [&](const std::vector<SourceCandidateId>& selected,
                              std::vector<uint32_t>* mapping) {
    for (SourceCandidateId candidate_id : selected) {
      const auto descriptor = available_by_id.find(candidate_id);
      if (descriptor == available_by_id.end()) return false;
      auto index = union_index.find(candidate_id);
      if (index == union_index.end()) {
        const uint32_t next = static_cast<uint32_t>(out->descriptors.size());
        out->descriptors.push_back({candidate_id, descriptor->second});
        index = union_index.emplace(candidate_id, next).first;
      }
      mapping->push_back(index->second);
    }
    return true;
  };

  if (!append_arm(arms.legacy, &out->legacy_indices) ||
      !append_arm(arms.canonical8192, &out->canonical8192_indices) ||
      (arms.retain_canonical12288 &&
       !append_arm(arms.canonical12288, &out->canonical12288_indices))) {
    *out = DescriptorUnionManifest{};
    return FixtureStatus::kMissingDescriptor;
  }
  return FixtureStatus::kOk;
}

namespace {

constexpr size_t kMaximumManifestBytes = 16u * 1024u * 1024u;

struct ParsedManifest {
  ArtifactPlan plan;
  std::vector<bool> complete;
};

std::string ChildPath(const std::string& root, const std::string& filename) {
  return root + "/" + filename;
}

bool IsLowerHexDigest(const std::string& value) {
  if (value.size() != 64) return false;
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

bool IsSafeToken(const std::string& value) {
  if (value.empty() || value == "." || value == "..") return false;
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
  });
}

bool IsSafeBasename(const std::string& value) {
  return IsSafeToken(value) && value.find('/') == std::string::npos &&
         value.find(".tmp.") == std::string::npos &&
         value != kStageDManifestFilename &&
         value != kStageDPromotionFilename;
}

ArtifactStatus ValidateRootDirectory(const std::string& root) {
  if (root.size() < 2 || root.front() != '/' || root.back() == '/') {
    return ArtifactStatus::kPathViolation;
  }
  std::string current;
  size_t start = 1;
  size_t component_count = 0;
  while (start <= root.size()) {
    const size_t slash = root.find('/', start);
    const size_t end = slash == std::string::npos ? root.size() : slash;
    const std::string component = root.substr(start, end - start);
    if (component.empty() || component == "." || component == "..") {
      return ArtifactStatus::kPathViolation;
    }
    current += "/" + component;
    struct stat info {};
    if (::lstat(current.c_str(), &info) != 0) {
      return ArtifactStatus::kPathViolation;
    }
    if (S_ISLNK(info.st_mode)) return ArtifactStatus::kSymlinkRejected;
    if (!S_ISDIR(info.st_mode)) return ArtifactStatus::kPathViolation;
    ++component_count;
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  // Refuse broad roots such as / or /private/tmp. A run-owned leaf is required.
  return component_count >= 3 ? ArtifactStatus::kOk
                              : ArtifactStatus::kPathViolation;
}

ArtifactStatus ValidatePlan(const ArtifactPlan& plan) {
  if (plan.identity.schema_version != kStageDArtifactSchemaVersion) {
    return ArtifactStatus::kManifestVersionMismatch;
  }
  if (!IsSafeToken(plan.identity.run_id) ||
      !IsLowerHexDigest(plan.identity.input_sha256) ||
      !IsLowerHexDigest(plan.identity.config_sha256) ||
      !IsLowerHexDigest(plan.identity.source_sha256) || plan.blocks.empty() ||
      plan.blocks.size() > std::numeric_limits<uint32_t>::max()) {
    return ArtifactStatus::kInvalidArgument;
  }
  std::set<uint32_t> block_ids;
  std::set<std::string> filenames;
  for (const ArtifactBlockPlan& block : plan.blocks) {
    if (!block_ids.insert(block.block_id).second) {
      return ArtifactStatus::kDuplicateBlockId;
    }
    if (!IsSafeBasename(block.filename)) {
      return ArtifactStatus::kPathViolation;
    }
    if (!filenames.insert(block.filename).second) {
      return ArtifactStatus::kDuplicateBlockFilename;
    }
    if (block.expected_size == 0 ||
        !IsLowerHexDigest(block.expected_sha256)) {
      return ArtifactStatus::kInvalidArgument;
    }
  }
  return ArtifactStatus::kOk;
}

template <typename Integer>
bool ParseInteger(const std::string& text, Integer* out) {
  if (out == nullptr || text.empty() || text.front() == '+' ||
      text.front() == '-') {
    return false;
  }
  Integer value = 0;
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto parsed = std::from_chars(begin, end, value);
  if (parsed.ec != std::errc() || parsed.ptr != end) return false;
  *out = value;
  return true;
}

std::vector<std::string> Split(const std::string& text, char delimiter) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (start <= text.size()) {
    const size_t end = text.find(delimiter, start);
    fields.push_back(text.substr(
        start, end == std::string::npos ? std::string::npos : end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return fields;
}

ArtifactStatus ReadSmallRegularFile(const std::string& path,
                                    ArtifactStatus missing_status,
                                    std::vector<uint8_t>* out) {
  if (out == nullptr) return ArtifactStatus::kInvalidArgument;
  out->clear();
  struct stat before {};
  if (::lstat(path.c_str(), &before) != 0) {
    return errno == ENOENT ? missing_status : ArtifactStatus::kIoFailure;
  }
  if (S_ISLNK(before.st_mode)) return ArtifactStatus::kSymlinkRejected;
  if (!S_ISREG(before.st_mode) || before.st_size < 0 ||
      static_cast<uint64_t>(before.st_size) > kMaximumManifestBytes) {
    return ArtifactStatus::kManifestMalformed;
  }
  const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    return errno == ELOOP ? ArtifactStatus::kSymlinkRejected
                          : ArtifactStatus::kIoFailure;
  }
  out->resize(static_cast<size_t>(before.st_size));
  size_t offset = 0;
  while (offset < out->size()) {
    const ssize_t count =
        ::read(fd, out->data() + offset, out->size() - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      const int saved_errno = errno;
      (void)::close(fd);
      errno = saved_errno;
      out->clear();
      return ArtifactStatus::kIoFailure;
    }
    offset += static_cast<size_t>(count);
  }
  if (::close(fd) != 0) {
    out->clear();
    return ArtifactStatus::kIoFailure;
  }
  return ArtifactStatus::kOk;
}

std::string DigestToHex(const aether::crypto::Sha256Digest& digest) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string output(64, '0');
  for (size_t index = 0; index < 32; ++index) {
    output[2 * index] = kHex[digest.bytes[index] >> 4];
    output[2 * index + 1] = kHex[digest.bytes[index] & 0x0fu];
  }
  return output;
}

std::string Sha256HexData(const uint8_t* data, size_t size) {
  aether::crypto::Sha256Digest digest{};
  aether::crypto::sha256(data, size, digest);
  return DigestToHex(digest);
}

ArtifactStatus HashRegularFile(const std::string& path, uint64_t expected_size,
                               const std::string& expected_sha256) {
  const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    if (errno == ENOENT) return ArtifactStatus::kBlockMissing;
    return errno == ELOOP ? ArtifactStatus::kSymlinkRejected
                          : ArtifactStatus::kIoFailure;
  }
  struct stat info {};
  if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
    (void)::close(fd);
    return ArtifactStatus::kUnexpectedFile;
  }
  if (static_cast<uint64_t>(info.st_size) != expected_size) {
    (void)::close(fd);
    return ArtifactStatus::kBlockSizeMismatch;
  }
  // ValidatePlan rejects zero-byte blocks; preserve that invariant here too so
  // mmap is never called with a zero length if this helper is reused.
  if (info.st_size == 0) {
    (void)::close(fd);
    return ArtifactStatus::kBlockSizeMismatch;
  }
  void* mapping = ::mmap(nullptr, static_cast<size_t>(info.st_size), PROT_READ,
                         MAP_PRIVATE, fd, 0);
  if (mapping == MAP_FAILED) {
    (void)::close(fd);
    return ArtifactStatus::kIoFailure;
  }
  const std::string actual = Sha256HexData(
      static_cast<const uint8_t*>(mapping), static_cast<size_t>(info.st_size));
  const int unmap_result = ::munmap(mapping, static_cast<size_t>(info.st_size));
  const int close_result = ::close(fd);
  if (unmap_result != 0 || close_result != 0) {
    return ArtifactStatus::kIoFailure;
  }
  return actual == expected_sha256 ? ArtifactStatus::kOk
                                   : ArtifactStatus::kBlockHashMismatch;
}

std::string SerializeManifest(const ArtifactPlan& plan,
                              const std::vector<bool>& complete) {
  std::ostringstream output;
  output << "STRICT8192_STAGE_D_MANIFEST_V1\n";
  output << "schema_version=" << plan.identity.schema_version << "\n";
  output << "run_id=" << plan.identity.run_id << "\n";
  output << "input_sha256=" << plan.identity.input_sha256 << "\n";
  output << "config_sha256=" << plan.identity.config_sha256 << "\n";
  output << "source_sha256=" << plan.identity.source_sha256 << "\n";
  output << "block_count=" << plan.blocks.size() << "\n";
  for (size_t index = 0; index < plan.blocks.size(); ++index) {
    const ArtifactBlockPlan& block = plan.blocks[index];
    output << "block=" << index << '|' << block.block_id << '|'
           << block.filename << '|' << block.expected_size << '|'
           << block.expected_sha256 << '|'
           << (complete[index] ? "complete" : "pending") << "\n";
  }
  return output.str();
}

ArtifactStatus ParseManifest(const std::vector<uint8_t>& bytes,
                             ParsedManifest* out) {
  if (out == nullptr || bytes.empty() || bytes.back() != '\n') {
    return ArtifactStatus::kManifestMalformed;
  }
  const std::string text(bytes.begin(), bytes.end());
  std::vector<std::string> lines;
  std::istringstream input(text);
  std::string line;
  while (std::getline(input, line)) lines.push_back(line);
  if (lines.size() < 7 || lines[0] != "STRICT8192_STAGE_D_MANIFEST_V1") {
    return ArtifactStatus::kManifestMalformed;
  }
  const auto value_after = [&](size_t index,
                               const char* prefix) -> std::string {
    const std::string expected(prefix);
    if (index >= lines.size() || lines[index].rfind(expected, 0) != 0) {
      return {};
    }
    return lines[index].substr(expected.size());
  };

  ParsedManifest parsed;
  if (!ParseInteger(value_after(1, "schema_version="),
                    &parsed.plan.identity.schema_version)) {
    return ArtifactStatus::kManifestMalformed;
  }
  if (parsed.plan.identity.schema_version != kStageDArtifactSchemaVersion) {
    return ArtifactStatus::kManifestVersionMismatch;
  }
  parsed.plan.identity.run_id = value_after(2, "run_id=");
  parsed.plan.identity.input_sha256 = value_after(3, "input_sha256=");
  parsed.plan.identity.config_sha256 = value_after(4, "config_sha256=");
  parsed.plan.identity.source_sha256 = value_after(5, "source_sha256=");
  uint32_t block_count = 0;
  if (!ParseInteger(value_after(6, "block_count="), &block_count) ||
      lines.size() != static_cast<size_t>(7u + block_count)) {
    return ArtifactStatus::kManifestMalformed;
  }
  parsed.complete.reserve(block_count);
  std::set<uint32_t> ids;
  std::set<std::string> filenames;
  for (uint32_t index = 0; index < block_count; ++index) {
    const std::vector<std::string> fields = Split(lines[7 + index], '|');
    if (fields.size() != 6 || fields[0].rfind("block=", 0) != 0) {
      return ArtifactStatus::kManifestMalformed;
    }
    uint32_t ordinal = 0;
    ArtifactBlockPlan block;
    if (!ParseInteger(fields[0].substr(6), &ordinal) ||
        !ParseInteger(fields[1], &block.block_id) ||
        !ParseInteger(fields[3], &block.expected_size)) {
      return ArtifactStatus::kManifestMalformed;
    }
    if (ordinal != index) return ArtifactStatus::kBlockOrderMismatch;
    block.filename = fields[2];
    block.expected_sha256 = fields[4];
    if (!ids.insert(block.block_id).second) {
      return ArtifactStatus::kDuplicateBlockId;
    }
    if (!filenames.insert(block.filename).second) {
      return ArtifactStatus::kDuplicateBlockFilename;
    }
    if (fields[5] == "complete") {
      parsed.complete.push_back(true);
    } else if (fields[5] == "pending") {
      parsed.complete.push_back(false);
    } else {
      return ArtifactStatus::kManifestMalformed;
    }
    parsed.plan.blocks.push_back(std::move(block));
  }
  const ArtifactStatus plan_status = ValidatePlan(parsed.plan);
  if (plan_status != ArtifactStatus::kOk) {
    return plan_status == ArtifactStatus::kManifestVersionMismatch
               ? plan_status
               : ArtifactStatus::kManifestMalformed;
  }
  const std::string canonical = SerializeManifest(parsed.plan, parsed.complete);
  if (canonical.size() != bytes.size() ||
      !std::equal(canonical.begin(), canonical.end(), bytes.begin())) {
    return ArtifactStatus::kManifestMalformed;
  }
  *out = std::move(parsed);
  return ArtifactStatus::kOk;
}

ArtifactStatus CompareManifestPlan(const ParsedManifest& parsed,
                                   const ArtifactPlan& expected) {
  if (parsed.plan.identity.schema_version != expected.identity.schema_version) {
    return ArtifactStatus::kManifestVersionMismatch;
  }
  if (parsed.plan.identity.run_id != expected.identity.run_id ||
      parsed.plan.identity.input_sha256 != expected.identity.input_sha256 ||
      parsed.plan.identity.config_sha256 != expected.identity.config_sha256 ||
      parsed.plan.identity.source_sha256 != expected.identity.source_sha256) {
    return ArtifactStatus::kManifestIdentityMismatch;
  }
  if (parsed.plan.blocks.size() != expected.blocks.size()) {
    return ArtifactStatus::kManifestPlanMismatch;
  }
  for (size_t index = 0; index < expected.blocks.size(); ++index) {
    const ArtifactBlockPlan& actual = parsed.plan.blocks[index];
    const ArtifactBlockPlan& wanted = expected.blocks[index];
    if (actual.block_id != wanted.block_id ||
        actual.filename != wanted.filename ||
        actual.expected_size != wanted.expected_size ||
        actual.expected_sha256 != wanted.expected_sha256) {
      return ArtifactStatus::kManifestPlanMismatch;
    }
  }
  return ArtifactStatus::kOk;
}

ArtifactStatus ListRootEntries(const std::string& root,
                               std::set<std::string>* names) {
  if (names == nullptr) return ArtifactStatus::kInvalidArgument;
  names->clear();
  DIR* directory = ::opendir(root.c_str());
  if (directory == nullptr) return ArtifactStatus::kIoFailure;
  ArtifactStatus status = ArtifactStatus::kOk;
  errno = 0;
  while (dirent* entry = ::readdir(directory)) {
    const std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    const std::string path = ChildPath(root, name);
    struct stat info {};
    if (::lstat(path.c_str(), &info) != 0) {
      status = ArtifactStatus::kIoFailure;
      break;
    }
    if (S_ISLNK(info.st_mode)) {
      status = ArtifactStatus::kSymlinkRejected;
      break;
    }
    if (name.find(".tmp.") != std::string::npos) {
      status = ArtifactStatus::kTempResidue;
      break;
    }
    if (!S_ISREG(info.st_mode)) {
      status = ArtifactStatus::kUnexpectedFile;
      break;
    }
    names->insert(name);
    errno = 0;
  }
  if (status == ArtifactStatus::kOk && errno != 0) {
    status = ArtifactStatus::kIoFailure;
  }
  if (::closedir(directory) != 0 && status == ArtifactStatus::kOk) {
    status = ArtifactStatus::kIoFailure;
  }
  return status;
}

ArtifactStatus LoadExpectedManifest(const std::string& root,
                                    const ArtifactPlan& expected,
                                    ParsedManifest* parsed,
                                    std::vector<uint8_t>* manifest_bytes) {
  const ArtifactStatus expected_status = ValidatePlan(expected);
  if (expected_status != ArtifactStatus::kOk) return expected_status;
  const ArtifactStatus root_status = ValidateRootDirectory(root);
  if (root_status != ArtifactStatus::kOk) return root_status;
  std::vector<uint8_t> bytes;
  const ArtifactStatus read_status = ReadSmallRegularFile(
      ChildPath(root, kStageDManifestFilename),
      ArtifactStatus::kManifestMissing, &bytes);
  if (read_status != ArtifactStatus::kOk) return read_status;
  ParsedManifest local;
  const ArtifactStatus parse_status = ParseManifest(bytes, &local);
  if (parse_status != ArtifactStatus::kOk) return parse_status;
  const ArtifactStatus compare_status = CompareManifestPlan(local, expected);
  if (compare_status != ArtifactStatus::kOk) return compare_status;
  if (manifest_bytes != nullptr) *manifest_bytes = bytes;
  *parsed = std::move(local);
  return ArtifactStatus::kOk;
}

ArtifactStatus AuditLoadedArtifact(const std::string& root,
                                   const ParsedManifest& parsed,
                                   bool allow_promotion_marker,
                                   ArtifactValidationReport* report) {
  std::set<std::string> names;
  const ArtifactStatus list_status = ListRootEntries(root, &names);
  if (list_status != ArtifactStatus::kOk) return list_status;
  std::set<std::string> allowed = {kStageDManifestFilename};
  if (allow_promotion_marker && names.count(kStageDPromotionFilename) != 0) {
    allowed.insert(kStageDPromotionFilename);
  }
  uint32_t completed = 0;
  for (size_t index = 0; index < parsed.plan.blocks.size(); ++index) {
    const ArtifactBlockPlan& block = parsed.plan.blocks[index];
    if (!parsed.complete[index]) continue;
    ++completed;
    allowed.insert(block.filename);
    if (names.count(block.filename) == 0) {
      return ArtifactStatus::kBlockMissing;
    }
    const ArtifactStatus hash_status = HashRegularFile(
        ChildPath(root, block.filename), block.expected_size,
        block.expected_sha256);
    if (hash_status != ArtifactStatus::kOk) return hash_status;
  }
  for (const std::string& name : names) {
    if (allowed.count(name) == 0) return ArtifactStatus::kUnexpectedFile;
  }
  if (report != nullptr) {
    report->completed_blocks = completed;
    report->total_blocks = static_cast<uint32_t>(parsed.plan.blocks.size());
  }
  return completed == parsed.plan.blocks.size() ? ArtifactStatus::kOk
                                                : ArtifactStatus::kIncomplete;
}

bool WriteAll(int fd, const uint8_t* data, size_t size) {
  size_t offset = 0;
  while (offset < size) {
    const ssize_t count = ::write(fd, data + offset, size - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    offset += static_cast<size_t>(count);
  }
  return true;
}

ArtifactStatus WriteFileTransactionalInternal(
    const std::string& root, const std::string& filename,
    const std::vector<uint8_t>& bytes, const TransactionFault& fault,
    bool allow_replace, TransactionTrace* trace) {
  if (trace != nullptr) trace->steps.clear();
  const ArtifactStatus root_status = ValidateRootDirectory(root);
  if (root_status != ArtifactStatus::kOk) return root_status;
  const bool reserved = filename == kStageDManifestFilename ||
                        filename == kStageDPromotionFilename;
  if ((!reserved && !IsSafeBasename(filename)) || bytes.empty()) {
    return filename.find('/') != std::string::npos
               ? ArtifactStatus::kPathViolation
               : ArtifactStatus::kInvalidArgument;
  }
  const std::string final_path = ChildPath(root, filename);
  struct stat existing {};
  if (::lstat(final_path.c_str(), &existing) == 0) {
    if (S_ISLNK(existing.st_mode)) return ArtifactStatus::kSymlinkRejected;
    if (!allow_replace || !S_ISREG(existing.st_mode)) {
      return ArtifactStatus::kUnexpectedFile;
    }
  } else if (errno != ENOENT) {
    return ArtifactStatus::kIoFailure;
  }

  static std::atomic<uint64_t> sequence{0};
  const std::string temp_name =
      "." + filename + ".tmp." + std::to_string(::getpid()) + "." +
      std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
  const std::string temp_path = ChildPath(root, temp_name);
  const int fd = ::open(temp_path.c_str(),
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        0600);
  if (fd < 0) return ArtifactStatus::kIoFailure;
  if (trace != nullptr) trace->steps.push_back(TransactionStep::kTempCreated);
  if (fault.point == TransactionFaultPoint::kAfterTempCreate) {
    (void)::close(fd);
    return ArtifactStatus::kFaultInjected;
  }
  if (fault.point == TransactionFaultPoint::kAfterPartialWrite) {
    const size_t partial_size = std::max<size_t>(1, bytes.size() / 2);
    const bool wrote = WriteAll(fd, bytes.data(), partial_size);
    if (trace != nullptr) trace->steps.push_back(TransactionStep::kPartialWrite);
    (void)::close(fd);
    return wrote ? ArtifactStatus::kFaultInjected : ArtifactStatus::kIoFailure;
  }
  if (!WriteAll(fd, bytes.data(), bytes.size())) {
    (void)::close(fd);
    return ArtifactStatus::kIoFailure;
  }
  if (trace != nullptr) trace->steps.push_back(TransactionStep::kFullWrite);
  if (::fsync(fd) != 0) {
    (void)::close(fd);
    return ArtifactStatus::kIoFailure;
  }
  if (trace != nullptr) trace->steps.push_back(TransactionStep::kFileFsync);
  if (fault.point == TransactionFaultPoint::kAfterFileFsync) {
    (void)::close(fd);
    return ArtifactStatus::kFaultInjected;
  }
  if (::close(fd) != 0) return ArtifactStatus::kIoFailure;
  if (trace != nullptr) trace->steps.push_back(TransactionStep::kFileClosed);
  if (fault.point == TransactionFaultPoint::kAfterFileClose) {
    return ArtifactStatus::kFaultInjected;
  }
  if (fault.point == TransactionFaultPoint::kSimulateCrossDeviceRename) {
    return ArtifactStatus::kCrossDeviceRename;
  }
  if (::rename(temp_path.c_str(), final_path.c_str()) != 0) {
    return errno == EXDEV ? ArtifactStatus::kCrossDeviceRename
                          : ArtifactStatus::kIoFailure;
  }
  if (trace != nullptr) trace->steps.push_back(TransactionStep::kAtomicRename);
  if (fault.point == TransactionFaultPoint::kAfterAtomicRename) {
    return ArtifactStatus::kFaultInjected;
  }
  const int directory_fd =
      ::open(root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (directory_fd < 0) return ArtifactStatus::kIoFailure;
  const int sync_result = ::fsync(directory_fd);
  const int close_result = ::close(directory_fd);
  if (sync_result != 0 || close_result != 0) {
    return ArtifactStatus::kIoFailure;
  }
  if (trace != nullptr) {
    trace->steps.push_back(TransactionStep::kParentDirectoryFsync);
  }
  return fault.point == TransactionFaultPoint::kAfterParentDirectoryFsync
             ? ArtifactStatus::kFaultInjected
             : ArtifactStatus::kOk;
}

std::vector<uint8_t> BytesOf(const std::string& text) {
  return std::vector<uint8_t>(text.begin(), text.end());
}

std::string SerializePromotionMarker(const ArtifactPlan& plan,
                                     const std::string& manifest_sha256) {
  std::ostringstream output;
  output << "STRICT8192_STAGE_D_PROMOTION_V1\n";
  output << "status=SUCCESS_FULL_SEQUENCE_LANE_Q_READY\n";
  output << "schema_version=" << plan.identity.schema_version << "\n";
  output << "run_id=" << plan.identity.run_id << "\n";
  output << "manifest_sha256=" << manifest_sha256 << "\n";
  return output.str();
}

ArtifactStatus ValidatePromotionMarker(const ArtifactPlan& plan,
                                       const std::vector<uint8_t>& manifest,
                                       const std::vector<uint8_t>& marker) {
  if (marker.empty() || marker.back() != '\n') {
    return ArtifactStatus::kPromotionMarkerInvalid;
  }
  const std::string marker_text(marker.begin(), marker.end());
  const std::string expected = SerializePromotionMarker(
      plan, Sha256HexData(manifest.data(), manifest.size()));
  return marker_text == expected ? ArtifactStatus::kOk
                                 : ArtifactStatus::kPromotionMarkerInvalid;
}

}  // namespace

CapacityGateResult CheckStageDCapacity(uint64_t available_bytes,
                                       uint64_t worst_case_bytes) noexcept {
  if (worst_case_bytes == 0) {
    return {ArtifactStatus::kWorstCaseUnknown, 0};
  }
  const uint64_t half_rounded_up = worst_case_bytes / 2 +
                                   (worst_case_bytes % 2);
  if (worst_case_bytes >
      std::numeric_limits<uint64_t>::max() - half_rounded_up) {
    return {ArtifactStatus::kCapacityArithmeticOverflow, 0};
  }
  const uint64_t required = worst_case_bytes + half_rounded_up;
  return {available_bytes >= required ? ArtifactStatus::kOk
                                      : ArtifactStatus::kInsufficientCapacity,
          required};
}

std::string Sha256Hex(const std::vector<uint8_t>& bytes) {
  return Sha256HexData(bytes.data(), bytes.size());
}

ArtifactStatus WriteFileTransactional(
    const std::string& root, const std::string& filename,
    const std::vector<uint8_t>& bytes, const TransactionFault& fault,
    TransactionTrace* trace) {
  return WriteFileTransactionalInternal(root, filename, bytes, fault,
                                        /*allow_replace=*/false, trace);
}

ArtifactStatus InitializeStageDArtifact(const std::string& root,
                                        const ArtifactPlan& plan,
                                        ArtifactWriteStats* stats) {
  if (stats == nullptr) return ArtifactStatus::kInvalidArgument;
  *stats = ArtifactWriteStats{};
  const ArtifactStatus plan_status = ValidatePlan(plan);
  if (plan_status != ArtifactStatus::kOk) return plan_status;
  const ArtifactStatus root_status = ValidateRootDirectory(root);
  if (root_status != ArtifactStatus::kOk) return root_status;
  std::set<std::string> names;
  const ArtifactStatus list_status = ListRootEntries(root, &names);
  if (list_status != ArtifactStatus::kOk) return list_status;
  if (names.empty()) {
    const std::vector<bool> complete(plan.blocks.size(), false);
    const TransactionFault none{};
    const ArtifactStatus write_status = WriteFileTransactionalInternal(
        root, kStageDManifestFilename,
        BytesOf(SerializeManifest(plan, complete)), none,
        /*allow_replace=*/false, &stats->last_transaction);
    if (write_status == ArtifactStatus::kOk) ++stats->manifest_writes;
    return write_status;
  }
  if (names.count(kStageDManifestFilename) == 0) {
    return ArtifactStatus::kUnexpectedFile;
  }
  ParsedManifest parsed;
  const ArtifactStatus load_status =
      LoadExpectedManifest(root, plan, &parsed, nullptr);
  if (load_status != ArtifactStatus::kOk) return load_status;
  ArtifactValidationReport report;
  const ArtifactStatus audit_status =
      AuditLoadedArtifact(root, parsed, /*allow_promotion_marker=*/true,
                          &report);
  return audit_status == ArtifactStatus::kIncomplete ? ArtifactStatus::kOk
                                                      : audit_status;
}

ArtifactStatus WriteStageDBatch(const std::string& root,
                                const ArtifactPlan& plan,
                                const std::vector<BlockPayload>& payloads,
                                const TransactionFault& fault,
                                ArtifactWriteStats* stats) {
  if (stats == nullptr) return ArtifactStatus::kInvalidArgument;
  *stats = ArtifactWriteStats{};
  const ArtifactStatus plan_status = ValidatePlan(plan);
  if (plan_status != ArtifactStatus::kOk) return plan_status;
  if (payloads.size() != plan.blocks.size()) {
    return ArtifactStatus::kPayloadMismatch;
  }
  std::set<uint32_t> payload_ids;
  for (size_t index = 0; index < payloads.size(); ++index) {
    if (!payload_ids.insert(payloads[index].block_id).second) {
      return ArtifactStatus::kDuplicateBlockId;
    }
    if (payloads[index].block_id != plan.blocks[index].block_id ||
        payloads[index].bytes.size() != plan.blocks[index].expected_size ||
        Sha256Hex(payloads[index].bytes) !=
            plan.blocks[index].expected_sha256) {
      return ArtifactStatus::kPayloadMismatch;
    }
  }
  ParsedManifest parsed;
  const ArtifactStatus load_status =
      LoadExpectedManifest(root, plan, &parsed, nullptr);
  if (load_status != ArtifactStatus::kOk) return load_status;
  ArtifactValidationReport report;
  const ArtifactStatus audit_status =
      AuditLoadedArtifact(root, parsed, /*allow_promotion_marker=*/false,
                          &report);
  if (audit_status != ArtifactStatus::kOk &&
      audit_status != ArtifactStatus::kIncomplete) {
    return audit_status;
  }

  for (size_t index = 0; index < plan.blocks.size(); ++index) {
    if (parsed.complete[index]) {
      ++stats->skipped_verified_blocks;
      continue;
    }
    const ArtifactBlockPlan& block = plan.blocks[index];
    TransactionFault block_fault{};
    if (fault.point != TransactionFaultPoint::kAfterManifestCommit &&
        fault.point != TransactionFaultPoint::kNone &&
        fault.trigger_block_id == block.block_id) {
      block_fault = fault;
    }
    const ArtifactStatus block_status = WriteFileTransactionalInternal(
        root, block.filename, payloads[index].bytes, block_fault,
        /*allow_replace=*/false, &stats->last_transaction);
    if (block_status != ArtifactStatus::kOk) return block_status;
    ++stats->block_file_writes;

    parsed.complete[index] = true;
    const TransactionFault none{};
    const ArtifactStatus manifest_status = WriteFileTransactionalInternal(
        root, kStageDManifestFilename,
        BytesOf(SerializeManifest(plan, parsed.complete)), none,
        /*allow_replace=*/true, &stats->last_transaction);
    if (manifest_status != ArtifactStatus::kOk) return manifest_status;
    ++stats->manifest_writes;
    if (fault.point == TransactionFaultPoint::kAfterManifestCommit &&
        fault.trigger_block_id == block.block_id) {
      return ArtifactStatus::kFaultInjected;
    }
  }
  return ArtifactStatus::kOk;
}

ArtifactStatus ValidateStageDArtifact(const std::string& root,
                                      const ArtifactPlan& plan,
                                      ArtifactValidationReport* report) {
  if (report == nullptr) return ArtifactStatus::kInvalidArgument;
  *report = ArtifactValidationReport{};
  ParsedManifest parsed;
  const ArtifactStatus load_status =
      LoadExpectedManifest(root, plan, &parsed, nullptr);
  if (load_status != ArtifactStatus::kOk) {
    report->status = load_status;
    return load_status;
  }
  const ArtifactStatus status =
      AuditLoadedArtifact(root, parsed, /*allow_promotion_marker=*/true,
                          report);
  report->status = status;
  return status;
}

ArtifactStatus PromoteStageDArtifact(const std::string& root,
                                     const ArtifactPlan& plan,
                                     const TransactionFault& fault,
                                     ArtifactWriteStats* stats) {
  if (stats == nullptr) return ArtifactStatus::kInvalidArgument;
  *stats = ArtifactWriteStats{};
  ArtifactValidationReport report;
  const ArtifactStatus artifact_status =
      ValidateStageDArtifact(root, plan, &report);
  if (artifact_status == ArtifactStatus::kIncomplete) {
    return ArtifactStatus::kPromotionNotReady;
  }
  if (artifact_status != ArtifactStatus::kOk) return artifact_status;

  const std::string marker_path = ChildPath(root, kStageDPromotionFilename);
  struct stat marker_info {};
  if (::lstat(marker_path.c_str(), &marker_info) == 0) {
    return ValidateStageDPromotion(root, plan, &report);
  }
  if (errno != ENOENT) return ArtifactStatus::kIoFailure;

  ParsedManifest parsed;
  std::vector<uint8_t> manifest;
  const ArtifactStatus load_status =
      LoadExpectedManifest(root, plan, &parsed, &manifest);
  if (load_status != ArtifactStatus::kOk) return load_status;
  const std::string marker = SerializePromotionMarker(
      plan, Sha256HexData(manifest.data(), manifest.size()));
  const ArtifactStatus write_status = WriteFileTransactionalInternal(
      root, kStageDPromotionFilename, BytesOf(marker), fault,
      /*allow_replace=*/false, &stats->last_transaction);
  if (write_status != ArtifactStatus::kOk) return write_status;
  return ValidateStageDPromotion(root, plan, &report);
}

ArtifactStatus ValidateStageDPromotion(const std::string& root,
                                       const ArtifactPlan& plan,
                                       ArtifactValidationReport* report) {
  if (report == nullptr) return ArtifactStatus::kInvalidArgument;
  *report = ArtifactValidationReport{};
  ParsedManifest parsed;
  std::vector<uint8_t> manifest;
  const ArtifactStatus load_status =
      LoadExpectedManifest(root, plan, &parsed, &manifest);
  if (load_status != ArtifactStatus::kOk) {
    report->status = load_status;
    return load_status;
  }
  const ArtifactStatus audit_status =
      AuditLoadedArtifact(root, parsed, /*allow_promotion_marker=*/true,
                          report);
  if (audit_status == ArtifactStatus::kIncomplete) {
    report->status = ArtifactStatus::kPromotionNotReady;
    return report->status;
  }
  if (audit_status != ArtifactStatus::kOk) {
    report->status = audit_status;
    return audit_status;
  }
  std::vector<uint8_t> marker;
  const ArtifactStatus marker_read = ReadSmallRegularFile(
      ChildPath(root, kStageDPromotionFilename),
      ArtifactStatus::kPromotionNotReady, &marker);
  if (marker_read != ArtifactStatus::kOk) {
    report->status = marker_read;
    return marker_read;
  }
  const ArtifactStatus marker_status =
      ValidatePromotionMarker(plan, manifest, marker);
  if (marker_status != ArtifactStatus::kOk) {
    report->status = marker_status;
    return marker_status;
  }
  report->status = ArtifactStatus::kSuccessFullSequenceLaneQReady;
  return report->status;
}

struct StageBJournalState {
  StageBJournalStatus status = StageBJournalStatus::kOff;
  StageBFailureReason first_failure = StageBFailureReason::kNone;
  uint32_t row_attempts = 0;
  uint32_t writer_calls = 0;
  uint32_t rows_written = 0;
  uint32_t last_ordinal = 0;
  uint32_t seal_attempts = 0;
  bool post_seal_close_warning = false;
  int diagnostics_fd = -1;
  int run_fd = -1;
  dev_t journal_device = 0;
  ino_t journal_inode = 0;
  bool journal_identity_pinned = false;
  std::string run_id;
  std::string source_sha256;
  std::string journal_prefix;
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  StageBTestFault fault = StageBTestFault::kNone;
  bool transient_fault_consumed = false;
#endif

  ~StageBJournalState() {
    if (run_fd >= 0) (void)::close(run_fd);
    if (diagnostics_fd >= 0) (void)::close(diagnostics_fd);
  }
};

SessionRecords::SessionRecords() = default;
SessionRecords::~SessionRecords() { ResetStageBLocked(this); }

namespace {

enum class StageBWritePhase { kHeader, kRow, kSeal };

const char* StageBRunKey() {
#if defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL)
  return "OFFICIAL_AETHER_PRECLAMP_RUN_ID_V1";
#else
  return "AETHER_PRECLAMP_RUN_ID_V1";
#endif
}

const char* StageBSourceKey() {
#if defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL)
  return "OFFICIAL_AETHER_PRECLAMP_SOURCE_SHA256_V1";
#else
  return "AETHER_PRECLAMP_SOURCE_SHA256_V1";
#endif
}

void CloseFd(int* fd) {
  if (fd != nullptr && *fd >= 0) {
    (void)::close(*fd);
    *fd = -1;
  }
}

void FailStageB(StageBJournalState* state, StageBFailureReason reason,
                StageBJournalStatus status = StageBJournalStatus::kFailed) {
  if (state == nullptr) return;
  if (state->first_failure == StageBFailureReason::kNone) {
    state->first_failure = reason;
  }
  state->status = status;
  CloseFd(&state->run_fd);
  CloseFd(&state->diagnostics_fd);
}

bool StageBRunIdValid(const std::string& value) {
  return value.size() >= 1 && value.size() <= 96 && value != "." &&
         value != ".." &&
         std::all_of(value.begin(), value.end(), [](char c) {
           return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
         });
}

bool StageBOwnedDirectory(int fd) {
  struct stat info {};
  return fd >= 0 && ::fstat(fd, &info) == 0 && S_ISDIR(info.st_mode) &&
         info.st_uid == ::geteuid();
}

int StageBOpenDirectoryAt(int parent_fd, const char* name) {
  const int fd = ::openat(parent_fd, name,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (!StageBOwnedDirectory(fd)) {
    if (fd >= 0) (void)::close(fd);
    return -1;
  }
  return fd;
}

bool StageBDirectoryEmpty(int fd) {
  const int duplicate = ::dup(fd);
  if (duplicate < 0) return false;
  DIR* directory = ::fdopendir(duplicate);
  if (directory == nullptr) {
    (void)::close(duplicate);
    return false;
  }
  bool empty = true;
  errno = 0;
  while (dirent* entry = ::readdir(directory)) {
    const std::string name(entry->d_name);
    if (name != "." && name != "..") {
      empty = false;
      break;
    }
    errno = 0;
  }
  const bool ok = errno == 0 && ::closedir(directory) == 0;
  return ok && empty;
}

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
bool StageBFaultIs(const StageBJournalState* state, StageBTestFault fault) {
  return state != nullptr && state->fault == fault;
}
#endif

bool StageBWriteAll(int fd, const uint8_t* data, size_t size,
                    StageBJournalState* state, StageBWritePhase phase) {
#if !defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  (void)state;
  (void)phase;
#endif
  size_t offset = 0;
  while (offset < size) {
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
    if (StageBFaultIs(state, StageBTestFault::kInterruptWriteOnce) &&
        !state->transient_fault_consumed) {
      state->transient_fault_consumed = true;
      errno = EINTR;
      continue;
    }
    size_t request = size - offset;
    if (StageBFaultIs(state, StageBTestFault::kShortWriteOnce) &&
        !state->transient_fault_consumed) {
      state->transient_fault_consumed = true;
      request = std::max<size_t>(1, request / 2);
    }
    const bool partial_fault =
        (phase == StageBWritePhase::kHeader &&
         StageBFaultIs(state, StageBTestFault::kHeaderPartialWrite)) ||
        (phase == StageBWritePhase::kRow &&
         StageBFaultIs(state, StageBTestFault::kRowPartialWrite)) ||
        (phase == StageBWritePhase::kSeal &&
         StageBFaultIs(state, StageBTestFault::kSealPartialWrite));
    if (partial_fault) {
      request = std::max<size_t>(1, request / 2);
      (void)::write(fd, data + offset, request);
      return false;
    }
    if (phase == StageBWritePhase::kRow &&
        StageBFaultIs(state, StageBTestFault::kRowEnospc)) {
      errno = ENOSPC;
      return false;
    }
#else
    const size_t request = size - offset;
#endif
    const ssize_t count = ::write(fd, data + offset, request);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    offset += static_cast<size_t>(count);
  }
  return true;
}

bool StageBRowValid(const FrameCounts& row) {
  const bool gpu_valid =
      (row.gpu_ms_status == FieldStatus::kValid &&
       std::isfinite(row.gpu_ms) && row.gpu_ms > 0.0f) ||
      (row.gpu_ms_status == FieldStatus::kUnavailable &&
       FloatBits(row.gpu_ms) == 0u);
  const bool thermal_valid =
      (row.thermal_state_status == FieldStatus::kValid &&
       row.thermal_state >= 0 && row.thermal_state <= 3) ||
      (row.thermal_state_status == FieldStatus::kUnavailable &&
       row.thermal_state == -1);
  return row.schema_version == 2 &&
         row.accepted_status == AcceptedFrameStatus::kAccepted &&
         row.frame_ordinal > 0 && row.frame_id >= 0 &&
         row.count_status == FieldStatus::kValid && row.preclamp_count > 0 &&
         row.legacy_count > 0 && row.descriptor_rows > 0 &&
         row.strict_shadow_count == std::min(row.preclamp_count, 8192u) &&
         row.strict_shadow_count <= row.legacy_count &&
         row.legacy_count <= row.preclamp_count &&
         row.descriptor_rows_status == FieldStatus::kValid &&
         row.descriptor_rows == row.legacy_count &&
         row.overflow_group_size ==
             (row.legacy_count > row.strict_shadow_count
                  ? row.legacy_count - row.strict_shadow_count
                  : 0u) &&
         gpu_valid && thermal_valid &&
         row.queue_backlog_status == FieldStatus::kPendingExternalJoin &&
         row.queue_backlog == 0;
}

std::string StageBSerializeRow(const FrameCounts& row) {
  uint32_t gpu_bits = 0;
  static_assert(sizeof(gpu_bits) == sizeof(row.gpu_ms));
  std::memcpy(&gpu_bits, &row.gpu_ms, sizeof(gpu_bits));
  char hex[9];
  std::snprintf(hex, sizeof(hex), "%08x", gpu_bits);
  std::ostringstream output;
  output << "frame|ordinal=" << row.frame_ordinal << "|id=" << row.frame_id
         << "|preclamp=" << row.preclamp_count << "|legacy="
         << row.legacy_count << "|strict=" << row.strict_shadow_count
         << "|overflow=" << row.overflow_group_size << "|descriptor_rows="
         << row.descriptor_rows << "|gpu_ms_status="
         << static_cast<uint32_t>(row.gpu_ms_status) << "|gpu_ms_bits=" << hex
         << "|thermal_status="
         << static_cast<uint32_t>(row.thermal_state_status) << "|thermal="
         << row.thermal_state << "|backlog_status=2|backlog=0\n";
  return output.str();
}

std::string StageBHeader(const std::string& run_id,
                         const std::string& source_sha256) {
  return "STRICT8192_STAGE_B_COUNTS_V1|schema=1|run_id=" + run_id +
         "|source_sha256=" + source_sha256 + "\n";
}

StageBFailureReason StageBPublishHeader(StageBJournalState* state) {
  static std::atomic<uint64_t> sequence{0};
  const std::string temp = ".stage_b_counts.v1.header.tmp." +
                           std::to_string(::getpid()) + "." +
                           std::to_string(sequence.fetch_add(1));
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kHeaderOpen)) {
    errno = EIO;
    return StageBFailureReason::kOpenFailed;
  }
#endif
  const int fd = ::openat(state->run_fd, temp.c_str(),
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
  if (fd < 0) return StageBFailureReason::kOpenFailed;
  const std::string header = StageBHeader(state->run_id, state->source_sha256);
  if (!StageBWriteAll(fd, reinterpret_cast<const uint8_t*>(header.data()),
                      header.size(), state, StageBWritePhase::kHeader)) {
    (void)::close(fd);
    return StageBFailureReason::kWriteFailed;
  }
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kHeaderFsync)) {
    (void)::close(fd);
    errno = EIO;
    return StageBFailureReason::kFsyncFailed;
  }
#endif
  if (::fsync(fd) != 0) {
    (void)::close(fd);
    return StageBFailureReason::kFsyncFailed;
  }
  struct stat unpublished_info {};
  if (::fstat(fd, &unpublished_info) != 0 ||
      !S_ISREG(unpublished_info.st_mode) ||
      unpublished_info.st_uid != ::geteuid()) {
    (void)::close(fd);
    return StageBFailureReason::kPathRejected;
  }
  const int close_result = ::close(fd);
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kHeaderClose)) {
    return StageBFailureReason::kCloseFailed;
  }
#endif
  if (close_result != 0) return StageBFailureReason::kCloseFailed;
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kHeaderPublish)) {
    errno = EIO;
    return StageBFailureReason::kPublishFailed;
  }
#endif
  if (::linkat(state->run_fd, temp.c_str(), state->run_fd,
               kStageBJournalFilename, 0) != 0) {
    return StageBFailureReason::kPublishFailed;
  }
  if (::unlinkat(state->run_fd, temp.c_str(), 0) != 0) {
    return StageBFailureReason::kPublishFailed;
  }
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kHeaderDirectoryFsync)) {
    errno = EIO;
    return StageBFailureReason::kFsyncFailed;
  }
#endif
  if (::fsync(state->run_fd) != 0) return StageBFailureReason::kFsyncFailed;
  const int published_fd =
      ::openat(state->run_fd, kStageBJournalFilename,
               O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  struct stat published_info {};
  struct stat live_info {};
  const bool published_identity_matches =
      published_fd >= 0 && ::fstat(published_fd, &published_info) == 0 &&
      ::fstatat(state->run_fd, kStageBJournalFilename, &live_info,
                AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISREG(published_info.st_mode) && S_ISREG(live_info.st_mode) &&
      published_info.st_uid == ::geteuid() &&
      live_info.st_uid == ::geteuid() &&
      published_info.st_dev == unpublished_info.st_dev &&
      published_info.st_ino == unpublished_info.st_ino &&
      live_info.st_dev == published_info.st_dev &&
      live_info.st_ino == published_info.st_ino;
  if (published_fd >= 0) (void)::close(published_fd);
  if (!published_identity_matches) return StageBFailureReason::kPathRejected;
  state->journal_device = unpublished_info.st_dev;
  state->journal_inode = unpublished_info.st_ino;
  state->journal_identity_pinned = true;
  state->journal_prefix = header;
  return StageBFailureReason::kNone;
}

bool StageBJournalIdentityMatches(const StageBJournalState* state, int fd) {
  if (state == nullptr || fd < 0 || !state->journal_identity_pinned) {
    return false;
  }
  struct stat opened_info {};
  struct stat live_info {};
  return ::fstat(fd, &opened_info) == 0 &&
         ::fstatat(state->run_fd, kStageBJournalFilename, &live_info,
                   AT_SYMLINK_NOFOLLOW) == 0 &&
         S_ISREG(opened_info.st_mode) && S_ISREG(live_info.st_mode) &&
         opened_info.st_uid == ::geteuid() &&
         live_info.st_uid == ::geteuid() &&
         opened_info.st_dev == state->journal_device &&
         opened_info.st_ino == state->journal_inode &&
         live_info.st_dev == opened_info.st_dev &&
         live_info.st_ino == opened_info.st_ino;
}

bool StageBEnsureInitialized(StageBJournalState* state) {
  if (state == nullptr) return false;
  if (state->status == StageBJournalStatus::kReady) return true;
  if (state->status != StageBJournalStatus::kOff) return false;
  const char* run_value = std::getenv(StageBRunKey());
  const char* source_value = std::getenv(StageBSourceKey());
  const char* home_value = std::getenv("HOME");
  if (run_value == nullptr || source_value == nullptr || home_value == nullptr) {
    FailStageB(state, StageBFailureReason::kIdentityMissing,
               StageBJournalStatus::kDisabledIdentity);
    return false;
  }
  state->run_id = run_value;
  state->source_sha256 = source_value;
  const std::string embedded = EmbeddedStageBSourceClosure();
  if (!StageBRunIdValid(state->run_id) ||
      !IsLowerHexDigest(state->source_sha256) ||
      !IsLowerHexDigest(embedded)) {
    FailStageB(state, StageBFailureReason::kIdentityInvalid,
               StageBJournalStatus::kDisabledIdentity);
    return false;
  }
  if (state->source_sha256 != embedded) {
    FailStageB(state, StageBFailureReason::kIdentityMismatch,
               StageBJournalStatus::kDisabledIdentity);
    return false;
  }
  const std::string home(home_value);
  if (home.empty() || home.front() != '/' || home.back() == '/') {
    FailStageB(state, StageBFailureReason::kHomeInvalid);
    return false;
  }
  int home_fd = ::open(home.c_str(),
                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (!StageBOwnedDirectory(home_fd)) {
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kHomeInvalid);
    return false;
  }
  int library_fd = StageBOpenDirectoryAt(home_fd, "Library");
  bool app_created = false;
  int app_fd = -1;
  if (library_fd >= 0) {
    if (::mkdirat(library_fd, "Application Support", 0700) == 0) {
      app_created = true;
    } else if (errno != EEXIST) {
      CloseFd(&library_fd);
      CloseFd(&home_fd);
      FailStageB(state, StageBFailureReason::kOpenFailed);
      return false;
    }
    if (app_created) {
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
      const bool parent_fsync_fault = StageBFaultIs(
          state, StageBTestFault::kApplicationSupportParentFsync);
#else
      constexpr bool parent_fsync_fault = false;
#endif
      if (parent_fsync_fault || ::fsync(library_fd) != 0) {
        CloseFd(&library_fd);
        CloseFd(&home_fd);
        FailStageB(state, StageBFailureReason::kFsyncFailed);
        return false;
      }
    }
    // Open and validate only after the newly created parent entry is durable.
    app_fd = StageBOpenDirectoryAt(library_fd, "Application Support");
  }
  if (library_fd < 0 || app_fd < 0) {
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kPathRejected);
    return false;
  }
  bool diagnostics_created = false;
  if (::mkdirat(app_fd, "AetherDiagnostics", 0700) == 0) {
    diagnostics_created = true;
  } else if (errno != EEXIST) {
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kOpenFailed);
    return false;
  }
  int diagnostics_fd = StageBOpenDirectoryAt(app_fd, "AetherDiagnostics");
  if (diagnostics_fd < 0 ||
      (diagnostics_created && ::fsync(app_fd) != 0)) {
    CloseFd(&diagnostics_fd);
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kPathRejected);
    return false;
  }
  if (::mkdirat(diagnostics_fd, state->run_id.c_str(), 0700) != 0) {
    const StageBFailureReason reason =
        errno == EEXIST ? StageBFailureReason::kRunCollision
                        : StageBFailureReason::kOpenFailed;
    CloseFd(&diagnostics_fd);
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, reason);
    return false;
  }
  struct stat claimed_info {};
  if (::fstatat(diagnostics_fd, state->run_id.c_str(), &claimed_info,
                AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(claimed_info.st_mode) || claimed_info.st_uid != ::geteuid()) {
    CloseFd(&diagnostics_fd);
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kPathRejected);
    return false;
  }
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kReplaceRunAfterClaim)) {
    const std::string displaced = ".displaced." + state->run_id;
    if (::renameat(diagnostics_fd, state->run_id.c_str(), diagnostics_fd,
                   displaced.c_str()) == 0) {
      (void)::mkdirat(diagnostics_fd, state->run_id.c_str(), 0700);
    }
  }
#endif
  int run_fd = StageBOpenDirectoryAt(diagnostics_fd, state->run_id.c_str());
  struct stat opened_info {};
  struct stat live_info {};
  const bool identity_matches =
      run_fd >= 0 && ::fstat(run_fd, &opened_info) == 0 &&
      ::fstatat(diagnostics_fd, state->run_id.c_str(), &live_info,
                AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISDIR(opened_info.st_mode) && S_ISDIR(live_info.st_mode) &&
      opened_info.st_uid == ::geteuid() && live_info.st_uid == ::geteuid() &&
      opened_info.st_dev == claimed_info.st_dev &&
      opened_info.st_ino == claimed_info.st_ino &&
      live_info.st_dev == opened_info.st_dev &&
      live_info.st_ino == opened_info.st_ino;
  if (!identity_matches || ::fsync(diagnostics_fd) != 0) {
    CloseFd(&run_fd);
    CloseFd(&diagnostics_fd);
    CloseFd(&app_fd);
    CloseFd(&library_fd);
    CloseFd(&home_fd);
    FailStageB(state, StageBFailureReason::kPathRejected);
    return false;
  }
  CloseFd(&app_fd);
  CloseFd(&library_fd);
  CloseFd(&home_fd);
  state->diagnostics_fd = diagnostics_fd;
  state->run_fd = run_fd;
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kUnexpectedEntryAfterClaim)) {
    const int rogue = ::openat(state->run_fd, "unexpected", O_WRONLY | O_CREAT |
                                                           O_EXCL | O_CLOEXEC,
                               0600);
    if (rogue >= 0) (void)::close(rogue);
  }
#endif
  if (!StageBDirectoryEmpty(state->run_fd)) {
    FailStageB(state, StageBFailureReason::kUnexpectedEntry);
    return false;
  }
  const StageBFailureReason publish_failure = StageBPublishHeader(state);
  if (publish_failure != StageBFailureReason::kNone) {
    FailStageB(state, publish_failure);
    return false;
  }
  state->status = StageBJournalStatus::kReady;
  return true;
}

bool StageBAppendRow(StageBJournalState* state, const FrameCounts& row) {
  if (!StageBEnsureInitialized(state)) return false;
  if (!StageBRowValid(row) ||
      (state->rows_written != 0 && row.frame_ordinal <= state->last_ordinal)) {
    FailStageB(state, StageBFailureReason::kRowInvariant);
    return false;
  }
  ++state->writer_calls;
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kRowOpen)) {
    FailStageB(state, StageBFailureReason::kOpenFailed);
    return false;
  }
#endif
  const int fd = ::openat(state->run_fd, kStageBJournalFilename,
                          O_WRONLY | O_APPEND | O_NONBLOCK | O_CLOEXEC |
                              O_NOFOLLOW);
  if (fd < 0) {
    FailStageB(state, StageBFailureReason::kOpenFailed);
    return false;
  }
  if (!StageBJournalIdentityMatches(state, fd)) {
    (void)::close(fd);
    FailStageB(state, StageBFailureReason::kPathRejected);
    return false;
  }
  const std::string line = StageBSerializeRow(row);
  if (!StageBWriteAll(fd, reinterpret_cast<const uint8_t*>(line.data()),
                      line.size(), state, StageBWritePhase::kRow)) {
    (void)::close(fd);
    FailStageB(state, StageBFailureReason::kWriteFailed);
    return false;
  }
  const int close_result = ::close(fd);
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
  if (StageBFaultIs(state, StageBTestFault::kRowClose)) {
    FailStageB(state, StageBFailureReason::kCloseFailed);
    return false;
  }
#endif
  if (close_result != 0) {
    FailStageB(state, StageBFailureReason::kCloseFailed);
    return false;
  }
  state->journal_prefix += line;
  ++state->rows_written;
  state->last_ordinal = row.frame_ordinal;
  return true;
}

template <typename Integer>
bool StageBParseUnsigned(const std::string& text, Integer* out) {
  if (text.empty() || (text.size() > 1 && text.front() == '0')) return false;
  return ParseInteger(text, out);
}

template <typename Integer>
bool StageBParseSigned(const std::string& text, Integer* out) {
  if (out == nullptr || text.empty() || text.front() == '+' || text == "-0") {
    return false;
  }
  if (text.front() != '-') return StageBParseUnsigned(text, out);
  if (text.size() < 2 || (text.size() > 2 && text[1] == '0')) return false;
  Integer value = 0;
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto parsed = std::from_chars(begin, end, value);
  if (parsed.ec != std::errc() || parsed.ptr != end) return false;
  *out = value;
  return true;
}

bool StageBParseHex32(const std::string& text, uint32_t* out) {
  if (out == nullptr || text.size() != 8 ||
      !std::all_of(text.begin(), text.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      })) {
    return false;
  }
  uint32_t value = 0;
  for (char c : text) {
    value = (value << 4) |
            static_cast<uint32_t>(c <= '9' ? c - '0' : c - 'a' + 10);
  }
  *out = value;
  return true;
}

bool StageBParseHeaderLine(const std::string& line, std::string* run_id,
                           std::string* source) {
  const std::vector<std::string> fields = Split(line, '|');
  if (fields.size() != 4 || fields[0] != "STRICT8192_STAGE_B_COUNTS_V1" ||
      fields[1] != "schema=1" || fields[2].rfind("run_id=", 0) != 0 ||
      fields[3].rfind("source_sha256=", 0) != 0) {
    return false;
  }
  *run_id = fields[2].substr(7);
  *source = fields[3].substr(14);
  return StageBRunIdValid(*run_id) && IsLowerHexDigest(*source) &&
         line + "\n" == StageBHeader(*run_id, *source);
}

bool StageBParseRowLine(const std::string& line, FrameCounts* out) {
  if (out == nullptr) return false;
  const std::vector<std::string> fields = Split(line, '|');
  static constexpr std::array<const char*, 13> prefixes = {
      "ordinal=", "id=", "preclamp=", "legacy=", "strict=", "overflow=",
      "descriptor_rows=", "gpu_ms_status=", "gpu_ms_bits=",
      "thermal_status=", "thermal=", "backlog_status=", "backlog="};
  if (fields.size() != 14 || fields[0] != "frame") return false;
  for (size_t i = 0; i < prefixes.size(); ++i) {
    if (fields[i + 1].rfind(prefixes[i], 0) != 0) return false;
  }
  const auto value = [&](size_t index) {
    return fields[index + 1].substr(std::strlen(prefixes[index]));
  };
  FrameCounts row;
  uint32_t gpu_status = 0;
  uint32_t gpu_bits = 0;
  uint32_t thermal_status = 0;
  uint32_t backlog_status = 0;
  if (!StageBParseUnsigned(value(0), &row.frame_ordinal) ||
      !StageBParseSigned(value(1), &row.frame_id) ||
      !StageBParseUnsigned(value(2), &row.preclamp_count) ||
      !StageBParseUnsigned(value(3), &row.legacy_count) ||
      !StageBParseUnsigned(value(4), &row.strict_shadow_count) ||
      !StageBParseUnsigned(value(5), &row.overflow_group_size) ||
      !StageBParseUnsigned(value(6), &row.descriptor_rows) ||
      !StageBParseUnsigned(value(7), &gpu_status) ||
      !StageBParseHex32(value(8), &gpu_bits) ||
      !StageBParseUnsigned(value(9), &thermal_status) ||
      !StageBParseSigned(value(10), &row.thermal_state) ||
      !StageBParseUnsigned(value(11), &backlog_status) ||
      !StageBParseUnsigned(value(12), &row.queue_backlog)) {
    return false;
  }
  if (gpu_status > 1 || thermal_status > 1 || backlog_status != 2) {
    return false;
  }
  row.accepted_status = AcceptedFrameStatus::kAccepted;
  row.count_status = FieldStatus::kValid;
  row.descriptor_rows_status = FieldStatus::kValid;
  row.gpu_ms_status = static_cast<FieldStatus>(gpu_status);
  std::memcpy(&row.gpu_ms, &gpu_bits, sizeof(gpu_bits));
  row.thermal_state_status = static_cast<FieldStatus>(thermal_status);
  row.queue_backlog_status = static_cast<FieldStatus>(backlog_status);
  if (!StageBRowValid(row) || line + "\n" != StageBSerializeRow(row)) {
    return false;
  }
  *out = row;
  return true;
}

bool StageBParseSealLine(const std::string& line, uint32_t* rows,
                         uint32_t* last_ordinal, std::string* digest) {
  const std::vector<std::string> fields = Split(line, '|');
  if (fields.size() != 4 || fields[0] != "seal" ||
      fields[1].rfind("rows=", 0) != 0 ||
      fields[2].rfind("last_ordinal=", 0) != 0 ||
      fields[3].rfind("journal_sha256=", 0) != 0 ||
      !StageBParseUnsigned(fields[1].substr(5), rows) ||
      !StageBParseUnsigned(fields[2].substr(13), last_ordinal)) {
    return false;
  }
  *digest = fields[3].substr(15);
  return IsLowerHexDigest(*digest);
}

bool StageBPrintableAscii(const std::vector<uint8_t>& bytes) {
  return std::all_of(bytes.begin(), bytes.end(), [](uint8_t c) {
    return c == '\n' || (c >= 0x20 && c <= 0x7e);
  });
}

class StageBJsonCursor {
 public:
  explicit StageBJsonCursor(const std::string& text) : text_(text) {}

  bool ParseObject(std::map<std::string, std::string>* fields) {
    if (fields == nullptr || !Consume('{')) return false;
    fields->clear();
    if (Consume('}')) return AtEnd();
    while (true) {
      const size_t key_start = position_;
      if (!SkipString()) return false;
      const std::string key = text_.substr(key_start, position_ - key_start);
      if (!fields->emplace(key, std::string()).second || !Consume(':')) {
        return false;
      }
      const size_t value_start = position_;
      if (!SkipValue(/*depth=*/0)) return false;
      (*fields)[key] = text_.substr(value_start, position_ - value_start);
      if (Consume('}')) return AtEnd();
      if (!Consume(',')) return false;
    }
  }

 private:
  bool AtEnd() const { return position_ == text_.size(); }

  bool Consume(char expected) {
    if (position_ >= text_.size() || text_[position_] != expected) {
      return false;
    }
    ++position_;
    return true;
  }

  bool SkipString() {
    if (!Consume('"')) return false;
    while (position_ < text_.size()) {
      const unsigned char c = static_cast<unsigned char>(text_[position_++]);
      if (c == '"') return true;
      if (c < 0x20) return false;
      if (c != '\\') continue;
      if (position_ >= text_.size()) return false;
      const char escaped = text_[position_++];
      if (escaped == '"' || escaped == '\\' || escaped == '/' ||
          escaped == 'b' || escaped == 'f' || escaped == 'n' ||
          escaped == 'r' || escaped == 't') {
        continue;
      }
      if (escaped != 'u' || position_ + 4 > text_.size()) return false;
      for (size_t i = 0; i < 4; ++i) {
        const char digit = text_[position_++];
        if (!((digit >= '0' && digit <= '9') ||
              (digit >= 'a' && digit <= 'f') ||
              (digit >= 'A' && digit <= 'F'))) {
          return false;
        }
      }
    }
    return false;
  }

  bool SkipNumber() {
    const size_t start = position_;
    if (position_ < text_.size() && text_[position_] == '-') ++position_;
    if (position_ >= text_.size()) return false;
    if (text_[position_] == '0') {
      ++position_;
      if (position_ < text_.size() && text_[position_] >= '0' &&
          text_[position_] <= '9') {
        return false;
      }
    } else {
      if (text_[position_] < '1' || text_[position_] > '9') return false;
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9') {
        ++position_;
      }
    }
    if (position_ < text_.size() && text_[position_] == '.') {
      ++position_;
      const size_t fraction = position_;
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9') {
        ++position_;
      }
      if (position_ == fraction) return false;
    }
    if (position_ < text_.size() &&
        (text_[position_] == 'e' || text_[position_] == 'E')) {
      ++position_;
      if (position_ < text_.size() &&
          (text_[position_] == '+' || text_[position_] == '-')) {
        ++position_;
      }
      const size_t exponent = position_;
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9') {
        ++position_;
      }
      if (position_ == exponent) return false;
    }
    return position_ > start;
  }

  bool SkipLiteral(const char* literal) {
    const size_t length = std::strlen(literal);
    if (text_.compare(position_, length, literal) != 0) return false;
    position_ += length;
    return true;
  }

  bool SkipArray(size_t depth) {
    if (depth > 32 || !Consume('[')) return false;
    if (Consume(']')) return true;
    while (true) {
      if (!SkipValue(depth + 1)) return false;
      if (Consume(']')) return true;
      if (!Consume(',')) return false;
    }
  }

  bool SkipNestedObject(size_t depth) {
    if (depth > 32 || !Consume('{')) return false;
    if (Consume('}')) return true;
    std::set<std::string> keys;
    while (true) {
      const size_t start = position_;
      if (!SkipString()) return false;
      if (!keys.insert(text_.substr(start, position_ - start)).second ||
          !Consume(':') || !SkipValue(depth + 1)) {
        return false;
      }
      if (Consume('}')) return true;
      if (!Consume(',')) return false;
    }
  }

  bool SkipValue(size_t depth) {
    if (position_ >= text_.size()) return false;
    switch (text_[position_]) {
      case '"': return SkipString();
      case '{': return SkipNestedObject(depth);
      case '[': return SkipArray(depth);
      case 't': return SkipLiteral("true");
      case 'f': return SkipLiteral("false");
      case 'n': return SkipLiteral("null");
      default: return SkipNumber();
    }
  }

  const std::string& text_;
  size_t position_ = 0;
};

const std::string* JsonField(const std::map<std::string, std::string>& fields,
                             const char* quoted_key) {
  const auto found = fields.find(quoted_key);
  return found == fields.end() ? nullptr : &found->second;
}

bool ParseTelemetryObject(const std::string& line,
                          std::map<std::string, std::string>* fields) {
  StageBJsonCursor parser(line);
  if (!parser.ParseObject(fields)) return false;
  const std::string* timestamp = JsonField(*fields, "\"t\"");
  const std::string* type = JsonField(*fields, "\"type\"");
  int64_t timestamp_value = -1;
  return timestamp != nullptr && type != nullptr &&
         StageBParseSigned(*timestamp, &timestamp_value) &&
         timestamp_value >= 0 && type->size() >= 2 && type->front() == '"' &&
         type->back() == '"';
}

bool ParseTelemetryFrame(const std::map<std::string, std::string>& fields,
                         int64_t* frame_id, uint32_t* ordinal,
                         uint32_t* queue_depth) {
  const std::string* type = JsonField(fields, "\"type\"");
  const std::string* seq = JsonField(fields, "\"seq\"");
  const std::string* fid = JsonField(fields, "\"fid\"");
  const std::string* result = JsonField(fields, "\"result\"");
  const std::string* queue = JsonField(fields, "\"queue\"");
  return type != nullptr && *type == "\"frame\"" && seq != nullptr &&
         fid != nullptr && result != nullptr && *result == "\"ok\"" &&
         queue != nullptr && StageBParseUnsigned(*seq, ordinal) &&
         *ordinal > 0 && StageBParseSigned(*fid, frame_id) && *frame_id >= 0 &&
         StageBParseUnsigned(*queue, queue_depth);
}

bool ParseTelemetryFinalize(const std::map<std::string, std::string>& fields) {
  const std::string* type = JsonField(fields, "\"type\"");
  const std::string* isolate = JsonField(fields, "\"iso\"");
  const std::string* result = JsonField(fields, "\"result\"");
  const std::string* return_code = JsonField(fields, "\"rc\"");
  const std::string* milliseconds = JsonField(fields, "\"wall_ms\"");
  int64_t rc = -1;
  int64_t wall_ms = -1;
  return type != nullptr && *type == "\"finalize_phase1\"" &&
         isolate != nullptr && *isolate == "\"worker\"" &&
         result != nullptr && *result == "\"ok\"" &&
         return_code != nullptr && StageBParseSigned(*return_code, &rc) &&
         rc == 0 && milliseconds != nullptr &&
         StageBParseSigned(*milliseconds, &wall_ms) && wall_ms >= 0;
}

}  // namespace

const char* EmbeddedStageBSourceClosure() {
  return AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1;
}

void ResetStageBLocked(SessionRecords* records) noexcept {
  if (records != nullptr) records->stage_b.reset();
}

void AppendStageBAcceptedLocked(SessionRecords* records,
                                const FrameCounts& row) noexcept {
  if (records == nullptr || !Enabled()) return;
  try {
    if (!records->stage_b) {
      records->stage_b = std::make_unique<StageBJournalState>();
    }
    ++records->stage_b->row_attempts;
    if (records->stage_b->status == StageBJournalStatus::kSealed ||
        records->stage_b->status ==
            StageBJournalStatus::kSealedWithCloseWarning) {
      FailStageB(records->stage_b.get(), StageBFailureReason::kAlreadySealed);
      return;
    }
    if (records->stage_b->status != StageBJournalStatus::kFailed &&
        records->stage_b->status != StageBJournalStatus::kDisabledIdentity) {
      (void)StageBAppendRow(records->stage_b.get(), row);
    }
  } catch (...) {
    if (records->stage_b) {
      FailStageB(records->stage_b.get(), StageBFailureReason::kWriteFailed);
    }
  }
}

bool CopyStageBJournalSnapshot(const SessionRecords* records,
                               StageBJournalSnapshot* out) {
  if (records == nullptr || out == nullptr) return false;
  std::lock_guard<std::mutex> lock(records->mutex);
  *out = StageBJournalSnapshot{};
  if (!records->stage_b) return true;
  out->status = records->stage_b->status;
  out->first_failure = records->stage_b->first_failure;
  out->row_attempts = records->stage_b->row_attempts;
  out->writer_calls = records->stage_b->writer_calls;
  out->rows_written = records->stage_b->rows_written;
  out->seal_attempts = records->stage_b->seal_attempts;
  out->post_seal_close_warning =
      records->stage_b->post_seal_close_warning;
  return true;
}

bool SealStageBJournal(SessionRecords* records) noexcept {
  if (records == nullptr || !Enabled()) return false;
  std::lock_guard<std::mutex> lock(records->mutex);
  try {
    if (!records->stage_b) {
      records->stage_b = std::make_unique<StageBJournalState>();
    }
    StageBJournalState* state = records->stage_b.get();
    if (state->status == StageBJournalStatus::kSealed ||
        state->status == StageBJournalStatus::kSealedWithCloseWarning) {
      return true;
    }
    if (!StageBEnsureInitialized(state)) return false;
    ++state->seal_attempts;
    if (records->accepted_rows.empty() ||
        state->rows_written != records->accepted_rows.size()) {
      FailStageB(state, StageBFailureReason::kRowInvariant);
      return false;
    }
    const uint32_t last_ordinal =
        records->accepted_rows.empty()
            ? 0
            : records->accepted_rows.back().frame_ordinal;
    const std::string digest = Sha256HexData(
        reinterpret_cast<const uint8_t*>(state->journal_prefix.data()),
        state->journal_prefix.size());
    std::ostringstream seal;
    seal << "seal|rows=" << state->rows_written
         << "|last_ordinal=" << last_ordinal
         << "|journal_sha256=" << digest << "\n";
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
    if (StageBFaultIs(state, StageBTestFault::kSealOpen)) {
      FailStageB(state, StageBFailureReason::kOpenFailed);
      return false;
    }
#endif
    const int fd = ::openat(state->run_fd, kStageBJournalFilename,
                            O_WRONLY | O_APPEND | O_NONBLOCK | O_CLOEXEC |
                                O_NOFOLLOW);
    if (fd < 0) {
      FailStageB(state, StageBFailureReason::kOpenFailed);
      return false;
    }
    if (!StageBJournalIdentityMatches(state, fd)) {
      (void)::close(fd);
      FailStageB(state, StageBFailureReason::kPathRejected);
      return false;
    }
    const std::string seal_line = seal.str();
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
    if (StageBFaultIs(state, StageBTestFault::kSealFsync)) {
      (void)::close(fd);
      FailStageB(state, StageBFailureReason::kFsyncFailed);
      return false;
    }
#endif
    if (!StageBWriteAll(fd,
                        reinterpret_cast<const uint8_t*>(seal_line.data()),
                        seal_line.size(), state, StageBWritePhase::kSeal)) {
      (void)::close(fd);
      FailStageB(state, StageBFailureReason::kWriteFailed);
      return false;
    }
    if (::fsync(fd) != 0) {
      (void)::close(fd);
      FailStageB(state, StageBFailureReason::kFsyncFailed);
      return false;
    }
    const int close_result = ::close(fd);
#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
    if (StageBFaultIs(state, StageBTestFault::kSealCloseAfterFsync)) {
      state->post_seal_close_warning = true;
      state->status = StageBJournalStatus::kSealedWithCloseWarning;
      return true;
    }
#endif
    if (close_result != 0) {
      state->post_seal_close_warning = true;
      state->status = StageBJournalStatus::kSealedWithCloseWarning;
      return true;
    }
    state->status = StageBJournalStatus::kSealed;
    return true;
  } catch (...) {
    if (records->stage_b) {
      FailStageB(records->stage_b.get(), StageBFailureReason::kWriteFailed);
    }
    return false;
  }
}

namespace {

struct StageBBridgeObservation {
  SessionRecords records;
  uint32_t accepted_ordinal = 0;
  int thermal_state = -1;
  bool viable = true;
  bool finalized = false;
};

std::mutex& StageBBridgeMutex() {
  static std::mutex mutex;
  return mutex;
}

std::unordered_map<void*, std::unique_ptr<StageBBridgeObservation>>&
StageBBridgeSessions() {
  static std::unordered_map<void*, std::unique_ptr<StageBBridgeObservation>>
      sessions;
  return sessions;
}

StageBBridgeObservation* FindStageBBridgeObservation(void* session) {
  const auto found = StageBBridgeSessions().find(session);
  return found == StageBBridgeSessions().end() ? nullptr : found->second.get();
}

}  // namespace

#if defined(__GNUC__) || defined(__clang__)
#define AETHER_STAGE_B_BRIDGE_HIDDEN __attribute__((visibility("hidden")))
#else
#define AETHER_STAGE_B_BRIDGE_HIDDEN
#endif

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_create(void* session) noexcept {
  if (!Enabled() || session == nullptr) return;
  try {
    auto observation = std::make_unique<StageBBridgeObservation>();
    std::lock_guard<std::mutex> lock(StageBBridgeMutex());
    StageBBridgeSessions().insert_or_assign(session, std::move(observation));
  } catch (...) {
    // Observation is private and fail-closed; production creation succeeded.
  }
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_thermal(void* session, int state) noexcept {
  if (!Enabled() || session == nullptr) return;
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeObservation* observation =
      FindStageBBridgeObservation(session);
  if (observation != nullptr) {
    observation->thermal_state = state >= 0 && state <= 3 ? state : -1;
  }
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_pre_add(void* session) noexcept {
  if (!Enabled()) return;
  if (HasSealedPendingCandidate()) {
    std::lock_guard<std::mutex> lock(StageBBridgeMutex());
    StageBBridgeObservation* observation =
        FindStageBBridgeObservation(session);
    if (observation != nullptr) observation->viable = false;
  }
  ClearPendingAtGpuEntry();
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_add(void* session, int result,
                                   const int* out_frame_id) noexcept {
  if (!Enabled()) return;
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeObservation* observation =
      FindStageBBridgeObservation(session);
  if (result != 0) {
    DiscardPending(PendingDiscardReason::kSessionRejected);
    return;
  }
  if (observation == nullptr) {
    DiscardPending(PendingDiscardReason::kSessionRejected);
    return;
  }
  if (observation->accepted_ordinal ==
      std::numeric_limits<uint32_t>::max()) {
    observation->viable = false;
    DiscardPending(PendingDiscardReason::kSessionRejected);
    return;
  }
  ++observation->accepted_ordinal;
  if (!observation->viable) {
    DiscardPending(PendingDiscardReason::kSessionRejected);
    return;
  }
  if (out_frame_id == nullptr || *out_frame_id < 0) {
    observation->viable = false;
    DiscardPending(PendingDiscardReason::kSessionRejected);
    return;
  }
  FrameCounts row;
  const FieldStatus thermal_status =
      observation->thermal_state >= 0 ? FieldStatus::kValid
                                      : FieldStatus::kUnavailable;
  if (!FinalizeAcceptedFrame(*out_frame_id, observation->accepted_ordinal,
                             thermal_status, observation->thermal_state,
                             &row) ||
      !AppendSessionRecord(&observation->records, row)) {
    observation->viable = false;
  }
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_remove(void* session, int result) noexcept {
  if (!Enabled() || result != 0) return;
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeObservation* observation =
      FindStageBBridgeObservation(session);
  if (observation != nullptr) observation->viable = false;
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_finalize(void* session, int result) noexcept {
  if (!Enabled() || result != 0) return;
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeObservation* observation =
      FindStageBBridgeObservation(session);
  if (observation == nullptr || observation->finalized) return;
  observation->finalized = true;
  if (observation->viable && !SealStageBJournal(&observation->records)) {
    observation->viable = false;
  }
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN void
aether_preclamp_stage_b_bridge_free(void* session) noexcept {
  if (!Enabled() || session == nullptr) return;
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeSessions().erase(session);
}

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN size_t
aether_preclamp_stage_b_bridge_test_session_count() noexcept {
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  return StageBBridgeSessions().size();
}

extern "C" AETHER_STAGE_B_BRIDGE_HIDDEN bool
aether_preclamp_stage_b_bridge_test_snapshot(
    void* session, uint32_t* accepted_ordinal, int* thermal_state,
    bool* viable, bool* finalized, StageBJournalSnapshot* journal) noexcept {
  if (accepted_ordinal == nullptr || thermal_state == nullptr ||
      viable == nullptr || finalized == nullptr || journal == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(StageBBridgeMutex());
  StageBBridgeObservation* observation =
      FindStageBBridgeObservation(session);
  if (observation == nullptr) return false;
  *accepted_ordinal = observation->accepted_ordinal;
  *thermal_state = observation->thermal_state;
  *viable = observation->viable;
  *finalized = observation->finalized;
  return CopyStageBJournalSnapshot(&observation->records, journal);
}
#endif

#undef AETHER_STAGE_B_BRIDGE_HIDDEN

StageBArtifactStatus ParseStageBJournal(
    const std::vector<uint8_t>& bytes, const std::string& expected_run_id,
    const std::string& expected_source_sha256, StageBParsedJournal* out) {
  if (out == nullptr) return StageBArtifactStatus::kInvalid;
  *out = StageBParsedJournal{};
  if (bytes.empty() || !StageBPrintableAscii(bytes)) return out->status;
  size_t complete_end = 0;
  for (size_t i = 0; i < bytes.size(); ++i) {
    if (bytes[i] == '\n') complete_end = i + 1;
  }
  if (complete_end == 0) return out->status;
  const bool has_partial = complete_end != bytes.size();
  const std::string complete(reinterpret_cast<const char*>(bytes.data()),
                             complete_end);
  std::vector<std::string> lines;
  std::istringstream stream(complete);
  std::string line;
  while (std::getline(stream, line)) lines.push_back(line);
  if (lines.empty() ||
      !StageBParseHeaderLine(lines[0], &out->run_id, &out->source_sha256) ||
      out->run_id != expected_run_id ||
      out->source_sha256 != expected_source_sha256) {
    return out->status;
  }
  std::unordered_set<int64_t> frame_ids;
  uint32_t previous_ordinal = 0;
  size_t prefix_bytes = lines[0].size() + 1;
  for (size_t index = 1; index < lines.size(); ++index) {
    if (lines[index].rfind("seal|", 0) == 0) {
      if (index + 1 != lines.size() || has_partial) return out->status;
      uint32_t rows = 0;
      uint32_t last_ordinal = 0;
      std::string digest;
      if (!StageBParseSealLine(lines[index], &rows, &last_ordinal, &digest) ||
          rows == 0 || rows != out->rows.size() ||
          last_ordinal != (out->rows.empty() ? 0 : previous_ordinal) ||
          digest != Sha256HexData(bytes.data(), prefix_bytes)) {
        return out->status;
      }
      std::ostringstream canonical;
      canonical << "seal|rows=" << rows << "|last_ordinal=" << last_ordinal
                << "|journal_sha256=" << digest;
      if (canonical.str() != lines[index]) return out->status;
      out->status = StageBArtifactStatus::kSealed;
      return out->status;
    }
    FrameCounts row;
    if (!StageBParseRowLine(lines[index], &row) ||
        row.frame_ordinal <= previous_ordinal ||
        !frame_ids.insert(row.frame_id).second) {
      return out->status;
    }
    previous_ordinal = row.frame_ordinal;
    out->rows.push_back(row);
    out->complete_prefix_rows = static_cast<uint32_t>(out->rows.size());
    prefix_bytes += lines[index].size() + 1;
  }
  out->status = StageBArtifactStatus::kIncomplete;
  return out->status;
}

StageBJoinStatus JoinStageBJournalTelemetry(
    const StageBParsedJournal& journal,
    const std::vector<uint8_t>& telemetry_jsonl,
    const StageBTelemetryPrefix& frozen_prefix, StageBJoinResult* out) {
  if (out == nullptr) return StageBJoinStatus::kInvalid;
  *out = StageBJoinResult{};
  if (journal.status != StageBArtifactStatus::kSealed ||
      journal.rows.empty() ||
      !IsLowerHexDigest(frozen_prefix.sha256) ||
      frozen_prefix.byte_length > telemetry_jsonl.size() ||
      telemetry_jsonl.empty() || telemetry_jsonl.back() != '\n' ||
      (frozen_prefix.byte_length != 0 &&
       telemetry_jsonl[frozen_prefix.byte_length - 1] != '\n') ||
      !StageBPrintableAscii(telemetry_jsonl) ||
      Sha256HexData(telemetry_jsonl.data(),
                    static_cast<size_t>(frozen_prefix.byte_length)) !=
          frozen_prefix.sha256) {
    return out->status;
  }
  const size_t suffix_offset = static_cast<size_t>(frozen_prefix.byte_length);
  if (suffix_offset == telemetry_jsonl.size()) return out->status;
  const std::string text(
      reinterpret_cast<const char*>(telemetry_jsonl.data() + suffix_offset),
      telemetry_jsonl.size() - suffix_offset);
  std::vector<std::string> lines;
  std::istringstream stream(text);
  std::string line;
  while (std::getline(stream, line)) lines.push_back(line);
  out->rows.reserve(journal.rows.size());
  size_t row_index = 0;
  bool finalize_seen = false;
  for (const std::string& telemetry_line : lines) {
    if (telemetry_line.empty()) {
      out->rows.clear();
      return out->status;
    }
    std::map<std::string, std::string> fields;
    if (!ParseTelemetryObject(telemetry_line, &fields)) {
      out->rows.clear();
      return out->status;
    }
    const std::string* type = JsonField(fields, "\"type\"");
    if (type != nullptr && *type == "\"frame\"") {
      int64_t frame_id = -1;
      uint32_t ordinal = 0;
      uint32_t queue_depth = 0;
      if (finalize_seen || row_index >= journal.rows.size() ||
          !ParseTelemetryFrame(fields, &frame_id, &ordinal, &queue_depth) ||
          frame_id != journal.rows[row_index].frame_id ||
          ordinal != journal.rows[row_index].frame_ordinal) {
        out->rows.clear();
        return out->status;
      }
      FrameCounts row = journal.rows[row_index++];
      row.queue_backlog_status = FieldStatus::kValid;
      row.queue_backlog = queue_depth;
      out->rows.push_back(row);
    } else if (type != nullptr && *type == "\"finalize_phase1\"") {
      if (finalize_seen || row_index != journal.rows.size() ||
          !ParseTelemetryFinalize(fields)) {
        out->rows.clear();
        return out->status;
      }
      finalize_seen = true;
    }
  }
  if (!finalize_seen || row_index != journal.rows.size()) {
    out->rows.clear();
    return out->status;
  }
  out->status = StageBJoinStatus::kCountSequenceComplete;
  return out->status;
}

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
void ConfigureStageBTestFault(SessionRecords* records,
                              StageBTestFault fault) noexcept {
  if (records == nullptr) return;
  std::lock_guard<std::mutex> lock(records->mutex);
  try {
    if (!records->stage_b) {
      records->stage_b = std::make_unique<StageBJournalState>();
    }
    records->stage_b->fault = fault;
    records->stage_b->transient_fault_consumed = false;
  } catch (...) {
  }
}
#endif

ExactParityResult CompareExactOffOnArtifacts(
    const ExactParityArtifact& off, const ExactParityArtifact& on) noexcept {
  uint32_t mismatch = 0;
  if (off.ordered_outputs.empty() || on.ordered_outputs.empty() ||
      off.ordered_outputs != on.ordered_outputs) {
    mismatch |= kOrderedOutputsMismatch;
  }
  if (off.database_bytes.empty() || on.database_bytes.empty() ||
      off.database_bytes != on.database_bytes) {
    mismatch |= kDatabaseMismatch;
  }
  if (off.ordered_matches_digest.empty() ||
      on.ordered_matches_digest.empty() ||
      off.ordered_matches_digest != on.ordered_matches_digest) {
    mismatch |= kOrderedMatchesMismatch;
  }
  if (off.final_ply_bytes.empty() || on.final_ply_bytes.empty() ||
      off.final_ply_bytes != on.final_ply_bytes) {
    mismatch |= kFinalPlyMismatch;
  }
  return {mismatch == 0 ? ExactParityStatus::kP3PendingExactHostParity
                        : ExactParityStatus::kInvalid,
          mismatch};
}

}  // namespace aether_preclamp_instr_v1
