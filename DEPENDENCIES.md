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

## Dependency test location (Day 2)

Host reachability and container reachability are different facts. Each probe
reports `TEST LOCATION`, `TARGET`, `DNS`, `TCP`. Docker service names such as
`opentts-ai-postgres-db` normally resolve only inside the Docker network, so a
host FAIL together with a container PASS is expected and is not an error.
Docker service names are never replaced with hardcoded IP addresses.

AI providers are checked with a configuration-only probe (enabled + key
present). No live AI call is made from `/dependencies`.
