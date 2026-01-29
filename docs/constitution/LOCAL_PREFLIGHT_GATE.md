# Local Pre-flight Gate

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All contributors before pushing code

---

## §0 PURPOSE

This document establishes **local pre-flight checks** that MUST pass before `git push`.

**Rationale**:
- CI queues are shared resources
- Failed CI runs waste 5-15 minutes per run
- Obvious errors (syntax, banned patterns) should be caught locally
- "Works on my machine" is not an excuse

---

## §1 MANDATORY LOCAL CHECKS

### §1.1 Check Categories

| Category | Check | Failure = Block Push |
|----------|-------|---------------------|
| Syntax | Swift/Python compiles | Yes |
| Banned Patterns | No Date()/datetime.now() in production | Yes |
| SSOT Integrity | Hash files match documents | Yes |
| Test Smoke | At least unit tests pass | Recommended |

### §1.2 Check Timing

```
Developer writes code
       │
       ▼
git add <files>
       │
       ▼
git commit -m "message"
       │
       ▼
[PRE-PUSH HOOK RUNS] ◄── This document defines what runs here
       │
       ├── Pass → git push proceeds
       │
       └── Fail → Push blocked, developer fixes locally
```

---

## §2 PRE-PUSH HOOK

### §2.1 Installation

**Automatic** (recommended):
```bash
# Run once after clone
./scripts/install-hooks.sh
```

**Manual**:
```bash
cp scripts/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

### §2.2 Hook Implementation

**File**: `.git/hooks/pre-push` (or `scripts/pre-push`)

```bash
#!/bin/bash
# Pre-push hook for PR1 Constitution compliance
# Source: LOCAL_PREFLIGHT_GATE.md §2.2

set -e

echo "╔════════════════════════════════════════╗"
echo "║     LOCAL PRE-FLIGHT CHECK             ║"
echo "╚════════════════════════════════════════╝"

FAILED=0

# §1.1 Check 1: Syntax
echo "▶ [1/4] Checking Swift syntax..."
if ! swift build --target Core 2>/dev/null; then
    echo "  ✗ Swift build failed"
    FAILED=1
else
    echo "  ✓ Swift syntax OK"
fi

# §1.1 Check 2: Banned Patterns
echo "▶ [2/4] Scanning for banned patterns..."
if ! ./scripts/scan-prohibited-patterns.sh; then
    echo "  ✗ Banned patterns found"
    FAILED=1
else
    echo "  ✓ No banned patterns"
fi

# §1.1 Check 3: SSOT Integrity
echo "▶ [3/4] Verifying SSOT integrity..."
if ! ./scripts/verify-ssot-integrity.sh; then
    echo "  ✗ SSOT integrity failed"
    FAILED=1
else
    echo "  ✓ SSOT integrity OK"
fi

# §1.1 Check 4: Smoke Test (optional but recommended)
echo "▶ [4/4] Running smoke tests..."
if swift test --filter SmokeTests 2>/dev/null; then
    echo "  ✓ Smoke tests passed"
else
    echo "  ⚠ Smoke tests failed (warning only)"
fi

echo ""
if [ $FAILED -ne 0 ]; then
    echo "╔════════════════════════════════════════╗"
    echo "║  ✗ PRE-FLIGHT FAILED - PUSH BLOCKED    ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "Fix the issues above and try again."
    exit 1
else
    echo "╔════════════════════════════════════════╗"
    echo "║  ✓ PRE-FLIGHT PASSED - PUSH ALLOWED    ║"
    echo "╚════════════════════════════════════════╝"
    exit 0
fi
```

---

## §3 SUPPORT SCRIPTS

### §3.1 Prohibited Pattern Scanner

**File**: `scripts/scan-prohibited-patterns.sh`

```bash
#!/bin/bash
# Scan for CI_HARDENING_CONSTITUTION prohibited patterns
# Source: LOCAL_PREFLIGHT_GATE.md §3.1

