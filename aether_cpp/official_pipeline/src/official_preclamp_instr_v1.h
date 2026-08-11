// strict-8192 instrumentation window v1 — PRIVATE/internal ABI.
// Authoritative P1 amendment SHA256:
// c269a53a525f1b9820580eb7f76d7606f03e420aa4e58c77408bd0d82ca157bd
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL) && \
    defined(AETHER_PRECLAMP_INSTR_ENV_SELFTEST)
#error "preclamp instr: OFFICIAL and SELFTEST namespaces must not alias"
#endif
#if !defined(AETHER_PRECLAMP_INSTR_ENV_OFFICIAL) && \
    !defined(AETHER_PRECLAMP_INSTR_ENV_SELFTEST)
#error "preclamp instr: exactly one env namespace must be selected"
#endif

#if defined(__GNUC__) || defined(__clang__)
#define AETHER_PRECLAMP_INSTR_PRIVATE __attribute__((visibility("hidden")))
#else
#define AETHER_PRECLAMP_INSTR_PRIVATE
#endif

struct aether_sfm_session;

namespace aether_preclamp_instr_v1 {

enum class FieldStatus : uint32_t {
  kUnavailable = 0,
  kValid = 1,
  kPendingExternalJoin = 2,
};

enum class AcceptedFrameStatus : uint32_t {
  kPending = 0,
  kAccepted = 1,
};

enum class PendingDiscardReason : uint32_t {
  kGpuEntryReset = 0,
  kZeroCandidate = 1,
  kValidationFailure = 2,
  kGpuFailureOrFallback = 3,
  kCanonicalRoute = 4,
  kSessionRejected = 5,
  kNonGpuRoute = 6,
};

struct FrameCounts {
  uint32_t schema_version = 2;
  AcceptedFrameStatus accepted_status = AcceptedFrameStatus::kPending;
  uint32_t frame_ordinal = 0;
  int64_t frame_id = -1;

  FieldStatus count_status = FieldStatus::kUnavailable;
  uint32_t preclamp_count = 0;
  uint32_t legacy_count = 0;
  uint32_t strict_shadow_count = 0;
  uint32_t overflow_group_size = 0;

  FieldStatus descriptor_rows_status = FieldStatus::kUnavailable;
  uint32_t descriptor_rows = 0;
  FieldStatus gpu_ms_status = FieldStatus::kUnavailable;
  float gpu_ms = 0.0f;
  FieldStatus thermal_state_status = FieldStatus::kUnavailable;
  int32_t thermal_state = -1;
  FieldStatus queue_backlog_status = FieldStatus::kUnavailable;
  uint32_t queue_backlog = 0;
};

enum class PhaseBHeadroomStatus : uint32_t {
  kInvalidInput = 0,
  kParkNoComputeHeadroom = 1,
  kComputeHeadroomPresent = 2,
  kArithmeticOverflow = 3,
};

struct PhaseBHeadroomReport {
  uint64_t accepted_frames = 0;
  uint64_t legacy_descriptor_rows_total = 0;
  uint64_t coverage8192_rows_total = 0;
  uint64_t canonical8192_rows_total = 0;
  uint64_t frames_descriptor_gt_8192 = 0;
  double coverage_row_headroom = 0.0;
  double canonical_row_headroom = 0.0;
};

// Pure count-ledger analysis for the frozen-capture Phase-B-first gate. This
// function assigns no timing or matcher credit and performs no I/O.
AETHER_PRECLAMP_INSTR_PRIVATE PhaseBHeadroomStatus AnalyzePhaseBHeadroom(
    const std::vector<FrameCounts>& rows, PhaseBHeadroomReport* out);

// Private per-session storage. Only the in-flight GPU snapshot is TLS; accepted
// history belongs to the session so worker-thread changes cannot split it and
// sequential sessions cannot contaminate each other.
struct SessionRecords {
  SessionRecords();
  ~SessionRecords();
  SessionRecords(const SessionRecords&) = delete;
  SessionRecords& operator=(const SessionRecords&) = delete;

