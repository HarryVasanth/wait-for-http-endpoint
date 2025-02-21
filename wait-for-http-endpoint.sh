#!/bin/sh

# Exit immediately on unhandled errors, treat unset variables as an error
set -eu

# Read inputs from environment variables
URL="${INPUT_URL}"
METHOD="${INPUT_METHOD:-GET}"
EXPECTED_STATUS="${INPUT_EXPECTED_STATUS:-200}"
TIMEOUT_MS="${INPUT_TIMEOUT:-60000}"
INTERVAL_MS="${INPUT_INTERVAL:-1000}"
INSECURE="${INPUT_INSECURE:-false}"
FOLLOW_REDIRECTS="${INPUT_FOLLOW_REDIRECTS:-false}"
BEARER_TOKEN="${INPUT_BEARER_TOKEN:-}"

# Calculate times using integer arithmetic
INTERVAL_SEC=$(awk "BEGIN {print $INTERVAL_MS/1000}")
MAX_ITERATIONS=$(awk "BEGIN {print int($TIMEOUT_MS/$INTERVAL_MS)}")
[ "$MAX_ITERATIONS" -eq 0 ] && MAX_ITERATIONS=1

# Prepare cURL arguments securely using positional parameters
# This prevents word-splitting vulnerabilities (ShellCheck SC2086)
set -- -sS -o /dev/null -w "%{http_code}" -X "$METHOD"

if [ "$INSECURE" = "true" ]; then
	set -- "$@" -k
fi
if [ "$FOLLOW_REDIRECTS" = "true" ]; then
	set -- "$@" -L
fi
if [ -n "$BEARER_TOKEN" ]; then
	set -- "$@" -H "Authorization: Bearer $BEARER_TOKEN"
fi

echo "🔗 Polling: $URL"
echo "⏱️  Timeout: ${TIMEOUT_MS}ms, Interval: ${INTERVAL_MS}ms"
echo "🔍 Expecting HTTP ${EXPECTED_STATUS} (Method: $METHOD)"

ITERATION=0
while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do

	# Temporarily disable exit-on-error to handle failed cURL requests (e.g., connection refused)
	set +e
	STATUS_CODE=$(curl "$@" "$URL" 2>/tmp/curl_err)
	CURL_EXIT=$?
	set -e

	if [ "$CURL_EXIT" -ne 0 ] || [ "$STATUS_CODE" = "000" ]; then
		# Format the error message to fit on one line
		ERR_MSG=$(tr '\n' ' ' </tmp/curl_err)
		echo "⏳ Waiting... (Error: $ERR_MSG)"
	else
		# Check if status code is in the expected list (handles comma-separated securely)
		case ",$EXPECTED_STATUS," in
		*",$STATUS_CODE,"*)
			echo "✅ Success: Received HTTP $STATUS_CODE"
			exit 0
			;;
		*)
			echo "⏳ Got HTTP $STATUS_CODE, expected one of: $EXPECTED_STATUS"
			;;
		esac
	fi

	ITERATION=$((ITERATION + 1))
	sleep "$INTERVAL_SEC"
done

echo "⏰ Timeout reached after ${TIMEOUT_MS}ms"
exit 1
