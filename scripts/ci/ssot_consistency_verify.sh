#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: SSOT constants value consistency check
# Verifies that Swift code values match Markdown documentation
# Zero external dependencies (uses only grep, awk, sed)

echo "==> SSOT Constants Consistency Verification"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

FAILED=0
CHECKED=0
MISMATCHES=0

SSOT_DOC="docs/constitution/SSOT_CONSTANTS.md"
CONSTANTS_DIR="Core/Constants"

if [ ! -f "$SSOT_DOC" ]; then
  echo "❌ SSOT_CONSTANTS.md not found"
  exit 1
fi

# ============================================================================
# Extract constants from Markdown tables and verify against Swift
# ============================================================================

echo "[1/2] Extracting constants from SSOT_CONSTANTS.md..."

# Function to extract value from Swift file
extract_swift_value() {
  local swift_file="$1"
  local prop_name="$2"
  
  if [ ! -f "$swift_file" ]; then
    echo "NOT_FOUND"
    return
  fi
  
  # Look for: static let propName = value or static let propName: Type = value
  local swift_value=$(grep -E "static\s+(let|var)\s+$prop_name\s*(:|=)" "$swift_file" 2>/dev/null | \
    sed -E 's/.*=\s*([0-9.]+).*/\1/' | head -1 || echo "NOT_FOUND")
  
  # Handle infinity
  if [[ "$swift_value" == "NOT_FOUND" ]]; then
    if grep -qE "$prop_name.*\.infinity|$prop_name.*Double\.infinity" "$swift_file" 2>/dev/null; then
      echo "∞"
      return
    fi
  fi
  
  echo "$swift_value"
}

# Parse SYSTEM_CONSTANTS section
while IFS='|' read -r _ ssot_id value unit _; do
  # Skip header rows and empty lines
  [[ "$ssot_id" =~ ^[[:space:]]*$ ]] && continue
  [[ "$ssot_id" =~ "SSOT_ID" ]] && continue
  [[ "$ssot_id" =~ "---" ]] && continue

  # Clean up values
  ssot_id=$(echo "$ssot_id" | tr -d ' ')
  value=$(echo "$value" | tr -d ' ')

  # Skip if not a constant reference
  [[ -z "$ssot_id" ]] && continue
  [[ "$ssot_id" =~ ^[A-Z] ]] || continue

  # Extract class and property name
  if [[ "$ssot_id" =~ ^([A-Z][a-zA-Z]+)\.([a-z][a-zA-Z]+)$ ]]; then
    class_name="${BASH_REMATCH[1]}"
    prop_name="${BASH_REMATCH[2]}"

    CHECKED=$((CHECKED + 1))

    # Find the Swift file and extract value
    swift_file="$CONSTANTS_DIR/${class_name}.swift"
    swift_value=$(extract_swift_value "$swift_file" "$prop_name")

    # Handle special values
    if [[ "$value" == "∞" ]]; then
      if [[ "$swift_value" == "∞" ]]; then
        continue  # Match
      else
        echo "❌ MISMATCH: $ssot_id"
        echo "   Documentation: $value"
        echo "   Swift code:    $swift_value"
        echo "   File: $swift_file"
        MISMATCHES=$((MISMATCHES + 1))
        FAILED=1
      fi
    elif [[ "$swift_value" != "$value" && "$swift_value" != "NOT_FOUND" ]]; then
      echo "❌ MISMATCH: $ssot_id"
      echo "   Documentation: $value"
      echo "   Swift code:    $swift_value"
      echo "   File: $swift_file"
      MISMATCHES=$((MISMATCHES + 1))
      FAILED=1
    fi
  fi
done < <(sed -n '/SSOT:SYSTEM_CONSTANTS:BEGIN/,/SSOT:SYSTEM_CONSTANTS:END/p' "$SSOT_DOC" | grep '^|')

# Repeat for other sections: CONVERSION_CONSTANTS, QUALITY_THRESHOLDS, RETRY_CONSTANTS, SAMPLING_CONSTANTS
for section in CONVERSION_CONSTANTS QUALITY_THRESHOLDS RETRY_CONSTANTS SAMPLING_CONSTANTS; do
  while IFS='|' read -r _ ssot_id value _; do
    [[ "$ssot_id" =~ ^[[:space:]]*$ ]] && continue
    [[ "$ssot_id" =~ "SSOT_ID" ]] && continue
    [[ "$ssot_id" =~ "---" ]] && continue

    ssot_id=$(echo "$ssot_id" | tr -d ' ')
    value=$(echo "$value" | tr -d ' ')

    [[ -z "$ssot_id" ]] && continue
    [[ "$ssot_id" =~ ^[A-Z] ]] || continue

    if [[ "$ssot_id" =~ ^([A-Z][a-zA-Z]+)\.([a-z][a-zA-Z]+)$ ]]; then
      class_name="${BASH_REMATCH[1]}"
      prop_name="${BASH_REMATCH[2]}"

      CHECKED=$((CHECKED + 1))

      swift_file="$CONSTANTS_DIR/${class_name}.swift"
      swift_value=$(extract_swift_value "$swift_file" "$prop_name")

      if [[ "$value" == "∞" ]]; then
        if [[ "$swift_value" != "∞" ]]; then
          echo "❌ MISMATCH: $ssot_id"
          echo "   Documentation: $value"
          echo "   Swift code:    $swift_value"
          MISMATCHES=$((MISMATCHES + 1))
          FAILED=1
        fi
      elif [[ "$swift_value" != "$value" && "$swift_value" != "NOT_FOUND" ]]; then
        echo "❌ MISMATCH: $ssot_id"
        echo "   Documentation: $value"
        echo "   Swift code:    $swift_value"
        MISMATCHES=$((MISMATCHES + 1))
        FAILED=1
      fi
    fi
  done < <(sed -n "/SSOT:${section}:BEGIN/,/SSOT:${section}:END/p" "$SSOT_DOC" | grep '^|')
done

echo "[2/2] Verification complete"
echo "   Checked: $CHECKED constants"
echo "   Mismatches: $MISMATCHES"

if [ $FAILED -ne 0 ]; then
  echo ""
  echo "❌ SSOT consistency verification FAILED"
  echo "Fix: Update either the documentation or code to match"
  exit 1
fi

echo "==> SSOT consistency verification PASSED"
exit 0
