# Observability - ai-gateway-1-of-10-chat

## Metrics (Prometheus, exposed at /metrics)

- ai_gateway_http_requests_total{method,route,status}
- ai_gateway_http_request_duration_seconds{method,route,status}
- ai_gateway_ai_requests_total{provider,status}
- ai_gateway_ai_request_duration_seconds{provider}
- ai_gateway_ai_request_errors_total{provider}
- ai_gateway_input_tokens_total{provider}
- ai_gateway_output_tokens_total{provider}
- ai_gateway_cache_hits_total
- ai_gateway_cache_misses_total

Labels are bounded and never include request_id, prompt, message,
instruction, or raw response content.

## Logging

Structured JSON logs to stdout/stderr with fields: timestamp, level,
service, request_id (where applicable), operation, status, latency.
Sensitive fields (password, api_key, secret, token, authorization,
private_key) are redacted automatically.

## Dashboard

observability/grafana/dashboard.json provides six panels: HTTP request
rate, HTTP error rate, request latency, AI request rate, token
consumption, and cache hit ratio. No credentials or hardcoded URLs are
included; import into any Grafana instance pointed at your Prometheus.

## Day 2 provider metrics

| Metric | Type | Labels |
|---|---|---|
| `ai_gateway_provider_requests_total` | counter | provider, model, operation, status |
| `ai_gateway_provider_errors_total` | counter | provider, model, operation, status |
| `ai_gateway_provider_request_duration_seconds` | histogram | provider, model, operation |
| `ai_gateway_provider_input_tokens_total` | counter | provider, model |
| `ai_gateway_provider_output_tokens_total` | counter | provider, model |

Labels are bounded. `request_id`, prompts, instructions, messages and raw
responses are never used as labels. Token counters increment only when the
provider actually reports usage.

Grafana: the existing dashboard gains panels for provider request rate,
provider error rate, provider latency (p95), tokens by provider, tokens by model.