set -e

VIOLATIONS=0

# Swift prohibited patterns
SWIFT_PATTERNS=(
    'Date()'
    'Timer\.scheduledTimer'
    'DispatchQueue.*asyncAfter'
    'Thread\.sleep'
    'Task\.sleep'
)

# Python prohibited patterns
PYTHON_PATTERNS=(
    'datetime\.now()'
    'datetime\.utcnow()'
    'time\.time()'
    'time\.sleep('
)

echo "Scanning Swift files..."
for pattern in "${SWIFT_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.swift" Sources/ 2>/dev/null | grep -v "Default.*Provider" | grep -v "Tests/" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

echo "Scanning Python files..."
for pattern in "${PYTHON_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.py" src/ 2>/dev/null | grep -v "default.*provider" | grep -v "test_" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

if [ $VIOLATIONS -gt 0 ]; then
    echo ""
    echo "Found $VIOLATIONS violation(s). See CI_HARDENING_CONSTITUTION.md §1."
    exit 1
fi

echo "No prohibited patterns found."
exit 0
```

### §3.2 SSOT Integrity Verifier

**File**: `scripts/verify-ssot-integrity.sh`

```bash
#!/bin/bash
# Verify SSOT document hash integrity
# Source: LOCAL_PREFLIGHT_GATE.md §3.2

set -e

FAILED=0

# Check constitution documents
for md in docs/constitution/*.md; do
    [ -f "$md" ] || continue

    hash_file="${md%.md}.hash"
    if [ ! -f "$hash_file" ]; then
        # Hash file not required for all documents yet
        continue
    fi

    expected=$(cat "$hash_file" | tr -d '[:space:]')
    actual=$(shasum -a 256 "$md" | cut -d' ' -f1)

    if [ "$expected" != "$actual" ]; then
        echo "INTEGRITY VIOLATION: $md"
        echo "  Document has been modified without updating hash"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        echo "  Fix: shasum -a 256 $md | cut -d' ' -f1 > $hash_file"
        FAILED=1
    fi
done

# Check constants files have headers
for swift in Core/Constants/*Constants.swift; do
    [ -f "$swift" ] || continue

    if ! grep -q "CONSTITUTIONAL CONTRACT" "$swift"; then
        echo "HEADER MISSING: $swift"
        echo "  Constants file missing 'CONSTITUTIONAL CONTRACT' header"
        FAILED=1
    fi
done

if [ $FAILED -ne 0 ]; then
    exit 1
fi

echo "SSOT integrity verified."
exit 0
```

---

## §4 CI INTEGRATION

### §4.1 Preflight Job

CI SHOULD mirror local checks:

```yaml
# .github/workflows/ci.yml
jobs:
  preflight:
    name: Pre-flight Checks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Scan Prohibited Patterns
        run: ./scripts/scan-prohibited-patterns.sh
      - name: Verify SSOT Integrity
        run: ./scripts/verify-ssot-integrity.sh
```

### §4.2 Feedback Loop

If CI fails but local passed:
1. Developer's hook may be outdated
2. Run `./scripts/install-hooks.sh` to update
3. If still mismatch, report to maintainers

---

## §5 DEVELOPER EXPERIENCE

### §5.1 Speed Requirement

Local pre-flight MUST complete in **< 30 seconds** on average hardware.

If checks take longer:
- Move slow checks to CI-only
- Optimize scripts
- Use incremental checking

### §5.2 Clear Error Messages

Every failure MUST include:
1. What failed
2. Where to look (file:line if possible)
3. How to fix (link to constitution section)

### §5.3 IDE Integration (Optional)

For VSCode:
```json
// .vscode/tasks.json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Pre-flight Check",
      "type": "shell",
      "command": "./scripts/pre-push",
      "problemMatcher": []
    }
  ]
}
```

---

## §6 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial constitution |

---

**END OF DOCUMENT**
