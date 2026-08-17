#!/usr/bin/env python3
from pathlib import Path


source = (
    Path(__file__).resolve().parents[2]
    / "official_pipeline"
    / "src"
    / "official_aether_sfm_c.cc"
).read_text(encoding="utf-8")

assert "live_cloud_arkit_ba_sim3_v2" in source
assert "live_cloud_same_id_point_delta_v2" in source
assert "PW_LIVE_CLOUD_DIAG_NATIVE_V2_20260810_AETHER_0ab02a0_SNAPSHOT_01" in source
assert 'AppendLiveCloudSnapshotDiagnosticsV2(s, "post_local_ba")' in source
assert 'AppendLiveCloudSnapshotDiagnosticsV2(s, "post_global_ba")' in source
assert "observation_only" in source

helper_start = source.index("void AppendLiveCloudSnapshotDiagnosticsV2(")
helper_end = source.index("\nstruct LocalBundleTraceSnapshotV1", helper_start)
helper = source[helper_start:helper_end]
for forbidden in (
    "AddPoint3D(",
    "DeletePoint3D(",
    "SetCamFromWorld(",
    "BundleAdjust",
    "IterativeGlobalRefinement",
    "preview_points",
):
    assert forbidden not in helper, forbidden
