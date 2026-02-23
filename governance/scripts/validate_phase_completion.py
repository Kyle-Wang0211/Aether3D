#!/usr/bin/env python3
"""Strict phase completion validator.

Purpose:
- Enforce that a phase is not only gate-passed but also algorithm-complete by
  explicit per-phase contracts.
- Contracts are defined in governance/phase_completion_contracts.json.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Sequence

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS_PATH = ROOT / "governance" / "phase_completion_contracts.json"
DEFAULT_REPORT_DIR = ROOT / "governance" / "generated" / "phases" / "strict_phase_reports"


@dataclass
class CheckFailure:
    code: str
    message: str
    context: Dict[str, Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate strict phase completion contracts.")
    parser.add_argument("--phase-id", type=int, required=True, help="Phase id to validate.")
    parser.add_argument(
        "--contracts",
        default=str(CONTRACTS_PATH),
        help="Path to phase completion contracts JSON.",
    )
    parser.add_argument(
        "--report-dir",
        default=str(DEFAULT_REPORT_DIR),
        help="Directory to write strict completion JSON report.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Skip command execution and only validate static checks.",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"Missing JSON file: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON at {path}: {exc}")


def write_report(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def build_runner_env() -> Dict[str, str]:
    env = os.environ.copy()
    cache_dir = ROOT / ".cache"
    clang_cache_dir = cache_dir / "clang" / "ModuleCache"
    swiftpm_module_cache_dir = cache_dir / "swiftpm" / "ModuleCache"
    for path in (clang_cache_dir, swiftpm_module_cache_dir):
        path.mkdir(parents=True, exist_ok=True)
    env["XDG_CACHE_HOME"] = str(cache_dir)
    env["CLANG_MODULE_CACHE_PATH"] = str(clang_cache_dir)
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(swiftpm_module_cache_dir)
    return env


def normalize_command(command: str) -> str:
    stripped = command.strip()
    if not stripped.startswith("swift "):
        return command
    try:
        parts = shlex.split(command)
    except ValueError:
        return command
    if len(parts) < 2:
        return command
    if parts[1] in {"build", "run", "test", "package"} and "--disable-sandbox" not in parts:
        parts.insert(2, "--disable-sandbox")
        return shlex.join(parts)
    return command


def resolve_phase_contract(contracts: Dict[str, Any], phase_id: int) -> Dict[str, Any]:
    phases = contracts.get("phases", [])
    for phase in phases:
        if int(phase.get("id", -1)) == phase_id:
            return phase
    raise SystemExit(f"Phase completion contract not found for phase id: {phase_id}")


def check_required_paths(required_paths: Sequence[str], failures: List[CheckFailure]) -> List[Dict[str, Any]]:
    checks: List[Dict[str, Any]] = []
    for pattern in required_paths:
        matches = sorted(glob.glob(str(ROOT / pattern), recursive=True))
        ok = len(matches) > 0
        checks.append({"pattern": pattern, "matched_count": len(matches), "ok": ok})
        if not ok:
            failures.append(
                CheckFailure(
                    code="REQUIRED_PATH_MISSING",
                    message="Required path pattern has no matches",
                    context={"pattern": pattern},
                )
            )
    return checks


def run_required_commands(commands: Sequence[str], dry_run: bool, failures: List[CheckFailure]) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    runner_env = build_runner_env()
    for command in commands:
        normalized = normalize_command(command)
        if dry_run:
            results.append({"command": normalized, "rc": 0, "ok": True, "output": "<dry-run>"})
            continue
        proc = subprocess.run(normalized, cwd=ROOT, shell=True, capture_output=True, text=True, env=runner_env)
        output = (proc.stdout or "") + (proc.stderr or "")
        ok = proc.returncode == 0
        results.append({"command": normalized, "rc": proc.returncode, "ok": ok, "output": output})
        if not ok:
            failures.append(
                CheckFailure(
                    code="REQUIRED_COMMAND_FAILED",
                    message="Required command failed",
                    context={"command": normalized, "rc": proc.returncode},
                )
            )
            # Fail-fast for command chain clarity.
            break
    return results


def check_forbidden_regex(
    checks: Sequence[Dict[str, Any]],
    failures: List[CheckFailure],
) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for item in checks:
        pattern = str(item.get("glob", ""))
        regex = str(item.get("regex", ""))
        description = str(item.get("description", "forbidden regex check"))
        files = sorted(glob.glob(str(ROOT / pattern), recursive=True))
        matched_entries: List[Dict[str, Any]] = []

        if not files:
            failures.append(
                CheckFailure(
                    code="FORBIDDEN_CHECK_NO_FILES",
                    message="Forbidden-regex check matched zero files",
                    context={"glob": pattern, "description": description},
                )
            )
            results.append(
                {
                    "glob": pattern,
                    "regex": regex,
                    "description": description,
                    "ok": False,
                    "files_scanned": 0,
                    "violations": [],
                }
            )
            continue

        compiled = re.compile(regex)
        for file_path in files:
            path = Path(file_path)
            try:
                content = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                failures.append(
                    CheckFailure(
                        code="FORBIDDEN_CHECK_READ_ERROR",
                        message="Unable to read file for forbidden-regex check",
                        context={"file": str(path.relative_to(ROOT)), "glob": pattern},
                    )
                )
                continue
            for match in compiled.finditer(content):
                matched_entries.append(
                    {
                        "file": str(path.relative_to(ROOT)),
                        "match": match.group(0),
                        "offset": match.start(),
                    }
                )

        ok = len(matched_entries) == 0
        if not ok:
            failures.append(
                CheckFailure(
                    code="FORBIDDEN_REGEX_HIT",
                    message="Forbidden pattern detected in phase files",
                    context={
                        "glob": pattern,
                        "regex": regex,
                        "violation_count": len(matched_entries),
                    },
                )
            )

        results.append(
            {
                "glob": pattern,
                "regex": regex,
                "description": description,
                "ok": ok,
                "files_scanned": len(files),
                "violations": matched_entries[:20],
            }
        )
    return results


def check_required_report(
    report_path: str | None,
    report_must_contain: Sequence[str],
    failures: List[CheckFailure],
) -> Dict[str, Any]:
    if not report_path:
        return {"configured": False, "ok": True}

    full_path = ROOT / report_path
    result: Dict[str, Any] = {
        "configured": True,
        "path": report_path,
        "exists": full_path.exists(),
        "ok": True,
        "missing_markers": [],
    }

    if not full_path.exists():
        failures.append(
            CheckFailure(
                code="REQUIRED_REPORT_MISSING",
                message="Required phase report file is missing",
                context={"path": report_path},
            )
        )
        result["ok"] = False
        return result

    text = full_path.read_text(encoding="utf-8", errors="ignore")
    missing = [marker for marker in report_must_contain if marker not in text]
    if missing:
        failures.append(
            CheckFailure(
                code="REQUIRED_REPORT_MARKER_MISSING",
                message="Required marker not found in phase report",
                context={"path": report_path, "missing_markers": missing},
            )
        )
        result["ok"] = False
    result["missing_markers"] = missing
    return result


def main() -> int:
    args = parse_args()
    contracts = load_json(Path(args.contracts).resolve())
    phase_contract = resolve_phase_contract(contracts, args.phase_id)
    failures: List[CheckFailure] = []

    required_paths = [str(v) for v in phase_contract.get("required_paths", [])]
    required_commands = [str(v) for v in phase_contract.get("required_commands", [])]
    forbidden_checks = list(phase_contract.get("forbidden_regex_checks", []))
    required_report_path = phase_contract.get("required_report_path")
    report_must_contain = [str(v) for v in phase_contract.get("report_must_contain", [])]

    path_results = check_required_paths(required_paths, failures)
    command_results = run_required_commands(required_commands, bool(args.dry_run), failures)
    forbidden_results = check_forbidden_regex(forbidden_checks, failures)
    required_report_result = check_required_report(required_report_path, report_must_contain, failures)

    out = {
        "phase_id": args.phase_id,
        "dry_run": bool(args.dry_run),
        "status": "passed" if not failures else "failed",
        "required_paths": path_results,
        "required_commands": command_results,
        "forbidden_regex_checks": forbidden_results,
        "required_report": required_report_result,
        "failures": [
            {"code": f.code, "message": f.message, "context": f.context}
            for f in failures
        ],
    }

    out_path = Path(args.report_dir).resolve() / f"phase-{args.phase_id:02d}-strict.json"
    write_report(out_path, out)
    print(
        "phase-completion-validator:",
        f"phase={args.phase_id}",
        f"status={out['status']}",
        f"report={out_path.relative_to(ROOT)}",
    )
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
