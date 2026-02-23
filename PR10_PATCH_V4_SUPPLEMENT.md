# PR#10 — PATCH V4 SUPPLEMENT: Residual Inconsistencies & Final Hardening

> **Status:** MANDATORY SUPPLEMENT — applies ON TOP of V1 (21) + V2 (14) + V3 (9)
> **Applies to:** The Enhanced Plan (`b186ba4e`) after V3 integration
> **Total patches after V4:** 44 + 7 = **51**

---

## PATCH-V4-A: Fix Stale Section Header "35个补丁" → "44个补丁"

**Problem:** Line 44 of the Enhanced Plan says `## 必须遵循的35个补丁要求` but the document now has 44 patches (V1:21 + V2:14 + V3:9).

**Fix:** Change to `## 必须遵循的44个补丁要求`

---

## PATCH-V4-B: Fix Stale Checklist "所有4个新文件" → "所有5个新文件"

**Problem:** Line 675 of the Enhanced Plan checklist still says `所有4个新文件都有宪法合同头` but V3-A mandates NEW_FILE_COUNT=5.

**Fix:** Change to `所有5个新文件都有宪法合同头（PATCH-A）`

---

## PATCH-V4-C: Fix PATCH-K Threshold Inconsistency (90% → 85%)

**Problem:** PATCH-K (line 197) still says `阈值：90%拒绝新上传，95%紧急拒绝所有写入` but V2-L changed the threshold to **85%**. The constant definition section (line 650) correctly says 0.85. This creates a contradiction within the same document.

**Fix:** Change PATCH-K description to:
```
- 阈值：**85%**拒绝新上传（V2-L更新），95%紧急拒绝所有写入
```

---

## PATCH-V4-D: Add Branch & Base Commit Context

**Problem:** The Enhanced Plan has no branch or commit information. An AI agent may operate on the wrong branch.

**Fix:** Add at the very top of the document (after the YAML frontmatter):

```markdown
## CRITICAL: Read This First

**Branch:** `pr10/server-upload-reception` (created from `main`, commit `2e82c96`)
**Switch to it:** `git checkout pr10/server-upload-reception`
**DO NOT touch other PR branches or any non-PR#10 files.**
```

---

## PATCH-V4-E: Add Complete Invariant Text (All 28 INV-U)

**Problem:** The Enhanced Plan only shows 1 example invariant. An AI agent must invent the text for the other 27, which may deviate from the intended specification. The Ultimate Plan (9b8185e0) has all 28 defined.

**Fix:** Add a section between PATCH-B requirements and PATCH-C:

