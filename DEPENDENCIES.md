# Dependencies - ai-gateway-1-of-10-chat

## Runtime dependencies

- Node.js 20 (Alpine, via Docker image)
- Hono (HTTP framework)
- @hono/node-server
- pg (PostgreSQL client)
- redis (Redis client)
- prom-client (Prometheus metrics)

## Infrastructure dependencies

- Docker + Docker Compose (or Docker Swarm compatible)
- PostgreSQL (external, configured via .env; not bundled)
- Redis (external, configured via .env; not bundled)
- Prometheus (optional, scrapes /metrics)
- Grafana (optional, imports observability/grafana/dashboard.json)
- External Docker network: SHARED_DOCKER_NETWORK (default ai-gateway-net)

## Explicitly NOT required to start this stack

Cloudflare, Firebase, Groq, Gemini, OpenAI, Anthropic, Lovable, Make, n8n.
