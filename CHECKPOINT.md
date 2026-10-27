# AI Gateway 1 of 10 — Chat

## Current Iteration

AI-GATEWAY-1-OF-10-CHAT (Chat Foundation)

## Implemented

- Node.js/Hono API foundation
- Docker Compose service definition (external network dependency)
- PostgreSQL connectivity + persistence
- Redis connectivity + cache foundation
- /health, /ready, /dependencies, /help, /metrics, /v1/chat
- Structured JSON logging with redaction
- Prometheus metrics
- Minimal Grafana dashboard
- Deployment lifecycle script (init/build/push/deploy/ps/logs/test/help)
- Basic smoke tests
- Security documentation and .gitignore

## Not Implemented

- Authentication / OAuth / JWT / user accounts / billing
- Real AI provider adapters and model routing
- Vector database / RAG / web search
- Voice, TTS, STT
- Autonomous / multi-agent orchestration
- Streaming beyond what Hono provides trivially
- Frontend

## Files

See repository root: deploy-ai-gateway-1-of-10-chat.sh, docker-compose.yml,
.env.example, .gitignore, README.md, ARCHITECTURE.md, DEPENDENCIES.md,
SECURITY.md, OBSERVABILITY.md, CHECKPOINT.md, api/, database/migrations/,
observability/grafana/, tests/.

## Docker Services

- api (Hono service, built from ./api, joins external network
  SHARED_DOCKER_NETWORK)

## External Dependencies

PostgreSQL, Redis, Prometheus (optional), Grafana (optional), external
Docker network ai-gateway-net (or configured name).

## Environment Variables

See .env.example for the full authoritative list.

## API Endpoints

GET /health, GET /ready, GET /dependencies, GET /help, GET /metrics,
POST /v1/chat

## Metrics

ai_gateway_http_requests_total, ai_gateway_http_request_duration_seconds,
ai_gateway_ai_requests_total, ai_gateway_ai_request_duration_seconds,
ai_gateway_ai_request_errors_total, ai_gateway_input_tokens_total,
ai_gateway_output_tokens_total, ai_gateway_cache_hits_total,
ai_gateway_cache_misses_total

## Database

Tables: agents, ai_requests, ai_usage (see
database/migrations/001_initial_chat_foundation.sql)

## Tests

tests/smoke_test.sh exercises all six endpoints and reports
PASS/FAIL/NOT AVAILABLE per endpoint; run via
`./deploy-ai-gateway-1-of-10-chat.sh test`.

## Security Validation

Run via `./deploy-ai-gateway-1-of-10-chat.sh test` (secret scan +
config validation). Review output before deploying beyond a trusted
local network.

## Known Limitations

Chat responses are stubbed (no live AI provider). No auth. Single
Postgres/Redis instance assumption. No horizontal scaling guidance yet.

## Next Iteration

ADDING THE REAL AI PROVIDER ADAPTER / MODEL ROUTING FOUNDATION

---

## Iteration: PROMPT-02 — Provider Abstraction + Model Registry

### Implemented
- Provider adapter interface (`chat` / `health` / `metadata`) + bounded error type.
- Groq adapter (OpenAI-compatible chat completions, fetch, timeout, no SDK).
- Provider registry, model registry (operator-declared models, categories), resolver.
- Deterministic resolution order with controlled failures; no fabricated responses.
- Migration `002_provider_model_registry.sql`: `providers`, `models`,
  `model_aliases` (structure only), `ai_usage_v2` (nullable token usage). No secrets stored.
- `/dependencies` and `/help` report provider status (config-only, no live call, no secrets).
- Provider metrics + extended existing Grafana dashboard.
- Deployment script hooked for provider validation, dependency matrix, provider tests,
  improved secret scan. Commands unchanged: init build push deploy ps logs test help.

### Tests
- Unit: provider registry, model registry, resolution, unknown provider, unknown model,
  missing configuration, secret non-leakage (`node --test tests/`).
- API: `/dependencies` provider status, invalid provider, invalid model, validation,
  default resolution, metrics presence (`tests/provider_test.sh`).

### Skipped / NOT AVAILABLE
- Live cloud provider chat is reported NOT AVAILABLE unless a real key is configured
  and the request actually executed.
- Container dependency probes are skipped when the API container is not running.

### Known limitations
- Only Groq has an adapter; Gemini is configuration placeholder only.
- Model aliases: tables exist, resolution not implemented.
- No streaming, tools, JSON mode, caching of AI responses, token estimation.
- Registry is env-driven at runtime; DB rows are for persistence/inspection.

### Next iteration
PROMPT-03 — Agent Registry + Agent Resolution (not implemented here).