```markdown
### Complete Invariant Definitions (Reference)

**upload_service.py (INV-U1 to INV-U10):**

INV-U1:  Atomic chunk persistence — write to .tmp then rename; partial writes NEVER visible
INV-U2:  Three-way pipeline — read, write, hash in single pass; O(256KB) constant memory
INV-U3:  Chunk ordering — chunks assembled in strict index order (0, 1, 2, ..., N-1)
INV-U4:  Contiguity validation — chunk indices MUST be gapless (no missing indices)
INV-U5:  Size invariant — assembled bundle byte count == declared bundle_size
INV-U6:  Per-chunk hash verification — every chunk re-verified during assembly via timing-safe compare
INV-U7:  fsync before rename — data durably written before atomic rename makes it visible
INV-U8:  Assembly temp isolation — .assembling files NEVER in final bundle path
INV-U9:  Path containment — all file operations confined to upload_dir/{upload_id}/ subtree
INV-U10: Crash recovery — .tmp and .assembling files are detectable and cleanable after crash

**integrity_checker.py (INV-U11 to INV-U20):**

INV-U11: Byte-identical Merkle — Python merkle_compute_root() == Swift MerkleTree.computeRoot()
INV-U12: RFC 9162 domain separation — leaf prefix 0x00, node prefix 0x01, NEVER omitted
INV-U13: Odd node promotion — unpaired nodes promoted WITHOUT re-hashing
INV-U14: Empty tree sentinel — zero-input Merkle root = 32 zero bytes
INV-U15: Domain tag NUL termination — all domain tags include trailing \x00 byte
INV-U16: Timing-safe comparison — ALL hash comparisons via hmac.compare_digest(), NEVER ==
INV-U17: Anti-enumeration — external errors NEVER reveal which verification layer failed
INV-U18: Fail-fast ordering — cheapest checks first (L5→L1→L2→L3→L4)
INV-U19: Zero additional I/O — integrity checker receives pre-computed values, does NO disk reads
INV-U20: Probabilistic formula parity — MUST use ceil(N * (1 - pow(delta, 1.0/N))) matching Swift

**deduplicator.py (INV-U21 to INV-U24):**

INV-U21: Index-backed queries — all dedup queries use existing indexed columns
INV-U22: User-scoped dedup — NEVER return another user's job/session
INV-U23: Race-safe post-assembly check — double-check AFTER assembly, before Job creation
INV-U24: Dedup result immutability — DedupResult is frozen after creation (frozen=True)

**cleanup_handler.py (INV-U25 to INV-U28):**

INV-U25: Fail-open deletion — if deletion raises, log error and continue
INV-U26: Orphan safety margin — orphan directories only deleted after 2× expiry (48h)
INV-U27: DB-before-file — always update DB state BEFORE deleting files
INV-U28: Global cleanup idempotent — running cleanup_global() twice produces no errors
```

---

## PATCH-V4-F: Add Pre-Read File: routes.py and job_service.py

**Problem:** The mandatory pre-read list (PATCH-V3-C) is missing two important files:
1. `server/app/api/routes.py` — maps HTTP methods to handler functions, needed to understand endpoint registration
2. `server/app/services/job_service.py` — existing service in the same package, shows the team's service coding patterns

**Fix:** Add to the pre-read list:

```
11. `server/app/api/routes.py` - 端点路由映射（12个端点），了解如何注册handler
12. `server/app/services/job_service.py` - 现有服务模式参考（同package中的已有实现）
```

Update the count from "10个文件" to "12个文件".

---

## PATCH-V4-G: Remove Duplicate Prohibition and Add Existing complete_upload() Two-Commit Note

**Problem 1:** Lines 751 and 756 both say `不要在DB提交后写入文件` — exact duplication.

**Problem 2:** The existing `complete_upload()` in `upload_handlers.py` has **TWO separate `db.commit()` calls** (lines 445 and 468). The plan says "use a single db.commit()" (V2-H) but doesn't explicitly note that the existing code already has two commits that need to be merged into one.

**Fix 1:** Remove the duplicate prohibition line 756.

**Fix 2:** Add a note to PATCH-V2-H:

```markdown
**NOTE:** The existing `complete_upload()` in `upload_handlers.py` has TWO `db.commit()` calls:
- Line 445: `upload_session.status = "completed"` then `db.commit()`
- Line 468: `db.add(job)`, `db.add(timeline_event)` then `db.commit()`

These TWO commits must be merged into ONE. Replace both with a single `db.commit()`
after ALL three operations (session update + Job creation + TimelineEvent creation).
```

---

## Summary

| Patch | Issue | Severity |
|-------|-------|----------|
| V4-A | Stale header "35" → "44" | LOW (cosmetic) |
| V4-B | Stale checklist "4个" → "5个" | **HIGH** (misleads AI) |
| V4-C | PATCH-K 90% contradicts V2-L 85% | **MEDIUM** (contradictory) |
| V4-D | Missing branch/commit info | **MEDIUM** (wrong branch risk) |
| V4-E | Only 1/28 invariant texts provided | **HIGH** (AI must invent 27) |
| V4-F | Missing routes.py + job_service.py in pre-read | LOW (context gap) |
| V4-G | Duplicate prohibition + missing two-commit note | **MEDIUM** (implementation risk) |

**Updated totals: 44 + 7 = 51 patches across V1-V4.**
