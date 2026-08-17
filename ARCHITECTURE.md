# Architecture - ai-gateway-1-of-10-chat

## Scope of this iteration

IMPLEMENTED:
- Node.js/Hono HTTP API
- PostgreSQL connectivity and persistence (ai_requests, ai_usage, agents)
- Redis connectivity as a non-authoritative cache layer
- /health, /ready, /dependencies, /help, /metrics, /v1/chat
- Prometheus metrics
- Minimal Grafana dashboard
- Deployment lifecycle script

NOT IMPLEMENTED (future iterations):
- Authentication / OAuth / JWT
- Real AI provider adapters (OpenAI, Anthropic, Gemini, Groq, etc.)
- Model routing / intelligent agent selection
- Vector database / RAG
- Streaming responses
- Multi-agent orchestration
- Frontend

## Request flow (current)

Client -> POST /v1/chat -> validate -> generate request_id ->
persist to Postgres (processing) -> cache lookup in Redis ->
stub response -> persist completion + usage -> return envelope.

## Network model

This stack expects an external Docker network named by
SHARED_DOCKER_NETWORK (default ai-gateway-net) to already exist,
shared with future stacks (agent registry, router, etc.).
