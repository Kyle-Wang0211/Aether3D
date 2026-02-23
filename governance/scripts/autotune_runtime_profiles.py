#!/usr/bin/env python3
"""Nightly runtime profile autotuning.

Flow:
1) Run replay KPI + Tri/Tet gate for forensic/balanced/speed.
2) Run one full gate sweep (error-level) for safety verification.
3) Emit tuned runtime constants per profile into governance/generated/runtime_profiles.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TABLE = ROOT / "governance/runtime/runtime_parameter_master_table_v1.json"
DEFAULT_OUTPUT_DIR = ROOT / "governance/generated/runtime_profiles"
KPI_REPORT = ROOT / "governance/generated/first_scan_runtime_metrics.json"
TRI_TET_REPORT = ROOT / "governance/generated/tri_tet_runtime_metrics.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Autotune runtime profile constants from replay + full gates.")
    parser.add_argument(
        "--table",
        default=str(DEFAULT_TABLE),
        help="Runtime parameter master table JSON path.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help="Directory to write tuned runtime profile constants.",
    )
    parser.add_argument(
        "--skip-full-gate",
        action="store_true",
        help="Skip full gate sweep execution.",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def run_command(command: str) -> Tuple[int, str]:
    proc = subprocess.run(
        command,
        cwd=ROOT,
        shell=True,
        text=True,
        capture_output=True,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def validate_table(table: Dict[str, Any]) -> None:
    params = table.get("parameters", [])
    profiles = table.get("profiles", [])
    if not isinstance(params, list) or not isinstance(profiles, list) or not profiles:
        raise SystemExit("Invalid parameter table: requires non-empty profiles[] and parameters[]")

    for item in params:
        if not isinstance(item, dict):
            continue
        pid = item.get("id", "<missing>")
        bounds = item.get("bounds", {})
        values = item.get("values", {})
        if not isinstance(bounds, dict) or not isinstance(values, dict):
            raise SystemExit(f"Invalid parameter entry: {pid}")
        min_v = bounds.get("min")
        max_v = bounds.get("max")
        if not isinstance(min_v, (int, float)) or not isinstance(max_v, (int, float)):
            raise SystemExit(f"Invalid bounds for parameter: {pid}")
        for profile in profiles:
            val = values.get(profile)
            if not isinstance(val, (int, float)):
                raise SystemExit(f"Missing value for parameter={pid}, profile={profile}")
            if not (float(min_v) <= float(val) <= float(max_v)):
                raise SystemExit(
                    f"Parameter out of bounds: {pid} profile={profile} value={val} bounds=[{min_v},{max_v}]"
                )


def extract_profile_values(table: Dict[str, Any], profile: str) -> Dict[str, float]:
    out: Dict[str, float] = {}
    for item in table.get("parameters", []):
        if not isinstance(item, dict):
            continue
        pid = item.get("id")
        values = item.get("values")
        if isinstance(pid, str) and isinstance(values, dict) and isinstance(values.get(profile), (int, float)):
            out[pid] = float(values[profile])
    return out


def compute_scores(
    *,
    profile_values: Dict[str, float],
    kpi: Dict[str, Any],
    tri_tet: Dict[str, Any],
) -> Dict[str, float]:
    success = float(kpi.get("firstScanSuccessRate", 0.0))
    replay = float(kpi.get("replayStableRate", 0.0))
    unknown_ratio = float(tri_tet.get("maxUnknownRatioObserved", 1.0))
    agreement = 1.0  # Placeholder until cross-validation aggregate report is connected.

    target_duration = max(1.0, profile_values.get("first_scan.target_duration_seconds", 180.0))
    hard_cap = max(1.0, profile_values.get("first_scan.hard_cap_seconds", 900.0))
    median_duration = float(kpi.get("medianDurationSeconds", target_duration))
    max_duration = float(kpi.get("maxDurationSeconds", hard_cap))

    normalized_median = min(2.0, median_duration / target_duration)
    normalized_max = min(2.0, max_duration / hard_cap)
    normalized_throughput = 0.5  # Placeholder until upload throughput metric is wired.

    quality_score = (
        0.50 * success
        + 0.20 * replay
        + 0.20 * max(0.0, 1.0 - unknown_ratio)
        + 0.10 * agreement
    )
    speed_score = (
        0.60 * min(1.0, max(0.0, 1.0 - (normalized_median - 1.0)))
        + 0.20 * min(1.0, max(0.0, 1.0 - (normalized_max - 1.0)))
        + 0.20 * normalized_throughput
    )
    return {
        "quality_score": round(quality_score, 6),
        "speed_score": round(speed_score, 6),
    }


def tune_profile_values(profile: str, values: Dict[str, float], kpi: Dict[str, Any]) -> Dict[str, float]:
    tuned = dict(values)
    target_duration_key = "first_scan.target_duration_seconds"
    target_success_key = "first_scan.target_success_rate"
    if target_duration_key not in tuned or target_success_key not in tuned:
        return tuned

    observed_success = float(kpi.get("firstScanSuccessRate", 0.0))
    target_success = tuned[target_success_key]
    duration = tuned[target_duration_key]

    if profile == "speed" and observed_success >= target_success + 0.03:
        tuned[target_duration_key] = max(140.0, duration - 5.0)
    elif profile == "balanced" and observed_success < target_success:
        tuned[target_duration_key] = min(180.0, duration + 5.0)

    return tuned


def run_profile_replay(profile: str, table_path: Path) -> Tuple[Dict[str, Any], Dict[str, Any], int, str]:
    command = (
        f"python3 governance/scripts/eval_first_scan_runtime_kpi.py --with-tri-tet "
        f"--profile {profile} --runtime-parameter-table {table_path}"
    )
    rc, output = run_command(command)
    if not KPI_REPORT.exists() or not TRI_TET_REPORT.exists():
        raise SystemExit(f"Replay outputs missing for profile={profile}\n{output}")
    return load_json(KPI_REPORT), load_json(TRI_TET_REPORT), rc, output


def main() -> int:
    args = parse_args()
    table_path = Path(args.table).resolve()
    output_dir = Path(args.output_dir).resolve()
    table = load_json(table_path)
    validate_table(table)

    profiles = [str(p) for p in table.get("profiles", [])]
    run_started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    manifest: Dict[str, Any] = {
        "metadata": {
            "run_started_at_utc": run_started_at,
            "table_path": str(table_path.relative_to(ROOT)),
            "full_gate_sweep_rc": 0,
        },
        "profiles": {},
    }

    for profile in profiles:
        base_values = extract_profile_values(table, profile)
        kpi_report, tri_tet_report, replay_rc, replay_output = run_profile_replay(profile, table_path)
        tuned_values = tune_profile_values(profile, base_values, kpi_report)
        scores = compute_scores(profile_values=tuned_values, kpi=kpi_report, tri_tet=tri_tet_report)
        payload = {
            "profile": profile,
            "source_table": str(table_path.relative_to(ROOT)),
            "replay_rc": replay_rc,
            "tuned_values": tuned_values,
            "scores": scores,
            "runtime_metrics": {
                "first_scan_success_rate": kpi_report.get("firstScanSuccessRate"),
                "replay_stable_rate": kpi_report.get("replayStableRate"),
                "median_duration_seconds": kpi_report.get("medianDurationSeconds"),
                "max_duration_seconds": kpi_report.get("maxDurationSeconds"),
                "tri_tet_max_unknown_ratio_observed": tri_tet_report.get("maxUnknownRatioObserved"),
            },
            "replay_output_tail": replay_output[-2000:],
        }
        write_json(output_dir / f"{profile}.json", payload)
        manifest["profiles"][profile] = {
            "replay_rc": replay_rc,
            "scores": scores,
            "output": str((output_dir / f"{profile}.json").relative_to(ROOT)),
        }
        if profile == "balanced" and replay_rc != 0:
            write_json(output_dir / "runtime_profiles_manifest.json", manifest)
            raise SystemExit("Balanced profile replay gate failed during autotune run.")

    if not args.skip_full_gate:
        cmd = (
            "python3 governance/scripts/run_gate_matrix.py --full-sweep --min-severity error "
            "--skip-gate-id G-FULL-GATE-SWEEP"
        )
        rc, output = run_command(cmd)
        manifest["metadata"]["full_gate_sweep_rc"] = rc
        manifest["metadata"]["full_gate_sweep_output_tail"] = output[-4000:]
        if rc != 0:
            write_json(output_dir / "runtime_profiles_manifest.json", manifest)
            raise SystemExit("Full gate sweep failed during nightly autotune run.")

    write_json(output_dir / "runtime_profiles_manifest.json", manifest)
    print("runtime-profile-autotune: pass")
    print(json.dumps(manifest, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
