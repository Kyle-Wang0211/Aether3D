#!/usr/bin/env python3
"""Release hard gate: quality floor non-regression + speed non-regression."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / "governance/baselines/release_hard_gate_baseline.json"
DEFAULT_KPI = ROOT / "governance/generated/first_scan_runtime_metrics.json"
DEFAULT_TRI_TET = ROOT / "governance/generated/tri_tet_runtime_metrics.json"
DEFAULT_REPORT = ROOT / "governance/generated/release_hard_gate_report.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate release hard gate.")
    parser.add_argument("--baseline", default=str(DEFAULT_BASELINE), help="Baseline JSON path.")
    parser.add_argument("--kpi", default=str(DEFAULT_KPI), help="Current first-scan KPI report path.")
    parser.add_argument("--tri-tet", default=str(DEFAULT_TRI_TET), help="Current Tri/Tet runtime report path.")
    parser.add_argument("--report", default=str(DEFAULT_REPORT), help="Output report path.")
    parser.add_argument(
        "--require-strict-speed-improvement",
        action="store_true",
        help="Require at least one strict speed improvement (not only equal).",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    baseline = load_json(Path(args.baseline).resolve())
    kpi = load_json(Path(args.kpi).resolve())
    tri_tet = load_json(Path(args.tri_tet).resolve())

    quality = baseline.get("quality_floor", {})
    speed = baseline.get("speed_floor", {})

    violations: List[str] = []

    first_scan_success = float(kpi.get("firstScanSuccessRate", 0.0))
    replay_stable = float(kpi.get("replayStableRate", 0.0))
    tri_tet_unknown_ratio = float(tri_tet.get("maxUnknownRatioObserved", 1.0))
    kpi_passes = bool(kpi.get("passesGate", False))
    tri_tet_passes = bool(tri_tet.get("passesGate", False))

    min_first_scan_success = float(quality.get("first_scan_success_rate", 0.0))
    min_replay_stable = float(quality.get("replay_stable_rate", 0.0))
    max_tri_tet_unknown = float(quality.get("tri_tet_max_unknown_ratio", 1.0))

    if first_scan_success < min_first_scan_success:
        violations.append(
            f"quality_regression:first_scan_success {first_scan_success:.6f} < {min_first_scan_success:.6f}"
        )
    if replay_stable < min_replay_stable:
        violations.append(
            f"quality_regression:replay_stable_rate {replay_stable:.6f} < {min_replay_stable:.6f}"
        )
    if tri_tet_unknown_ratio > max_tri_tet_unknown:
        violations.append(
            f"quality_regression:tri_tet_unknown_ratio {tri_tet_unknown_ratio:.6f} > {max_tri_tet_unknown:.6f}"
        )
    if not kpi_passes:
        violations.append("quality_regression:first_scan_runtime_gate_failed")
    if not tri_tet_passes:
        violations.append("quality_regression:tri_tet_runtime_gate_failed")

    median_duration = float(kpi.get("medianDurationSeconds", 1e12))
    max_duration = float(kpi.get("maxDurationSeconds", 1e12))
    max_median = float(speed.get("median_duration_seconds", 1e12))
    max_max = float(speed.get("max_duration_seconds", 1e12))

    if median_duration > max_median:
        violations.append(f"speed_regression:median_duration {median_duration:.6f} > {max_median:.6f}")
    if max_duration > max_max:
        violations.append(f"speed_regression:max_duration {max_duration:.6f} > {max_max:.6f}")

    strict_improved = (median_duration < max_median) or (max_duration < max_max)
    if args.require_strict_speed_improvement and not strict_improved:
        violations.append("speed_regression:no_strict_improvement")

    payload = {
        "passesGate": len(violations) == 0,
        "violations": violations,
        "baseline": {
            "quality_floor": quality,
            "speed_floor": speed,
        },
        "observed": {
            "first_scan_success_rate": first_scan_success,
            "replay_stable_rate": replay_stable,
            "tri_tet_max_unknown_ratio": tri_tet_unknown_ratio,
            "median_duration_seconds": median_duration,
            "max_duration_seconds": max_duration,
            "strict_speed_improved": strict_improved,
        },
    }
    write_json(Path(args.report).resolve(), payload)

    if payload["passesGate"]:
        print("release-hard-gate: pass")
        print(json.dumps(payload, ensure_ascii=True))
        return 0

    print("release-hard-gate: failed")
    print(json.dumps(payload, ensure_ascii=True))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
