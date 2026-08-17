#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = (ROOT / "aether_cpp/official_pipeline/src/official_aether_sfm_c.cc").read_text()
CMAKE = (ROOT / "aether_cpp/third_party/glomap_vendor/CMakeLists.txt").read_text()

assert '#include "arkit_pose_store_v1.h"' in SOURCE
assert "PersistArkitPoseSnapshot(*s, rec)" in SOURCE
assert "ReadArkitPoseStoreV1" in SOURCE
assert "pose_records.size()" in SOURCE
assert "FrameIdentityDigestV1" in SOURCE
assert "rec.frame_identity_digest != pose.frame_identity_digest" in SOURCE
assert "AddImageWithTrivialFrame(std::move(restored_image)" in SOURCE
assert "aether_ba_set_gravity_prior(image.Name().c_str()" in SOURCE
assert "arkit_pose_store_v1.cc" in CMAKE

def function_body(name: str, next_name: str) -> str:
    start = SOURCE.index(name)
    end = SOURCE.index(next_name, start)
    return SOURCE[start:end]

sync_finalize = function_body(
    "aether_sfm_result_t aether_sfm_finalize(",
    "aether_sfm_result_t aether_sfm_finalize_async(",
)
async_finalize = function_body(
    "aether_sfm_result_t aether_sfm_finalize_async(",
    "int aether_sfm_finalize_status(",
)

# Production streaming finalize/recovery must never invoke the db-driven
# registration pipeline. RunIncremental remains legal only for the explicit
# batch/reference C ABI outside these two functions.
assert "RunIncremental(" not in sync_finalize
assert "RunIncremental(" not in async_finalize
assert "if (!RebuildFrameRecordsForResume(s))" in async_finalize
assert "return AETHER_SFM_ERR_NOT_REGISTERED" in async_finalize

# [WITHDRAWN-PARITY 2026-08-04] Regression guard for a blocker that this file
# used to pass straight through. A frame the user withdrew must be restored by
# RebuildFrameRecordsForResume with EVERY mutation live remove_frame applies,
# not just image_id. Restoring image_id = 0 alone left n_keypoints and the
# descriptors populated, so FinalizeRematchStarvedFrames — whose candidate gate
# only tested n_keypoints — re-admitted the withdrawn frame and wrote
# WriteMatches(0, other) / WriteTwoViewGeometry(0, other). Those rows insert
# silently, then abort stage-2 in DatabaseCache::Load -> image_to_frame_id.at(0),
# so every later finalize AND resume died at the same place forever.
for mutation in (
    "rec.image_id = 0;",
    "rec.descriptors.clear();",
    "rec.points.clear();",
    "rec.n_keypoints = 0;",
):
    assert mutation in SOURCE, f"resume withdrawal must mirror remove_frame: {mutation}"

# All three pair-producing paths must state the withdrawal predicate explicitly
# rather than inferring it from n_keypoints.
assert "if (img1 == 0 || img2 == 0 || img1 == img2) continue;" in SOURCE
assert "s->frames[j].image_id == 0 || s->frames[f].image_id == 0" in SOURCE
assert "prev.image_id != 0 && prev.n_keypoints > 0" in SOURCE

# remove_frame must record the withdrawal BEFORE it destroys the frame's db
# matches; the reverse order resurrects a deleted photo when the persist fails.
assert "PersistArkitPoseSnapshotWithWithdrawal(*s, frame_id)" in SOURCE
assert SOURCE.index("PersistArkitPoseSnapshotWithWithdrawal(*s, frame_id)") < SOURCE.index(
    "s->frames[frame_id].image_id = 0;"
)

# A frame that dies after its db row was created must consume its ordinal
# instead of leaving a hole: frame_id comes from s->frames.size(), so a hole
# makes the next frame regenerate the same "frame_%06d.jpg" and hit the
# images.name UNIQUE constraint, which bricks the whole live capture rather than
# costing one frame.
#
# This must be a scope guard, not a per-branch fixup. The first version only
# covered the pose-snapshot failure, and a host replay of cap7_day then hit a
# transient "database is locked" during the db writes instead: that path left
# via the outer catch, pushed nothing, and killed frames 8..145 of a 146-frame
# capture. The guard has to fire on every exit including exceptions.
assert "struct OrdinalGuardV1" in SOURCE
assert "ordinal_guard.committed = true;" in SOURCE
assert "session->frames.push_back(std::move(withdrawn));" in SOURCE
# The guard must be armed before the first fallible step after WriteImage, and
# disarmed only once the real record is stored.
assert SOURCE.index("} ordinal_guard{") < SOURCE.index("s->db->WriteKeypoints(image_id, kps);")
assert SOURCE.index("s->frames.push_back(std::move(rec));") < SOURCE.index(
    "ordinal_guard.committed = true;"
)
# Destructors must not throw during unwinding.
guard_body = SOURCE[SOURCE.index("struct OrdinalGuardV1") : SOURCE.index("} ordinal_guard{")]
assert "try {" in guard_body and "catch (...)" in guard_body

print("PASS mandatory_arkit_recovery_contract")
