# Wait for HTTP(S) Endpoint Action

This is a simple GitHub action that polls a specified HTTP(S) endpoint until it responds with the expected status code or the timeout is exceeded.

## Features

- Configurable HTTP method, timeout, and polling interval
- Support for multiple expected status codes
- **Support for Bearer Token authorization**
- **Options to skip TLS verification and follow redirects**
- Detailed console output for debugging, exposing exact connection errors
- Lightweight implementation using Alpine Linux, Bash, and cURL

## Inputs

| Input              | Description                                    | Required | Default |
| ------------------ | ---------------------------------------------- | -------- | ------- |
| `url`              | The URL to poll                                | Yes      | N/A     |
| `method`           | The HTTP method to use                         | No       | GET     |
| `expected-status`  | Expected HTTP status code(s) (comma-separated) | No       | 200     |
| `timeout`          | Maximum polling time in milliseconds           | No       | 60000   |
| `interval`         | Polling interval in milliseconds               | No       | 1000    |
| `insecure`         | Skip TLS certificate verification (true/false) | No       | false   |
| `follow-redirects` | Follow HTTP redirects (true/false)             | No       | false   |
| `bearer-token`     | Optional token for the Authorization header    | No       | N/A     |

## Usage

```yml
steps:
  - name: Wait for API to be ready
    uses: harryvasanth/wait-for-http-endpoint@v1
    with:
      url: http://api.example.com/health
      method: GET
      expected-status: 200,201
      timeout: 30000
      interval: 500
      follow-redirects: "true"
```

## Examples

### Wait for a local development server to start:

```yml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Start server
        run: npm start &
      - name: Wait for server
        uses: harryvasanth/wait-for-http-endpoint@v1
        with:
          url: http://localhost:3000
          timeout: 60000
      - name: Run tests
        run: npm test
```

### Wait for an authenticated endpoint with self-signed certs:

```yml
steps:
  - name: Wait for staging backend
    uses: harryvasanth/wait-for-http-endpoint@v1
    with:
      url: https://staging.example.local/api/v1/status
      expected-status: 200
      insecure: "true"
      bearer-token: ${{ secrets.API_TEST_TOKEN }}
```
