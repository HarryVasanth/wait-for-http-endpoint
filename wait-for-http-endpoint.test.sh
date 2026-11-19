#!/bin/bash
# Self-check for wait-for-http-endpoint.sh. Run: ./wait-for-http-endpoint.test.sh
# Starts a tiny local HTTP server, then runs the script against it.
# Uses bash 3.2-safe syntax so it also runs on macOS.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/wait-for-http-endpoint.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
SERVER_PID=
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '✅ %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '❌ %s\n   %s\n' "$1" "$2"
	if [ -n "${OUT:-}" ]; then
		printf '%s\n' "$OUT" | sed 's/^/   | /'
	fi
}

# run <expected-exit> <needle-or-empty> <description> [VAR=value...]
run() {
	local expected=$1 needle=$2 desc=$3
	shift 3
	OUT=$(env -i PATH="$PATH" HOME="${HOME:-}" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 "$@" "$SCRIPT" 2>&1)
	CODE=$?
	if [ "$CODE" -ne "$expected" ]; then
		fail "$desc" "expected exit $expected, got $CODE"
	elif [ -n "$needle" ] && [[ $OUT != *"$needle"* ]]; then
		fail "$desc" "output does not contain: $needle"
	else
		pass "$desc"
	fi
}

# --- 🖥️ Test server ---------------------------------------------------------

PY=python3
if ! command -v python3 >/dev/null 2>&1; then PY=python; fi
command -v "$PY" >/dev/null 2>&1 || {
	echo "❌ python3 is required for the test server"
	exit 2
}

cat >"$TMP/server.py" <<'PY'
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

counts = {}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body=b"", headers=None):
        try:
            self.send_response(code)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_path(self):
        path = self.path.split("?")[0]
        if path == "/ok":
            self.send(200, b"ready")
        elif path == "/created":
            self.send(201, b"created")
        elif path == "/json":
            self.send(200, b'{"status":"ready"}')
        elif path == "/redirect":
            self.send(302, b"", {"Location": "/ok"})
        elif path == "/never":
            self.send(503, b"not ready")
        elif path == "/flaky":
            with lock:
                counts[path] = counts.get(path, 0) + 1
                n = counts[path]
            self.send(503, b"warming up") if n <= 2 else self.send(200, b"ready")
        elif path == "/delay":
            time.sleep(1.5)
            self.send(200, b"slow")
        elif path == "/echo":
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            data = {
                "method": self.command,
                "authorization": self.headers.get("Authorization", ""),
                "token": self.headers.get("X-Test", ""),
                "content_type": self.headers.get("Content-Type", ""),
                "body": body.decode("utf-8", "replace"),
            }
            self.send(200, json.dumps(data).encode())
        elif path == "/auth":
            if self.headers.get("Authorization") == "Bearer secret":
                self.send(200, b"ok")
            else:
                self.send(401, b"no")
        else:
            self.send(404, b"nope")

    do_GET = handle_path
    do_POST = handle_path
    do_PUT = handle_path
    do_DELETE = handle_path
    do_HEAD = handle_path

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

PORT_FILE="$TMP/port"
"$PY" "$TMP/server.py" "$PORT_FILE" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
i=0
while [ "$i" -lt 100 ] && [ ! -s "$PORT_FILE" ]; do
	sleep 0.05
	i=$((i + 1))
done
if [ ! -s "$PORT_FILE" ]; then
	echo "❌ test server did not start"
	cat "$TMP/server.log"
	exit 1
fi
BASE="http://127.0.0.1:$(cat "$PORT_FILE")"

# --- ✅ Success paths -------------------------------------------------------

