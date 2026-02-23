#!/usr/bin/env python3
"""Execute governance gates from ci_gate_matrix.json.

This runner is used by Cursor phase runbooks to enforce batch-level gate sweeps.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence

ROOT = Path(__file__).resolve().parents[2]
GOV_DIR = ROOT / "governance"
SEVERITY_RANK = {"info": 0, "warning": 1, "error": 2}


def build_runner_env() -> Dict[str, str]:
    env = os.environ.copy()
    cache_dir = ROOT / ".cache"
    clang_cache_dir = cache_dir / "clang" / "ModuleCache"
    swiftpm_module_cache_dir = cache_dir / "swiftpm" / "ModuleCache"

    for path in (
        clang_cache_dir,
        swiftpm_module_cache_dir,
    ):
        path.mkdir(parents=True, exist_ok=True)

    # Keep module caches inside workspace-writable locations.
    env["XDG_CACHE_HOME"] = str(cache_dir)
    env["CLANG_MODULE_CACHE_PATH"] = str(clang_cache_dir)
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(swiftpm_module_cache_dir)
    return env


def normalize_command(command: str) -> str:
    """Inject sandbox-safe flags for SwiftPM commands in constrained environments."""
    stripped = command.strip()
    if not stripped.startswith("swift "):
        return command
    try:
        parts = shlex.split(command)
    except ValueError:
        return command
    if len(parts) < 2:
        return command
    swift_subcommand = parts[1]
    if swift_subcommand not in {"build", "run", "test", "package"}:
        return command
    if "--disable-sandbox" in parts:
        return command
    parts.insert(2, "--disable-sandbox")
    return shlex.join(parts)


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run governance gates from ci_gate_matrix.json")
    parser.add_argument("--phase-id", type=int, help="Run required gates for one phase id.")
    parser.add_argument(
        "--full-sweep",
        action="store_true",
        help="Run all gates in ci_gate_matrix.json after severity filtering.",
    )
    parser.add_argument(
        "--min-severity",
        choices=["info", "warning", "error"],
        default="error",
        help="Lowest severity to include in execution.",
    )
    parser.add_argument(
        "--skip-gate-id",
        action="append",
        default=[],
        help="Gate id to skip (can be repeated).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing them.",
    )
    return parser.parse_args()


def gate_selected(severity: str, min_severity: str) -> bool:
    return SEVERITY_RANK.get(severity, -1) >= SEVERITY_RANK[min_severity]


def collect_gate_ids(
    *,
    full_sweep: bool,
    phase_id: int | None,
    phase_plan: Dict[str, Any],
    gate_matrix: Dict[str, Any],
    min_severity: str,
    skipped: Sequence[str],
) -> List[str]:
    gates = gate_matrix.get("gates", [])
    gate_by_id = {gate.get("id"): gate for gate in gates if isinstance(gate.get("id"), str)}
    skip_set = {gate_id for gate_id in skipped if gate_id}

    if full_sweep:
        ordered = sorted(gate_by_id.keys())
    else:
        if phase_id is None:
            raise SystemExit("Specify --phase-id or --full-sweep.")
        phase = next((item for item in phase_plan.get("phases", []) if item.get("id") == phase_id), None)
        if phase is None:
            raise SystemExit(f"Unknown phase id: {phase_id}")
        ordered = [gate_id for gate_id in phase.get("required_gate_ids", []) if isinstance(gate_id, str)]

    selected: List[str] = []
    for gate_id in ordered:
        if gate_id in skip_set:
            continue
        gate = gate_by_id.get(gate_id)
        if gate is None:
            raise SystemExit(f"Gate id not found in ci_gate_matrix.json: {gate_id}")
        if not gate_selected(str(gate.get("severity", "info")), min_severity):
            continue
        selected.append(gate_id)
    return selected


def run_commands(
    gate_ids: Sequence[str],
    gate_matrix: Dict[str, Any],
    *,
    dry_run: bool,
) -> int:
    gate_by_id = {
        gate.get("id"): gate
        for gate in gate_matrix.get("gates", [])
        if isinstance(gate.get("id"), str)
    }
    failed: List[str] = []

    runner_env = build_runner_env()

    for gate_id in gate_ids:
        gate = gate_by_id[gate_id]
        print(f"[gate:{gate_id}] {gate.get('name', '<unnamed>')}")
        commands = gate.get("commands", [])
        for command in commands:
            normalized = normalize_command(command)
            print(f"  $ {normalized}")
            if dry_run:
                continue
            rc = subprocess.run(normalized, cwd=ROOT, shell=True, env=runner_env).returncode
            if rc != 0:
                failed.append(f"{gate_id}: {normalized} (rc={rc})")
                print(f"  ! failed: rc={rc}")
                break

    print(
        "gate-matrix-runner:",
        f"executed={len(gate_ids)}",
        f"failed={len(failed)}",
    )
    if failed:
        print("failed-commands:")
        for item in failed:
            print(f" - {item}")
        return 1
    return 0


def main() -> int:
    args = parse_args()
    gate_matrix = load_json(GOV_DIR / "ci_gate_matrix.json")
    phase_plan = load_json(GOV_DIR / "phase_plan.json")

    gate_ids = collect_gate_ids(
        full_sweep=bool(args.full_sweep),
        phase_id=args.phase_id,
        phase_plan=phase_plan,
        gate_matrix=gate_matrix,
        min_severity=args.min_severity,
        skipped=args.skip_gate_id,
    )

    if not gate_ids:
        print("gate-matrix-runner: no gates selected")
        return 0

    return run_commands(gate_ids, gate_matrix, dry_run=bool(args.dry_run))


if __name__ == "__main__":
    raise SystemExit(main())
