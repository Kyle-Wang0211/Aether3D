#!/usr/bin/env python3
"""Shadow dual-run evaluator with stop-loss and cutover decision artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / "governance/generated/first_scan_runtime_metrics.json"
DEFAULT_CANDIDATE = ROOT / "governance/generated/first_scan_runtime_metrics.json"
DEFAULT_THRESHOLDS = ROOT / "governance/runtime/shadow_cutover_thresholds_v1.json"
DEFAULT_OUTPUT_DIR = ROOT / "governance/generated"
DEFAULT_GOLDEN_REPORT = ROOT / "governance/generated/golden_replay_report.json"


def load_json(path: Path, default: dict[str, Any] | None = None) -> dict[str, Any]:
    if not path.exists():
        if default is not None:
            return default
        raise FileNotFoundError(f"missing json: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def normalize_metrics(obj: dict[str, Any]) -> dict[str, float]:
    # Preferred schema:
    # p50_ms, p95_ms, p99_ms, memory_peak_mb, power_avg_w, crash_free_rate,
    # nan_count, inf_count.
    p50 = safe_float(obj.get("p50_ms"), safe_float(obj.get("medianDurationSeconds"), 0.0) * 1000.0)
    p95 = safe_float(obj.get("p95_ms"), p50)
    p99 = safe_float(obj.get("p99_ms"), p95)
    memory = safe_float(obj.get("memory_peak_mb"), safe_float(obj.get("memoryUsageMB"), 0.0))
    power = safe_float(obj.get("power_avg_w"), safe_float(obj.get("powerWatts"), 0.0))
    crash_free = safe_float(obj.get("crash_free_rate"), safe_float(obj.get("firstScanSuccessRate"), 1.0))
    nan_count = safe_float(obj.get("nan_count"), 0.0)
    inf_count = safe_float(obj.get("inf_count"), 0.0)
    return {
        "p50_ms": p50,
        "p95_ms": p95,
        "p99_ms": p99,
        "memory_peak_mb": memory,
        "power_avg_w": power,
        "crash_free_rate": crash_free,
        "nan_count": nan_count,
        "inf_count": inf_count,
    }


def ratio(numerator: float, denominator: float) -> float:
    if denominator <= 1e-9:
        return 1.0
    return numerator / denominator


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate shadow run and emit cutover decision artifacts")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--candidate", type=Path, default=DEFAULT_CANDIDATE)
    parser.add_argument("--thresholds", type=Path, default=DEFAULT_THRESHOLDS)
    parser.add_argument("--golden-report", type=Path, default=DEFAULT_GOLDEN_REPORT)
    parser.add_argument("--diff-input", type=Path, default=None)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--require-guard-pass", action="store_true")
    parser.add_argument("--require-cutover", action="store_true")
    args = parser.parse_args()

    baseline_raw = load_json(args.baseline, default={})
    candidate_raw = load_json(args.candidate, default={})
    thresholds = load_json(args.thresholds, default={})

    baseline = normalize_metrics(baseline_raw)
    candidate = normalize_metrics(candidate_raw)

    tier_a_bit_exact = True
    tier_b_max_abs_diff = 0.0
    if args.golden_report.exists():
        report = load_json(args.golden_report)
        tier_a_bit_exact = bool(report.get("tierA", {}).get("bitExact", True))
        tier_b_max_abs_diff = safe_float(report.get("tierB", {}).get("maxAbsDiff"), 0.0)

    if args.diff_input is not None and args.diff_input.exists():
        diff_payload = load_json(args.diff_input)
    else:
        diff_payload = {
            "tierA_bitExact": tier_a_bit_exact,
            "tierB_maxAbsDiff": tier_b_max_abs_diff,
        }

    p50_ratio = ratio(candidate["p50_ms"], baseline["p50_ms"])
    p95_ratio = ratio(candidate["p95_ms"], baseline["p95_ms"])
    p99_ratio = ratio(candidate["p99_ms"], baseline["p99_ms"])
    memory_ratio = ratio(candidate["memory_peak_mb"], baseline["memory_peak_mb"] if baseline["memory_peak_mb"] > 0 else 1.0)
    power_ratio = ratio(candidate["power_avg_w"], baseline["power_avg_w"] if baseline["power_avg_w"] > 0 else 1.0)
    crash_free_drop = baseline["crash_free_rate"] - candidate["crash_free_rate"]

    epsilon = safe_float(thresholds.get("tier_b_epsilon"), 1e-5)
    p95_limit = safe_float(thresholds.get("p95_regression_max_ratio"), 1.03)
    p99_limit = safe_float(thresholds.get("p99_regression_max_ratio"), 1.05)
    crash_limit = safe_float(thresholds.get("crash_free_drop_max_abs"), 0.001)
    benefit = thresholds.get("positive_benefit", {})
    p50_gain = safe_float(benefit.get("p50_gain_min_ratio"), 0.05)
    p95_gain = safe_float(benefit.get("p95_gain_min_ratio"), 0.03)
    memory_drop = safe_float(benefit.get("memory_drop_min_ratio"), 0.05)
    power_drop = safe_float(benefit.get("power_drop_min_ratio"), 0.03)

    pass_correctness = tier_a_bit_exact and tier_b_max_abs_diff <= epsilon
    pass_stability = p95_ratio <= p95_limit and p99_ratio <= p99_limit and crash_free_drop <= crash_limit
    pass_safety = candidate["nan_count"] == 0.0 and candidate["inf_count"] == 0.0

    has_positive_benefit = (
        (1.0 - p50_ratio) >= p50_gain
        or ((1.0 - p95_ratio) >= p95_gain and p99_ratio <= 1.0)
        or (1.0 - memory_ratio) >= memory_drop
        or (1.0 - power_ratio) >= power_drop
    )

    can_cutover = bool(pass_correctness and pass_stability and pass_safety and has_positive_benefit)

    reasons: list[str] = []
    if not pass_correctness:
        reasons.append("correctness_not_met")
    if not pass_stability:
        reasons.append("stability_not_met")
    if not pass_safety:
        reasons.append("safety_not_met")
    if not has_positive_benefit:
        reasons.append("no_positive_benefit")

    metrics_out = {
        "baseline": baseline,
        "candidate": candidate,
        "ratios": {
            "p50_ratio": p50_ratio,
            "p95_ratio": p95_ratio,
            "p99_ratio": p99_ratio,
            "memory_ratio": memory_ratio,
            "power_ratio": power_ratio,
        },
        "crash_free_drop": crash_free_drop,
    }
    decision_out = {
        "pass_correctness": pass_correctness,
        "pass_stability": pass_stability,
        "pass_safety": pass_safety,
        "has_positive_benefit": has_positive_benefit,
        "can_cutover": can_cutover,
        "reasons": reasons,
        "thresholds": thresholds,
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "shadow_diff.json").write_text(
        json.dumps(diff_payload, indent=2, sort_keys=True), encoding="utf-8"
    )
    (args.output_dir / "shadow_metrics.json").write_text(
        json.dumps(metrics_out, indent=2, sort_keys=True), encoding="utf-8"
    )
    (args.output_dir / "cutover_decision.json").write_text(
        json.dumps(decision_out, indent=2, sort_keys=True), encoding="utf-8"
    )

    print(f"shadow-cutover: pass_correctness={pass_correctness} pass_stability={pass_stability} pass_safety={pass_safety}")
    print(f"shadow-cutover: positive_benefit={has_positive_benefit} can_cutover={can_cutover}")
    print(f"shadow-cutover: output_dir={args.output_dir}")

    if args.require_guard_pass and not (pass_correctness and pass_stability and pass_safety):
        return 1
    if args.require_cutover and not can_cutover:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
