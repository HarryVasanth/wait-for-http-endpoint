# 🔗 Wait for HTTP Endpoint Action

Poll an HTTP(S) endpoint until it returns an expected status, or stop at a deadline.

No Docker. No Node. One bash script and curl. The step starts in milliseconds and
works on GitHub-hosted and self-hosted runners.

## ✨ Why use this

- 🪶 **Lightweight.** No image build and no image pull. The step starts at once.
- 🎯 **Flexible matching.** Expect one code, a list, or a whole class like `2xx`.
- 📄 **Body readiness.** Optionally wait until the response body matches a regex.
- 🧾 **Real requests.** Add methods, headers, a body, a content type and a bearer token.
- 🔁 **Clean retries.** Every poll is bounded, so a hung connection cannot pass the deadline.
- 📊 **Clear results.** Outputs for status, attempts and duration. A step summary table.
- 🔐 **Safe logs.** Tokens, header values and URL query strings stay out of the log.
- 🌍 **Portable.** Linux, macOS and Windows (Git Bash), as long as curl exists.

## 📥 Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `url` | 🔗 URL to poll (`http` or `https`) | Yes | none |
| `method` | 🛠️ HTTP method | No | `GET` |
| `expected-status` | 🎯 Expected code(s): `200`, `200,201`, `2xx` | No | `200` |
| `timeout` | ⏱️ Maximum polling time in milliseconds | No | `60000` |
| `interval` | 🔄 Time between polls in milliseconds | No | `1000` |
| `insecure` | 🔓 Skip TLS certificate verification | No | `false` |
| `follow-redirects` | ↪️ Follow HTTP redirects | No | `false` |
| `max-redirects` | ↪️ Maximum redirects to follow | No | `10` |
| `bearer-token` | 🔑 Bearer token for the `Authorization` header | No | none |
| `headers` | 🧾 Extra headers, one `Name: value` per line | No | none |
| `content-type` | 📦 `Content-Type` for the request body | No | none |
| `body` | 📦 Request body sent with every poll | No | none |
| `expected-body` | 📄 POSIX extended regex the body must match | No | none |
| `user-agent` | 🪪 `User-Agent` header | No | `wait-for-http-endpoint` |
| `print-body` | 📄 Print the last response body in the log | No | `false` |
| `continue-on-error` | ⏭️ Pass the step when the endpoint never becomes ready | No | `false` |

## 📤 Outputs

| Output | Description |
| --- | --- |
| `result` | 📊 `success` or `failure` |
| `status` | 🚦 Last HTTP status code (`000` when the request failed) |
| `attempts` | 🔢 Number of requests made |
| `duration_ms` | ⏱️ Total time spent polling in milliseconds |
| `error` | ❌ Failure reason, empty on success |

## 🎯 Status matching

`expected-status` takes a comma-separated list. Spaces are trimmed.

```yaml
expected-status: "200,201,204"   # any of these codes
expected-status: "2xx"           # any 2xx code
expected-status: "200, 3xx"      # mix codes and classes
```

Codes must be three digits and start with `1` to `5`. Classes are `1xx` through
`5xx`. Case does not matter.

## 🛠️ Usage

### 🔗 Basic health check

```yaml
- name: Wait for the API
  uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://api.example.com/health
    timeout: 30000
    interval: 500
```

### 🎯 Accept a class of codes

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: http://localhost:3000/
    expected-status: 2xx,3xx
    follow-redirects: "true"
```

### 🔑 Authenticated endpoint

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://staging.example.com/api/status
    bearer-token: ${{ secrets.API_TEST_TOKEN }}
```

### 🧾 Custom headers and a request body

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://api.example.com/graphql
    method: POST
    content-type: application/json
    headers: |
      X-Environment: staging
      Accept: application/json
    body: '{"query":"{ health { ok } }"}'
    expected-status: "200,201"
```

### 📄 Wait until the body says it is ready

A `200` can arrive before the app is actually ready. Match the body too:

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://api.example.com/health
    expected-body: '"status"[[:space:]]*:[[:space:]]*"ready"'
    timeout: 60000
```

### 🔓 Self-signed certificate

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://staging.example.local/health
    insecure: "true"
```

### ⏭️ Do not fail the job

```yaml
- id: probe
  uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
  with:
    url: https://preview.example.com/
    timeout: 10000
    continue-on-error: "true"

- if: steps.probe.outputs.result == 'failure'
  run: echo "Preview is not up: ${{ steps.probe.outputs.error }}"
```

### ☕ Wait for a local development server

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Start the server
        run: npm start &
      - name: Wait for the server
        uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
        with:
          url: http://localhost:3000/
          timeout: 60000
      - name: Run tests
        run: npm test
```

## 🧪 Standalone use

Set the `INPUT_*` variables and run the script. This works outside GitHub Actions.

```bash
curl -fsSLO https://raw.githubusercontent.com/HarryVasanth/wait-for-http-endpoint/main/wait-for-http-endpoint.sh
chmod +x wait-for-http-endpoint.sh

INPUT_URL=http://localhost:3000/health \
INPUT_EXPECTED_STATUS=200,2xx \
INPUT_TIMEOUT=30000 \
./wait-for-http-endpoint.sh
```

The script prints the outputs when `GITHUB_OUTPUT` is not set.

## 🔐 Security

- **No runtime downloads.** The action runs the script from its own repository.
- **No Docker socket.** The action never asks for host access.
- **Hidden secrets.** Bearer tokens, header values and the URL query/fragment are never printed.
- **Opt-in body output.** `print-body` is off by default because a response body can contain secrets.
- **Pin for production.** Reference the exact release tag, not the moving major tag:

```yaml
- uses: HarryVasanth/wait-for-http-endpoint@v1.1.0
```

- **Limit the job.** Add `permissions: contents: read` when the job needs nothing more.

## ⚠️ Limits

- The deadline has millisecond precision on GNU date. On systems with BSD date
  (macOS), it falls back to whole seconds, so the timeout can be up to 1s late.
- A request is bounded by `--max-time` rounded up to whole seconds. A tiny
  `timeout` can therefore run for up to about 1s.
- Systems without fractional `sleep` round the interval up to whole seconds.
- `expected-body` cannot be used with `method: HEAD`, because a HEAD response has no body.
- `print-body` prints at most 2000 bytes of the last response.
- A slow endpoint is checked with the remaining time. If the deadline passes during
  a request, that request is allowed to finish or hit `--max-time`.
- The action needs `curl` and `bash`. GitHub-hosted runners provide both.

## 🔄 Migrating from v1

The v1 action used Docker. This version is a composite action. The inputs keep
their names and defaults, so existing workflows keep working. The only additions
are the new optional inputs and outputs. Docker is no longer required, and the
step starts without pulling an image.

## 📄 License

MIT
