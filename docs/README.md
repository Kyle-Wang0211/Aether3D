# Documentation Index (Source of Truth)

## Authoritative Specifications (SSOT)

These documents are the ONLY Source of Truth (SSOT).

### Root Documents
- [WHITEBOX.md](WHITEBOX.md)
- [ACCEPTANCE.md](ACCEPTANCE.md)
- [WORKFLOW.md](WORKFLOW.md)
- [ROLLBACK.md](ROLLBACK.md)

### Constitution Documents
Within `docs/constitution/`, only files referenced by [docs/constitution/INDEX.md](constitution/INDEX.md) are authoritative.

## SSOT Boundary

- `docs/WHITEBOX.md`, `docs/ACCEPTANCE.md`, `docs/WORKFLOW.md`, `docs/ROLLBACK.md` are SSOT.
- `docs/constitution/` is an active directory, but NOT all files inside are automatically SSOT.
- Only the constitution files explicitly referenced by `docs/constitution/INDEX.md` are considered authoritative.

## Do Not Infer SSOT By Filenames

Do NOT infer SSOT from file names (e.g., " 2", "legacy", version strings). SSOT is explicit only. If multiple similar docs exist, treat `_archive` as non-authoritative and follow the SSOT list above.

## Archived Documents

All content under `docs/_archive/` is historical and NOT authoritative. Do NOT use archived documents as input for implementation or reasoning.

