#!/usr/bin/env python3
"""Golden replay guard for Tier-A/Tier-B consistency artifacts.

Tier-A: fixture file hashes must match manifest.
Tier-B: optional floating diff report must stay within epsilon.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "fixtures/manifest.json"
DEFAULT_OUTPUT = ROOT / "governance/generated/golden_replay_report.json"


def sha256_hex(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate golden replay fixture consistency")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tier-b-diff", type=Path, default=None)
    parser.add_argument("--tier-b-epsilon", type=float, default=1e-5)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def compute_tier_b_max_abs(diff_path: Path | None) -> float:
    if diff_path is None or not diff_path.exists():
        return 0.0
    obj = load_json(diff_path)
    values: list[float] = []

    def collect(node: Any) -> None:
        if isinstance(node, (int, float)):
            values.append(abs(float(node)))
            return
        if isinstance(node, list):
            for item in node:
                collect(item)
            return
        if isinstance(node, dict):
            for item in node.values():
                collect(item)

    collect(obj)
    return max(values) if values else 0.0


def main() -> int:
    args = parse_args()
    manifest = load_json(args.manifest)
    fixtures = manifest.get("fixtures", [])
    mismatches: list[dict[str, str]] = []

    for fixture in fixtures:
        rel = fixture.get("relativePath")
        expected = fixture.get("fileHashHex")
        if not isinstance(rel, str) or not isinstance(expected, str):
            continue
        path = ROOT / rel
        if not path.exists():
            mismatches.append(
                {
                    "relativePath": rel,
                    "expected": expected,
                    "actual": "missing",
                }
            )
            continue
        actual = sha256_hex(path)
        if actual.lower() != expected.lower():
            mismatches.append(
                {
                    "relativePath": rel,
                    "expected": expected,
                    "actual": actual,
                }
            )

    tier_b_max_abs = compute_tier_b_max_abs(args.tier_b_diff)
    tier_a_pass = len(mismatches) == 0
    tier_b_pass = tier_b_max_abs <= args.tier_b_epsilon

    report = {
        "manifest": str(args.manifest.relative_to(ROOT)),
        "fixtureCount": len(fixtures),
        "tierA": {
            "bitExact": tier_a_pass,
            "mismatchCount": len(mismatches),
            "mismatches": mismatches,
        },
        "tierB": {
            "epsilon": args.tier_b_epsilon,
            "maxAbsDiff": tier_b_max_abs,
            "pass": tier_b_pass,
            "diffSource": None if args.tier_b_diff is None else str(args.tier_b_diff),
        },
        "pass": bool(tier_a_pass and tier_b_pass),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")

    print(f"golden-replay: fixtures={len(fixtures)} mismatches={len(mismatches)} tierB_max={tier_b_max_abs:.8f}")
    print(f"golden-replay: report={args.output}")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
