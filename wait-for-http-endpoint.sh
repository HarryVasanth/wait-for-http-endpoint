#!/bin/bash
# Poll an HTTP(S) endpoint until it returns an expected status, or stop at a deadline.
#
# This is a composite action script. It needs bash and curl.
# See action.yml for the inputs and README.md for examples.

set -euo pipefail
export LC_ALL=C

# --- 🧾 Output helpers -------------------------------------------------------

# Escape data for a workflow command. Keep the message on one line.
gh_escape() {
	local s=${1:-}
	s=${s//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}

error() { echo "::error::❌ $(gh_escape "$*")" >&2; exit 1; }
warn() { echo "::warning::⚠️ $(gh_escape "$*")"; }
notice() { echo "::notice::✅ $(gh_escape "$*")"; }
debug() { if [ "${RUNNER_DEBUG:-}" = "1" ]; then echo "::debug::$(gh_escape "$*")"; fi; }

# Write one output. Print it when the script runs outside GitHub Actions.
write_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
	else
		printf '%s=%s\n' "$1" "$2"
	fi
}

# --- 🔢 Input helpers --------------------------------------------------------

# Strip the CR that Windows shells can leave in env values.
strip_cr() { printf '%s' "${1//$'\r'/}"; }

# Strip surrounding whitespace. Use for config values, never for bodies.
trim() {
	local v
	v=$(strip_cr "${1:-}")
	v=${v#"${v%%[![:space:]]*}"}
	v=${v%"${v##*[![:space:]]}"}
	printf '%s' "$v"
}

lower() { printf '%s' "$(trim "${1:-}")" | tr '[:upper:]' '[:lower:]'; }

is_uint() { case ${1:-} in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Read a whole number. Set $NUM. Stop on a bad value.
num() { # <name> <value> <default> <min> [max]
	local raw=${2:-} min=${4:-0} max=${5:-}
	if [ -z "$raw" ]; then
		raw=$3
	fi
	raw=$(trim "$raw")
	is_uint "$raw" || error "$1 must be a non-negative integer"
	[ ${#raw} -le 9 ] || error "$1 must be 999999999 or less"
	NUM=$((10#$raw))
	if [ "$NUM" -lt "$min" ]; then
		error "$1 must be at least $min"
	fi
	if [ -n "$max" ] && [ "$NUM" -gt "$max" ]; then
		error "$1 must be $max or less"
	fi
}

# Parse a boolean. Set $BOOL.
bool() {
	case $(lower "${2:-}") in
	true | 1 | yes | on) BOOL=true ;;
	false | 0 | no | off | '') BOOL=false ;;
	*) error "$1 must be true or false" ;;
	esac
}

# Split a comma-separated list. Set $ITEMS to the non-empty trimmed entries.
ITEMS=()
split_list() {
	local item
	local -a parts
	ITEMS=()
	if [ -z "${1:-}" ]; then
		return 0
	fi
	IFS=',' read -ra parts <<<"$1"
	for item in "${parts[@]}"; do
		item=$(trim "$item")
		if [ -n "$item" ]; then
			ITEMS+=("$item")
		fi
	done
}

join_by() {
	local sep=$1 out='' x
	shift
	for x in "$@"; do
		out+="$x$sep"
	done
	printf '%s' "${out%"$sep"}"
}

# Make a value safe for a Markdown table cell.
md_cell() {
	local s=${1:-} pipe='|' tick='`'
	s=${s//$'\r'/}
	s=${s//$'\n'/ }
	s=${s//$pipe/\\|}
	s=${s//$tick/\'}
	printf '%s' "$s"
}

# Keep a message on one line.
one_line() { printf '%s' "${1:-}" | tr '\n\r' '  '; }

# Hide the query, fragment and userinfo. They often contain tokens.
safe_url() {
	local u=${1:-} scheme rest
	u=${u%%#*}
	u=${u%%\?*}
	case $u in
	*://*@*)
		scheme=${u%%://*}
		rest=${u#*://}
		u="$scheme://${rest#*@}"
		;;
	esac
	printf '%s' "$u"
}

# --- 📥 Inputs --------------------------------------------------------------

URL=$(trim "${INPUT_URL:-}")
[ -n "$URL" ] || error "url is required"
case $URL in
[Hh][Tt][Tt][Pp]://?* | [Hh][Tt][Tt][Pp][Ss]://?*) ;;
*) error "url must start with http:// or https://" ;;
esac
case $URL in
*[[:space:]]*) error "url must not contain whitespace" ;;
esac
SAFE_URL=$(safe_url "$URL")

METHOD=$(trim "${INPUT_METHOD:-GET}" | tr '[:lower:]' '[:upper:]')
[ -n "$METHOD" ] || error "method must not be empty"
case $METHOD in
*[!A-Z0-9-]*) error "method must contain only letters, digits or '-'" ;;
esac

EXPECTED_STATUS=$(trim "${INPUT_EXPECTED_STATUS:-200}")
EXPECTED=()
split_list "$EXPECTED_STATUS"
if [ ${#ITEMS[@]} -gt 0 ]; then
	EXPECTED=("${ITEMS[@]}")
fi
[ ${#EXPECTED[@]} -gt 0 ] || error "expected-status must contain at least one code"
for status in "${EXPECTED[@]}"; do
	case $status in
	[1-5][0-9][0-9]) ;;
	[1-5][xX][xX]) ;;
	*) error "expected-status '$status' must be a 3-digit code or a class like 2xx" ;;
	esac
done
EXPECTED_DISPLAY=$(join_by ', ' "${EXPECTED[@]}")

num timeout "${INPUT_TIMEOUT:-}" 60000 1 86400000
TIMEOUT_MS=$NUM
num interval "${INPUT_INTERVAL:-}" 1000 1 3600000
INTERVAL_MS=$NUM
num max-redirects "${INPUT_MAX_REDIRECTS:-}" 10 0 50
MAX_REDIRECTS=$NUM

bool insecure "${INPUT_INSECURE:-false}"
INSECURE=$BOOL
bool follow-redirects "${INPUT_FOLLOW_REDIRECTS:-false}"
FOLLOW_REDIRECTS=$BOOL
bool continue-on-error "${INPUT_CONTINUE_ON_ERROR:-false}"
CONTINUE_ON_ERROR=$BOOL
bool print-body "${INPUT_PRINT_BODY:-false}"
PRINT_BODY=$BOOL

BEARER_TOKEN=$(trim "${INPUT_BEARER_TOKEN:-}")
USER_AGENT=$(trim "${INPUT_USER_AGENT:-wait-for-http-endpoint}")
CONTENT_TYPE=$(trim "${INPUT_CONTENT_TYPE:-}")
EXPECTED_BODY=$(trim "${INPUT_EXPECTED_BODY:-}")
HEADERS_RAW=$(strip_cr "${INPUT_HEADERS:-}")
BODY=${INPUT_BODY:-}

HEADERS=()
if [ -n "$HEADERS_RAW" ]; then
	line_no=0
	while IFS= read -r line; do
		line_no=$((line_no + 1))
		line=$(trim "$line")
		if [ -z "$line" ]; then
			continue
		fi
		case $line in
		*:*) ;;
		*) error "headers: line $line_no must look like 'Name: value'" ;;
		esac
		[ -n "$(trim "${line%%:*}")" ] || error "headers: line $line_no has an empty name"
		HEADERS+=("$line")
	done <<<"$HEADERS_RAW"
fi

HAS_AUTH_HEADER=0
for header in "${HEADERS[@]+"${HEADERS[@]}"}"; do
	if [ "$(lower "$(trim "${header%%:*}")")" = authorization ]; then
		HAS_AUTH_HEADER=1
	fi
done
if [ -n "$BEARER_TOKEN" ] && [ "$HAS_AUTH_HEADER" -eq 1 ]; then
	warn "bearer-token ignored: headers already sets Authorization"
	BEARER_TOKEN=
fi

if [ "$METHOD" = HEAD ] && [ -n "$EXPECTED_BODY" ]; then
	error "expected-body cannot be used with method HEAD"
fi

if [ -n "$EXPECTED_BODY" ]; then
	grep_rc=0
	printf '' | grep -aEq -- "$EXPECTED_BODY" || grep_rc=$?
	if [ "$grep_rc" -eq 2 ]; then
		error "expected-body is not a valid extended regex"
	fi
fi

command -v curl >/dev/null 2>&1 || error "curl is required but was not found"

# --- ⏱️ Clocks and sleeps ---------------------------------------------------

# GNU date gives milliseconds. BSD date does not, so fall back to whole seconds.
HAVE_MS_DATE=0
case $(date +%s%3N 2>/dev/null || true) in
'' | *[!0-9]*) HAVE_MS_DATE=0 ;;
*) HAVE_MS_DATE=1 ;;
esac

now_ms() {
	if [ "$HAVE_MS_DATE" -eq 1 ]; then
		date +%s%3N
	else
		printf '%s000' "$(date +%s)"
	fi
}

HAVE_FRAC_SLEEP=0
if sleep 0.01 >/dev/null 2>&1; then HAVE_FRAC_SLEEP=1; fi

sleep_ms() {
	local ms=$1
	if [ "$ms" -le 0 ]; then
		return 0
	fi
	if [ "$HAVE_FRAC_SLEEP" -eq 1 ]; then
		sleep "$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))"
	else
		# shortcut: a sleep without fractions rounds up to whole seconds.
		# Upgrade to a decimal sleep if a target system lacks GNU sleep.
		sleep $(((ms + 999) / 1000))
	fi
}

fmt_secs() { printf '%d.%01d' $(($1 / 1000)) $((($1 % 1000) / 100)); }

curl_hint() {
	case $1 in
	3) printf 'malformed URL' ;;
	5) printf 'could not resolve proxy' ;;
	6) printf 'could not resolve host' ;;
	7) printf 'connection refused' ;;
	28) printf 'request timed out' ;;
	35) printf 'TLS handshake failed' ;;
	47) printf 'too many redirects' ;;
	52) printf 'empty reply from server' ;;
	56) printf 'connection reset by peer' ;;
	60) printf 'TLS certificate is not trusted (try insecure: true)' ;;
	*) printf 'curl exit %s' "$1" ;;
	esac
}

