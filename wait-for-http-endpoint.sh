#!/bin/sh

# Read inputs from environment variables
URL="${INPUT_URL}"
METHOD="${INPUT_METHOD:-GET}"
EXPECTED_STATUS="${INPUT_EXPECTED_STATUS:-200}"
TIMEOUT_MS="${INPUT_TIMEOUT:-60000}"
INTERVAL_MS="${INPUT_INTERVAL:-1000}"

# Convert milliseconds to seconds
TIMEOUT=$(awk "BEGIN {print $TIMEOUT_MS/1000}")
INTERVAL=$(awk "BEGIN {print $INTERVAL_MS/1000}")

START_TIME=$(date +%s)
END_TIME=$(awk "BEGIN {print $START_TIME + $TIMEOUT}")

echo "🔗 Polling $URL every ${INTERVAL}s for up to ${TIMEOUT}s"
echo "🔍 Expecting HTTP ${EXPECTED_STATUS} (Method: $METHOD)"

while :; do
    CURRENT_TIME=$(date +%s)

    # Check timeout
    if [ "$(awk "BEGIN {print $CURRENT_TIME >= $END_TIME}")" -eq 1 ]; then
        echo "⏰ Timeout reached after ${TIMEOUT}s"
        exit 1
    fi

    # Make request
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X "$METHOD" "$URL")

    # Check if status matches any expected code
    echo "$EXPECTED_STATUS" | tr ',' '\n' | while read -r CODE; do
        if [ "$STATUS_CODE" -eq "$CODE" ] 2>/dev/null; then
            echo "✅ Success: Received HTTP $STATUS_CODE"
            exit 0
        fi
    done

    sleep "$INTERVAL"
done
