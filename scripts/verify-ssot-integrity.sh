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