# --- 🧰 Runtime -------------------------------------------------------------

TMP_DIR=$(mktemp -d 2>/dev/null) || error "could not create a temporary directory"
BODY_FILE=$TMP_DIR/body
ERR_FILE=$TMP_DIR/err
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$METHOD" = HEAD ]; then
	# -X HEAD makes curl wait for a body; --head does not.
	CURL=(curl -sS --user-agent "$USER_AGENT" --head -o /dev/null -w '%{http_code}')
else
	CURL=(curl -sS --user-agent "$USER_AGENT" -o "$BODY_FILE" -w '%{http_code}' -X "$METHOD")
fi
if [ "$INSECURE" = true ]; then
	CURL+=(--insecure)
fi
if [ "$FOLLOW_REDIRECTS" = true ]; then
	CURL+=(--location --max-redirs "$MAX_REDIRECTS")
fi
if [ -n "$BEARER_TOKEN" ]; then
	CURL+=(--header "Authorization: Bearer $BEARER_TOKEN")
fi
for header in "${HEADERS[@]+"${HEADERS[@]}"}"; do
	CURL+=(--header "$header")
done
if [ -n "$CONTENT_TYPE" ]; then
	CURL+=(--header "Content-Type: $CONTENT_TYPE")
fi
if [ -n "$BODY" ]; then
	CURL+=(--data-binary "$BODY")
