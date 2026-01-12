# SSOT Lint Exemptions Registry

> All lint rule exemptions must be registered here with justification.
> Zero exemptions is the goal for Core/Constants/.

---

<!-- SSOT:EXEMPTIONS:BEGIN -->
## Active Exemptions

| File | Line | Rule | Justification | Added | Expires |
|------|------|------|---------------|-------|---------|
| — | — | — | No exemptions | — | — |
<!-- SSOT:EXEMPTIONS:END -->

---

## Exemption Guidelines

1. **Justification Required**: Every exemption must explain why the rule cannot be followed
2. **Expiration Preferred**: Set an expiration date when possible
3. **PR Review**: Adding exemptions requires explicit PR approval
4. **Minimize Scope**: Exempt specific lines, not entire files

## How to Add an Exemption

1. Add `// SSOT_EXEMPTION` or `// LINT:ALLOW:<RULE>` comment in code
2. Register in this file with justification
3. Include in PR description

## Exemption Categories

- `LEGACY`: Pre-existing code, planned for refactor
- `EXTERNAL`: Third-party code constraints
- `PLATFORM`: Platform-specific requirements
- `TEMPORARY`: Short-term workaround with expiration