run 0 "Success: HTTP 200" "immediate success" "INPUT_URL=$BASE/ok"
run 0 "Success: HTTP 201" "comma list with spaces" "INPUT_URL=$BASE/created" "INPUT_EXPECTED_STATUS=200, 201"
run 0 "Success: HTTP 200" "status class 2xx" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_STATUS=2xx"
run 0 "Success: HTTP 200" "uppercase status class" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_STATUS=2XX"
run 0 "Success: HTTP 200" "retries a flaky endpoint" "INPUT_URL=$BASE/flaky" "INPUT_TIMEOUT=4000" "INPUT_INTERVAL=50"
run 0 "Success: HTTP 302" "redirect is not followed" "INPUT_URL=$BASE/redirect" "INPUT_EXPECTED_STATUS=302"
run 0 "Success: HTTP 200" "redirect is followed" "INPUT_URL=$BASE/redirect" "INPUT_FOLLOW_REDIRECTS=true"
run 0 "Success: HTTP 200" "HEAD request" "INPUT_URL=$BASE/ok" "INPUT_METHOD=HEAD"
run 0 "Success: HTTP 200" "bearer token accepted" "INPUT_URL=$BASE/auth" "INPUT_BEARER_TOKEN=secret"
run 0 "Success: HTTP 200" "CRLF timeout input" "INPUT_URL=$BASE/ok" "INPUT_TIMEOUT=$(printf '1000\r')"
run 0 "Success: HTTP 200" "CRLF header input" "INPUT_URL=$BASE/ok" "INPUT_HEADERS=$(printf 'X-Test: abc\r')"
run 0 "ignored" "bearer is skipped when Authorization header exists" "INPUT_URL=$BASE/auth" \
	"INPUT_BEARER_TOKEN=wrong" "INPUT_HEADERS=Authorization: Bearer secret"

# --- 📦 Headers and body ----------------------------------------------------

run 0 '"token": "abc"' "custom header reaches the server" "INPUT_URL=$BASE/echo" \
	"INPUT_HEADERS=$(printf 'X-Test: abc\nX-Other: def')" "INPUT_PRINT_BODY=true"
run 0 "" "method reaches the server" "INPUT_URL=$BASE/echo" "INPUT_METHOD=POST" \
	'INPUT_EXPECTED_BODY="method": "POST"'
run 0 "" "content-type reaches the server" "INPUT_URL=$BASE/echo" \
	"INPUT_CONTENT_TYPE=application/json" 'INPUT_EXPECTED_BODY="content_type": "application/json"'
run 0 "" "request body reaches the server" "INPUT_URL=$BASE/echo" \
	"INPUT_METHOD=POST" "INPUT_BODY=hello-body" 'INPUT_EXPECTED_BODY="body": "hello-body"'

# --- 📄 Expected body -------------------------------------------------------

run 0 "Success: HTTP 200" "body regex matches" "INPUT_URL=$BASE/json" \
	"INPUT_EXPECTED_BODY=status\":\"ready"
run 1 "body did not match" "body regex miss times out" "INPUT_URL=$BASE/json" \
	"INPUT_EXPECTED_BODY=degraded"

# --- ⏰ Timeout and failure outputs -----------------------------------------

run 1 "Timed out" "wrong status times out" "INPUT_URL=$BASE/never"
run 1 "Timed out" "slow endpoint is bounded by timeout" "INPUT_URL=$BASE/delay" "INPUT_TIMEOUT=300"
run 0 "Timed out" "continue on error exits 0" "INPUT_URL=$BASE/never" "INPUT_CONTINUE_ON_ERROR=true"
run 1 "not ready" "print-body shows the last body" "INPUT_URL=$BASE/never" "INPUT_PRINT_BODY=true"
run 1 "" "body is hidden by default" "INPUT_URL=$BASE/never"
if [[ ${OUT:-} == *"not ready"* ]]; then
	fail "body is hidden by default" "body leaked into the log"
fi

# --- 🧾 Input validation ----------------------------------------------------

run 1 "url is required" "url is required"
run 1 "must start with http" "url scheme is checked" "INPUT_URL=ftp://example.com"
run 1 "must not contain whitespace" "url whitespace is rejected" "INPUT_URL=http://a b"
run 1 "method must not be empty" "empty method is rejected" "INPUT_URL=$BASE/ok" "INPUT_METHOD=  "
run 1 "method must contain only" "bad method is rejected" "INPUT_URL=$BASE/ok" "INPUT_METHOD=GE T"
run 1 "3-digit code or a class" "bad status is rejected" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_STATUS=abc"
run 1 "3-digit code or a class" "status class is validated" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_STATUS=9xx"
run 1 "at least one code" "empty status list is rejected" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_STATUS=,"
run 1 "at least 1" "zero timeout is rejected" "INPUT_URL=$BASE/ok" "INPUT_TIMEOUT=0"
run 1 "non-negative integer" "text timeout is rejected" "INPUT_URL=$BASE/ok" "INPUT_TIMEOUT=abc"
run 1 "at least 1" "zero interval is rejected" "INPUT_URL=$BASE/ok" "INPUT_INTERVAL=0"
run 1 "non-negative integer" "negative max-redirects is rejected" "INPUT_URL=$BASE/ok" "INPUT_MAX_REDIRECTS=-1"
run 1 "50 or less" "max-redirects cap is enforced" "INPUT_URL=$BASE/ok" "INPUT_MAX_REDIRECTS=51"
run 1 "must be true or false" "bad boolean is rejected" "INPUT_URL=$BASE/ok" "INPUT_INSECURE=maybe"
run 1 "must look like" "header without colon is rejected" "INPUT_URL=$BASE/ok" "INPUT_HEADERS=NoColon"
run 1 "empty name" "header with no name is rejected" "INPUT_URL=$BASE/ok" "INPUT_HEADERS=: value"
run 1 "not a valid extended regex" "bad body regex is rejected" "INPUT_URL=$BASE/ok" "INPUT_EXPECTED_BODY=([a"
run 1 "cannot be used with method HEAD" "body match with HEAD is rejected" "INPUT_URL=$BASE/ok" \
	"INPUT_METHOD=HEAD" "INPUT_EXPECTED_BODY=ready"

