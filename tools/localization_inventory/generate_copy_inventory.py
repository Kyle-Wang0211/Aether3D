#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PAIR_RE = re.compile(
    r"""\bt\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)""",
    re.DOTALL,
)
STRING_RE = re.compile(r'''"((?:[^"\\]|\\.)*)"''', re.DOTALL)
HAN_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
SWIFT_EXTENSIONS = {".swift"}
SCAN_DIRS = ("App", "Core")
SKIP_PARTS = {".build", "Tests", "Archive", "artifacts", "generated", "server", "aether_cpp"}


@dataclass
class CopyEntry:
    entry_id: str
    file_path: str
    line: int
    kind: str
    status: str
    code: str
    zh_text: str
    en_text: str


def decode_swift_string(raw: str) -> str:
    value = raw.replace(r"\\", "\\")
    value = value.replace(r"\"", '"')
    value = value.replace(r"\n", "\n")
    value = value.replace(r"\t", "\t")
    return value


def compact_code(snippet: str) -> str:
    return " ".join(snippet.strip().split())


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def make_entry_id(relative_path: str, line: int, kind: str, code: str) -> str:
    digest = hashlib.sha1(f"{relative_path}:{line}:{kind}:{code}".encode("utf-8")).hexdigest()[:12]
    return f"COPY_{digest}"


def iter_swift_files(repo_root: Path) -> Iterable[Path]:
    for top_level in SCAN_DIRS:
        base = repo_root / top_level
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.suffix not in SWIFT_EXTENSIONS:
                continue
            if any(part in SKIP_PARTS for part in path.parts):
                continue
            yield path


def extract_entries(repo_root: Path) -> list[CopyEntry]:
    entries: list[CopyEntry] = []

    for file_path in iter_swift_files(repo_root):
        text = file_path.read_text(encoding="utf-8")
        relative_path = str(file_path.relative_to(repo_root))
        occupied_spans: list[tuple[int, int]] = []

        for match in PAIR_RE.finditer(text):
            zh_text = decode_swift_string(match.group(1))
            en_text = decode_swift_string(match.group(2))
            line = line_number_for_offset(text, match.start())
            code = compact_code(match.group(0))
            entry_id = make_entry_id(relative_path, line, "bilingual_pair", code)
            entries.append(
                CopyEntry(
                    entry_id=entry_id,
                    file_path=relative_path,
                    line=line,
                    kind="bilingual_pair",
                    status="paired",
                    code=code,
                    zh_text=zh_text,
                    en_text=en_text,
                )
            )
            occupied_spans.append((match.start(), match.end()))

        for match in STRING_RE.finditer(text):
            start = match.start()
            end = match.end()
            if any(start >= span_start and end <= span_end for span_start, span_end in occupied_spans):
                continue

            raw_value = match.group(1)
            if not HAN_RE.search(raw_value):
                continue

            literal_text = decode_swift_string(raw_value)
            line = line_number_for_offset(text, start)
            code = compact_code(text.splitlines()[line - 1])
            entry_id = make_entry_id(relative_path, line, "source_literal", code)
            entries.append(
                CopyEntry(
                    entry_id=entry_id,
                    file_path=relative_path,
                    line=line,
                    kind="source_literal",
                    status="needs_translation",
                    code=code,
                    zh_text=literal_text,
                    en_text="",
                )
            )

    entries.sort(key=lambda item: (item.file_path, item.line, item.entry_id))
    return entries


def write_tsv(path: Path, entries: list[CopyEntry], language: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["id", "file", "line", "kind", "status", "code", "text"])
        for entry in entries:
            writer.writerow(
                [
                    entry.entry_id,
                    entry.file_path,
                    entry.line,
                    entry.kind,
                    entry.status,
                    entry.code,
                    entry.en_text if language == "en" else entry.zh_text,
                ]
            )


def write_manifest(path: Path, entries: list[CopyEntry]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "entry_count": len(entries),
        "paired_count": sum(1 for entry in entries if entry.kind == "bilingual_pair"),
        "needs_translation_count": sum(1 for entry in entries if entry.status == "needs_translation"),
        "entries": [
            {
                "id": entry.entry_id,
                "file": entry.file_path,
                "line": entry.line,
                "kind": entry.kind,
                "status": entry.status,
                "code": entry.code,
                "zh": entry.zh_text,
                "en": entry.en_text,
            }
            for entry in entries
        ],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_readme(path: Path, entries: list[CopyEntry], repo_root: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    paired_count = sum(1 for entry in entries if entry.kind == "bilingual_pair")
    needs_translation_count = sum(1 for entry in entries if entry.status == "needs_translation")
    path.write_text(
        "\n".join(
            [
                "# Copy Inventory",
                "",
                "This folder is generated by `tools/localization_inventory/generate_copy_inventory.py`.",
                "",
                f"- Repo root: `{repo_root}`",
                f"- Total entries: `{len(entries)}`",
                f"- Paired zh/en entries: `{paired_count}`",
                f"- Source literals still needing English fill-in: `{needs_translation_count}`",
                "",
                "Files:",
                "- `zh-CN/copy_inventory.tsv`: the Chinese source-side inventory.",
                "- `en-US/copy_inventory.tsv`: the English-side inventory, aligned by the same `id` field.",
                "- `inventory_manifest.json`: the machine-readable combined manifest.",
                "",
                "Each row keeps the same stable `id`, file path, line number, and compact code snippet so future translation passes can diff by code location instead of re-searching manually.",
                "",
                "Regenerate:",
                "```bash",
                "python3 tools/localization_inventory/generate_copy_inventory.py --repo-root . --output-dir docs/localization_inventory",
                "```",
                "",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate zh/en copy inventory tables from Swift source.")
    parser.add_argument("--repo-root", required=True, help="Path to the repository root to scan.")
    parser.add_argument("--output-dir", required=True, help="Directory that will receive the generated inventory.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    output_dir = Path(args.output_dir).resolve()

    entries = extract_entries(repo_root)
    write_tsv(output_dir / "zh-CN" / "copy_inventory.tsv", entries, language="zh")
    write_tsv(output_dir / "en-US" / "copy_inventory.tsv", entries, language="en")
    write_manifest(output_dir / "inventory_manifest.json", entries)
    write_readme(output_dir / "README.md", entries, repo_root)


if __name__ == "__main__":
    main()
