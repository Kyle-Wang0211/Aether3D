#!/bin/bash
# ban_apple_only_imports.sh
# Prevents Apple-only imports in Linux-compiled targets
# Fails CI if forbidden imports are found outside conditional compilation guards

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0
VIOLATIONS=()
FORBIDDEN_IMPORTS=(
    "import CryptoKit"
    "import Crypto"
    "import UIKit"
    "import AppKit"
    "import WatchKit"
    "import TVUIKit"
)

# Files that are ALLOWED to import CryptoKit/Crypto (with conditional compilation)
ALLOWED_SHIM_FILES=(
    "Tests/Constants/TestHelpers/CryptoShim.swift"
    "Core/Quality/Serialization/SHA256Utility.swift"
    "Core/Audit/TraceIdGenerator.swift"
    "Core/Audit/SigningKeyStore.swift"
    "Core/Audit/SignedAuditLog.swift"
    "Core/Audit/SignedAuditEntry.swift"
    "Core/Artifacts/ArtifactManifest.swift"
    "Core/Invariants/InvariantPolicies.swift"
    "Core/Network/APIContract.swift"
    "Tests/Gates/PolicyHashGateTests.swift"
)

# Files/directories that are excluded from Linux builds or have exceptions
EXCLUDED_PATTERNS=(
    "App/"  # iOS/macOS app code, not compiled on Linux
    "*.md"  # Documentation
    "*.json"  # Data files
    "*.sh"  # Shell scripts
)

echo "🔍 Scanning for Apple-only imports in Linux-compiled targets..."
echo ""

# Scan Swift files in Tests/ and Core/ directories
SCAN_DIRS=("Tests" "Core")
FOUND_VIOLATIONS=()

for dir in "${SCAN_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        continue
    fi
    
    while IFS= read -r -d '' file; do
        # Skip excluded patterns
        skip=false
        for pattern in "${EXCLUDED_PATTERNS[@]}"; do
            if [[ "$file" == *"$pattern"* ]]; then
                skip=true
                break
            fi
        done
        [ "$skip" = true ] && continue
        
        # Check if this file is an allowed shim file
        is_allowed_shim=false
        for allowed in "${ALLOWED_SHIM_FILES[@]}"; do
            if [[ "$file" == *"$allowed"* ]]; then
                is_allowed_shim=true
                break
            fi
        done
        
        # Check for forbidden imports
        for forbidden in "${FORBIDDEN_IMPORTS[@]}"; do
            # Skip CryptoKit/Crypto checks for allowed shim files (they use conditional compilation)
            if [[ "$forbidden" == "import CryptoKit" || "$forbidden" == "import Crypto" ]]; then
                if [ "$is_allowed_shim" = true ]; then
                    continue
                fi
            fi
            
            # Check if import exists
            if grep -q "^[[:space:]]*${forbidden}" "$file"; then
                # Check if it's inside a conditional compilation guard
                line_num=$(grep -n "^[[:space:]]*${forbidden}" "$file" | head -1 | cut -d: -f1)
                
                # Look backwards for #if canImport(...) guard
                has_guard=false
                if [ "$line_num" -gt 1 ]; then
                    # Check lines before the import
                    prev_lines=$(sed -n "1,$((line_num - 1))p" "$file")
                    if echo "$prev_lines" | grep -q "#if canImport"; then
                        # Check if there's a matching #else or #endif after
                        after_lines=$(sed -n "${line_num},\$p" "$file")
                        if echo "$after_lines" | grep -qE "^[[:space:]]*#(else|endif)"; then
                            has_guard=true
                        fi
                    fi
                fi
                
                if [ "$has_guard" = false ]; then
                    VIOLATIONS+=("$file:$line_num:${forbidden}")
                    ERRORS=$((ERRORS + 1))
                fi
            fi
        done
    done < <(find "$dir" -name "*.swift" -type f -print0)
done

# Report violations
if [ ${#FOUND_VIOLATIONS[@]} -gt 0 ]; then
    echo "❌ Found Apple-only imports without conditional compilation guards:"
    echo ""
    for violation in "${FOUND_VIOLATIONS[@]}"; do
        echo "  $violation"
        ERRORS=$((ERRORS + 1))
    done
    echo ""
    echo "Fix: Wrap Apple-only imports in conditional compilation:"
    echo "  #if canImport(CryptoKit)"
    echo "  import CryptoKit"
    echo "  #elseif canImport(Crypto)"
    echo "  import Crypto"
    echo "  #endif"
    echo ""
    echo "Or use the cross-platform CryptoShim (Tests/Constants/TestHelpers/CryptoShim.swift)"
    echo ""
    exit 1
else
    echo "✅ No forbidden Apple-only imports found"
    echo ""
    exit 0
fi
