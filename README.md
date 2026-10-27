# ai-gateway-1-of-10-chat

Stack 1 of 10 in a planned hybrid AI platform. This repository is a single,
independently deployable stack: a chat gateway foundation.

## Status

Iteration 1 of 10 - Chat Foundation. See CHECKPOINT.md for exact scope.

## Quick start

```
cp .env.example .env   # if not already created
./deploy-ai-gateway-1-of-10-chat.sh init
./deploy-ai-gateway-1-of-10-chat.sh build
./deploy-ai-gateway-1-of-10-chat.sh deploy
./deploy-ai-gateway-1-of-10-chat.sh test
```

## Commands

Run `./deploy-ai-gateway-1-of-10-chat.sh help` for the full command list.

See ARCHITECTURE.md, DEPENDENCIES.md, OBSERVABILITY.md, SECURITY.md, and
CHECKPOINT.md for details.
# PROMPT-01-CHAT-STACK-ARCHITECT

## Day 2 — Provider Abstraction + Model Registry (IMPLEMENTED)

Flow: `HTTP API -> request resolver -> model registry -> provider adapter -> external provider`.

Configuration (see `.env.example`, values only in the untracked `.env`):
`AI_DEFAULT_PROVIDER`, `AI_DEFAULT_MODEL`, `AI_REQUEST_TIMEOUT_MS`,
`GROQ_ENABLED`, `GROQ_API_KEY`, `GROQ_BASE_URL`, `GROQ_MODELS`
(`GROQ_MODELS` is operator-declared: `model_key:category,...`).

- IMPLEMENTED: provider interface, Groq adapter, model registry, deterministic
  resolution, provider health in `/dependencies`, provider metrics, migration
  `002_provider_model_registry.sql`, unit + API tests.
- PLANNED: logical model aliases (tables exist, resolution not implemented),
  response caching, agent registry (PROMPT-03).
- NOT IMPLEMENTED: streaming, tools, JSON mode, embeddings, vision, voice,
  token estimation, auth, billing, additional providers (Gemini is config-only).

With no provider configured, `POST /v1/chat` returns HTTP 503 with
`error.code = no_provider_configured`. No response is ever fabricated.
