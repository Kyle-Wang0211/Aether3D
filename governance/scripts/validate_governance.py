#!/usr/bin/env python3
"""Validate protocol governance SSOT artifacts and implementation bindings.

This script is intentionally stdlib-only so it can run in minimal CI environments.
"""

from __future__ import annotations

import argparse
import ast
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
            "audit-anchor",
            "p0-quality",
            "upload-contract",
            "first-scan-kpi",
            "dual-lane-upload",
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
    if value_type in {"float", "int", "bool"}:
        numeric = evaluate_numeric_expression(raw)
        if value_type == "float":
            return float(numeric)
        if value_type == "int":
            numeric_f = float(numeric)
            rounded = round(numeric_f)
            if abs(numeric_f - rounded) > 1e-9:
                raise ValueError(f"Cannot parse int from non-integer expression {raw!r}")
            return int(rounded)
        return 1 if bool(numeric) else 0
    return raw


def _normalize_expression(raw: str) -> str:
    # Remove common inline comment tails and trailing separators.
    expr = raw.strip()
    expr = expr.split("//", 1)[0]
    expr = expr.split("#", 1)[0]
    expr = expr.strip().rstrip(",")
    expr = expr.replace("_", "")
    # C/C++ float suffix support (e.g. 0.18f).
    expr = re.sub(r"(?<=\d)[fF]\b", "", expr)
    expr = re.sub(r"\btrue\b", "True", expr, flags=re.IGNORECASE)
    expr = re.sub(r"\bfalse\b", "False", expr, flags=re.IGNORECASE)
    return expr


