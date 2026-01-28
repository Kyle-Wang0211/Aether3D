#!/bin/bash
# Verify all constitution document hashes
# Source: MODULE_CONTRACT_EQUIVALENCE.md §8.4

set -e
FAILED=0

for md in docs/constitution/*.md; do
    hash_file="${md%.md}.hash"
    if [ ! -f "$hash_file" ]; then
        echo "ERROR: Missing hash file for $md"
        FAILED=1
        continue
    fi

    expected=$(cat "$hash_file" | tr -d '[:space:]')
    actual=$(shasum -a 256 "$md" | cut -d' ' -f1)

    if [ "$expected" != "$actual" ]; then
        echo "ERROR: Hash mismatch for $md"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAILED=1
    else
        echo "OK: $md"
    fi
done

exit $FAILED
