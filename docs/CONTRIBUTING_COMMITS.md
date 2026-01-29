# Commit Message Convention

Format:
```
<type>(<scope>): <subject>

<body>

SSOT-Change: yes|no
```

Types: feat, fix, refactor, test, docs, chore
Scopes: ssot, constants, errorcodes, registry, validation, tests, ci

## SSOT Declaration Requirement

Every commit **must** include an `SSOT-Change` footer:

```
SSOT-Change: yes
```
or
```
SSOT-Change: no
```

### When to Use `SSOT-Change: yes`

Use `yes` when your commit modifies **any** of these paths:

| Path | Description |
|------|-------------|
| `Core/Constants/` | System constants |
| `Core/SSOT/` | Evidence escalation |
| `docs/constitution/` | Governance documents |
| `.github/workflows/` | CI workflows |
| `scripts/ci/` | CI scripts |
| `scripts/hooks/` | Git hooks |
| `Core/Models/Observation*.swift` | Observation model |
| `Core/Models/EvidenceEscalation*.swift` | Evidence types |

### When to Use `SSOT-Change: no`

Use `no` for all other changes that don't touch the paths above.

### Examples

**Good - SSOT change:**
```
feat(ssot): add new quality threshold

Added QualityThresholds.minConfidence for gray-to-white transitions.

SSOT-Change: yes
```

**Good - Non-SSOT change:**
```
feat(app): add settings screen

SSOT-Change: no
```

**Bad - Missing footer:**
```
feat(app): add feature

(This will be rejected by commit-msg hook)
```

**Bad - Wrong value for SSOT path:**
```
docs(constitution): update policy

SSOT-Change: no
(This will be rejected - constitution changes require yes)
```

### Enforcement

1. **Local**: `commit-msg` hook validates format
2. **Local**: `pre-push` hook runs quality gate
3. **CI**: Independent SSOT gate verification (cannot be bypassed)
4. **GitHub**: CODEOWNERS requires approval for protected paths

## Examples

- `feat(ssot): add quality threshold specs`
  `SSOT-Change: yes`

- `test(constants): add smoke tests`
  `SSOT-Change: no`