def evaluate_numeric_expression(raw: str) -> float:
    expr = _normalize_expression(raw)
    if not expr:
        raise ValueError(f"Cannot parse empty expression from {raw!r}")

    operators: Dict[type, Callable[[Any, Any], Any]] = {
        ast.Add: lambda a, b: a + b,
        ast.Sub: lambda a, b: a - b,
        ast.Mult: lambda a, b: a * b,
        ast.Div: lambda a, b: a / b,
        ast.FloorDiv: lambda a, b: a // b,
        ast.Mod: lambda a, b: a % b,
        ast.Pow: lambda a, b: a**b,
    }

    def walk(node: ast.AST) -> float:
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float, bool)):
            return float(node.value)
        if isinstance(node, ast.Num):  # pragma: no cover
            return float(node.n)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            operand = walk(node.operand)
            return operand if isinstance(node.op, ast.UAdd) else -operand
        if isinstance(node, ast.BinOp) and type(node.op) in operators:
            left = walk(node.left)
            right = walk(node.right)
            return float(operators[type(node.op)](left, right))
        raise ValueError(f"Unsupported expression node: {type(node).__name__}")

    try:
        parsed = ast.parse(expr, mode="eval")
    except SyntaxError as exc:
        raise ValueError(f"Cannot parse expression {raw!r}: {exc}") from exc

    return walk(parsed.body)


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
    contract_ids = {
        contract.get("id")
        for contract in registry.get("contracts", [])
        if isinstance(contract.get("id"), str)
    }
    constants = {c.get("id"): c for c in registry.get("constants", [])}
    active_constants = {
        cid
        for cid, constant in constants.items()
        if isinstance(cid, str) and constant.get("status") != "deprecated"
    }
    referenced_constants: set[str] = set()

    for check in bindings.get("checks", []):
        if check.get("status") == "deprecated":
            continue
        check_id = check.get("id", "<missing>")
        if blur_only and "BLUR" not in check_id:
            continue

        rel_path = check.get("path")
        regex = check.get("regex")
        value_type = check.get("value_type")
        contract_id = check.get("contract_id")
        expected_constant = check.get("expected", {}).get("constant_id")
        if isinstance(expected_constant, str):
            referenced_constants.add(expected_constant)
        if not isinstance(contract_id, str) or contract_id not in contract_ids:
            add_finding(
                findings,
                fid=f"BINDING-CONTRACT-MISSING-{check_id}",
                severity="error",
                scope="bindings",
                message="Binding references unknown contract",
                context={"contract_id": contract_id},
            )
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

    if blur_only:
        return

    metadata = bindings.get("metadata", {})
    raw_policy = metadata.get("coverage_policy", {})
    coverage_mode = "declared_only"
    required_constant_ids: set[str] = set()

    if isinstance(raw_policy, dict):
        raw_mode = raw_policy.get("mode")
        if raw_mode is not None:
            if raw_mode in {"declared_only", "all_active_constants", "required_list"}:
                coverage_mode = raw_mode
            else:
                add_finding(
                    findings,
                    fid="BINDING-COVERAGE-POLICY-MODE-INVALID",
                    severity="error",
                    scope="bindings",
                    message="Invalid binding coverage policy mode",
                    context={"mode": raw_mode},
                )

        raw_required = raw_policy.get("required_constant_ids", [])
        if coverage_mode == "required_list":
            if not isinstance(raw_required, list):
                add_finding(
                    findings,
                    fid="BINDING-COVERAGE-POLICY-REQUIRED-TYPE",
                    severity="error",
                    scope="bindings",
                    message="required_constant_ids must be a list in required_list mode",
                )
            else:
                for idx, item in enumerate(raw_required):
                    if not isinstance(item, str) or not item.startswith("K-"):
                        add_finding(
                            findings,
                            fid=f"BINDING-COVERAGE-POLICY-REQUIRED-INVALID-{idx}",
                            severity="error",
                            scope="bindings",
                            message="required_constant_ids contains invalid constant id",
                            context={"index": idx, "value": item},
                        )
                        continue
                    required_constant_ids.add(item)

    expected_constants: set[str]
    if coverage_mode == "all_active_constants":
        expected_constants = active_constants
    elif coverage_mode == "required_list":
        expected_constants = required_constant_ids
        for constant_id in sorted(required_constant_ids - set(constants.keys())):
            add_finding(
                findings,
                fid=f"BINDING-COVERAGE-REQUIRED-MISSING-CONSTANT-{constant_id}",
                severity="error",
                scope="bindings",
                message="Coverage policy references unknown constant",
                context={"constant_id": constant_id},
            )
    else:
        # declared_only: only validate constants explicitly listed in checks.
        expected_constants = referenced_constants

    for constant_id in sorted(expected_constants - referenced_constants):
        add_finding(
            findings,
            fid=f"BINDING-COVERAGE-MISSING-{constant_id}",
            severity="error",
            scope="bindings",
            message="Coverage policy expected a binding check for this constant",
            context={"constant_id": constant_id, "mode": coverage_mode},
        )

    active_bound = len(active_constants & referenced_constants)
    active_total = len(active_constants)
    coverage_ratio = 1.0 if active_total == 0 else active_bound / active_total
    add_finding(
        findings,
        fid="BINDING-COVERAGE-SUMMARY",
        severity="info",
        scope="bindings",
        message="Binding coverage summary",
        context={
            "mode": coverage_mode,
            "active_constants": active_total,
            "bound_active_constants": active_bound,
            "unbound_active_constants": active_total - active_bound,
            "coverage_ratio": round(coverage_ratio, 6),
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


def validate_audit_anchor_policy(registry: Dict[str, Any], findings: List[Dict[str, Any]]) -> None:
    constants = {
        constant.get("id"): constant
        for constant in registry.get("constants", [])
        if isinstance(constant.get("id"), str)
    }

    required_ids = [
        "K-AUDIT-RFC3161-ANCHOR-SEC",
        "K-AUDIT-TIME-DRIFT-MAX-SEC",
        "K-AUDIT-HASH-BATCH-FRAMES",
    ]
    for constant_id in required_ids:
        if constant_id not in constants:
            add_finding(
                findings,
                fid=f"AUDIT-ANCHOR-CONSTANT-MISSING-{constant_id}",
                severity="error",
                scope="audit-anchor",
                message="Required audit anchor constant missing from registry",
                context={"constant_id": constant_id},
            )

    anchor = constants.get("K-AUDIT-RFC3161-ANCHOR-SEC")
    if anchor is not None:
        value = anchor.get("value")
        if not isinstance(value, (int, float)) or int(value) != 60:
            add_finding(
                findings,
                fid="AUDIT-ANCHOR-INTERVAL-NOT-60S",
                severity="error",
                scope="audit-anchor",
                message="Audit anchor interval must be exactly 60 seconds for client-first high-strength mode",
                context={"actual": value, "expected": 60},
            )

    drift = constants.get("K-AUDIT-TIME-DRIFT-MAX-SEC")
    if drift is not None:
        value = drift.get("value")
        if not isinstance(value, (int, float)) or not (0 < float(value) <= 300):
            add_finding(
                findings,
                fid="AUDIT-ANCHOR-DRIFT-OUT-OF-RANGE",
                severity="error",
                scope="audit-anchor",
                message="Time drift max must be in (0, 300] seconds",
                context={"actual": value},
            )

    prompt = find_prompt_file()
    if prompt is None:
        add_finding(
            findings,
            fid="AUDIT-ANCHOR-PROMPT-MISSING",
            severity="warning",
            scope="audit-anchor",
            message="CURSOR_MEGA_PROMPT_V2.md not found for audit anchor policy scan",
        )
        return

    text = prompt.read_text(encoding="utf-8", errors="replace")
    required_patterns: List[Tuple[str, str]] = [
        ("session_start_anchor", r"session开始时强制一次"),
        ("session_end_anchor", r"session结束时强制一次"),
        ("client_direct_tsa", r"客户端直连 TSA"),
        ("server_verify_archive_only", r"云端仅做验签与存档"),
        ("anchor_constant_60s", r"K_AUDIT_RFC3161_ANCHOR_SEC\s*=\s*60"),
    ]
    for key, pattern in required_patterns:
        if not re.search(pattern, text, re.MULTILINE):
            add_finding(
                findings,
                fid=f"AUDIT-ANCHOR-PROMPT-MISSING-{key.upper()}",
                severity="error",
                scope="audit-anchor",
                message="Prompt is missing required client-first audit-anchor policy marker",
                context={"pattern": pattern},
            )


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


def _read_text(path: Path) -> Optional[str]:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def _extract_swift_static_value(text: str, symbol: str) -> Optional[float]:
    pattern = re.compile(rf"public\s+static\s+let\s+{re.escape(symbol)}\s*:\s*[^=]+\s*=\s*([^\n]+)")
    match = pattern.search(text)
    if not match:
        return None
    raw = match.group(1).strip()
    try:
        return float(evaluate_numeric_expression(raw))
    except ValueError:
        return None


def validate_p0_quality_implementation(findings: List[Dict[str, Any]]) -> None:
    checks = [
        {
            "path": ROOT / "Core/Quality/Metrics/ExposureAnalyzer.swift",
            "must_not": [r"return\s+0\.05", r"Placeholder - detect connected regions"],
            "must_contain": [r"withUnsafeBytes", r"overexposedLumaThreshold", r"underexposedLumaThreshold"],
            "id": "P0-QUALITY-EXPOSURE",
        },
        {
            "path": ROOT / "Core/Quality/Metrics/TextureAnalyzer.swift",
            "must_not": [r"return\s+QualityThresholds\.minFeatureDensity"],
            "must_contain": [r"gradientThresholdSq", r"calculateTextureEntropy", r"withUnsafeBytes"],
            "id": "P0-QUALITY-TEXTURE",
        },
        {
            "path": ROOT / "Core/Quality/Metrics/MotionAnalyzer.swift",
            "must_not": [r"return\s+0\.6", r"Placeholder - in production, use IMU data and frame differences"],
            "must_contain": [r"previousFrame", r"signedShiftHistory", r"withUnsafeBytes"],
            "id": "P0-QUALITY-MOTION",
        },
    ]

    for item in checks:
        text = _read_text(item["path"])
        if text is None:
            add_finding(
                findings,
                fid=f"{item['id']}-FILE-MISSING",
                severity="error",
                scope="p0-quality",
                message="Required quality implementation file is missing",
                context={"path": str(item["path"].relative_to(ROOT))},
            )
            continue

        for pattern in item["must_not"]:
            if re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"{item['id']}-PLACEHOLDER-DETECTED",
                    severity="error",
                    scope="p0-quality",
                    message="Placeholder implementation pattern detected",
                    context={"path": str(item["path"].relative_to(ROOT)), "pattern": pattern},
                )
        for pattern in item["must_contain"]:
            if not re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"{item['id']}-MISSING-LOGIC",
                    severity="error",
                    scope="p0-quality",
                    message="Expected implementation marker missing",
                    context={"path": str(item["path"].relative_to(ROOT)), "pattern": pattern},
                )

    supplemental_checks = [
        {
            "id": "P0-CLOSURE-INFOGAIN",
            "path": ROOT / "Core/Quality/Admission/InformationGainCalculator.swift",
            "must_not": [r"return\s+0\.5", r"Placeholder implementation", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-PROGRESS",
            "path": ROOT / "Core/Quality/Direction/ProgressTracker.swift",
            "must_not": [r"Placeholder", r"return\s+false"],
        },
        {
            "id": "P0-CLOSURE-TENENGRAD",
            "path": ROOT / "Core/Quality/Metrics/TenengradDetector.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-BRIGHTNESS",
            "path": ROOT / "Core/Quality/Metrics/BrightnessAnalyzer.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-OVERLAP",
            "path": ROOT / "Core/Quality/OverlapEstimator.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-QUALITY-SHA",
            "path": ROOT / "Core/Quality/Serialization/SHA256Utility.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-GUIDANCE",
            "path": ROOT / "Core/Quality/Visualization/GuidanceRenderer.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-DIMENSIONAL",
            "path": ROOT / "Core/Evidence/DimensionalEvidence.swift",
            "must_not": [r"TODO", r"return\s+0\.0\s+as\s+stub", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-EVIDENCE-INVARIANTS",
            "path": ROOT / "Core/Evidence/EvidenceInvariants.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-ASN1",
            "path": ROOT / "Core/TimeAnchoring/ASN1Builder.swift",
            "must_not": [r"TODO", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-ROUGHTIME",
            "path": ROOT / "Core/TimeAnchoring/RoughtimeClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-TSA",
            "path": ROOT / "Core/TimeAnchoring/TSAClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-OTS",
            "path": ROOT / "Core/TimeAnchoring/OpenTimestampsAnchor.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-HASH",
            "path": ROOT / "Core/MerkleTree/MerkleTreeHash.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-TREE",
            "path": ROOT / "Core/MerkleTree/MerkleTree.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-CONSISTENCY",
            "path": ROOT / "Core/MerkleTree/ConsistencyProof.swift",
            "must_not": [r"TODO"],
        },
        {
            "id": "P0-CLOSURE-TSDF-RING",
            "path": ROOT / "Core/TSDF/TSDFVolume.swift",
            "must_not": [r"keyframeId:\s*nil\s*//\s*TODO"],
        },
    ]

    for item in supplemental_checks:
        text = _read_text(item["path"])
        if text is None:
            add_finding(
                findings,
                fid=f"{item['id']}-FILE-MISSING",
                severity="error",
                scope="p0-quality",
                message="Required closure file is missing",
                context={"path": str(item["path"].relative_to(ROOT))},
            )
            continue

        for pattern in item["must_not"]:
            if re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"{item['id']}-FORBIDDEN-PATTERN",
                    severity="error",
                    scope="p0-quality",
                    message="Forbidden placeholder/crash pattern detected",
                    context={"path": str(item["path"].relative_to(ROOT)), "pattern": pattern},
                )

    supplemental_checks = [
        {
            "id": "P0-CLOSURE-INFOGAIN",
            "path": ROOT / "Core/Quality/Admission/InformationGainCalculator.swift",
            "must_not": [r"return\s+0\.5", r"Placeholder implementation", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-PROGRESS",
            "path": ROOT / "Core/Quality/Direction/ProgressTracker.swift",
            "must_not": [r"Placeholder", r"return\s+false"],
        },
        {
            "id": "P0-CLOSURE-TENENGRAD",
            "path": ROOT / "Core/Quality/Metrics/TenengradDetector.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-BRIGHTNESS",
            "path": ROOT / "Core/Quality/Metrics/BrightnessAnalyzer.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-OVERLAP",
            "path": ROOT / "Core/Quality/OverlapEstimator.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-QUALITY-SHA",
            "path": ROOT / "Core/Quality/Serialization/SHA256Utility.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-GUIDANCE",
            "path": ROOT / "Core/Quality/Visualization/GuidanceRenderer.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-DIMENSIONAL",
            "path": ROOT / "Core/Evidence/DimensionalEvidence.swift",
            "must_not": [r"TODO", r"return\s+0\.0\s+as\s+stub", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-EVIDENCE-INVARIANTS",
            "path": ROOT / "Core/Evidence/EvidenceInvariants.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-ASN1",
            "path": ROOT / "Core/TimeAnchoring/ASN1Builder.swift",
            "must_not": [r"TODO", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-ROUGHTIME",
            "path": ROOT / "Core/TimeAnchoring/RoughtimeClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-TSA",
            "path": ROOT / "Core/TimeAnchoring/TSAClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-OTS",
            "path": ROOT / "Core/TimeAnchoring/OpenTimestampsAnchor.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-HASH",
            "path": ROOT / "Core/MerkleTree/MerkleTreeHash.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-TREE",
            "path": ROOT / "Core/MerkleTree/MerkleTree.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-CONSISTENCY",
            "path": ROOT / "Core/MerkleTree/ConsistencyProof.swift",
            "must_not": [r"TODO"],
        },
        {
            "id": "P0-CLOSURE-TSDF-RING",
            "path": ROOT / "Core/TSDF/TSDFVolume.swift",
            "must_not": [r"keyframeId:\s*nil\s*//\s*TODO"],
        },
    ]

    for item in supplemental_checks:
        text = _read_text(item["path"])
        if text is None:
            add_finding(
                findings,
                fid=f"{item['id']}-FILE-MISSING",
                severity="error",
                scope="p0-quality",
                message="Required closure file is missing",
                context={"path": str(item["path"].relative_to(ROOT))},
            )
            continue

        for pattern in item["must_not"]:
            if re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"{item['id']}-FORBIDDEN-PATTERN",
                    severity="error",
                    scope="p0-quality",
                    message="Forbidden placeholder/crash pattern detected",
                    context={"path": str(item["path"].relative_to(ROOT)), "pattern": pattern},
                )

    supplemental_checks = [
        {
            "id": "P0-CLOSURE-INFOGAIN",
            "path": ROOT / "Core/Quality/Admission/InformationGainCalculator.swift",
            "must_not": [r"return\s+0\.5", r"Placeholder implementation", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-PROGRESS",
            "path": ROOT / "Core/Quality/Direction/ProgressTracker.swift",
            "must_not": [r"Placeholder", r"return\s+false"],
        },
        {
            "id": "P0-CLOSURE-TENENGRAD",
            "path": ROOT / "Core/Quality/Metrics/TenengradDetector.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-BRIGHTNESS",
            "path": ROOT / "Core/Quality/Metrics/BrightnessAnalyzer.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-OVERLAP",
            "path": ROOT / "Core/Quality/OverlapEstimator.swift",
            "must_not": [r"Placeholder", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-QUALITY-SHA",
            "path": ROOT / "Core/Quality/Serialization/SHA256Utility.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-GUIDANCE",
            "path": ROOT / "Core/Quality/Visualization/GuidanceRenderer.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-DIMENSIONAL",
            "path": ROOT / "Core/Evidence/DimensionalEvidence.swift",
            "must_not": [r"TODO", r"return\s+0\.0\s+as\s+stub", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-EVIDENCE-INVARIANTS",
            "path": ROOT / "Core/Evidence/EvidenceInvariants.swift",
            "must_not": [r"fatalError\("],
        },
        {
            "id": "P0-CLOSURE-ASN1",
            "path": ROOT / "Core/TimeAnchoring/ASN1Builder.swift",
            "must_not": [r"TODO", r"Placeholder"],
        },
        {
            "id": "P0-CLOSURE-ROUGHTIME",
            "path": ROOT / "Core/TimeAnchoring/RoughtimeClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-TSA",
            "path": ROOT / "Core/TimeAnchoring/TSAClient.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-OTS",
            "path": ROOT / "Core/TimeAnchoring/OpenTimestampsAnchor.swift",
            "must_not": [r"TODO", r"Not yet implemented"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-HASH",
            "path": ROOT / "Core/MerkleTree/MerkleTreeHash.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-TREE",
            "path": ROOT / "Core/MerkleTree/MerkleTree.swift",
            "must_not": [r"fatalError\(", r"TODO"],
        },
        {
            "id": "P0-CLOSURE-MERKLE-CONSISTENCY",
            "path": ROOT / "Core/MerkleTree/ConsistencyProof.swift",
            "must_not": [r"TODO"],
        },
        {
            "id": "P0-CLOSURE-TSDF-RING",
            "path": ROOT / "Core/TSDF/TSDFVolume.swift",
            "must_not": [r"keyframeId:\s*nil\s*//\s*TODO"],
        },
    ]

    for item in supplemental_checks:
        text = _read_text(item["path"])
        if text is None:
            add_finding(
                findings,
                fid=f"{item['id']}-FILE-MISSING",
                severity="error",
                scope="p0-quality",
                message="Required closure file is missing",
                context={"path": str(item["path"].relative_to(ROOT))},
            )
            continue

        for pattern in item["must_not"]:
            if re.search(pattern, text, re.MULTILINE):
                add_finding(
                    findings,
                    fid=f"{item['id']}-FORBIDDEN-PATTERN",
                    severity="error",
                    scope="p0-quality",
                    message="Forbidden placeholder/crash pattern detected",
                    context={"path": str(item["path"].relative_to(ROOT)), "pattern": pattern},
                )

    quality_text = _read_text(ROOT / "Core/Constants/QualityThresholds.swift")
    core_blur_text = _read_text(ROOT / "Core/Constants/CoreBlurThresholds.swift")
    if quality_text is None or core_blur_text is None:
        add_finding(
            findings,
            fid="P0-QUALITY-BLUR-SSOT-FILES-MISSING",
            severity="error",
            scope="p0-quality",
            message="Unable to validate blur threshold SSOT because constants file is missing",
        )
        return

    laplacian = _extract_swift_static_value(quality_text, "laplacianBlurThreshold")
    frame_reject = _extract_swift_static_value(core_blur_text, "frameRejection")
    if laplacian is None or frame_reject is None:
        add_finding(
            findings,
            fid="P0-QUALITY-BLUR-SSOT-PARSE-ERROR",
            severity="error",
            scope="p0-quality",
            message="Unable to parse blur thresholds for SSOT comparison",
            context={"laplacian": laplacian, "frameRejection": frame_reject},
        )
    elif abs(laplacian - frame_reject) > 1e-6:
        add_finding(
            findings,
            fid="P0-QUALITY-BLUR-SSOT-MISMATCH",
            severity="error",
            scope="p0-quality",
            message="QualityThresholds.laplacianBlurThreshold must equal CoreBlurThresholds.frameRejection",
            context={"laplacianBlurThreshold": laplacian, "frameRejection": frame_reject},
        )


def validate_upload_contract_consistency(findings: List[Dict[str, Any]]) -> None:
    upload_constants_path = ROOT / "Core/Constants/UploadConstants.swift"
    chunk_uploader_path = ROOT / "Core/Upload/ChunkedUploader.swift"
    server_contract_path = ROOT / "server/app/api/contract_constants.py"

    upload_constants = _read_text(upload_constants_path)
    chunk_uploader = _read_text(chunk_uploader_path)
    server_contract = _read_text(server_contract_path)
    if upload_constants is None or chunk_uploader is None or server_contract is None:
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-FILES-MISSING",
            severity="error",
            scope="upload-contract",
            message="Upload contract consistency validation requires constants/client/server files",
            context={
                "upload_constants": upload_constants is not None,
                "chunk_uploader": chunk_uploader is not None,
                "server_contract": server_contract is not None,
            },
        )
        return

    version_pattern = re.compile(r'UPLOAD_CONTRACT_VERSION\s*=\s*"([^"]+)"')
    version_match = version_pattern.search(upload_constants)
    version = version_match.group(1) if version_match else None
    if version != "PR9-UPLOAD-1.0":
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-VERSION-MISMATCH",
            severity="error",
            scope="upload-contract",
            message="UploadConstants.UPLOAD_CONTRACT_VERSION must be PR9-UPLOAD-1.0",
            context={"actual": version},
        )

    if not re.search(r'request\.httpMethod\s*=\s*"PATCH"', chunk_uploader):
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-HTTP-METHOD-DRIFT",
            severity="error",
            scope="upload-contract",
            message="ChunkedUploader must use PATCH for chunk uploads",
        )
    if not re.search(r'X-Chunk-Hash', chunk_uploader):
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-HEADER-DRIFT",
            severity="error",
            scope="upload-contract",
            message="ChunkedUploader must send X-Chunk-Hash header",
        )

    client_chunk_max = _extract_swift_static_value(upload_constants, "CHUNK_SIZE_MAX_BYTES")
    server_max_match = re.search(r"MAX_CHUNK_SIZE_BYTES\s*=\s*([^\n#]+)", server_contract)
    server_chunk_max: Optional[float] = None
    if server_max_match:
        try:
            server_chunk_max = float(evaluate_numeric_expression(server_max_match.group(1).strip()))
        except ValueError:
            server_chunk_max = None

    if client_chunk_max is None or server_chunk_max is None:
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-CHUNK-PARSE-ERROR",
            severity="error",
            scope="upload-contract",
            message="Unable to parse client/server max chunk size",
            context={"client": client_chunk_max, "server": server_chunk_max},
        )
    elif abs(client_chunk_max - server_chunk_max) > 1e-6:
        add_finding(
            findings,
            fid="UPLOAD-CONTRACT-CHUNK-LIMIT-MISMATCH",
            severity="error",
            scope="upload-contract",
            message="Client and server max chunk size must match exactly",
            context={"client_chunk_max": client_chunk_max, "server_chunk_max": server_chunk_max},
        )


def validate_first_scan_kpi(findings: List[Dict[str, Any]]) -> None:
    whitebox = _read_text(ROOT / "docs/WHITEBOX.md")
    phase_plan = load_json(GOV_DIR / "phase_plan.json")
    registry = load_json(GOV_DIR / "contract_registry.json")
    runtime_report_path = ROOT / "governance/generated/first_scan_runtime_metrics.json"
    registry = load_json(GOV_DIR / "contract_registry.json")
    runtime_report_path = ROOT / "governance/generated/first_scan_runtime_metrics.json"
    registry = load_json(GOV_DIR / "contract_registry.json")
    runtime_report_path = ROOT / "governance/generated/first_scan_runtime_metrics.json"

    if whitebox is None:
        add_finding(
            findings,
            fid="FIRST-SCAN-WHITEBOX-MISSING",
            severity="error",
            scope="first-scan-kpi",
            message="docs/WHITEBOX.md is required for first-scan KPI policy validation",
        )
    else:
        required_markers = [
            r"2-3\s*分钟",
            r"15\s*分钟",
            r"首扫成功率优先",
        ]
        for marker in required_markers:
            if not re.search(marker, whitebox):
                add_finding(
                    findings,
                    fid=f"FIRST-SCAN-WHITEBOX-MISSING-{re.sub(r'[^A-Z0-9]+', '-', marker.upper())}",
                    severity="error",
                    scope="first-scan-kpi",
                    message="WHITEBOX policy marker missing",
                    context={"pattern": marker},
                )

    phase8 = next((p for p in phase_plan.get("phases", []) if p.get("id") == 8), None)
    if phase8 is None:
        add_finding(
            findings,
            fid="FIRST-SCAN-PHASE8-MISSING",
            severity="error",
            scope="first-scan-kpi",
            message="Phase 8 is required for first-scan KPI enforcement",
        )
    else:
        gate_ids = set(phase8.get("required_gate_ids", []))
        if "G-FIRST-SCAN-SUCCESS-KPI" not in gate_ids:
            add_finding(
                findings,
                fid="FIRST-SCAN-PHASE8-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Phase 8 must require G-FIRST-SCAN-SUCCESS-KPI gate",
            )
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid="FIRST-SCAN-PHASE8-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Phase 8 must require G-PURE-VISION-RUNTIME-FIXTURE gate",
            )

    for phase in phase_plan.get("phases", []):
        phase_id = phase.get("id")
        if phase_id not in {9, 10, 11, 12, 13}:
            continue
        gate_ids = set(phase.get("required_gate_ids", []))
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-PHASE-{phase_id}-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Pure vision runtime fixture gate must be required in phase 9-13",
                context={"phase_id": phase_id},
            )

    constants = {
        c.get("id"): c
        for c in registry.get("constants", [])
        if isinstance(c.get("id"), str) and c.get("status") == "active"
    }
    required_constants = [
        "K-BLUR-FRAME-REJECTION",
        "K-FRAME-MIN-ORB-FEATURES",
        "K-OBS-MIN-BASELINE-PIXELS",
        "K-OBS-REQ-PARALLAX-RATIO",
        "K-OBS-SIGMA-Z-TARGET-M",
        "K-VOLUME-CLOSURE-RATIO-MIN",
        "K-VOLUME-UNKNOWN-VOXEL-MAX",
        "K-THERMAL-CRITICAL-C",
        "K-GUIDANCE-S4-S5-THRESHOLD",
        "K-EVIDENCE-S5-MIN-SOFT",
    ]
    for constant_id in required_constants:
        if constant_id not in constants:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-MISSING-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant is missing",
                context={"constant_id": constant_id},
            )

    expected_values = {
        "K-BLUR-FRAME-REJECTION": 200.0,
        "K-GUIDANCE-S4-S5-THRESHOLD": 0.88,
        "K-EVIDENCE-S5-MIN-SOFT": 0.75,
    }
    for constant_id, expected in expected_values.items():
        if constant_id not in constants:
            continue
        actual = constants[constant_id].get("value")
        if not isinstance(actual, (int, float)) or abs(float(actual) - expected) > 1e-9:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-VALUE-DRIFT-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant value drifted",
                context={"constant_id": constant_id, "actual": actual, "expected": expected},
            )

    if not runtime_report_path.exists():
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-MISSING",
            severity="error",
            scope="first-scan-kpi",
            message=(
                "Missing runtime replay KPI report at governance/generated/first_scan_runtime_metrics.json. "
                "Run governance/scripts/eval_first_scan_runtime_kpi.py before this validation."
            ),
        )
        return

    try:
        runtime_report = json.loads(runtime_report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-JSON-INVALID",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report is not valid JSON",
            context={"error": str(exc)},
        )
        return

    numeric_requirements: List[Tuple[str, float, str]] = [
        ("firstScanSuccessRate", 0.90, ">="),
        ("replayStableRate", 1.0, ">="),
        ("maxDurationSeconds", 900.0, "<="),
    ]
    for key, threshold, op in numeric_requirements:
        value = runtime_report.get(key)
        if not isinstance(value, (int, float)):
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-MISSING-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric missing or invalid",
                context={"metric": key, "value": value},
            )
            continue
        v = float(value)
        passed = v >= threshold if op == ">=" else v <= threshold
        if not passed:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-FAILED-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric failed threshold",
                context={"metric": key, "value": v, "threshold": threshold, "op": op},
            )

    hard_cap_violations = runtime_report.get("hardCapViolations")
    if not isinstance(hard_cap_violations, int) or hard_cap_violations != 0:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-HARDCAP-VIOLATION",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI detected hard-cap violations",
            context={"hardCapViolations": hard_cap_violations},
        )

    passes_gate = runtime_report.get("passesGate")
    if passes_gate is not True:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-PASS-FLAG-FAILED",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report indicates gate failure",
            context={"passesGate": passes_gate},
        )
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid="FIRST-SCAN-PHASE8-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Phase 8 must require G-PURE-VISION-RUNTIME-FIXTURE gate",
            )

    for phase in phase_plan.get("phases", []):
        phase_id = phase.get("id")
        if phase_id not in {9, 10, 11, 12, 13}:
            continue
        gate_ids = set(phase.get("required_gate_ids", []))
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-PHASE-{phase_id}-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Pure vision runtime fixture gate must be required in phase 9-13",
                context={"phase_id": phase_id},
            )

    constants = {
        c.get("id"): c
        for c in registry.get("constants", [])
        if isinstance(c.get("id"), str) and c.get("status") == "active"
    }
    required_constants = [
        "K-BLUR-FRAME-REJECTION",
        "K-FRAME-MIN-ORB-FEATURES",
        "K-OBS-MIN-BASELINE-PIXELS",
        "K-OBS-REQ-PARALLAX-RATIO",
        "K-OBS-SIGMA-Z-TARGET-M",
        "K-VOLUME-CLOSURE-RATIO-MIN",
        "K-VOLUME-UNKNOWN-VOXEL-MAX",
        "K-THERMAL-CRITICAL-C",
        "K-GUIDANCE-S4-S5-THRESHOLD",
        "K-EVIDENCE-S5-MIN-SOFT",
    ]
    for constant_id in required_constants:
        if constant_id not in constants:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-MISSING-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant is missing",
                context={"constant_id": constant_id},
            )

    expected_values = {
        "K-BLUR-FRAME-REJECTION": 200.0,
        "K-GUIDANCE-S4-S5-THRESHOLD": 0.88,
        "K-EVIDENCE-S5-MIN-SOFT": 0.75,
    }
    for constant_id, expected in expected_values.items():
        if constant_id not in constants:
            continue
        actual = constants[constant_id].get("value")
        if not isinstance(actual, (int, float)) or abs(float(actual) - expected) > 1e-9:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-VALUE-DRIFT-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant value drifted",
                context={"constant_id": constant_id, "actual": actual, "expected": expected},
            )

    if not runtime_report_path.exists():
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-MISSING",
            severity="error",
            scope="first-scan-kpi",
            message=(
                "Missing runtime replay KPI report at governance/generated/first_scan_runtime_metrics.json. "
                "Run governance/scripts/eval_first_scan_runtime_kpi.py before this validation."
            ),
        )
        return

    try:
        runtime_report = json.loads(runtime_report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-JSON-INVALID",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report is not valid JSON",
            context={"error": str(exc)},
        )
        return

    numeric_requirements: List[Tuple[str, float, str]] = [
        ("firstScanSuccessRate", 0.90, ">="),
        ("replayStableRate", 1.0, ">="),
        ("maxDurationSeconds", 900.0, "<="),
    ]
    for key, threshold, op in numeric_requirements:
        value = runtime_report.get(key)
        if not isinstance(value, (int, float)):
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-MISSING-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric missing or invalid",
                context={"metric": key, "value": value},
            )
            continue
        v = float(value)
        passed = v >= threshold if op == ">=" else v <= threshold
        if not passed:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-FAILED-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric failed threshold",
                context={"metric": key, "value": v, "threshold": threshold, "op": op},
            )

    hard_cap_violations = runtime_report.get("hardCapViolations")
    if not isinstance(hard_cap_violations, int) or hard_cap_violations != 0:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-HARDCAP-VIOLATION",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI detected hard-cap violations",
            context={"hardCapViolations": hard_cap_violations},
        )

    passes_gate = runtime_report.get("passesGate")
    if passes_gate is not True:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-PASS-FLAG-FAILED",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report indicates gate failure",
            context={"passesGate": passes_gate},
        )
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid="FIRST-SCAN-PHASE8-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Phase 8 must require G-PURE-VISION-RUNTIME-FIXTURE gate",
            )

    for phase in phase_plan.get("phases", []):
        phase_id = phase.get("id")
        if phase_id not in {9, 10, 11, 12, 13}:
            continue
        gate_ids = set(phase.get("required_gate_ids", []))
        if "G-PURE-VISION-RUNTIME-FIXTURE" not in gate_ids:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-PHASE-{phase_id}-RUNTIME-GATE-MISSING",
                severity="error",
                scope="first-scan-kpi",
                message="Pure vision runtime fixture gate must be required in phase 9-13",
                context={"phase_id": phase_id},
            )

    constants = {
        c.get("id"): c
        for c in registry.get("constants", [])
        if isinstance(c.get("id"), str) and c.get("status") == "active"
    }
    required_constants = [
        "K-BLUR-FRAME-REJECTION",
        "K-FRAME-MIN-ORB-FEATURES",
        "K-OBS-MIN-BASELINE-PIXELS",
        "K-OBS-REQ-PARALLAX-RATIO",
        "K-OBS-SIGMA-Z-TARGET-M",
        "K-VOLUME-CLOSURE-RATIO-MIN",
        "K-VOLUME-UNKNOWN-VOXEL-MAX",
        "K-THERMAL-CRITICAL-C",
        "K-GUIDANCE-S4-S5-THRESHOLD",
        "K-EVIDENCE-S5-MIN-SOFT",
    ]
    for constant_id in required_constants:
        if constant_id not in constants:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-MISSING-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant is missing",
                context={"constant_id": constant_id},
            )

    expected_values = {
        "K-BLUR-FRAME-REJECTION": 200.0,
        "K-GUIDANCE-S4-S5-THRESHOLD": 0.88,
        "K-EVIDENCE-S5-MIN-SOFT": 0.75,
    }
    for constant_id, expected in expected_values.items():
        if constant_id not in constants:
            continue
        actual = constants[constant_id].get("value")
        if not isinstance(actual, (int, float)) or abs(float(actual) - expected) > 1e-9:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-CONSTANT-VALUE-DRIFT-{constant_id}",
                severity="error",
                scope="first-scan-kpi",
                message="First-scan KPI hardpoint constant value drifted",
                context={"constant_id": constant_id, "actual": actual, "expected": expected},
            )

    if not runtime_report_path.exists():
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-MISSING",
            severity="error",
            scope="first-scan-kpi",
            message=(
                "Missing runtime replay KPI report at governance/generated/first_scan_runtime_metrics.json. "
                "Run governance/scripts/eval_first_scan_runtime_kpi.py before this validation."
            ),
        )
        return

    try:
        runtime_report = json.loads(runtime_report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-REPORT-JSON-INVALID",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report is not valid JSON",
            context={"error": str(exc)},
        )
        return

    numeric_requirements: List[Tuple[str, float, str]] = [
        ("firstScanSuccessRate", 0.90, ">="),
        ("replayStableRate", 1.0, ">="),
        ("maxDurationSeconds", 900.0, "<="),
    ]
    for key, threshold, op in numeric_requirements:
        value = runtime_report.get(key)
        if not isinstance(value, (int, float)):
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-MISSING-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric missing or invalid",
                context={"metric": key, "value": value},
            )
            continue
        v = float(value)
        passed = v >= threshold if op == ">=" else v <= threshold
        if not passed:
            add_finding(
                findings,
                fid=f"FIRST-SCAN-RUNTIME-METRIC-FAILED-{key}",
                severity="error",
                scope="first-scan-kpi",
                message="Runtime replay KPI metric failed threshold",
                context={"metric": key, "value": v, "threshold": threshold, "op": op},
            )

    hard_cap_violations = runtime_report.get("hardCapViolations")
    if not isinstance(hard_cap_violations, int) or hard_cap_violations != 0:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-HARDCAP-VIOLATION",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI detected hard-cap violations",
            context={"hardCapViolations": hard_cap_violations},
        )

    passes_gate = runtime_report.get("passesGate")
    if passes_gate is not True:
        add_finding(
            findings,
            fid="FIRST-SCAN-RUNTIME-PASS-FLAG-FAILED",
            severity="error",
            scope="first-scan-kpi",
            message="Runtime replay KPI report indicates gate failure",
            context={"passesGate": passes_gate},
        )