fi

status_matches() { # <status>
	local want code=$1
	for want in "${EXPECTED[@]+"${EXPECTED[@]}"}"; do
		case $want in
		[1-5][xX][xX])
			if [ "${code:0:1}" = "${want:0:1}" ]; then return 0; fi
			;;
		*)
			if [ "$code" = "$want" ]; then return 0; fi
			;;
		esac
	done
	return 1
}

print_body() {
	if [ ! -s "$BODY_FILE" ]; then
		echo "📄 Response body: (empty)"
		return 0
	fi
	echo "::group::📄 Last response body"
	# shortcut: body output is capped, and it may contain secrets, so it is opt-in.
	head -c 2000 "$BODY_FILE" | tr -d '\r\000'
	bytes=$(wc -c <"$BODY_FILE" | tr -d ' ')
	if [ "$bytes" -gt 2000 ]; then
		echo
		echo "… (truncated)"
	fi
	echo
	echo "::endgroup::"
}

emit_summary() { # <result> <status> <error>
	if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
		return 0
	fi
	{
		echo "### ⏳ Wait for HTTP Endpoint"
		echo
		echo "| Field | Value |"
		echo "| --- | --- |"
		# shellcheck disable=SC2016 # backticks are Markdown, not a command
		printf '| 🌐 URL | `%s` |\n' "$(md_cell "$SAFE_URL")"
		# shellcheck disable=SC2016
		printf '| 🛠️ Method | `%s` |\n' "$(md_cell "$METHOD")"
		# shellcheck disable=SC2016
		printf '| 🎯 Expected | `%s` |\n' "$(md_cell "$EXPECTED_DISPLAY")"
		printf '| 📊 Result | %s |\n' "$1"
		# shellcheck disable=SC2016
		printf '| 🚦 Status | `%s` |\n' "$(md_cell "$2")"
		printf '| 🔢 Attempts | %s |\n' "$ATTEMPT"
		printf '| ⏱️ Duration | %ss |\n' "$(fmt_secs "$DURATION_MS")"
		if [ -n "$3" ]; then
			# shellcheck disable=SC2016
			printf '| ❌ Error | `%s` |\n' "$(md_cell "$3")"
		fi
	} >>"$GITHUB_STEP_SUMMARY"
}

