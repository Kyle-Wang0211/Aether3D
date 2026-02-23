---
bypass:
  gates: [Gate1]
  sunset: 2026-12-31
---

**Frontmatter Note:** Above YAML is an example for RFCs enabling gate bypass. Frontmatter must start at line 1 when present. Remove entire frontmatter block (including fence markers) if RFC does not enable bypass.

# RFC-0000: Template

**Status:** Template  
**Author:** @<username>  
**Owner:** @kaidongwang  
**Created:** YYYY-MM-DD  
**Superseded by:** N/A  
**Effective Until:** N/A

**Template Note:** This file is a permanent template. Status field is fixed at "Template" and never changes to Draft/Accepted/Rejected/Superseded.

## 1. Motivation

Explain why this change is needed.

Minimum: 300 non-whitespace characters.

**Character Counting Method (SSOT):**

Count all non-whitespace characters in section raw markdown text:
- Includes: letters, digits, punctuation, markdown syntax characters
- Excludes: spaces, tabs, newlines
- Includes: content inside code blocks and other markdown constructs

## 2. Scope

**In Scope:**
- List specific items

**Out of Scope:**
- List explicitly excluded items

Minimum: 200 non-whitespace characters for entire section.

## 3. Design

Technical design and implementation approach.

Minimum: 600 non-whitespace characters.

## 4. Alternatives

Alternatives considered and reasons for rejection.

Minimum: 300 non-whitespace characters.

## 5. Risks

Identified risks and mitigation strategies.

Minimum: 300 non-whitespace characters.

## 6. Rollback

Step-by-step rollback procedure if implementation fails.

Minimum: 300 non-whitespace characters.

## Incident RFC Additional Requirements

RFCs addressing governance incidents must include:
- **Timeline:** Chronological event sequence
- **Root Cause:** Technical or process failure analysis
- **Impact:** Affected systems and scope
- **Fix:** Immediate remediation actions taken
- **Prevention:** Long-term safeguards

## Gate-Related RFC Requirements

RFCs modifying gate system must reference GATES_POLICY.md sections by title (not number).

Example: "Per GATES_POLICY.md 'Gate Definitions Table' section" (not "Section 2.2").