def validate_dual_lane_upload_policy(findings: List[Dict[str, Any]]) -> None:
    phase_plan = load_json(GOV_DIR / "phase_plan.json")
    phase13 = next((p for p in phase_plan.get("phases", []) if p.get("id") == 13), None)
    phase8 = next((p for p in phase_plan.get("phases", []) if p.get("id") == 8), None)
    if phase13 is None:
        add_finding(
            findings,
            fid="DUAL-LANE-PHASE13-MISSING",
            severity="error",
            scope="dual-lane-upload",
            message="Phase 13 is required to enforce dual-lane upload policy",
        )
        return

    gate_ids = set(phase13.get("required_gate_ids", []))
    if "G-DUAL-LANE-UPLOAD-POLICY" not in gate_ids:
        add_finding(
            findings,
            fid="DUAL-LANE-PHASE13-GATE-MISSING",
            severity="error",
            scope="dual-lane-upload",
            message="Phase 13 must require G-DUAL-LANE-UPLOAD-POLICY",
        )

    joined_steps = "\n".join(phase13.get("cursor_steps", []))
    phase8_steps = "\n".join(phase8.get("cursor_steps", [])) if phase8 else ""

    if not re.search(r"S5素材.*优先.*上云", phase8_steps):
        add_finding(
            findings,
            fid="DUAL-LANE-ONLINE-LANE-MISSING",
            severity="error",
            scope="dual-lane-upload",
            message="Phase 8 cursor steps are missing online S5-priority upload marker",
            context={"pattern": r"S5素材.*优先.*上云"},
        )

    if not re.search(r"最终.*全量.*S0-S5.*全部接纳", joined_steps):
        add_finding(
            findings,
            fid="DUAL-LANE-FINAL-LANE-MISSING",
            severity="error",
            scope="dual-lane-upload",
            message="Phase 13 cursor steps are missing final full-acceptance upload marker",
            context={"pattern": r"最终.*全量.*S0-S5.*全部接纳"},
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

    if should_run(scopes, "audit-anchor"):
        validate_audit_anchor_policy(registry, findings)

    if should_run(scopes, "p0-quality"):
        validate_p0_quality_implementation(findings)

    if should_run(scopes, "upload-contract"):
        validate_upload_contract_consistency(findings)

    if should_run(scopes, "first-scan-kpi"):
        validate_first_scan_kpi(findings)

    if should_run(scopes, "dual-lane-upload"):
        validate_dual_lane_upload_policy(findings)

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
