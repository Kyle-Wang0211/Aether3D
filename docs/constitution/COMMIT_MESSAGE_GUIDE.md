# Commit Message Guide

**Document Version:** 1.1.1  
**Status:** IMMUTABLE

---

## Overview

This guide explains how to write commit messages that pass repository hooks and follow Conventional Commits format.

---

## Commit Message Format

### Header (First Line)
**Format:** `<type>(<scope>): <subject>`

**Required:**
- Must be a single line (max 72 characters recommended)
- Must follow Conventional Commits format
- Must not include "SSOT-Change: yes/no" in the header

**Examples:**
```
ci(ssot-foundation): fix Xcode selection and add Linux preflight gate
docs(constitution): establish SSOT Foundation v1.1 with CI hardening
test(ssot): add cross-platform consistency shadow suite
fix(ci): remove hardcoded Xcode paths from workflow
```

### Body
**Format:**
```
SSOT-Change: yes

## Changes

[Detailed description of changes]

## Invariants Preserved

[Confirmation that invariants are preserved]

## Testing

[What was tested]
```

**Required:**
- `SSOT-Change: yes` or `SSOT-Change: no` must be on its own line in the body
- Use blank lines to separate sections
- Use markdown formatting for clarity

---

## Using the Commit Template

### Method 1: Use Template File
```bash
git commit -t COMMIT_MESSAGE_TEMPLATE.txt
```

This opens your editor with the template pre-filled. Edit as needed, then save and close.

### Method 2: Manual Format
```bash
git commit -m "ci(ssot-foundation): fix Xcode selection" -m "SSOT-Change: yes" -m "" -m "## Changes" -m "- Removed hardcoded Xcode paths" -m "- Added setup-xcode action"
```

### Method 3: Editor with Template
```bash
# Set template as commit template
git config commit.template COMMIT_MESSAGE_TEMPLATE.txt

# Then commit normally
git commit
```

---

## Common Types

- `ci`: Changes to CI/CD configuration
- `docs`: Documentation changes
- `test`: Test additions or changes
- `fix`: Bug fixes
- `feat`: New features (rare for SSOT Foundation)
- `refactor`: Code refactoring
- `chore`: Maintenance tasks

---

## Common Scopes

- `ssot-foundation`: SSOT Foundation related changes
- `constitution`: Constitution documentation
- `ci`: CI/CD related
- `constants`: Constants/catalogs

---

## Validation

Commit messages are validated by repository hooks:
- Header must match `<type>(<scope>): <subject>` pattern
- `SSOT-Change` trailer must be in body, not header
- Subject should be concise and descriptive

---

## Examples

### Good Commit Message
```
ci(ssot-foundation): fix Xcode selection and add Linux preflight gate

SSOT-Change: yes

## Changes
- Removed hardcoded /Applications/Xcode_*.app paths
- Added maxim-lobanov/setup-xcode@v1 action
- Pinned runs-on to macos-14

## Invariants Preserved
- No algorithms added
- Append-only preserved
```

### Bad Commit Message (Will Fail Hook)
```
SSOT-Change: yes - Fixed Xcode selection

This commit fixes the Xcode selection issue...
```
**Problem:** Header doesn't follow `<type>(<scope>): <subject>` format

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Audience:** All contributors  
**Purpose:** Ensure commit messages pass hooks and follow standards