  mutable std::mutex mutex;
  std::vector<FrameCounts> accepted_rows;
  std::unique_ptr<struct StageBJournalState> stage_b;
};

AETHER_PRECLAMP_INSTR_PRIVATE const char* EnvKey();
AETHER_PRECLAMP_INSTR_PRIVATE bool Enabled();
AETHER_PRECLAMP_INSTR_PRIVATE bool ShouldCreateCandidateGpuBuffer(
    uint32_t candidate_count);

// Extractor/GPU/session lifecycle. Clamp exit updates pending only. Sealing
// consumes a complete accepted legacy GPU result; publishing consumes the seal
// after the production session has assigned its accepted frame identity.
AETHER_PRECLAMP_INSTR_PRIVATE void ClearPendingAtGpuEntry() noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE void BeginLegacyClamp(
    uint32_t preclamp_count) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE void UpdateLegacyClampResult(
    uint32_t legacy_count) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE void DiscardPending(
    PendingDiscardReason reason) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE bool SealAcceptedLegacyGpuResult(
    uint32_t descriptor_rows, FieldStatus gpu_ms_status, float gpu_ms) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE bool FinalizeAcceptedFrame(
    int64_t frame_id, uint32_t frame_ordinal,
    FieldStatus thermal_state_status, int32_t thermal_state,
    FrameCounts* out) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE void ResetSessionRecords(
    SessionRecords* records) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE bool AppendSessionRecord(
    SessionRecords* records, const FrameCounts& row) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE bool CopySessionRecords(
    const SessionRecords* records, std::vector<FrameCounts>* out);
AETHER_PRECLAMP_INSTR_PRIVATE bool DrainSessionRecords(
    SessionRecords* records, std::vector<FrameCounts>* out) noexcept;

// Private production-session adapters used by instrumentation export/tests.
// They are deliberately absent from the stable C ABI header.
AETHER_PRECLAMP_INSTR_PRIVATE void ResetOfficialSessionRecords(
    ::aether_sfm_session* session) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE bool CopyOfficialSessionRecords(
    const ::aether_sfm_session* session, std::vector<FrameCounts>* out);
AETHER_PRECLAMP_INSTR_PRIVATE bool DrainOfficialSessionRecords(
    ::aether_sfm_session* session, std::vector<FrameCounts>* out) noexcept;

inline constexpr char kStageBJournalFilename[] = "stage_b_counts.v1";

enum class StageBJournalStatus : uint32_t {
  kOff = 0,
  kDisabledIdentity = 1,
  kReady = 2,
  kFailed = 3,
  kSealed = 4,
  kSealedWithCloseWarning = 5,
};

enum class StageBFailureReason : uint32_t {
  kNone = 0,
  kIdentityMissing = 1,
  kIdentityInvalid = 2,
  kIdentityMismatch = 3,
  kHomeInvalid = 4,
  kPathRejected = 5,
  kRunCollision = 6,
  kUnexpectedEntry = 7,
  kOpenFailed = 8,
  kWriteFailed = 9,
  kFsyncFailed = 10,
  kCloseFailed = 11,
  kPublishFailed = 12,
  kRowInvariant = 13,
  kAlreadySealed = 14,
};

struct StageBJournalSnapshot {
  StageBJournalStatus status = StageBJournalStatus::kOff;
  StageBFailureReason first_failure = StageBFailureReason::kNone;
  uint32_t row_attempts = 0;
  uint32_t writer_calls = 0;
  uint32_t rows_written = 0;
  uint32_t seal_attempts = 0;
  bool post_seal_close_warning = false;
};

AETHER_PRECLAMP_INSTR_PRIVATE const char* EmbeddedStageBSourceClosure();
AETHER_PRECLAMP_INSTR_PRIVATE bool CopyStageBJournalSnapshot(
    const SessionRecords* records, StageBJournalSnapshot* out);
AETHER_PRECLAMP_INSTR_PRIVATE bool SealStageBJournal(
    SessionRecords* records) noexcept;

enum class StageBArtifactStatus : uint32_t {
  kInvalid = 0,
  kIncomplete = 1,
  kSealed = 2,
};

struct StageBParsedJournal {
  StageBArtifactStatus status = StageBArtifactStatus::kInvalid;
  std::string run_id;
  std::string source_sha256;
  std::vector<FrameCounts> rows;
  uint32_t complete_prefix_rows = 0;
};

AETHER_PRECLAMP_INSTR_PRIVATE StageBArtifactStatus ParseStageBJournal(
    const std::vector<uint8_t>& bytes, const std::string& expected_run_id,
    const std::string& expected_source_sha256, StageBParsedJournal* out);

enum class StageBJoinStatus : uint32_t {
  kInvalid = 0,
  kCountSequenceComplete = 1,
};

struct StageBJoinResult {
  StageBJoinStatus status = StageBJoinStatus::kInvalid;
  std::vector<FrameCounts> rows;
};

struct StageBTelemetryPrefix {
  uint64_t byte_length = 0;
  std::string sha256;
};

AETHER_PRECLAMP_INSTR_PRIVATE StageBJoinStatus JoinStageBJournalTelemetry(
    const StageBParsedJournal& journal,
    const std::vector<uint8_t>& telemetry_jsonl,
    const StageBTelemetryPrefix& frozen_prefix, StageBJoinResult* out);

#if defined(AETHER_PRECLAMP_INSTR_TEST_HOOKS)
enum class StageBTestFault : uint32_t {
  kNone = 0,
  kInterruptWriteOnce = 1,
  kShortWriteOnce = 2,
  kHeaderOpen = 3,
  kHeaderPartialWrite = 4,
  kHeaderFsync = 5,
  kHeaderClose = 6,
  kHeaderPublish = 7,
  kHeaderDirectoryFsync = 8,
  kRowOpen = 9,
  kRowEnospc = 10,
  kRowPartialWrite = 11,
  kRowClose = 12,
  kSealOpen = 13,
  kSealPartialWrite = 14,
  kSealFsync = 15,
  kSealCloseAfterFsync = 16,
  kUnexpectedEntryAfterClaim = 17,
  kReplaceRunAfterClaim = 18,
  kApplicationSupportParentFsync = 19,
};

AETHER_PRECLAMP_INSTR_PRIVATE void ConfigureStageBTestFault(
    SessionRecords* records, StageBTestFault fault) noexcept;
#endif

enum class FixtureStatus : uint32_t {
  kOk = 0,
  kInvalidInput = 1,
  kLegacyIdentityMismatch = 2,
  kMissingDescriptor = 3,
  kConflictingDescriptor = 4,
};

struct ReplayFrame {
  int64_t frame_id = -1;
  uint32_t preclamp_count = 0;
  uint32_t legacy_count = 0;
  uint32_t overflow_group_size = 0;
};

enum class ReplayFrameRole : uint32_t {
  kFirst = 0,
  kPreclampMedian = 1,
  kOverflowP90 = 2,
  kOverflowMaximum = 3,
  kFinalThird = 4,
};

enum class ReplayOmissionReason : uint32_t {
  kNoHigherDistinctMetric = 1,
  kNoLaterAcceptedFrame = 2,
};

struct SelectedReplayFrame {
  ReplayFrameRole role = ReplayFrameRole::kFirst;
  int64_t frame_id = -1;
};

struct ReplayRoleOmission {
  ReplayFrameRole role = ReplayFrameRole::kFirst;
  ReplayOmissionReason reason =
      ReplayOmissionReason::kNoHigherDistinctMetric;
};

struct ReplaySelectionManifest {
  std::vector<SelectedReplayFrame> selected;
  std::vector<ReplayRoleOmission> omissions;
};

AETHER_PRECLAMP_INSTR_PRIVATE FixtureStatus SelectReplayFrames(
    const std::vector<int64_t>& ordered_accepted_frame_ids,
    const std::vector<ReplayFrame>& frames,
    ReplaySelectionManifest* out);

struct LegacyReplayIdentity {
  std::vector<uint8_t> keypoints;
  std::vector<uint8_t> descriptors;
};

AETHER_PRECLAMP_INSTR_PRIVATE FixtureStatus ValidateLegacyReplayIdentity(
    const LegacyReplayIdentity& stored,
    const LegacyReplayIdentity& replayed);

using SourceCandidateId = uint64_t;

struct CandidateDescriptor {
  SourceCandidateId source_candidate_id = 0;
  std::vector<uint8_t> bytes;
};

struct DescriptorArmSelections {
  std::vector<SourceCandidateId> legacy;
  std::vector<SourceCandidateId> canonical8192;
  std::vector<SourceCandidateId> canonical12288;
  bool retain_canonical12288 = false;
};

struct DescriptorUnionManifest {
  std::vector<CandidateDescriptor> descriptors;
  std::vector<uint32_t> legacy_indices;
  std::vector<uint32_t> canonical8192_indices;
  std::vector<uint32_t> canonical12288_indices;
};

AETHER_PRECLAMP_INSTR_PRIVATE bool ShouldCollapseFixed12288(
    const std::vector<uint32_t>& legacy_counts);
AETHER_PRECLAMP_INSTR_PRIVATE FixtureStatus BuildDescriptorUnion(
    const DescriptorArmSelections& arms,
    const std::vector<CandidateDescriptor>& available,
    DescriptorUnionManifest* out);

// Stage-D export is offline-only. These types and functions remain private to
// the instrumentation implementation and are never called from extraction.
inline constexpr uint32_t kStageDArtifactSchemaVersion = 1;
inline constexpr char kStageDManifestFilename[] = "stage_d_manifest.v1";
inline constexpr char kStageDPromotionFilename[] = "stage_d_promotion.v1";

enum class ArtifactStatus : uint32_t {
  kOk = 0,
  kSuccessFullSequenceLaneQReady = 1,
  kWorstCaseUnknown = 2,
  kCapacityArithmeticOverflow = 3,
  kInsufficientCapacity = 4,
  kInvalidArgument = 5,
  kPathViolation = 6,
  kSymlinkRejected = 7,
  kIoFailure = 8,
  kFaultInjected = 9,
  kCrossDeviceRename = 10,
  kTempResidue = 11,
  kUnexpectedFile = 12,
  kManifestMissing = 13,
  kManifestMalformed = 14,
  kManifestVersionMismatch = 15,
  kManifestIdentityMismatch = 16,
  kManifestPlanMismatch = 17,
  kDuplicateBlockId = 18,
  kDuplicateBlockFilename = 19,
  kBlockOrderMismatch = 20,
  kBlockMissing = 21,
  kBlockSizeMismatch = 22,
  kBlockHashMismatch = 23,
  kPayloadMismatch = 24,
  kIncomplete = 25,
  kPromotionNotReady = 26,
  kPromotionMarkerInvalid = 27,
};

struct CapacityGateResult {
  ArtifactStatus status = ArtifactStatus::kInvalidArgument;
  uint64_t required_bytes = 0;
};

struct ArtifactIdentity {
  uint32_t schema_version = kStageDArtifactSchemaVersion;
  std::string run_id;
  std::string input_sha256;
  std::string config_sha256;
  std::string source_sha256;
};

struct ArtifactBlockPlan {
  uint32_t block_id = 0;
  std::string filename;
  uint64_t expected_size = 0;
  std::string expected_sha256;
};

struct ArtifactPlan {
  ArtifactIdentity identity;
  std::vector<ArtifactBlockPlan> blocks;
};

struct BlockPayload {
  uint32_t block_id = 0;
  std::vector<uint8_t> bytes;
};

enum class TransactionStep : uint32_t {
  kTempCreated = 0,
  kPartialWrite = 1,
  kFullWrite = 2,
  kFileFsync = 3,
  kFileClosed = 4,
  kAtomicRename = 5,
  kParentDirectoryFsync = 6,
};

enum class TransactionFaultPoint : uint32_t {
  kNone = 0,
  kAfterTempCreate = 1,
  kAfterPartialWrite = 2,
  kAfterFileFsync = 3,
  kAfterFileClose = 4,
  kSimulateCrossDeviceRename = 5,
  kAfterAtomicRename = 6,
  kAfterParentDirectoryFsync = 7,
  kAfterManifestCommit = 8,
};

struct TransactionFault {
  TransactionFaultPoint point = TransactionFaultPoint::kNone;
  uint32_t trigger_block_id = 0;
};

struct TransactionTrace {
  std::vector<TransactionStep> steps;
};

struct ArtifactWriteStats {
  uint32_t block_file_writes = 0;
  uint32_t manifest_writes = 0;
  uint32_t skipped_verified_blocks = 0;
  TransactionTrace last_transaction;
};

struct ArtifactValidationReport {
  ArtifactStatus status = ArtifactStatus::kInvalidArgument;
  uint32_t completed_blocks = 0;
  uint32_t total_blocks = 0;
};

AETHER_PRECLAMP_INSTR_PRIVATE CapacityGateResult CheckStageDCapacity(
    uint64_t available_bytes, uint64_t worst_case_bytes) noexcept;
AETHER_PRECLAMP_INSTR_PRIVATE std::string Sha256Hex(
    const std::vector<uint8_t>& bytes);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus WriteFileTransactional(
    const std::string& root, const std::string& filename,
    const std::vector<uint8_t>& bytes, const TransactionFault& fault,
    TransactionTrace* trace);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus InitializeStageDArtifact(
    const std::string& root, const ArtifactPlan& plan,
    ArtifactWriteStats* stats);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus WriteStageDBatch(
    const std::string& root, const ArtifactPlan& plan,
    const std::vector<BlockPayload>& payloads,
    const TransactionFault& fault, ArtifactWriteStats* stats);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus ValidateStageDArtifact(
    const std::string& root, const ArtifactPlan& plan,
    ArtifactValidationReport* report);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus PromoteStageDArtifact(
    const std::string& root, const ArtifactPlan& plan,
    const TransactionFault& fault, ArtifactWriteStats* stats);
AETHER_PRECLAMP_INSTR_PRIVATE ArtifactStatus ValidateStageDPromotion(
    const std::string& root, const ArtifactPlan& plan,
    ArtifactValidationReport* report);

enum class ExactParityStatus : uint32_t {
  kInvalid = 0,
  kP3PendingExactHostParity = 1,
};

inline constexpr uint32_t kOrderedOutputsMismatch = 1u << 0;
inline constexpr uint32_t kDatabaseMismatch = 1u << 1;
inline constexpr uint32_t kOrderedMatchesMismatch = 1u << 2;
inline constexpr uint32_t kFinalPlyMismatch = 1u << 3;

struct ExactParityArtifact {
  std::vector<uint8_t> ordered_outputs;
  std::vector<uint8_t> database_bytes;
  std::vector<uint8_t> ordered_matches_digest;
  std::vector<uint8_t> final_ply_bytes;
};

struct ExactParityResult {
  ExactParityStatus status = ExactParityStatus::kInvalid;
  uint32_t mismatch_mask = 0;
};

AETHER_PRECLAMP_INSTR_PRIVATE ExactParityResult CompareExactOffOnArtifacts(
    const ExactParityArtifact& off, const ExactParityArtifact& on) noexcept;

}  // namespace aether_preclamp_instr_v1

#undef AETHER_PRECLAMP_INSTR_PRIVATE
