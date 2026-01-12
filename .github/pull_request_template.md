# What / Why
- **Scope:** (one sentence)
- **Non-goals:** (explicitly list what's NOT included)

# SSOT Contract Impact
- [ ] **No SSOT change** (constants/thresholds/error codes unchanged)
- [ ] **SSOT changed** → fill below:
  - Changed: 
  - Migration: (none / snapshot update / doc update)
  - Backward compatible: (yes/no)

# Verification
- [ ] `swift build` passed
- [ ] `swift test` passed (or filtered tests)

# Anti-rot Gates
- [ ] No `fatalError` / `preconditionFailure` in Core/
- [ ] No magic numbers outside Core/Constants/
- [ ] New error codes registered + tested

# Key Files Changed
- 

