#!/usr/bin/env python3
"""Generate deterministic Cursor phase runbooks from governance SSOT files."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[2]
GOV_DIR = ROOT / "governance"


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Cursor runbooks from governance files")
    parser.add_argument(
        "--output",
        default="governance/generated/phases",
        help="Output directory for generated phase runbooks",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Do not write files; fail if generated content differs from files on disk.",
    )
    return parser.parse_args()


def format_phase_runbook(
    phase: Dict[str, Any],
    contracts_by_id: Dict[str, Dict[str, Any]],
    gates_by_id: Dict[str, Dict[str, Any]],
) -> str:
    pid = phase["id"]
    lines: List[str] = []
    lines.append(f"# Phase {pid:02d} Runbook - {phase['name']}")
    lines.append("")
    lines.append("## Objective")
    lines.append(phase["objective"])
    lines.append("")

    prereqs = phase.get("prerequisite_phase_ids", [])
    lines.append("## Entry Criteria")
    if prereqs:
        lines.append(f"- Prerequisite phases passed: {', '.join(str(x) for x in prereqs)}")
    else:
        lines.append("- Prerequisite phases passed: none")
    lines.append(f"- Track: {phase['track']}")
    lines.append("")

    lines.append("## Required Contracts")
    for cid in phase.get("required_contract_ids", []):
        contract = contracts_by_id.get(cid)
        if contract:
            lines.append(f"- `{cid}` [{contract['status']}] - {contract['title']}")
        else:
            lines.append(f"- `{cid}` [missing] - unresolved reference")
    lines.append("")

    lines.append("## Required Gates")
    for gid in phase.get("required_gate_ids", []):
        gate = gates_by_id.get(gid)
        if gate:
            lines.append(f"- `{gid}` ({gate['severity']}) - {gate['name']}")
        else:
            lines.append(f"- `{gid}` (missing)")
    lines.append("")

    lines.append("## Cursor Steps")
    for idx, step in enumerate(phase.get("cursor_steps", []), start=1):
        lines.append(f"{idx}. {step}")
    lines.append("")

    lines.append("## Gate Commands")
    for gid in phase.get("required_gate_ids", []):
        gate = gates_by_id.get(gid)
        lines.append(f"### {gid}")
        if not gate:
            lines.append("Missing gate definition.")
            lines.append("")
            continue
        lines.append(gate["name"])
        lines.append("")
        lines.append("```bash")
        for command in gate.get("commands", []):
            lines.append(command)
        lines.append("```")
        lines.append("")
        lines.append("Expected artifacts:")
        for artifact in gate.get("artifacts", []):
            lines.append(f"- `{artifact}`")
        lines.append("")

    lines.append("## Deliverables")
    for deliverable in phase.get("deliverables", []):
        lines.append(f"- `{deliverable}`")
    lines.append("")

    lines.append("## Exit Criteria")
    lines.append("- All required gates pass.")
    lines.append("- Governance strict validation returns zero errors.")
    lines.append(f"- Tag checkpoint `phase-{pid}-pass` on `codex/protocol-governance-integration`.")
    lines.append("")

    return "\n".join(lines)


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "phase"


def render_index(phases: List[Dict[str, Any]]) -> str:
    lines: List[str] = []
    lines.append("# Cursor Phase Runbook Index")
    lines.append("")
    lines.append("Generated from `governance/phase_plan.json`.")
    lines.append("")
    lines.append("| Phase | Track | Name | File |")
    lines.append("|---|---|---|---|")
    for phase in phases:
        pid = phase["id"]
        filename = f"phase-{pid:02d}-{slugify(phase['name'])}.md"
        lines.append(f"| {pid} | {phase['track']} | {phase['name']} | `{filename}` |")
    lines.append("")
    return "\n".join(lines)


def normalize(text: str) -> str:
    if not text.endswith("\n"):
        return text + "\n"
    return text


def main() -> int:
    args = parse_args()

    registry = load_json(GOV_DIR / "contract_registry.json")
    phase_plan = load_json(GOV_DIR / "phase_plan.json")
    gate_matrix = load_json(GOV_DIR / "ci_gate_matrix.json")

    contracts_by_id = {c["id"]: c for c in registry.get("contracts", [])}
    gates_by_id = {g["id"]: g for g in gate_matrix.get("gates", [])}
    phases = sorted(phase_plan.get("phases", []), key=lambda p: p["id"])

    out_dir = ROOT / args.output
    mismatches: List[str] = []

    if not args.check:
        out_dir.mkdir(parents=True, exist_ok=True)
        for stale in out_dir.glob("phase-*.md"):
            stale.unlink()

    for phase in phases:
        pid = phase["id"]
        filename = f"phase-{pid:02d}-{slugify(phase['name'])}.md"
        path = out_dir / filename
        content = normalize(format_phase_runbook(phase, contracts_by_id, gates_by_id))

        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                mismatches.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(content, encoding="utf-8")

    index_content = normalize(render_index(phases))
    index_path = out_dir / "index.md"

    if args.check:
        if not index_path.exists() or index_path.read_text(encoding="utf-8") != index_content:
            mismatches.append(str(index_path.relative_to(ROOT)))
    else:
        index_path.write_text(index_content, encoding="utf-8")

    if args.check and mismatches:
        print("runbook-check: mismatches found")
        for mismatch in mismatches:
            print(f" - {mismatch}")
        return 1

    mode = "check" if args.check else "write"
    print(f"runbook-generator: {mode} mode completed for {len(phases)} phases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
