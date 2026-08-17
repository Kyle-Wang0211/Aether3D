#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BA = (ROOT / "aether_cpp/official_pipeline/src/official_bundle_adjustment_ceres.cc").read_text()
SFM = (ROOT / "aether_cpp/official_pipeline/src/official_aether_sfm_c.cc").read_text()

assert '#include "gravity_ba_prior_v1.h"' in BA
assert "MaybeAddAetherGravityPriors(reconstruction);" in BA
assert "GravityBaPriorCostV1" in BA
assert "aether_ba_set_gravity_prior" in BA
assert "aether_ba_clear_gravity_priors" in BA

# The production streaming frame must install its gravity before live BA runs.
register = SFM.index("aether_ba_set_gravity_prior(name")
incremental_ba = SFM.index("MaybeIncrementalGlobalRefine(s);", register)
frames_push = SFM.index("s->frames.push_back(std::move(rec));", register)
assert register < incremental_ba < frames_push

# Batch and new streaming sessions must not inherit another session's priors.
assert SFM.count("aether_ba_clear_gravity_priors();") >= 3
# [2026-08-04] The attitude anchor must be robustified exactly like the position
# prior it sits next to. It is applied to every frame at a tight sigma against a
# VIO measurement that can be transiently wrong (thermal, relocalization), so an
# unrobustified squared cost let a single bad frame pull the entire solve.
gravity_fn = BA[BA.index("void MaybeAddAetherGravityPriors(") :]
gravity_fn = gravity_fn[: gravity_fn.index("\n private:")]
assert "aether_prior_loss_.get()" in gravity_fn
assert "nullptr,\n          pose_params);" not in gravity_fn

# gravity_cam is derived from the same ARKit quaternion that seeds the pose, so
# the residual is identically zero at ingest. A conversion regression or a
# cross-session registry collision therefore cannot be seen in residuals — the
# setup-time consistency check is the only place it can be caught.
assert "kMinAnchorConsistencyCos" in gravity_fn
assert "num_inconsistent" in gravity_fn

# Never log a count without its denominator: "injected N" alone cannot tell a
# healthy solve from one whose priors were silently dropped.
assert 'num_added << "/"' in gravity_fn
assert "num_eligible" in gravity_fn

print("PASS mandatory_gravity_ba_contract")
