#!/usr/bin/env python3
"""Run full phase pipeline sequentially with hard stop on failure.

This runner orchestrates:
1) required gates per phase (via run_gate_matrix.py)
2) deliverable checks
3) adaptation checks (governance diagnostics + first-scan KPI when applicable)
4) machine-readable phase reports and run manifest
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
GOV_DIR = ROOT / "governance"
DEFAULT_PLAN = GOV_DIR / "phase_plan.json"
DEFAULT_STATE = GOV_DIR / "generated" / "phases" / "pipeline_state.json"
DEFAULT_REPORT_DIR = GOV_DIR / "generated" / "phases" / "pipeline_reports"
DEFAULT_MANIFEST = GOV_DIR / "generated" / "phases" / "pipeline_manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run full phase pipeline sequentially (hard stop on failure)."
    )
    parser.add_argument(
        "--phase-plan",
        default=str(DEFAULT_PLAN),
        help="Path to phase_plan.json",
    )
    parser.add_argument(
        "--from-phase",
        type=int,
        help="Start phase id (inclusive). Default: plan minimum id.",
    )
    parser.add_argument(
        "--to-phase",
        type=int,
        help="End phase id (inclusive). Default: plan maximum id.",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume from pipeline state (starts after highest completed phase).",
    )
    parser.add_argument(
        "--fresh-state",
        action="store_true",
        help="Ignore existing state and start from a clean in-memory state.",
    )
    parser.add_argument(
        "--state-file",
        default=str(DEFAULT_STATE),
        help="Path to pipeline state JSON.",
    )
    parser.add_argument(
        "--report-dir",
        default=str(DEFAULT_REPORT_DIR),
        help="Directory for per-phase reports.",
    )
    parser.add_argument(
        "--manifest",
        default=str(DEFAULT_MANIFEST),
        help="Run manifest output path.",
    )
    parser.add_argument(
        "--enforce-deliverables",
        action="store_true",
        help="Fail phase when path-like deliverables are missing.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions only; do not execute gates.",
    )
    parser.add_argument(
        "--skip-strict-completion",
        action="store_true",
        help="Skip strict phase completion validator (not recommended).",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"Missing required file: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}")


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def looks_like_path(deliverable: str) -> bool:
    if not deliverable or deliverable.isspace():
        return False
    if any(ch in deliverable for ch in ("*", "/", ".")):
        return True
    token = deliverable.lower()
    return token.endswith(("json", "md", "txt", "log"))


def match_deliverables(deliverables: Sequence[str]) -> Dict[str, Any]:
    matched: List[str] = []
    missing: List[str] = []
    informational: List[str] = []
    for item in deliverables:
        if not looks_like_path(item):
            informational.append(item)
            continue
        pattern = str(ROOT / item)
        hits = sorted(glob.glob(pattern))
        if hits:
            matched.append(item)
        else:
            missing.append(item)
    return {
        "matched": matched,
        "missing": missing,
        "informational": informational,
    }


def run_gate_phase(phase_id: int, dry_run: bool) -> Tuple[int, str]:
    cmd = [
        "python3",
        "governance/scripts/run_gate_matrix.py",
        "--phase-id",
        str(phase_id),
        "--min-severity",
        "info",
    ]
    if dry_run:
        cmd.append("--dry-run")
        return 0, " ".join(cmd)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def run_strict_phase_completion(phase_id: int, dry_run: bool) -> Tuple[int, str]:
    cmd = [
        "python3",
        "governance/scripts/validate_phase_completion.py",
        "--phase-id",
        str(phase_id),
    ]
    if dry_run:
        cmd.append("--dry-run")
        return 0, " ".join(cmd)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def read_governance_diagnostics() -> Dict[str, Any]:
    path = GOV_DIR / "generated" / "governance_diagnostics.json"
    if not path.exists():
        return {"exists": False}
    payload = load_json(path)
    summary = payload.get("summary", {})
    return {
        "exists": True,
        "path": str(path.relative_to(ROOT)),
        "summary": {
            "error": int(summary.get("error", 0) or 0),
            "warning": int(summary.get("warning", 0) or 0),
            "info": int(summary.get("info", 0) or 0),
        },
        "findings": payload.get("findings", []),
    }


def read_first_scan_metrics() -> Dict[str, Any]:
    path = GOV_DIR / "generated" / "first_scan_runtime_metrics.json"
    if not path.exists():
        return {"exists": False}
    payload = load_json(path)
    return {
        "exists": True,
        "path": str(path.relative_to(ROOT)),
        "passesGate": bool(payload.get("passesGate", False)),
        "firstScanSuccessRate": payload.get("firstScanSuccessRate"),
        "replayStableRate": payload.get("replayStableRate"),
        "medianDurationSeconds": payload.get("medianDurationSeconds"),
        "hardCapViolations": payload.get("hardCapViolations"),
    }


def phase_adaptation_ok(phase: Dict[str, Any], diagnostics: Dict[str, Any], metrics: Dict[str, Any]) -> Tuple[bool, List[str]]:
    reasons: List[str] = []
    gate_ids = set(phase.get("required_gate_ids", []))

    if "G-CONTRACT-VALIDATOR" in gate_ids:
        if diagnostics.get("exists") is not True:
            reasons.append("missing governance diagnostics report")
        elif int(diagnostics.get("summary", {}).get("error", 0)) > 0:
            reasons.append("governance diagnostics has error findings")

    kpi_gates = {"G-FIRST-SCAN-SUCCESS-KPI", "G-PURE-VISION-RUNTIME-FIXTURE"}
    if gate_ids & kpi_gates:
        if metrics.get("exists") is not True:
            reasons.append("missing first-scan runtime metrics report")
        elif metrics.get("passesGate") is not True:
            reasons.append("first-scan runtime metrics passesGate=false")

    return len(reasons) == 0, reasons


def read_state(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {
            "updated_at": None,
            "completed_phase_ids": [],
            "failed_phase_ids": [],
            "phase_reports": [],
        }
    return load_json(path)


def ensure_prerequisites(
    phase: Dict[str, Any],
    completed: Sequence[int],
) -> Tuple[bool, List[int]]:
    prereqs = [int(v) for v in phase.get("prerequisite_phase_ids", [])]
    missing = [pid for pid in prereqs if pid not in completed]
    return len(missing) == 0, missing


def main() -> int:
    args = parse_args()
    phase_plan_path = Path(args.phase_plan).resolve()
    state_path = Path(args.state_file).resolve()
    report_dir = Path(args.report_dir).resolve()
    manifest_path = Path(args.manifest).resolve()

    phase_plan = load_json(phase_plan_path)
    phases = sorted(phase_plan.get("phases", []), key=lambda p: int(p.get("id", -1)))
    if not phases:
        raise SystemExit("phase_plan has no phases.")

    min_id = int(phases[0]["id"])
    max_id = int(phases[-1]["id"])

    from_id = int(args.from_phase) if args.from_phase is not None else min_id
    to_id = int(args.to_phase) if args.to_phase is not None else max_id
    if from_id > to_id:
        raise SystemExit("--from-phase must be <= --to-phase")

    state = read_state(state_path)
    if args.dry_run or args.fresh_state:
        completed: List[int] = []
        failed: List[int] = []
    else:
        completed = [int(v) for v in state.get("completed_phase_ids", [])]
        failed = [int(v) for v in state.get("failed_phase_ids", [])]
        failed = [item for item in failed if item not in completed]

    if args.resume and completed:
        resume_from = max(completed) + 1
        from_id = max(from_id, resume_from)

    selected = [p for p in phases if from_id <= int(p["id"]) <= to_id]
    if not selected:
        print("No phases selected.")
        return 0

    run_manifest: Dict[str, Any] = {
        "started_at": now_iso(),
        "phase_plan": str(phase_plan_path),
        "from_phase": from_id,
        "to_phase": to_id,
        "dry_run": bool(args.dry_run),
        "enforce_deliverables": bool(args.enforce_deliverables),
        "strict_completion": not bool(args.skip_strict_completion),
        "results": [],
    }
    run_completed: List[int] = []
    run_failed: List[int] = []

    for phase in selected:
        phase_id = int(phase["id"])
        phase_name = str(phase.get("name", f"phase-{phase_id}"))
        ok_prereq, missing_prereq = ensure_prerequisites(phase, completed)
        phase_report: Dict[str, Any] = {
            "phase_id": phase_id,
            "phase_name": phase_name,
            "started_at": now_iso(),
            "prerequisites_ok": ok_prereq,
            "missing_prerequisites": missing_prereq,
            "required_gate_ids": list(phase.get("required_gate_ids", [])),
            "required_contract_ids": list(phase.get("required_contract_ids", [])),
        }

        print(f"[phase:{phase_id}] {phase_name}")

        if not ok_prereq:
            phase_report["gate_exit_code"] = 1
            phase_report["gate_output"] = "blocked: missing prerequisites"
            phase_report["status"] = "failed"
            phase_report["failed_reasons"] = ["missing prerequisites"]
            phase_report["finished_at"] = now_iso()
            report_path = report_dir / f"phase-{phase_id:02d}-report.json"
            write_json(report_path, phase_report)
            run_manifest["results"].append(phase_report)
            run_failed.append(phase_id)
            break

        gate_rc, gate_output = run_gate_phase(phase_id=phase_id, dry_run=bool(args.dry_run))
        phase_report["gate_exit_code"] = gate_rc
        phase_report["gate_output"] = gate_output

        strict_rc = 0
        strict_output = "skipped"
        if not bool(args.skip_strict_completion):
            strict_rc, strict_output = run_strict_phase_completion(
                phase_id=phase_id,
                dry_run=bool(args.dry_run),
            )
        phase_report["strict_completion_exit_code"] = strict_rc
        phase_report["strict_completion_output"] = strict_output

        deliverable_status = match_deliverables(phase.get("deliverables", []))
        phase_report["deliverables"] = deliverable_status

        diagnostics = read_governance_diagnostics()
        metrics = read_first_scan_metrics()
        phase_report["adaptation"] = {
            "governance_diagnostics": diagnostics,
            "first_scan_metrics": metrics,
        }
        if args.dry_run:
            adaptation_ok = True
            adaptation_reasons = ["dry-run mode"]
        else:
            adaptation_ok, adaptation_reasons = phase_adaptation_ok(phase, diagnostics, metrics)
        phase_report["adaptation_ok"] = adaptation_ok
        phase_report["adaptation_reasons"] = adaptation_reasons

        failed_reasons: List[str] = []
        if gate_rc != 0:
            failed_reasons.append("required gate command failed")
        if strict_rc != 0:
            failed_reasons.append("strict phase completion check failed")
        if bool(args.enforce_deliverables) and deliverable_status["missing"]:
            failed_reasons.append("deliverables missing")
        if not adaptation_ok:
            failed_reasons.append("adaptation checks failed")

        phase_report["status"] = "passed" if not failed_reasons else "failed"
        phase_report["failed_reasons"] = failed_reasons
        phase_report["finished_at"] = now_iso()

        report_path = report_dir / f"phase-{phase_id:02d}-report.json"
        write_json(report_path, phase_report)
        run_manifest["results"].append(phase_report)

        if failed_reasons:
            run_failed.append(phase_id)
            print(f"[phase:{phase_id}] failed: {', '.join(failed_reasons)}")
            break

        print(f"[phase:{phase_id}] passed")
        run_completed.append(phase_id)
        if phase_id not in completed:
            completed.append(phase_id)
        if phase_id in failed:
            failed = [item for item in failed if item != phase_id]

    run_completed = sorted(set(run_completed))
    run_failed = sorted(set(run_failed))
    run_manifest["finished_at"] = now_iso()
    run_manifest["completed_phase_ids"] = run_completed
    run_manifest["failed_phase_ids"] = run_failed
    run_manifest["status"] = "passed" if not run_failed else "failed"
    write_json(manifest_path, run_manifest)

    if not args.dry_run:
        completed = sorted(set(completed))
        failed = sorted(set(failed + run_failed))
        failed = [item for item in failed if item not in completed]

        state["updated_at"] = now_iso()
        state["completed_phase_ids"] = completed
        state["failed_phase_ids"] = failed
        existing_reports = [str(v) for v in state.get("phase_reports", [])]
        new_reports = [
            str((report_dir / f"phase-{int(r['phase_id']):02d}-report.json").resolve())
            for r in run_manifest["results"]
        ]
        state["phase_reports"] = sorted(set(existing_reports + new_reports))
        write_json(state_path, state)

    print(
        "pipeline:",
        f"status={run_manifest['status']}",
        f"completed={len(run_completed)}",
        f"failed={len(run_failed)}",
        f"manifest={manifest_path.relative_to(ROOT)}",
    )
    return 0 if run_manifest["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