# --- 🎯 Banner --------------------------------------------------------------

echo "⏳ Wait for HTTP Endpoint"
printf '🌐 URL: %s\n' "$SAFE_URL"
printf '🎯 Expecting HTTP %s · method %s\n' "$EXPECTED_DISPLAY" "$METHOD"
printf '⏱️  Timeout %sms · interval %sms\n' "$TIMEOUT_MS" "$INTERVAL_MS"
if [ "$INSECURE" = true ]; then echo "🔓 TLS verification: off"; fi
if [ "$FOLLOW_REDIRECTS" = true ]; then printf '↪️  Follow up to %s redirect(s)\n' "$MAX_REDIRECTS"; fi
if [ ${#HEADERS[@]} -gt 0 ]; then printf '🧾 Custom headers: %d (values hidden)\n' "${#HEADERS[@]}"; fi
if [ -n "$BODY" ]; then echo "📦 Request body: set (hidden)"; fi
if [ -n "$BEARER_TOKEN" ]; then echo "🔑 Bearer token: set (hidden)"; fi
if [ -n "$EXPECTED_BODY" ]; then printf '📄 Body must match: %s\n' "$EXPECTED_BODY"; fi
debug "ms-clock=$HAVE_MS_DATE fractional-sleep=$HAVE_FRAC_SLEEP"

# --- 🔄 Poll loop -----------------------------------------------------------

ATTEMPT=0
LAST_STATUS=000
LAST_STATE=
LAST_ERR=
LAST_BODY_MISS=0
START_MS=$(now_ms)
DEADLINE_MS=$((START_MS + TIMEOUT_MS))
LAST_LOG_MS=$START_MS

while :; do
	NOW=$(now_ms)
	REMAINING=$((DEADLINE_MS - NOW))
	if [ "$ATTEMPT" -gt 0 ] && [ "$REMAINING" -le 0 ]; then
		break
	fi
	ATTEMPT=$((ATTEMPT + 1))

	# Bound every request so a hung connection cannot pass the deadline.
	REQ_S=$(((REMAINING + 999) / 1000))
	if [ "$REQ_S" -lt 1 ]; then REQ_S=1; fi

	set +e
	STATUS=$("${CURL[@]}" --max-time "$REQ_S" "$URL" 2>"$ERR_FILE")
	CURL_RC=$?
	set -e
	STATUS=$(printf '%s' "$STATUS" | tail -n 1 | tr -d '\r')
	case $STATUS in
	[0-9][0-9][0-9]) ;;
	*) STATUS=000 ;;
	esac
	LAST_STATUS=$STATUS
	LAST_BODY_MISS=0
	LAST_ERR=

	MATCHED=0
	if [ "$CURL_RC" -eq 0 ] && [ "$STATUS" != 000 ]; then
		if status_matches "$STATUS"; then MATCHED=1; fi
	fi
	if [ "$MATCHED" -eq 1 ] && [ -n "$EXPECTED_BODY" ]; then
		if ! grep -aEq -- "$EXPECTED_BODY" "$BODY_FILE"; then
			MATCHED=0
			LAST_BODY_MISS=1
		fi
	fi

	ELAPSED=$(( $(now_ms) - START_MS ))

	if [ "$MATCHED" -eq 1 ]; then
		DURATION_MS=$ELAPSED
		notice "Success: HTTP $STATUS after $ATTEMPT attempt(s) in $(fmt_secs "$DURATION_MS")s"
		if [ "$PRINT_BODY" = true ]; then print_body; fi
		write_output result success
		write_output status "$STATUS"
		write_output attempts "$ATTEMPT"
		write_output duration_ms "$DURATION_MS"
		write_output error ""
		emit_summary "✅ success" "$STATUS" ""
		exit 0
	fi

	if [ "$CURL_RC" -ne 0 ]; then
		LAST_ERR=$(head -n 1 "$ERR_FILE" | tr -d '\r')
		STATE="error:$CURL_RC"
		if [ -n "$LAST_ERR" ]; then
			DETAIL=$LAST_ERR
		else
			DETAIL=$(curl_hint "$CURL_RC")
		fi
	elif [ "$LAST_BODY_MISS" -eq 1 ]; then
		STATE="body:$STATUS"
		DETAIL="HTTP $STATUS, body did not match"
	else
		STATE="status:$STATUS"
		DETAIL="HTTP $STATUS (expected $EXPECTED_DISPLAY)"
	fi
	DETAIL=${DETAIL:0:300}

	NOW=$(now_ms)
	if [ "$ATTEMPT" -eq 1 ] || [ "$STATE" != "$LAST_STATE" ] || [ $((NOW - LAST_LOG_MS)) -ge 5000 ]; then
		printf '⏳ attempt %d · %s · %ss\n' "$ATTEMPT" "$(one_line "$DETAIL")" "$(fmt_secs "$((NOW - START_MS))")"
		LAST_LOG_MS=$NOW
	fi
	LAST_STATE=$STATE

	NOW=$(now_ms)
	REMAINING=$((DEADLINE_MS - NOW))
	if [ "$REMAINING" -le 0 ]; then
		break
	fi
	WAIT_MS=$INTERVAL_MS
	if [ "$WAIT_MS" -gt "$REMAINING" ]; then WAIT_MS=$REMAINING; fi
	sleep_ms "$WAIT_MS"
done

# --- ⏰ Timeout -------------------------------------------------------------

DURATION_MS=$(( $(now_ms) - START_MS ))
if [ "$LAST_BODY_MISS" -eq 1 ]; then
	REASON="body did not match expected-body"
elif [ -n "$LAST_ERR" ]; then
	REASON="last error: $(one_line "$LAST_ERR")"
else
	REASON="last HTTP $LAST_STATUS"
fi
FAIL_ERROR="Timed out after ${TIMEOUT_MS}ms and $ATTEMPT attempt(s); $REASON"
FAIL_ERROR=${FAIL_ERROR:0:500}

if [ "$PRINT_BODY" = true ]; then print_body; fi

write_output result failure
write_output status "$LAST_STATUS"
write_output attempts "$ATTEMPT"
write_output duration_ms "$DURATION_MS"
write_output error "$FAIL_ERROR"
emit_summary "⏰ timeout" "$LAST_STATUS" "$FAIL_ERROR"

if [ "$CONTINUE_ON_ERROR" = true ]; then
	warn "$FAIL_ERROR"
	exit 0
fi
echo "::error::❌ $(gh_escape "$FAIL_ERROR")" >&2
exit 1
