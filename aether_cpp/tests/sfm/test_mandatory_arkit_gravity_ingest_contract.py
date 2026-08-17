#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "aether_cpp/official_pipeline/src/official_aether_sfm_c.cc"
HEADER = ROOT / "aether_cpp/include/aether_sfm_c.h"


def function_body(text: str, signature: str, next_signature: str) -> str:
    begin = text.index(signature)
    end = text.index(next_signature, begin)
    return text[begin:end]


source = SOURCE.read_text()
header = HEADER.read_text()
body = function_body(
    source,
    "static aether_sfm_result_t AddFrameFeaturesImpl(",
    "aether_sfm_result_t aether_sfm_add_frame(",
)

assert '#include "mandatory_arkit_gravity_v1.h"' in source
assert "BuildMandatoryArkitGravityPoseV1(" in body
assert body.index("BuildMandatoryArkitGravityPoseV1(") < body.index("WriteCamera(")
assert "if (pose_qwxyz && pose_t)" not in body
assert "rec.has_pose = true;" in body
assert "colmap::EstimateTwoViewGeometry(" not in source
assert source.count("EstimateMandatoryFrameTwoViewGeometry(") >= 9
assert "use_inliers ?" not in body
assert "may be NULL" not in "\n".join(
    line for line in header.splitlines() if "pose_qwxyz" in line or "pose_t[3]" in line
)

print("PASS mandatory_arkit_gravity_ingest_contract")
