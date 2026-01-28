#!/bin/bash
# Check for overdue emergency bypasses
# Source: EMERGENCY_PROTOCOL.md §4.3

TODAY=$(date -u +%Y-%m-%dT%H:%M:%SZ)

FAILED=0

if [ ! -f "docs/emergencies/ACTIVE_BYPASSES.md" ]; then
    echo "No active bypasses file found."
    exit 0
fi

grep "| ACTIVE |" docs/emergencies/ACTIVE_BYPASSES.md | while read line; do
    EXPIRES=$(echo "$line" | cut -d'|' -f5 | tr -d ' ')
    if [[ "$TODAY" > "$EXPIRES" ]]; then
        BYPASS_ID=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
        echo "::error::OVERDUE BYPASS: $BYPASS_ID expired on $EXPIRES"
        FAILED=1
    fi
done

exit $FAILED