# --- 🔐 Secrets stay out of logs --------------------------------------------

OUT=$(env -i PATH="$PATH" HOME="${HOME:-}" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/ok?token=s3cr3t" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 0 ] && [[ $OUT != *"s3cr3t"* ]] && [[ $OUT == *"/ok"* ]]; then
	pass "url query is hidden"
else
	fail "url query is hidden" "exit $CODE or the query leaked"
fi

OUT=$(env -i PATH="$PATH" HOME="${HOME:-}" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/auth" INPUT_BEARER_TOKEN=secret "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 0 ] && [[ $OUT != *"secret"* ]]; then
	pass "bearer token is hidden"
else
	fail "bearer token is hidden" "exit $CODE or the token leaked"
fi

OUT=$(env -i PATH="$PATH" HOME="${HOME:-}" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/ok" "INPUT_HEADERS=X-Test: hiddenvalue" "$SCRIPT" 2>&1)
CODE=$?
if [ "$CODE" -eq 0 ] && [[ $OUT != *"hiddenvalue"* ]]; then
	pass "header value is hidden"
else
	fail "header value is hidden" "exit $CODE or the value leaked"
fi

# --- 📤 Outputs and summary -------------------------------------------------

outfile="$TMP/outputs"
env -i PATH="$PATH" HOME="${HOME:-}" GITHUB_OUTPUT="$outfile" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/ok" "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '^result=success$' "$outfile" &&
	grep -q '^status=200$' "$outfile" &&
	grep -q '^attempts=1$' "$outfile" &&
	grep -Eq '^duration_ms=[0-9]+$' "$outfile" &&
	grep -q '^error=$' "$outfile"; then
	pass "writes success outputs"
else
	fail "writes success outputs" "outputs: $(cat "$outfile")"
fi

failfile="$TMP/fail-outputs"
env -i PATH="$PATH" HOME="${HOME:-}" GITHUB_OUTPUT="$failfile" INPUT_TIMEOUT=600 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/never" "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '^result=failure$' "$failfile" &&
	grep -q '^status=503$' "$failfile" &&
	grep -Eq '^attempts=[1-9][0-9]*$' "$failfile" &&
	grep -q '^error=Timed out' "$failfile"; then
	pass "writes failure outputs"
else
	fail "writes failure outputs" "outputs: $(cat "$failfile")"
fi

sumfile="$TMP/summary"
env -i PATH="$PATH" HOME="${HOME:-}" GITHUB_STEP_SUMMARY="$sumfile" INPUT_TIMEOUT=1000 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/ok" "$SCRIPT" >/dev/null 2>&1 || true
if grep -q 'Wait for HTTP Endpoint' "$sumfile" &&
	grep -q '✅ success' "$sumfile" &&
	grep -q '127.0.0.1' "$sumfile"; then
	pass "writes the step summary"
else
	fail "writes the step summary" "summary: $(cat "$sumfile")"
fi

failsum="$TMP/fail-summary"
env -i PATH="$PATH" HOME="${HOME:-}" GITHUB_STEP_SUMMARY="$failsum" INPUT_TIMEOUT=600 INPUT_INTERVAL=25 \
	"INPUT_URL=$BASE/never" "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '⏰ timeout' "$failsum"; then
	pass "writes a timeout summary"
else
	fail "writes a timeout summary" "summary: $(cat "$failsum")"
fi

# --- 🏁 Result --------------------------------------------------------------

echo
printf '✅ %d passed · ❌ %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
