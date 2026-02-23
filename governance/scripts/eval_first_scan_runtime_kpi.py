#!/usr/bin/env python3
"""Evaluate pure-vision runtime gates and first-scan KPI from replay fixture.

This script is fail-closed:
- Any fixture mismatch => non-zero exit.
- Any KPI threshold failure => non-zero exit.
It writes machine-readable reports for governance validation.

Phase 14 extension:
- Tri/Tet deterministic Kuhn-5 replay and classification gate.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence, Set, Tuple

ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = ROOT / "governance/contract_registry.json"
KPI_FIXTURE_PATH = ROOT / "Tests/Fixtures/pure_vision_runtime_replay_v1.json"
KPI_OUTPUT_PATH = ROOT / "governance/generated/first_scan_runtime_metrics.json"
TRI_TET_FIXTURE_PATH = ROOT / "Tests/Fixtures/tri_tet_kuhn5_replay_v1.json"
TRI_TET_OUTPUT_PATH = ROOT / "governance/generated/tri_tet_runtime_metrics.json"
TRI_TET_LOG_PATH = ROOT / "governance/generated/reports/phase-14-zero-fab-tritet-log.txt"
RUNTIME_PARAMETER_TABLE_PATH = ROOT / "governance/runtime/runtime_parameter_master_table_v1.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate first-scan KPI and Tri/Tet runtime gates.")
    parser.add_argument(
        "--profile",
        choices=["forensic", "balanced", "speed"],
        help="Use profile overrides from runtime parameter table.",
    )
    parser.add_argument(
        "--runtime-parameter-table",
        default=str(RUNTIME_PARAMETER_TABLE_PATH),
        help="Runtime parameter table JSON path for profile overrides.",
    )
    parser.add_argument(
        "--tri-tet-only",
        action="store_true",
        help="Run only Tri/Tet deterministic runtime gate evaluation.",
    )
    parser.add_argument(
        "--with-tri-tet",
        action="store_true",
        help="Run first-scan KPI plus Tri/Tet gate in one execution.",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"Missing required file: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON at {path}: {exc}")


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def thresholds_from_registry() -> Dict[str, float]:
    registry = load_json(REGISTRY_PATH)
    constants = {
        item["id"]: item["value"]
        for item in registry.get("constants", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    required = {
        "blur": "K-BLUR-FRAME-REJECTION",
        "orb": "K-FRAME-MIN-ORB-FEATURES",
        "baseline": "K-OBS-MIN-BASELINE-PIXELS",
        "parallax": "K-OBS-REQ-PARALLAX-RATIO",
        "sigma": "K-OBS-SIGMA-Z-TARGET-M",
        "closure": "K-VOLUME-CLOSURE-RATIO-MIN",
        "unknown": "K-VOLUME-UNKNOWN-VOXEL-MAX",
        "thermal": "K-THERMAL-CRITICAL-C",
        "guidance": "K-GUIDANCE-S4-S5-THRESHOLD",
        "soft": "K-EVIDENCE-S5-MIN-SOFT",
    }
    out: Dict[str, float] = {}
    missing: List[str] = []
    for key, cid in required.items():
        value = constants.get(cid)
        if not isinstance(value, (int, float)):
            missing.append(cid)
            continue
        out[key] = float(value)
    if missing:
        raise SystemExit(f"Missing runtime threshold constants: {missing}")
    return out


def failed_gate_ids(metrics: Dict[str, Any], t: Dict[str, float]) -> Set[str]:
    failed: Set[str] = set()
    if float(metrics.get("baselinePixels", 0.0)) < t["baseline"]:
        failed.add("baseline_pixels")
    if float(metrics.get("blurLaplacian", 0.0)) < t["blur"]:
        failed.add("blur_laplacian")
    if int(metrics.get("orbFeatures", 0)) < int(t["orb"]):
        failed.add("orb_feature_count")
    if float(metrics.get("parallaxRatio", 0.0)) < t["parallax"]:
        failed.add("parallax_ratio")
    if float(metrics.get("depthSigmaMeters", 1e9)) > t["sigma"]:
        failed.add("depth_sigma")
    if float(metrics.get("closureRatio", 0.0)) < t["closure"]:
        failed.add("closure_ratio")
    if float(metrics.get("unknownVoxelRatio", 1e9)) > t["unknown"]:
        failed.add("unknown_voxel_ratio")
    if float(metrics.get("thermalCelsius", 1e9)) > t["thermal"]:
        failed.add("thermal_celsius")
    return failed


def load_profile_overrides(profile: str | None, table_path: Path) -> Dict[str, float]:
    if not profile:
        return {}
    table = load_json(table_path)
    params = table.get("parameters", [])
    if not isinstance(params, list):
        raise SystemExit(f"Invalid runtime parameter table at {table_path}: missing parameters[]")

    profile_values: Dict[str, float] = {}
    for item in params:
        if not isinstance(item, dict):
            continue
        pid = item.get("id")
        values = item.get("values")
        if not isinstance(pid, str) or not isinstance(values, dict):
            continue
        raw = values.get(profile)
        if not isinstance(raw, (int, float)):
            continue
        profile_values[pid] = float(raw)

    key_map = {
        "first_scan.target_success_rate": "target_success_rate",
        "first_scan.target_replay_stable_rate": "target_replay_stable_rate",
        "first_scan.target_duration_seconds": "first_scan_target_seconds",
        "first_scan.hard_cap_seconds": "hard_cap_seconds",
        "first_scan.max_hard_cap_violations": "max_hard_cap_violations",
        "tri_tet.max_unknown_ratio": "tri_tet_max_unknown_ratio",
    }
    out: Dict[str, float] = {}
    for pid, key in key_map.items():
        if pid in profile_values:
            out[key] = profile_values[pid]
    return out


def classify_failure(
    sample: Dict[str, Any],
    failed_gates: Set[str],
    s5_pass: bool,
    within_first_scan: bool,
    hard_cap_seconds: float,
) -> str:
    duration = float(sample.get("durationSeconds", 0.0))
    replay_stable = bool(sample.get("replayHashStable", False))
    if duration > hard_cap_seconds:
        return "hard_cap_exceeded"
    if not within_first_scan:
        return "first_scan_duration_exceeded"
    if not replay_stable:
        return "replay_hash_unstable"
    if not s5_pass:
        return "s5_material_not_reached"
    if failed_gates:
        return f"gate_failed:{sorted(failed_gates)[0]}"
    return "unknown_failure"


def run_first_scan_kpi(
    thresholds: Dict[str, float],
    *,
    first_scan_target_seconds: float = 180.0,
    hard_cap_seconds: float = 900.0,
    overrides: Dict[str, float] | None = None,
) -> Tuple[Dict[str, Any], List[str]]:
    fixture = load_json(KPI_FIXTURE_PATH)
    expected = fixture.get("expected", {})
    overrides = overrides or {}
    errors: List[str] = []

    for case in fixture.get("gate_cases", []):
        metrics = case.get("metrics", {})
        expected_failed = set(case.get("expected_failed_gates", []))
        actual_failed = failed_gate_ids(metrics, thresholds)
        if actual_failed != expected_failed:
            errors.append(
                f"gate case mismatch ({case.get('name')}): expected={sorted(expected_failed)} actual={sorted(actual_failed)}"
            )

    samples = fixture.get("first_scan_samples", [])
    if not samples:
        errors.append("first_scan_samples is empty")
        samples = []

    success_count = 0
    replay_stable_count = 0
    hard_cap_violations = 0
    durations: List[float] = []
    failure_reasons: Dict[str, int] = {}

    for sample in samples:
        duration = float(sample.get("durationSeconds", 0.0))
        durations.append(duration)
        replay_stable = bool(sample.get("replayHashStable", False))
        if replay_stable:
            replay_stable_count += 1
        if duration > hard_cap_seconds:
            hard_cap_violations += 1

        failed_gates = failed_gate_ids(sample.get("metrics", {}), thresholds)
        s5_pass = (
            float(sample.get("guidanceDisplayValue", 0.0)) >= thresholds["guidance"]
            and float(sample.get("softEvidenceValue", 0.0)) >= thresholds["soft"]
        )
        within_first_scan = duration <= first_scan_target_seconds
        passed = (not failed_gates) and s5_pass and within_first_scan
        if passed:
            success_count += 1
        else:
            reason = classify_failure(
                sample,
                failed_gates,
                s5_pass,
                within_first_scan,
                hard_cap_seconds,
            )
            failure_reasons[reason] = failure_reasons.get(reason, 0) + 1

    total = len(samples)
    success_rate = (success_count / total) if total > 0 else 0.0
    replay_rate = (replay_stable_count / total) if total > 0 else 0.0
    median_duration = statistics.median(durations) if durations else 0.0
    max_duration = max(durations) if durations else 0.0

    target_success_rate = float(overrides.get("target_success_rate", expected.get("target_success_rate", 0.9)))
    target_replay_rate = float(
        overrides.get("target_replay_stable_rate", expected.get("target_replay_stable_rate", 1.0))
    )
    max_hard_caps = int(overrides.get("max_hard_cap_violations", expected.get("max_hard_cap_violations", 0)))

    passes_gate = (
        success_rate >= target_success_rate
        and replay_rate >= target_replay_rate
        and hard_cap_violations <= max_hard_caps
    )

    reason_key = expected.get("expected_failure_reason")
    reason_count = int(expected.get("expected_failure_count", 0))
    check_fixture_failure_reason = (
        "target_success_rate" not in overrides
        and "target_replay_stable_rate" not in overrides
        and "max_hard_cap_violations" not in overrides
        and "first_scan_target_seconds" not in overrides
        and "hard_cap_seconds" not in overrides
    )
    if reason_key is not None and check_fixture_failure_reason:
        if failure_reasons.get(str(reason_key), 0) != reason_count:
            errors.append(
                f"failure reason mismatch: expected {reason_key}={reason_count}, "
                f"actual={failure_reasons.get(str(reason_key), 0)}"
            )

    report = {
        "totalSessions": total,
        "firstScanSuccessRate": success_rate,
        "replayStableRate": replay_rate,
        "medianDurationSeconds": median_duration,
        "maxDurationSeconds": max_duration,
        "hardCapViolations": hard_cap_violations,
        "failureReasons": failure_reasons,
        "targetSuccessRate": target_success_rate,
        "targetReplayStableRate": target_replay_rate,
        "firstScanTargetSeconds": first_scan_target_seconds,
        "hardCapSeconds": hard_cap_seconds,
        "passesGate": passes_gate and not errors,
    }
    write_json(KPI_OUTPUT_PATH, report)
    return report, errors


def _as_point3(values: Sequence[Any]) -> Tuple[float, float, float]:
    if len(values) != 3:
        raise ValueError(f"Expected 3D point, got length={len(values)}")
    return float(values[0]), float(values[1]), float(values[2])


def _kuhn5(parity: int) -> List[Tuple[int, int, int, int]]:
    if parity & 1 == 0:
        return [
            (0, 1, 3, 7),
            (0, 3, 2, 7),
            (0, 2, 6, 7),
            (0, 6, 4, 7),
            (0, 4, 5, 7),
        ]
    return [
        (1, 0, 2, 6),
        (1, 2, 3, 6),
        (1, 3, 7, 6),
        (1, 7, 5, 6),
        (1, 5, 4, 6),
    ]


def _centroid3(points: Sequence[Tuple[float, float, float]]) -> Tuple[float, float, float]:
    n = float(len(points))
    return (
        sum(p[0] for p in points) / n,
        sum(p[1] for p in points) / n,
        sum(p[2] for p in points) / n,
    )


def _distance3(a: Tuple[float, float, float], b: Tuple[float, float, float]) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    dz = a[2] - b[2]
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def run_tri_tet_runtime_gate(
    thresholds: Dict[str, float],
    *,
    unknown_ratio_override: float | None = None,
) -> Tuple[Dict[str, Any], List[str]]:
    fixture = load_json(TRI_TET_FIXTURE_PATH)
    errors: List[str] = []

    kuhn_cfg = fixture.get("kuhn5", {})
    expected_even = kuhn_cfg.get("parity0")
    expected_odd = kuhn_cfg.get("parity1")
    if expected_even is not None and expected_even != [list(v) for v in _kuhn5(0)]:
        errors.append("kuhn5 parity0 fixture mismatch against deterministic reference")
    if expected_odd is not None and expected_odd != [list(v) for v in _kuhn5(1)]:
        errors.append("kuhn5 parity1 fixture mismatch against deterministic reference")

    samples = fixture.get("replay_samples", [])
    if not samples:
        errors.append("tri_tet replay_samples is empty")

    sample_reports: List[Dict[str, Any]] = []
    max_unknown_ratio_observed = 0.0
    unknown_ratio_threshold = float(
        unknown_ratio_override
        if unknown_ratio_override is not None
        else fixture.get("expected", {}).get("max_unknown_ratio", thresholds["unknown"])
    )

    for sample in samples:
        name = str(sample.get("name", "unnamed"))
        config = sample.get("config", {})
        measured_min = int(config.get("measuredMinViewCount", 3))
        estimated_min = int(config.get("estimatedMinViewCount", 2))
        max_dist = float(config.get("maxTriangleToTetDistance", 0.08))

        vertices_raw = sample.get("vertices", [])
        vertex_lookup: Dict[int, Dict[str, Any]] = {}
        for v in vertices_raw:
            index = int(v.get("index"))
            vertex_lookup[index] = {
                "position": _as_point3(v.get("position", [0.0, 0.0, 0.0])),
                "viewCount": int(v.get("viewCount", 0)),
            }

        tets_raw = sample.get("tetrahedra", [])
        if isinstance(tets_raw, dict) and "parity" in tets_raw:
            parity = int(tets_raw.get("parity", 0))
            tets = [{"id": i, "vertices": list(verts)} for i, verts in enumerate(_kuhn5(parity))]
        else:
            tets = tets_raw

        measured_count = 0
        estimated_count = 0
        unknown_count = 0
        classifications: Dict[str, str] = {}

        for tri in sample.get("triangles", []):
            patch_id = str(tri.get("patchId", "unknown_patch"))
            tri_vertices = [_as_point3(p) for p in tri.get("vertices", [])]
            if len(tri_vertices) != 3:
                errors.append(f"{name}:{patch_id}: invalid triangle vertex count")
                continue
            tri_centroid = _centroid3(tri_vertices)

            nearest_id = -1
            nearest_dist = float("inf")
            nearest_min_views = 0
            for tet in tets:
                tet_id = int(tet.get("id", -1))
                tet_vertices = [int(x) for x in tet.get("vertices", [])]
                if len(tet_vertices) != 4:
                    continue
                tet_points = [vertex_lookup[idx]["position"] for idx in tet_vertices if idx in vertex_lookup]
                if len(tet_points) != 4:
                    continue
                tet_centroid = _centroid3(tet_points)
                dist = _distance3(tri_centroid, tet_centroid)
                min_views = min(int(vertex_lookup[idx]["viewCount"]) for idx in tet_vertices)
                if dist < nearest_dist or (abs(dist - nearest_dist) <= 1e-7 and tet_id < nearest_id):
                    nearest_id = tet_id
                    nearest_dist = dist
                    nearest_min_views = min_views

            if nearest_id < 0:
                classification = "unknown"
            elif nearest_min_views >= measured_min and nearest_dist <= max_dist:
                classification = "measured"
            elif nearest_min_views >= estimated_min:
                classification = "estimated"
            else:
                classification = "unknown"

            classifications[patch_id] = classification
            if classification == "measured":
                measured_count += 1
            elif classification == "estimated":
                estimated_count += 1
            else:
                unknown_count += 1

        total = measured_count + estimated_count + unknown_count
        unknown_ratio = (unknown_count / total) if total > 0 else 0.0
        max_unknown_ratio_observed = max(max_unknown_ratio_observed, unknown_ratio)
        sample_reports.append(
            {
                "name": name,
                "measuredCount": measured_count,
                "estimatedCount": estimated_count,
                "unknownCount": unknown_count,
                "unknownRatio": unknown_ratio,
                "classifications": classifications,
            }
        )

        expected = sample.get("expected", {})
        for key, actual in (
            ("measuredCount", measured_count),
            ("estimatedCount", estimated_count),
            ("unknownCount", unknown_count),
        ):
            if key in expected and int(expected.get(key)) != actual:
                errors.append(f"{name}:{key} expected={expected.get(key)} actual={actual}")

        expected_map = expected.get("classificationByPatch", {})
        if isinstance(expected_map, dict):
            for patch_id, expected_class in expected_map.items():
                actual_class = classifications.get(str(patch_id))
                if actual_class != str(expected_class):
                    errors.append(
                        f"{name}:patch={patch_id} expected_class={expected_class} actual_class={actual_class}"
                    )

    if max_unknown_ratio_observed > unknown_ratio_threshold:
        errors.append(
            "tri_tet max unknown ratio exceeded: "
            f"observed={max_unknown_ratio_observed:.6f} threshold={unknown_ratio_threshold:.6f}"
        )

    report: Dict[str, Any] = {
        "totalSamples": len(samples),
        "maxUnknownRatioObserved": max_unknown_ratio_observed,
        "unknownRatioThreshold": unknown_ratio_threshold,
        "sampleReports": sample_reports,
        "failureReasons": errors,
        "passesGate": len(errors) == 0,
    }
    write_json(TRI_TET_OUTPUT_PATH, report)

    TRI_TET_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    status = "PASS" if report["passesGate"] else "FAIL"
    lines = [
        f"Phase 14 深度验收: {status}",
        f"tri_tet_runtime_gate: {'pass' if report['passesGate'] else 'failed'}",
        f"self-heal loop: {'pass' if report['passesGate'] else 'failed'}",
        f"samples={report['totalSamples']}",
        f"max_unknown_ratio_observed={report['maxUnknownRatioObserved']:.6f}",
        f"unknown_ratio_threshold={report['unknownRatioThreshold']:.6f}",
    ]
    if errors:
        lines.append("errors:")
        lines.extend(f"- {reason}" for reason in errors)
    TRI_TET_LOG_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report, errors


def print_first_scan_result(report: Dict[str, Any], errors: Sequence[str]) -> int:
    if errors:
        print("first-scan-runtime-kpi: fixture mismatch/errors detected")
        for error in errors:
            print(f"  - {error}")
        return 1

    if not report["passesGate"]:
        print("first-scan-runtime-kpi: KPI thresholds failed")
        print(json.dumps(report, indent=2, ensure_ascii=True))
        return 1

    print("first-scan-runtime-kpi: pass")
    print(json.dumps(report, ensure_ascii=True))
    return 0


def print_tri_tet_result(report: Dict[str, Any], errors: Sequence[str]) -> int:
    if errors or not report.get("passesGate"):
        print("tri-tet-runtime-gate: failed")
        for error in errors:
            print(f"  - {error}")
        print(json.dumps(report, ensure_ascii=True))
        return 1
    print("tri-tet-runtime-gate: pass")
    print(json.dumps(report, ensure_ascii=True))
    return 0


def main() -> int:
    args = parse_args()
    thresholds = thresholds_from_registry()
    overrides = load_profile_overrides(args.profile, Path(args.runtime_parameter_table))
    first_scan_target_seconds = float(overrides.get("first_scan_target_seconds", 180.0))
    hard_cap_seconds = float(overrides.get("hard_cap_seconds", 900.0))
    tri_tet_max_unknown_ratio = overrides.get("tri_tet_max_unknown_ratio")

    if args.tri_tet_only:
        tri_report, tri_errors = run_tri_tet_runtime_gate(
            thresholds,
            unknown_ratio_override=tri_tet_max_unknown_ratio,
        )
        return print_tri_tet_result(tri_report, tri_errors)

    kpi_report, kpi_errors = run_first_scan_kpi(
        thresholds,
        first_scan_target_seconds=first_scan_target_seconds,
        hard_cap_seconds=hard_cap_seconds,
        overrides=overrides,
    )
    kpi_rc = print_first_scan_result(kpi_report, kpi_errors)

    if args.with_tri_tet:
        tri_report, tri_errors = run_tri_tet_runtime_gate(
            thresholds,
            unknown_ratio_override=tri_tet_max_unknown_ratio,
        )
        tri_rc = print_tri_tet_result(tri_report, tri_errors)
        return 1 if (kpi_rc != 0 or tri_rc != 0) else 0

    return kpi_rc


if __name__ == "__main__":
    raise SystemExit(main())
