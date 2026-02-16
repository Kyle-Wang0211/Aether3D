#!/usr/bin/env python3
"""Validate protocol governance SSOT artifacts and implementation bindings.

This script is intentionally stdlib-only so it can run in minimal CI environments.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
GOV_DIR = ROOT / "governance"


def find_prompt_file() -> Optional[Path]:
    candidates = [
        ROOT / "CURSOR_MEGA_PROMPT_V2.md",
        ROOT.parent / "CURSOR_MEGA_PROMPT_V2.md",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"Missing required file: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON at {path}: {exc}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate governance contracts and bindings")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on any error severity finding.",
    )
    parser.add_argument(
        "--report",
        default="governance/generated/governance_diagnostics.json",
        help="Output JSON diagnostics report path (workspace-relative).",
    )
    parser.add_argument(
        "--only",
        action="append",
        choices=[
            "registry",
            "phase-order",
            "bindings",
            "structural",
            "flags",
            "flag-namespace",
            "section-order",
            "branch",
            "blur",
        ],
        help="Run only selected validation scopes.",
    )
    parser.add_argument(
        "--check-branch",
        action="store_true",
        help="Only validate branch policy against governance metadata.",
    )
    return parser.parse_args()


def should_run(scopes: Optional[Sequence[str]], scope: str) -> bool:
    return not scopes or scope in scopes


def add_finding(
    findings: List[Dict[str, Any]],
    *,
    fid: str,
    severity: str,
    scope: str,
    message: str,
    context: Optional[Dict[str, Any]] = None,
) -> None:
    finding: Dict[str, Any] = {
        "id": fid,
        "severity": severity,
        "scope": scope,
        "message": message,
    }
    if context:
        finding["context"] = context
    findings.append(finding)


def get_git_branch() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except Exception:
        return "<unknown>"


def ensure_unique_ids(
    items: Iterable[Dict[str, Any]],
    key: str,
    scope: str,
    findings: List[Dict[str, Any]],
) -> None:
    seen: Dict[str, int] = {}
    for idx, item in enumerate(items):
        value = item.get(key)
        if not isinstance(value, str) or not value:
            add_finding(
                findings,
                fid=f"{scope.upper()}-MISSING-{key.upper()}-{idx}",
                severity="error",
                scope=scope,
                message=f"Missing or invalid {key} at index {idx}",
            )
            continue
        if value in seen:
            add_finding(
                findings,
                fid=f"{scope.upper()}-DUPLICATE-{value}",
                severity="error",
                scope=scope,
                message=f"Duplicate {key}: {value}",
                context={"first_index": seen[value], "duplicate_index": idx},
            )
        else:
            seen[value] = idx


def validate_registry(
    registry: Dict[str, Any],
    phase_plan: Dict[str, Any],
    gate_matrix: Dict[str, Any],
    findings: List[Dict[str, Any]],
) -> None:
    contracts = registry.get("contracts", [])
    constants = registry.get("constants", [])
    feature_flags = registry.get("feature_flags", [])
    phases = phase_plan.get("phases", [])
    gates = gate_matrix.get("gates", [])

    ensure_unique_ids(contracts, "id", "registry", findings)
    ensure_unique_ids(constants, "id", "registry", findings)
    ensure_unique_ids(gates, "id", "registry", findings)

    contract_ids = {c.get("id") for c in contracts if isinstance(c.get("id"), str)}
    gate_ids = {g.get("id") for g in gates if isinstance(g.get("id"), str)}

    for contract in contracts:
        cid = contract.get("id", "<missing>")
        for gid in contract.get("enforced_by_gate_ids", []):
            if gid not in gate_ids:
                add_finding(
                    findings,
                    fid=f"REGISTRY-CONTRACT-GATE-MISSING-{cid}-{gid}",
                    severity="error",
                    scope="registry",
                    message="Contract references undefined gate",
                    context={"contract_id": cid, "gate_id": gid},
                )

    for phase in phases:
        pid = phase.get("id")
        for cid in phase.get("required_contract_ids", []):
            if cid not in contract_ids:
                add_finding(
                    findings,
                    fid=f"REGISTRY-PHASE-CONTRACT-MISSING-{pid}-{cid}",
                    severity="error",
                    scope="registry",
                    message="Phase references undefined contract",
                    context={"phase_id": pid, "contract_id": cid},
                )
        for gid in phase.get("required_gate_ids", []):
            if gid not in gate_ids:
                add_finding(
                    findings,
                    fid=f"REGISTRY-PHASE-GATE-MISSING-{pid}-{gid}",
                    severity="error",
                    scope="registry",
                    message="Phase references undefined gate",
                    context={"phase_id": pid, "gate_id": gid},
                )

    for flag in feature_flags:
        if flag.get("track") == "X" and flag.get("default") != 0:
            add_finding(
                findings,
                fid=f"REGISTRY-FLAG-DEFAULT-{flag.get('name','<missing>')}",
                severity="error",
                scope="registry",
                message="Track X feature flag default must be OFF (0)",
                context={"flag": flag.get("name"), "default": flag.get("default")},
            )


def validate_phase_order(phase_plan: Dict[str, Any], findings: List[Dict[str, Any]]) -> None:
    metadata = phase_plan.get("metadata", {})
    phases = phase_plan.get("phases", [])
    ids = sorted([p.get("id") for p in phases if isinstance(p.get("id"), int)])
    span = metadata.get("phase_id_span", {})
    min_id = span.get("min")
    max_id = span.get("max")

    if min_id is None or max_id is None:
        add_finding(
            findings,
            fid="PHASE-ORDER-SPAN-MISSING",
            severity="error",
            scope="phase-order",
            message="phase_id_span missing min/max",
        )
        return

    expected = list(range(min_id, max_id + 1))
    if ids != expected:
        add_finding(
            findings,
            fid="PHASE-ORDER-NONCONTIGUOUS",
            severity="error",
            scope="phase-order",
            message="Phase ids are not contiguous within declared span",
            context={"actual": ids, "expected": expected},
        )

    phase_map = {p.get("id"): p for p in phases if isinstance(p.get("id"), int)}
    for phase_id, phase in phase_map.items():
        prereqs = phase.get("prerequisite_phase_ids", [])
        for prereq in prereqs:
            if prereq not in phase_map:
                add_finding(
                    findings,
                    fid=f"PHASE-ORDER-PREREQ-MISSING-{phase_id}-{prereq}",
                    severity="error",
                    scope="phase-order",
                    message="Phase has missing prerequisite id",
                    context={"phase_id": phase_id, "prerequisite": prereq},
                )
            elif prereq >= phase_id:
                add_finding(
                    findings,
                    fid=f"PHASE-ORDER-PREREQ-NONPAST-{phase_id}-{prereq}",
                    severity="error",
                    scope="phase-order",
                    message="Phase prerequisite must be smaller than phase id",
                    context={"phase_id": phase_id, "prerequisite": prereq},
                )


def parse_value(raw: str, value_type: str) -> Any:
    if value_type == "float":
        return float(raw)
    if value_type == "int":
        return int(raw)
    if value_type == "bool":
        lowered = raw.lower()
        if lowered in {"1", "true"}:
            return 1
        if lowered in {"0", "false"}:
            return 0
        raise ValueError(f"Cannot parse bool from {raw!r}")
    return raw


def values_match(actual: Any, expected: Any, value_type: str, tolerance: float = 1e-6) -> bool:
    if value_type == "float":
        return abs(float(actual) - float(expected)) <= tolerance
    return actual == expected


def validate_code_bindings(
    registry: Dict[str, Any],
    bindings: Dict[str, Any],
    findings: List[Dict[str, Any]],
    *,
    blur_only: bool,
) -> None:
    constants = {c.get("id"): c for c in registry.get("constants", [])}

    for check in bindings.get("checks", []):
        if check.get("status") == "deprecated":
            continue
        check_id = check.get("id", "<missing>")
        if blur_only and "BLUR" not in check_id:
            continue

        rel_path = check.get("path")
        regex = check.get("regex")
        value_type = check.get("value_type")
        expected_constant = check.get("expected", {}).get("constant_id")
        if not all([rel_path, regex, value_type, expected_constant]):
            add_finding(
                findings,
                fid=f"BINDING-CONFIG-{check_id}",
                severity="error",
                scope="bindings",
                message="Binding config is incomplete",
                context={"check": check},
            )
            continue

        constant = constants.get(expected_constant)
        if not constant:
            add_finding(
                findings,
                fid=f"BINDING-CONSTANT-MISSING-{check_id}",
                severity="error",
                scope="bindings",
                message="Binding references unknown constant",
                context={"constant_id": expected_constant},
            )
            continue

        expected_value = constant.get("value")
        file_path = ROOT / rel_path
        if not file_path.exists():
            optional = bool(check.get("optional", False))
            add_finding(
                findings,
                fid=f"BINDING-FILE-MISSING-{check_id}",
                severity="warning" if optional else "error",
                scope="bindings",
                message="Binding target file missing",
                context={"path": rel_path, "optional": optional},
            )
            if optional:
                continue
            continue

        text = file_path.read_text(encoding="utf-8", errors="replace")
        match = re.search(regex, text, re.MULTILINE)
        if not match:
            add_finding(
                findings,
                fid=f"BINDING-PATTERN-MISSING-{check_id}",
                severity="error",
                scope="bindings",
                message="Binding regex did not match target file",
                context={"path": rel_path, "regex": regex},
            )
            continue

        raw = match.group(1)
        try:
            actual = parse_value(raw, value_type)
        except ValueError as exc:
            add_finding(
                findings,
                fid=f"BINDING-PARSE-ERROR-{check_id}",
                severity="error",
                scope="bindings",
                message=str(exc),
                context={"raw": raw, "value_type": value_type},
            )
            continue

        if not values_match(actual, expected_value, value_type):
            add_finding(
                findings,
                fid=f"BINDING-VALUE-MISMATCH-{check_id}",
                severity="error",
                scope="bindings",
                message="Binding value mismatch",
                context={
                    "path": rel_path,
                    "actual": actual,
                    "expected": expected_value,
                    "constant_id": expected_constant,
                },
            )


def validate_structural_checks(
    structural: Dict[str, Any],
    findings: List[Dict[str, Any]],
    *,
    blur_only: bool,
) -> None:
    for check in structural.get("checks", []):
        if check.get("status") == "deprecated":
            continue
        check_id = check.get("id", "<missing>")
        if blur_only and "BLUR" not in check_id:
            continue

        file_path = ROOT / str(check.get("path", ""))
        if not file_path.exists():
            optional = bool(check.get("optional", False))
            add_finding(
                findings,
                fid=f"STRUCT-FILE-MISSING-{check_id}",
                severity="warning" if optional else "error",
                scope="structural",
                message="Structural check target file missing",
                context={"path": str(check.get("path")), "optional": optional},
            )
            if optional:
                continue
            continue

        text = file_path.read_text(encoding="utf-8", errors="replace")
        for pattern in check.get("must_contain", []):
            if not re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"STRUCT-MISSING-{check_id}",
                    severity="error",
                    scope="structural",
                    message="Required pattern missing",
                    context={"path": str(check.get("path")), "pattern": pattern},
                )

        for pattern in check.get("must_not_contain", []):
            if re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"STRUCT-FORBIDDEN-{check_id}",
                    severity="error",
                    scope="structural",
                    message="Forbidden pattern present",
                    context={"path": str(check.get("path")), "pattern": pattern},
                )


def validate_flags(registry: Dict[str, Any], findings: List[Dict[str, Any]]) -> None:
    for flag in registry.get("feature_flags", []):
        name = flag.get("name", "<missing>")
        if flag.get("track") == "X" and flag.get("default") != 0:
            add_finding(
                findings,
                fid=f"FLAG-DEFAULT-NOT-OFF-{name}",
                severity="error",
                scope="flags",
                message="Track X flag default must be 0",
                context={"flag": name, "default": flag.get("default")},
            )
        if flag.get("actual") is not None and flag.get("actual") != flag.get("default"):
            add_finding(
                findings,
                fid=f"FLAG-ACTUAL-DRIFT-{name}",
                severity="error",
                scope="flags",
                message="Feature flag actual state drifts from governance default",
                context={"flag": name, "default": flag.get("default"), "actual": flag.get("actual")},
            )


def validate_flag_namespace(findings: List[Dict[str, Any]]) -> None:
    prompt = find_prompt_file()
    if prompt is None:
        add_finding(
            findings,
            fid="FLAG-NS-PROMPT-MISSING",
            severity="warning",
            scope="flag-namespace",
            message="CURSOR_MEGA_PROMPT_V2.md not found for namespace scan",
        )
        return

    text = prompt.read_text(encoding="utf-8", errors="replace")
    feature_flag_count = len(re.findall(r"AETHER_FEATURE_FLAG_[A-Z0-9_]+", text))
    enable_flag_count = len(re.findall(r"AETHER_ENABLE_[A-Z0-9_]+", text))
    if feature_flag_count > 0 and enable_flag_count > 0:
        add_finding(
            findings,
            fid="FLAG-NS-MIXED-PREFIXES",
            severity="warning",
            scope="flag-namespace",
            message="Mixed flag namespaces detected (AETHER_FEATURE_FLAG_ and AETHER_ENABLE_)",
            context={
                "AETHER_FEATURE_FLAG_count": feature_flag_count,
                "AETHER_ENABLE_count": enable_flag_count,
            },
        )


def validate_section_order(findings: List[Dict[str, Any]]) -> None:
    prompt = find_prompt_file()
    if prompt is None:
        add_finding(
            findings,
            fid="SECTION-ORDER-PROMPT-MISSING",
            severity="warning",
            scope="section-order",
            message="CURSOR_MEGA_PROMPT_V2.md not found",
        )
        return

    pattern = re.compile(r"^##\s+§6\.(\d+)([a-z]?)")
    prev_num: Optional[int] = None
    prev_raw: Optional[str] = None
    prev_line: Optional[int] = None

    for idx, line in enumerate(prompt.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        match = pattern.match(line)
        if not match:
            continue
        num = int(match.group(1))
        raw = f"{match.group(1)}{match.group(2)}"
        if prev_num is not None and num < prev_num:
            add_finding(
                findings,
                fid=f"SECTION-ORDER-NONMONOTONIC-{idx}",
                severity="error",
                scope="section-order",
                message="§6 section numbering decreased",
                context={
                    "line": idx,
                    "current": raw,
                    "previous": prev_raw,
                    "previous_line": prev_line,
                },
            )
        prev_num = num
        prev_raw = raw
        prev_line = idx


def validate_branch(registry: Dict[str, Any], findings: List[Dict[str, Any]]) -> None:
    expected = registry.get("metadata", {}).get("long_lived_integration_branch")
    actual = get_git_branch()
    if expected and actual != expected:
        add_finding(
            findings,
            fid="BRANCH-NOT-INTEGRATION",
            severity="error",
            scope="branch",
            message="Current git branch does not match long-lived integration branch",
            context={"expected": expected, "actual": actual},
        )


def summarize(findings: List[Dict[str, Any]]) -> Dict[str, int]:
    summary = {"error": 0, "warning": 0, "info": 0}
    for finding in findings:
        sev = finding.get("severity", "info")
        if sev not in summary:
            summary[sev] = 0
        summary[sev] += 1
    return summary


def write_report(report_path: Path, findings: List[Dict[str, Any]], args: argparse.Namespace) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    summary = summarize(findings)
    payload = {
        "generated_at": dt.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "strict": bool(args.strict),
        "only": args.only or [],
        "summary": summary,
        "findings": findings,
    }
    report_path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    scopes = args.only or []

    registry = load_json(GOV_DIR / "contract_registry.json")
    phase_plan = load_json(GOV_DIR / "phase_plan.json")
    gate_matrix = load_json(GOV_DIR / "ci_gate_matrix.json")
    bindings = load_json(GOV_DIR / "code_bindings.json")
    structural = load_json(GOV_DIR / "structural_checks.json")

    findings: List[Dict[str, Any]] = []

    if args.check_branch:
        validate_branch(registry, findings)
        write_report(ROOT / args.report, findings, args)
        summary = summarize(findings)
        print(f"branch-check: errors={summary.get('error',0)} warnings={summary.get('warning',0)}")
        return 1 if summary.get("error", 0) > 0 else 0

    if should_run(scopes, "registry"):
        validate_registry(registry, phase_plan, gate_matrix, findings)

    if should_run(scopes, "phase-order"):
        validate_phase_order(phase_plan, findings)

    if should_run(scopes, "bindings") or should_run(scopes, "blur"):
        validate_code_bindings(
            registry,
            bindings,
            findings,
            blur_only=should_run(scopes, "blur") and not should_run(scopes, "bindings"),
        )

    if should_run(scopes, "structural") or should_run(scopes, "blur"):
        validate_structural_checks(
            structural,
            findings,
            blur_only=should_run(scopes, "blur") and not should_run(scopes, "structural"),
        )

    if should_run(scopes, "flags"):
        validate_flags(registry, findings)

    if should_run(scopes, "flag-namespace"):
        validate_flag_namespace(findings)

    if should_run(scopes, "section-order"):
        validate_section_order(findings)

    if should_run(scopes, "branch"):
        validate_branch(registry, findings)

    report_path = ROOT / args.report
    write_report(report_path, findings, args)

    summary = summarize(findings)
    print(
        "governance-validator:",
        f"errors={summary.get('error',0)}",
        f"warnings={summary.get('warning',0)}",
        f"info={summary.get('info',0)}",
    )

    if args.strict and summary.get("error", 0) > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
