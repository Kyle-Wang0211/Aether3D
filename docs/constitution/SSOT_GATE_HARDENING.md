# SSOT Gate Hardening

> **Version:** 1.0.0
> **Branch:** infra/ssot-gate-hardening
> **Status:** Implementation Complete

## Overview

This document describes the hardening measures applied to SSOT (Single Source of Truth) push detection mechanisms. These changes prevent accidental or malicious modifications to critical system constants and governance documents.

## Changes Summary

### A. Detection Enhancements

| ID | Change | File | Impact |
|----|--------|------|--------|
| A1 | Fix commit-msg regex `$` anchor | scripts/hooks/commit-msg | Prevents trailing content bypass |
| A2 | DecisionPolicy bypass → hard fail | scripts/quality_lint.sh | Enforces state transition boundary |
| A3 | Expand SSOT path prefixes | scripts/ci/ssot_declaration_check.sh | Covers more critical paths |
| A4 | Add hash integrity verification | scripts/ci/ssot_integrity_verify.sh | Detects document tampering |
| A5 | Add deletion protection | scripts/ci/ssot_declaration_check.sh | Prevents SSOT file removal |
| A6 | Expand git diff range for CI | scripts/ci/ssot_declaration_check.sh | Catches all commits in PR |
| A7 | Add CODEOWNERS | .github/CODEOWNERS | Requires owner approval |
| A8 | Add CI SSOT gate | .github/workflows/ci.yml | Prevents --no-verify bypass |
| A9 | Add constants consistency check | scripts/ci/ssot_consistency_verify.sh | Code-doc value matching |
| A10 | Add CI integrity verification | scripts/ci/ci_integrity_verify.sh | Prevents CI self-modification |

### B. Test Coverage

| ID | Test File | Coverage |
|----|-----------|----------|
| B1 | Tests/CI/SSOTDeclarationTests.swift | Declaration script logic |
| B2 | Tests/CI/CommitMessageFormatTests.swift | Commit message regex |
| B3 | Tests/CI/SSOTIntegrityTests.swift | Hash and header verification |
| B4 | Tests/CI/SSOTConsistencyTests.swift | Code-doc value matching |
| B5 | Tests/CI/SSOTPathPrefixTests.swift | Path coverage completeness |
| B6 | Tests/CI/SSOTDeletionProtectionTests.swift | Deletion detection |
| B7 | Tests/QualityPreCheck/DecisionPolicyBypassTests.swift | Policy bypass detection |
| B8 | Tests/CI/SSOTGateIntegrationTests.swift | End-to-end pipeline |

### C. Additional Enhancements

| ID | Enhancement | File | Purpose |
|----|-------------|------|---------|
| N1 | SSOT audit log | scripts/ci/ssot_audit_log.sh | Machine-readable change tracking |
| N2 | Pre-commit hook | scripts/hooks/pre-commit | Early detection warning |
| N3 | SSOT dependency check | scripts/ci/ssot_dependency_check.sh | Cross-reference validation |
| N4 | Branch protection verify | scripts/ci/verify_branch_protection.sh | GitHub API validation |

## Protected Paths

All paths listed below require `SSOT-Change: yes` in commit messages:

```
Core/Constants/
Core/SSOT/
docs/constitution/
.github/workflows/
scripts/ci/
scripts/hooks/
Core/Models/Observation*.swift
Core/Models/EvidenceEscalation*.swift
```

## Enforcement Layers

```
Layer 1: commit-msg hook
   ↓ (can bypass with --no-verify)
Layer 2: pre-push hook
   ↓ (can bypass with --no-verify)
Layer 3: CI ssot-declaration-gate
   ↓ (CANNOT bypass - independent verification)
Layer 4: CODEOWNERS review
   ↓ (CANNOT bypass - GitHub enforced)
Layer 5: Branch protection
   ↓ (CANNOT bypass - GitHub enforced)
```

## Commit Message Format

```
<type>(<scope>): <subject>

<body>

SSOT-Change: yes|no
```

### Requirements

1. **Header**: Must match `^(feat|fix|refactor|test|docs|chore)\([a-z0-9_-]+\): .{1,72}$`
2. **Footer**: Must include exactly `SSOT-Change: yes` or `SSOT-Change: no`
3. **SSOT paths**: Changes to protected paths require `SSOT-Change: yes`

## Verification Commands

```bash
# Run SSOT declaration check
bash scripts/ci/ssot_declaration_check.sh

# Run SSOT integrity check
bash scripts/ci/ssot_integrity_verify.sh

# Run SSOT consistency check
bash scripts/ci/ssot_consistency_verify.sh

# Run CI integrity check
bash scripts/ci/ci_integrity_verify.sh

# Run full quality gate
bash scripts/quality_gate.sh
```

## Related Documents

- [GATES_POLICY.md](constitution/GATES_POLICY.md) - Gate definitions and bypass rules
- [SSOT_CONSTANTS.md](constitution/SSOT_CONSTANTS.md) - Constants registry
- [CONTRIBUTING_COMMITS.md](../CONTRIBUTING_COMMITS.md) - Commit message guidelines
