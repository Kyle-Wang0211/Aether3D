#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: Zero-dependency scan using only default tools (grep, no ripgrep).
# Closed-world: scans ONLY App/Capture for banned runtime primitives.
# Tests are validated by swift test rules instead.

ROOT="App/Capture"

# Banned patterns (regex for grep -E).
PATTERNS=(
  'fatalError\('
  'preconditionFailure\('
  'assertionFailure\('
  'precondition\('
  'assert\('
  'dispatchPrecondition\('
  'Timer\.scheduledTimer'
  'DispatchQueue\.main\.asyncAfter'
  '\bDate\(\)'
)

# Closed-world allowlist: exact filename matches only
ALLOWLIST_DATE=(
  "App/Capture/ClockProvider.swift"
)

ALLOWLIST_TIMER=(
  "App/Capture/TimerScheduler.swift"
)

echo "==> prohibit_fatal_patterns: scanning $ROOT"

# Dependency check
if ! command -v grep &> /dev/null; then
  echo "❌ Missing required command: grep"
  echo "   grep is required for pattern scanning. Install via system package manager."
  exit 1
fi

# Check scan root exists
if [[ ! -d "$ROOT" ]]; then
  echo "❌ Missing scan root: $ROOT"
  echo "   Closed-world: scan root must exist. Ensure you are running from repo root."
  exit 1
fi

found=0

# Preprocess: drop full-line comments, and neutralize double-quoted strings (best-effort).
preprocess() {
  # 1) remove lines that are only comments
  # 2) replace "...." with "" (best-effort, no multiline)
  sed -E 's/^[[:space:]]*\/\/.*$//g' | sed -E 's/"[^"]*"/""/g'
}

# Check if file is in allowlist (exact path match)
is_allowed_date() {
  local file="$1"
  for allowed in "${ALLOWLIST_DATE[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

is_allowed_timer() {
  local file="$1"
  for allowed in "${ALLOWLIST_TIMER[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r -d '' f; do
  # Preprocess file once
  body="$(preprocess < "$f")"

  for p in "${PATTERNS[@]}"; do
    # Check allowlist for Date() pattern
    if [[ "$p" == '\bDate\(\)' ]]; then
      if is_allowed_date "$f"; then
        continue  # Allowed in ClockProvider.swift
      fi
    fi
    
    # Check allowlist for Timer.scheduledTimer pattern
    if [[ "$p" == 'Timer\.scheduledTimer' ]]; then
      if is_allowed_timer "$f"; then
        continue  # Allowed in TimerScheduler.swift
      fi
    fi

    # Check for matches
    matches="$(printf "%s" "$body" | grep -nE "$p" || true)"
    if [[ -n "$matches" ]]; then
      while IFS=: read -r line_num line_content; do
        # Skip if line is empty after preprocessing
        [[ -z "$line_content" ]] && continue
        
        echo "❌ BANNED PATTERN: $p"
        echo "   file: $f"
        echo "   line $line_num: $line_content"
        found=1
      done <<< "$matches"
    fi
  done
done < <(find "$ROOT" -type f -name '*.swift' -print0 2>/dev/null || true)

if [[ "$found" -ne 0 ]]; then
  echo "==> prohibit_fatal_patterns FAILED"
  exit 1
fi

echo "==> prohibit_fatal_patterns PASSED"
