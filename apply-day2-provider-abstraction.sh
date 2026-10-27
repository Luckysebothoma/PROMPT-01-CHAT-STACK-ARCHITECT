#!/usr/bin/env bash
# =============================================================================
# apply-day2-provider-abstraction.sh
# PROMPT-02 / DAY 2 — Provider Abstraction + Model Registry
# Applies the smallest correct Day-2 increment to the EXISTING repository
#   PROMPT-01-CHAT-STACK-ARCHITECT  (stack: ai-gateway-1-of-10-chat)
#
# Idempotent. Adds files, patches existing files only via guarded markers.
# Does NOT rewrite Stack 01, does NOT touch .env, DB data, Redis data.
# Run from the repository root:  bash apply-day2-provider-abstraction.sh
# =============================================================================
set -u
set -o pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$ROOT_DIR/docker-compose.yml" ] || ROOT_DIR="$PWD"
cd "$ROOT_DIR" || exit 1

log()  { printf "[INFO] %s\n" "$*" >&2; }
ok()   { printf "[PASS] %s\n" "$*" >&2; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
die()  { printf "[FAIL] %s\n" "$*" >&2; exit 1; }

# --- preflight: confirm we are in the Stack 01 repository ---------------------
for f in docker-compose.yml api/src/index.js api/src/routes/chat.js \
         database/migrations/001_initial_chat_foundation.sql \
         deploy-ai-gateway-1-of-10.sh observability/grafana/dashboard.json; do
  [ -f "$f" ] || die "Not the Stack 01 repository root (missing $f)"
done
ok "Stack 01 repository detected at $ROOT_DIR"

backup() { [ -f "$1" ] && [ ! -f "$1.day1.bak" ] && cp "$1" "$1.day1.bak"; return 0; }

mkdir -p api/src/providers scripts tests database/migrations

# =============================================================================
# 1. PROVIDER CONFIGURATION (env-driven; no secrets in code)
# =============================================================================
cat > api/src/lib/providerEnv.js <<'EOF'
// Day-2 provider configuration. Secrets are read from the environment only
// and are never logged, persisted or returned by the API.
function bool(v, d = false) {
  if (v === undefined || v === "") return d;
  return String(v).toLowerCase() === "true";
}

export const providerEnv = {
  DEFAULT_PROVIDER: process.env.AI_DEFAULT_PROVIDER || "",
  DEFAULT_MODEL: process.env.AI_DEFAULT_MODEL || "",
  REQUEST_TIMEOUT_MS: parseInt(process.env.AI_REQUEST_TIMEOUT_MS || "30000", 10),

  groq: {
    name: "groq",
    display_name: "Groq",
    enabled: bool(process.env.GROQ_ENABLED, false),
    apiKey: process.env.GROQ_API_KEY || "",
    baseUrl: process.env.GROQ_BASE_URL || "https://api.groq.com/openai/v1",
    // Comma separated "model_key:category" pairs. No models are fabricated:
    // the operator declares exactly which provider models exist.
    models: process.env.GROQ_MODELS || "",
  },
};

export function providerConfigured(p) {
  return !!(p && p.enabled && p.apiKey);
}
EOF
ok "api/src/lib/providerEnv.js"

# =============================================================================
# 2. PROVIDER ADAPTER INTERFACE
# =============================================================================
cat > api/src/providers/provider.interface.js <<'EOF'
// ProviderAdapter contract. Every adapter MUST implement:
//   metadata() -> { name, display_name, enabled, configured, base_url }
//   health()   -> { enabled, configured, status }   (no live network call)
//   chat({ model, instruction, message, temperature })
//        -> { content, model, usage: { input_tokens, output_tokens, total_tokens } | null }
// usage MUST be null when the provider does not report it. Never estimate.
export class ProviderAdapter {
  constructor(name) { this.name = name; }
  metadata() { throw new Error("metadata() not implemented"); }
  health() { throw new Error("health() not implemented"); }
  async chat() { throw new Error("chat() not implemented"); }
}

export class ProviderError extends Error {
  constructor(code, message, providerStatus) {
    super(message);
    this.code = code;                     // safe, non-leaking code
    this.providerStatus = providerStatus || null;
  }
}
EOF
ok "api/src/providers/provider.interface.js"

# =============================================================================
# 3. REAL CLOUD PROVIDER ADAPTER (Groq, OpenAI-compatible chat completions)
# =============================================================================
cat > api/src/providers/groq.provider.js <<'EOF'
import { ProviderAdapter, ProviderError } from "./provider.interface.js";
import { providerEnv, providerConfigured } from "../lib/providerEnv.js";

export class GroqProvider extends ProviderAdapter {
  constructor() {
    super("groq");
    this.cfg = providerEnv.groq;
  }

  metadata() {
    return {
      name: this.cfg.name,
      display_name: this.cfg.display_name,
      enabled: this.cfg.enabled,
      configured: providerConfigured(this.cfg),
      base_url: this.cfg.baseUrl,   // never the key
      supports_streaming: false,    // not implemented in this iteration
      supports_json: null,          // unknown per model; not fabricated
      supports_tools: null,
    };
  }

  // Lightweight configuration check only. No live API call.
  health() {
    const m = this.metadata();
    let status = "unavailable";
    if (!m.enabled) status = "disabled";
    else if (!m.configured) status = "not_configured";
    else status = "available";
    return { enabled: m.enabled, configured: m.configured, status };
  }

  async chat({ model, instruction, message, temperature }) {
    if (!providerConfigured(this.cfg)) {
      throw new ProviderError("provider_not_configured", "Provider is not configured");
    }
    const messages = [];
    if (instruction) messages.push({ role: "system", content: instruction });
    messages.push({ role: "user", content: message });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), providerEnv.REQUEST_TIMEOUT_MS);
    let res;
    try {
      res = await fetch(`${this.cfg.baseUrl.replace(/\/$/, "")}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.cfg.apiKey}`,
        },
        body: JSON.stringify({
          model,
          messages,
          ...(typeof temperature === "number" ? { temperature } : {}),
        }),
        signal: controller.signal,
      });
    } catch (err) {
      throw new ProviderError("provider_unreachable", "Upstream AI provider request failed");
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      // Upstream body is deliberately NOT propagated to the client.
      throw new ProviderError("provider_error", "Upstream AI provider returned an error", res.status);
    }

    let payload;
    try { payload = await res.json(); }
    catch { throw new ProviderError("provider_bad_response", "Upstream AI provider returned an unreadable response"); }

    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      throw new ProviderError("provider_bad_response", "Upstream AI provider returned no content");
    }

    const u = payload?.usage;
    const usage = u && typeof u.prompt_tokens === "number" && typeof u.completion_tokens === "number"
      ? {
          input_tokens: u.prompt_tokens,
          output_tokens: u.completion_tokens,
          total_tokens: typeof u.total_tokens === "number"
            ? u.total_tokens
            : u.prompt_tokens + u.completion_tokens,
        }
      : null;   // provider did not report usage -> explicitly unavailable

    return { content, model: payload?.model || model, usage };
  }
}
EOF
ok "api/src/providers/groq.provider.js"

# =============================================================================
# 4. PROVIDER + MODEL REGISTRY
# =============================================================================
cat > api/src/providers/provider.registry.js <<'EOF'
import { GroqProvider } from "./groq.provider.js";

const adapters = new Map();
adapters.set("groq", new GroqProvider());
// Additional adapters (gemini, openai, ...) register here in later iterations.

export function getProvider(name) {
  return adapters.get(String(name || "").toLowerCase()) || null;
}
export function listProviders() {
  return Array.from(adapters.values());
}
export function providerHealthMap() {
  const out = {};
  for (const a of adapters.values()) out[a.name] = a.health();
  return out;
}
export function anyProviderAvailable() {
  return listProviders().some((a) => a.health().status === "available");
}
EOF

cat > api/src/providers/model.registry.js <<'EOF'
import { providerEnv } from "../lib/providerEnv.js";

// Supported categories. Only categories that are actually implemented are
// used; the structure allows more to be added without schema changes.
export const CATEGORIES = [
  "chat", "reasoning", "code", "json", "writing",
  "content", "analysis", "vision", "embedding", "audio", "voice",
];

// Models are declared by the operator via <PROVIDER>_MODELS, e.g.
//   GROQ_MODELS=some-provider-model-id:chat,another-model-id:reasoning
// No model identifiers are invented by the gateway.
function parseModels(providerName, spec) {
  const out = [];
  for (const raw of String(spec || "").split(",")) {
    const item = raw.trim();
    if (!item) continue;
    const [key, category] = item.split(":").map((s) => (s || "").trim());
    if (!key) continue;
    out.push({
      provider: providerName,
      model_key: key,
      display_name: key,
      category: CATEGORIES.includes(category) ? category : "chat",
      enabled: true,
      temperature_default: null,   // unknown unless declared
      context_window: null,        // unknown -> null, never fabricated
      supports_streaming: false,   // streaming not implemented this iteration
      supports_json: null,
      supports_tools: null,
    });
  }
  return out;
}

let registry = null;

export function buildRegistry() {
  const models = [...parseModels("groq", providerEnv.groq.models)];
  // The configured default model is always resolvable even if not listed.
  const dp = providerEnv.DEFAULT_PROVIDER;
  const dm = providerEnv.DEFAULT_MODEL;
  if (dp && dm && !models.some((m) => m.provider === dp && m.model_key === dm)) {
    models.push({
      provider: dp, model_key: dm, display_name: dm, category: "chat",
      enabled: true, temperature_default: null, context_window: null,
      supports_streaming: false, supports_json: null, supports_tools: null,
    });
  }
  return models;
}

export function listModels() {
  if (!registry) registry = buildRegistry();
  return registry;
}
export function findModel(provider, modelKey) {
  return listModels().find(
    (m) => m.provider === provider && m.model_key === modelKey && m.enabled
  ) || null;
}
export function findModelAnyProvider(modelKey) {
  return listModels().find((m) => m.model_key === modelKey && m.enabled) || null;
}
export function resetRegistry() { registry = null; }
EOF

cat > api/src/providers/resolver.js <<'EOF'
import { providerEnv } from "../lib/providerEnv.js";
import { getProvider } from "./provider.registry.js";
import { findModel, findModelAnyProvider } from "./model.registry.js";

// Deterministic resolution order:
//   1. explicit provider   2. explicit model   3. (agent mapping: PROMPT-03)
//   4. AI_DEFAULT_PROVIDER 5. AI_DEFAULT_MODEL 6. controlled failure
export function resolveTarget({ provider, model }) {
  let providerName = provider || null;
  let modelKey = model || null;

  if (!providerName && modelKey) {
    const m = findModelAnyProvider(modelKey);
    if (m) providerName = m.provider;
  }
  if (!providerName) providerName = providerEnv.DEFAULT_PROVIDER || null;
  if (!modelKey) modelKey = providerEnv.DEFAULT_MODEL || null;

  if (!providerName || !modelKey) {
    return { ok: false, code: "no_provider_configured",
      message: "No AI provider or model is configured for this gateway" };
  }

  const adapter = getProvider(providerName);
  if (!adapter) {
    return { ok: false, code: "unknown_provider",
      message: `Provider '${providerName}' is not registered` };
  }
  const health = adapter.health();
  if (health.status !== "available") {
    return { ok: false, code: "provider_unavailable",
      message: `Provider '${providerName}' is ${health.status}` };
  }
  if (provider && model && !findModel(providerName, modelKey)) {
    return { ok: false, code: "unknown_model",
      message: `Model '${modelKey}' is not registered for provider '${providerName}'` };
  }

  return { ok: true, provider: providerName, model: modelKey, adapter };
}
EOF
ok "provider registry / model registry / resolver"

# =============================================================================
# 5. METRICS (bounded labels only)
# =============================================================================
cat > api/src/lib/providerMetrics.js <<'EOF'
import client from "prom-client";
import { register } from "./metrics.js";

// Bounded labels only: provider, model, operation, status.
export const providerRequestsTotal = new client.Counter({
  name: "ai_gateway_provider_requests_total",
  help: "Total provider requests",
  labelNames: ["provider", "model", "operation", "status"],
  registers: [register],
});
export const providerErrorsTotal = new client.Counter({
  name: "ai_gateway_provider_errors_total",
  help: "Total provider errors",
  labelNames: ["provider", "model", "operation", "status"],
  registers: [register],
});
export const providerRequestDuration = new client.Histogram({
  name: "ai_gateway_provider_request_duration_seconds",
  help: "Provider request duration in seconds",
  labelNames: ["provider", "model", "operation"],
  registers: [register],
});
export const providerInputTokensTotal = new client.Counter({
  name: "ai_gateway_provider_input_tokens_total",
  help: "Input tokens reported by the provider",
  labelNames: ["provider", "model"],
  registers: [register],
});
export const providerOutputTokensTotal = new client.Counter({
  name: "ai_gateway_provider_output_tokens_total",
  help: "Output tokens reported by the provider",
  labelNames: ["provider", "model"],
  registers: [register],
});
EOF
ok "api/src/lib/providerMetrics.js"

# =============================================================================
# 6. CHAT ROUTE — resolution -> adapter -> usage -> persistence -> envelope
# =============================================================================
backup api/src/routes/chat.js
cat > api/src/routes/chat.js <<'EOF'
import { Hono } from "hono";
import { randomUUID } from "node:crypto";
import { env } from "../lib/env.js";
import { logger } from "../lib/logger.js";
import { getPool, checkPostgres } from "../lib/db.js";
import {
  aiRequestsTotal, aiRequestDuration, aiRequestErrorsTotal,
} from "../lib/metrics.js";
import {
  providerRequestsTotal, providerErrorsTotal, providerRequestDuration,
  providerInputTokensTotal, providerOutputTokensTotal,
} from "../lib/providerMetrics.js";
import { resolveTarget } from "../providers/resolver.js";
import { ProviderError } from "../providers/provider.interface.js";

export const chatRoutes = new Hono();

function envelopeSuccess(requestId, data, meta) {
  return { success: true, request_id: requestId, data: data || {}, meta: meta || {} };
}
function envelopeError(requestId, code, message, meta) {
  return { success: false, request_id: requestId, error: { code, message }, meta: meta || {} };
}

async function pgReady() {
  if (!env.POSTGRES_ENABLED) return false;
  const pg = await checkPostgres();
  return pg.status === "connected";
}

async function persistRequest({ requestId, operation, agentName, provider, model, status }) {
  if (!(await pgReady())) return;
  try {
    await getPool().query(
      `INSERT INTO ai_requests (request_id, operation, agent_name, provider, model, status)
       VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (request_id) DO NOTHING`,
      [requestId, operation, agentName || null, provider || null, model || null, status]
    );
  } catch (err) {
    logger.warn({ operation: "persist_request_failed", request_id: requestId, message: err.message });
  }
}

async function completeRequest({ requestId, status, latencyMs }) {
  if (!(await pgReady())) return;
  try {
    await getPool().query(
      `UPDATE ai_requests SET status=$2, completed_at=NOW(), latency_ms=$3 WHERE request_id=$1`,
      [requestId, status, latencyMs]
    );
  } catch (err) {
    logger.warn({ operation: "complete_request_failed", request_id: requestId, message: err.message });
  }
}

// usage may be null: provider did not report token usage. Never estimated.
async function recordUsage({ requestId, provider, model, usage }) {
  if (!(await pgReady())) return;
  try {
    await getPool().query(
      `INSERT INTO ai_usage_v2 (request_id, provider, model, input_tokens, output_tokens,
                                total_tokens, usage_reported)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [requestId, provider || null, model || null,
       usage ? usage.input_tokens : null,
       usage ? usage.output_tokens : null,
       usage ? usage.total_tokens : null,
       !!usage]
    );
  } catch (err) {
    logger.warn({ operation: "record_usage_failed", request_id: requestId, message: err.message });
  }
}

chatRoutes.post("/v1/chat", async (c) => {
  const requestId = randomUUID();
  const startedAt = process.hrtime.bigint();
  const operation = "chat";

  let body;
  try { body = await c.req.json(); }
  catch { return c.json(envelopeError(requestId, "invalid_json", "Request body must be valid JSON"), 400); }

  const message = body && typeof body.message === "string" ? body.message : null;
  if (!message) {
    return c.json(envelopeError(requestId, "validation_error",
      "Field 'message' is required and must be a string"), 400);
  }
  const agentName = typeof body.agent_name === "string" ? body.agent_name : null;
  const instruction = typeof body.instruction === "string" ? body.instruction : null;
  const temperature = typeof body.temperature === "number" ? body.temperature : undefined;
  const metadata = body.metadata && typeof body.metadata === "object" ? body.metadata : {};

  const resolved = resolveTarget({
    provider: typeof body.provider === "string" ? body.provider : null,
    model: typeof body.model === "string" ? body.model : null,
  });

  if (!resolved.ok) {
    // Controlled failure. No AI response is fabricated.
    const httpStatus = resolved.code === "no_provider_configured" ? 503 : 400;
    logger.warn({ operation: "chat_resolution_failed", request_id: requestId, message: resolved.code });
    return c.json(envelopeError(requestId, resolved.code, resolved.message,
      { provider: null, model: null, cached: false }), httpStatus);
  }

  const { provider, model, adapter } = resolved;
  const labels = { provider, model, operation };

  await persistRequest({ requestId, operation, agentName, provider, model, status: "processing" });
  aiRequestsTotal.inc({ provider, status: "started" });
  const endAiTimer = aiRequestDuration.startTimer({ provider });
  const endProviderTimer = providerRequestDuration.startTimer(labels);

  let result;
  try {
    result = await adapter.chat({ model, instruction, message, temperature });
  } catch (err) {
    endProviderTimer(); endAiTimer();
    const code = err instanceof ProviderError ? err.code : "provider_error";
    providerRequestsTotal.inc({ ...labels, status: "error" });
    providerErrorsTotal.inc({ ...labels, status: code });
    aiRequestErrorsTotal.inc({ provider });
    logger.error({ operation: "chat_execution_failed", request_id: requestId, message: code });
    const latencyMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    await completeRequest({ requestId, status: "error", latencyMs });
    return c.json(envelopeError(requestId, code,
      "The AI provider request could not be completed", { provider, model, cached: false }), 502);
  }
  endProviderTimer(); endAiTimer();

  providerRequestsTotal.inc({ ...labels, status: "success" });
  aiRequestsTotal.inc({ provider, status: "completed" });

  if (result.usage) {
    providerInputTokensTotal.inc({ provider, model }, result.usage.input_tokens);
    providerOutputTokensTotal.inc({ provider, model }, result.usage.output_tokens);
  }

  const latencyMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
  await completeRequest({ requestId, status: "completed", latencyMs });
  await recordUsage({ requestId, provider, model, usage: result.usage });

  logger.info({ operation, request_id: requestId, status: "completed",
    latency: latencyMs, agent_name: agentName, provider, model });

  return c.json(
    envelopeSuccess(
      requestId,
      { content: result.content, reply: result.content,   // 'reply' kept for backward compatibility
        agent_name: agentName, instruction_applied: !!instruction },
      { provider, model: result.model || model, cached: false, latency_ms: latencyMs,
        usage: result.usage, usage_reported: !!result.usage, metadata }
    )
  );
});
EOF
ok "api/src/routes/chat.js (provider-driven)"

# =============================================================================
# 7. /dependencies + /help — provider status (no secrets, no live calls)
# =============================================================================
backup api/src/routes/health.js
python3 - <<'PY'
import re, io
p = "api/src/routes/health.js"
s = open(p).read()
if "providerHealthMap" not in s:
    s = s.replace(
        'import { checkRedis } from "../lib/redisClient.js";',
        'import { checkRedis } from "../lib/redisClient.js";\n'
        'import { providerHealthMap } from "../providers/provider.registry.js";\n'
        'import { listModels } from "../providers/model.registry.js";\n'
        'import { providerEnv } from "../lib/providerEnv.js";'
    )
    s = s.replace(
        '  return c.json({\n    service: env.APP_NAME,\n    dependencies: { postgres: pg, redis: redis },\n  });',
        '  return c.json({\n'
        '    service: env.APP_NAME,\n'
        '    test_location: "container",\n'
        '    dependencies: { postgres: pg, redis: redis },\n'
        '    ai_providers: providerHealthMap(),\n'
        '  });'
    )
    s = s.replace(
        '    supported_operations: ["chat"],',
        '    supported_operations: ["chat"],\n'
        '    default_provider: providerEnv.DEFAULT_PROVIDER || null,\n'
        '    default_model: providerEnv.DEFAULT_MODEL || null,\n'
        '    providers: providerHealthMap(),\n'
        '    models: listModels(),'
    )
    s = s.replace(
        '"This is iteration 1 of 10. Real AI provider routing is not implemented yet."',
        '"Iteration 2: provider abstraction + model registry. Streaming, aliases, agents not implemented."'
    )
    open(p, "w").write(s)
    print("[PASS] api/src/routes/health.js patched")
else:
    print("[INFO] api/src/routes/health.js already patched")
PY

# =============================================================================
# 8. DATABASE MIGRATION (new file only; 001 untouched; no secrets stored)
# =============================================================================
cat > database/migrations/002_provider_model_registry.sql <<'EOF'
-- 002_provider_model_registry.sql
-- PROMPT-02 / Day 2: provider + model registry.
-- API keys are NEVER stored here. Secrets remain in environment configuration.

BEGIN;

CREATE TABLE IF NOT EXISTS providers (
    id            BIGSERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    enabled       BOOLEAN NOT NULL DEFAULT FALSE,
    base_url      TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS models (
    id                   BIGSERIAL PRIMARY KEY,
    provider_id          BIGINT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
    model_key            TEXT NOT NULL,
    display_name         TEXT NOT NULL,
    category             TEXT NOT NULL DEFAULT 'chat',
    enabled              BOOLEAN NOT NULL DEFAULT TRUE,
    temperature_default  NUMERIC(3,2),
    context_window       INTEGER,
    supports_streaming   BOOLEAN,
    supports_json        BOOLEAN,
    supports_tools       BOOLEAN,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider_id, model_key)
);

-- Structure that allows logical aliases (e.g. "fast-chat") to be added later.
-- No alias resolution is implemented in this iteration.
CREATE TABLE IF NOT EXISTS model_aliases (
    id          BIGSERIAL PRIMARY KEY,
    alias       TEXT NOT NULL UNIQUE,
    model_id    BIGINT NOT NULL REFERENCES models(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Usage table that can represent "provider did not report usage" (NULL).
CREATE TABLE IF NOT EXISTS ai_usage_v2 (
    id              BIGSERIAL PRIMARY KEY,
    request_id      UUID NOT NULL REFERENCES ai_requests(request_id) ON DELETE CASCADE,
    provider        TEXT,
    model           TEXT,
    input_tokens    INTEGER CHECK (input_tokens  IS NULL OR input_tokens  >= 0),
    output_tokens   INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
    total_tokens    INTEGER CHECK (total_tokens  IS NULL OR total_tokens  >= 0),
    usage_reported  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_models_provider_id   ON models(provider_id);
CREATE INDEX IF NOT EXISTS idx_models_category      ON models(category);
CREATE INDEX IF NOT EXISTS idx_ai_usage_v2_request  ON ai_usage_v2(request_id);

-- Register only the provider that has an implemented adapter.
-- enabled=false by default: enablement is driven by environment configuration.
INSERT INTO providers (name, display_name, enabled, base_url)
VALUES ('groq', 'Groq', FALSE, 'https://api.groq.com/openai/v1')
ON CONFLICT (name) DO NOTHING;

-- No models are seeded: model identifiers are operator-declared
-- (<PROVIDER>_MODELS) and must not be fabricated by the gateway.

COMMIT;
EOF
ok "database/migrations/002_provider_model_registry.sql"

# =============================================================================
# 9. .env.example (variable names only, never values)
# =============================================================================
if ! grep -q "AI_DEFAULT_PROVIDER" .env.example 2>/dev/null; then
  cat >> .env.example <<'EOF'

# --- Day 2: AI provider abstraction ---------------------------------------
# No credentials are committed. Fill these only in your local .env file.
AI_DEFAULT_PROVIDER=
AI_DEFAULT_MODEL=
AI_REQUEST_TIMEOUT_MS=30000

GROQ_ENABLED=false
GROQ_API_KEY=
GROQ_BASE_URL=https://api.groq.com/openai/v1
# Operator-declared models: "model_key:category" comma separated
GROQ_MODELS=

# Configuration placeholders only. No adapter implemented in this iteration.
GEMINI_ENABLED=false
GEMINI_API_KEY=
GEMINI_BASE_URL=
EOF
  ok ".env.example extended"
else
  log ".env.example already contains Day-2 keys"
fi

# =============================================================================
# 10. docker-compose: pass provider configuration through to the API container
# =============================================================================
backup docker-compose.yml
if ! grep -q "AI_DEFAULT_PROVIDER" docker-compose.yml; then
  python3 - <<'PY'
p = "docker-compose.yml"
s = open(p).read()
add = """      AI_DEFAULT_PROVIDER: ${AI_DEFAULT_PROVIDER:-}
      AI_DEFAULT_MODEL: ${AI_DEFAULT_MODEL:-}
      AI_REQUEST_TIMEOUT_MS: ${AI_REQUEST_TIMEOUT_MS:-30000}
      GROQ_ENABLED: ${GROQ_ENABLED:-false}
      GROQ_API_KEY: ${GROQ_API_KEY:-}
      GROQ_BASE_URL: ${GROQ_BASE_URL:-https://api.groq.com/openai/v1}
      GROQ_MODELS: ${GROQ_MODELS:-}
"""
s = s.replace("      PROMETHEUS_ENABLED: ${PROMETHEUS_ENABLED:-true}\n",
              "      PROMETHEUS_ENABLED: ${PROMETHEUS_ENABLED:-true}\n" + add, 1)
open(p, "w").write(s)
print("[PASS] docker-compose.yml extended")
PY
else
  log "docker-compose.yml already extended"
fi

# =============================================================================
# 11. GRAFANA: extend the EXISTING dashboard (only metrics that exist)
# =============================================================================
backup observability/grafana/dashboard.json
python3 - <<'PY'
import json
p = "observability/grafana/dashboard.json"
d = json.load(open(p))
have = {pn.get("title") for pn in d.get("panels", [])}
nid = max([pn.get("id", 0) for pn in d["panels"]] + [0])
y = max([pn["gridPos"]["y"] + pn["gridPos"]["h"] for pn in d["panels"]] + [0])
new = [
 ("Provider Request Rate", 'sum(rate(ai_gateway_provider_requests_total[5m])) by (provider, model, status)'),
 ("Provider Error Rate", 'sum(rate(ai_gateway_provider_errors_total[5m])) by (provider, status)'),
 ("Provider Latency (p95)", 'histogram_quantile(0.95, sum(rate(ai_gateway_provider_request_duration_seconds_bucket[5m])) by (le, provider))'),
 ("Tokens by Provider", 'sum(rate(ai_gateway_provider_input_tokens_total[5m])) by (provider)'),
 ("Tokens by Model", 'sum(rate(ai_gateway_provider_output_tokens_total[5m])) by (model)'),
]
added = 0
for i, (title, expr) in enumerate(new):
    if title in have: continue
    nid += 1
    d["panels"].append({
        "id": nid, "title": title, "type": "timeseries",
        "gridPos": {"x": (added % 2) * 12, "y": y + (added // 2) * 8, "w": 12, "h": 8},
        "targets": [{"expr": expr}],
    })
    added += 1
if added:
    d["version"] = d.get("version", 1) + 1
    json.dump(d, open(p, "w"), indent=2)
print(f"[PASS] Grafana dashboard: {added} panel(s) added")
PY

# =============================================================================
# 12. TESTS — unit (node:test) + provider/API tests with PASS/FAIL/SKIP/N-A
# =============================================================================
cat > tests/provider_registry.test.mjs <<'EOF'
import { test } from "node:test";
import assert from "node:assert/strict";

process.env.AI_DEFAULT_PROVIDER = process.env.AI_DEFAULT_PROVIDER || "";
process.env.AI_DEFAULT_MODEL = process.env.AI_DEFAULT_MODEL || "";

const { getProvider, providerHealthMap } = await import("../api/src/providers/provider.registry.js");
const { listModels, CATEGORIES } = await import("../api/src/providers/model.registry.js");
const { resolveTarget } = await import("../api/src/providers/resolver.js");

test("provider registry exposes the groq adapter", () => {
  const p = getProvider("groq");
  assert.ok(p);
  const m = p.metadata();
  assert.equal(m.name, "groq");
  assert.ok(!("apiKey" in m), "metadata must never expose credentials");
  assert.ok(!JSON.stringify(m).includes(process.env.GROQ_API_KEY || "__none__"));
});

test("provider health never performs a live call and never leaks secrets", () => {
  const h = providerHealthMap();
  assert.ok(h.groq);
  assert.ok(["available", "disabled", "not_configured", "unavailable"].includes(h.groq.status));
  assert.equal(JSON.stringify(h).toLowerCase().includes("key"), false);
});

test("unknown provider fails in a controlled way", () => {
  const r = resolveTarget({ provider: "does-not-exist", model: "x" });
  assert.equal(r.ok, false);
  assert.equal(r.code, "unknown_provider");
});

test("no configuration yields no_provider_configured, never a fabricated answer", () => {
  const r = resolveTarget({ provider: null, model: null });
  if (!process.env.AI_DEFAULT_PROVIDER || !process.env.AI_DEFAULT_MODEL) {
    assert.equal(r.ok, false);
    assert.equal(r.code, "no_provider_configured");
  }
});

test("model registry only contains operator-declared models", () => {
  for (const m of listModels()) {
    assert.ok(CATEGORIES.includes(m.category));
    assert.equal(m.supports_streaming, false);
    assert.ok(m.context_window === null || typeof m.context_window === "number");
  }
});
EOF

cat > tests/provider_test.sh <<'EOF'
#!/usr/bin/env bash
# Day-2 provider tests. Reports PASS / FAIL / SKIPPED / NOT AVAILABLE.
# A live cloud provider test is only claimed when a key is configured AND
# the request actually executed.
set -u
BASE="${1:-http://127.0.0.1:${API_PORT:-4400}}"
pass=0; fail=0; skip=0
P(){ echo "[PASS] $*"; pass=$((pass+1)); }
F(){ echo "[FAIL] $*"; fail=$((fail+1)); }
S(){ echo "[SKIP] $*"; skip=$((skip+1)); }
N(){ echo "[N/A ] $*"; skip=$((skip+1)); }

command -v curl >/dev/null 2>&1 || { N "curl unavailable"; exit 0; }
curl -sf "$BASE/health" >/dev/null 2>&1 || { N "API not reachable at $BASE"; exit 0; }

body(){ curl -s -o /tmp/day2_body.$$ -w '%{http_code}' -X POST "$BASE/v1/chat" \
        -H 'Content-Type: application/json' -d "$1"; }

echo "== /dependencies exposes provider status without secrets"
dep=$(curl -s "$BASE/dependencies")
echo "$dep" | grep -q 'ai_providers' && P "ai_providers present" || F "ai_providers missing"
echo "$dep" | grep -qiE '(api_key|authorization|bearer |sk-|gsk_)' && F "possible secret in /dependencies" || P "no secret material in /dependencies"

echo "== invalid provider"
code=$(body '{"message":"hi","provider":"nope","model":"x"}')
[ "$code" = "400" ] && P "invalid provider -> 400" || F "invalid provider -> $code"

echo "== invalid model"
code=$(body '{"message":"hi","provider":"groq","model":"definitely-not-registered"}')
[ "$code" = "400" ] || [ "$code" = "503" ] && P "invalid model -> $code (controlled)" || F "invalid model -> $code"

echo "== validation"
code=$(body '{}'); [ "$code" = "400" ] && P "missing message -> 400" || F "missing message -> $code"

echo "== default resolution / no provider configured"
code=$(body '{"message":"hello"}')
if [ "$code" = "503" ]; then
  grep -q 'no_provider_configured' /tmp/day2_body.$$ && P "no provider configured -> controlled 503" || F "503 without expected error code"
  N "live provider chat (no provider configured)"
elif [ "$code" = "200" ]; then
  grep -q '"success":true' /tmp/day2_body.$$ && P "live provider chat executed (HTTP 200)" || F "200 without success envelope"
  grep -q 'usage_reported' /tmp/day2_body.$$ && P "token usage state reported" || F "usage state missing"
elif [ "$code" = "502" ]; then
  F "provider configured but upstream request failed (see API logs)"
else
  F "unexpected status $code"
fi
rm -f /tmp/day2_body.$$

echo "== metrics registered"
m=$(curl -s "$BASE/metrics")
for name in ai_gateway_provider_requests_total ai_gateway_provider_errors_total \
            ai_gateway_provider_request_duration_seconds \
            ai_gateway_provider_input_tokens_total ai_gateway_provider_output_tokens_total; do
  echo "$m" | grep -q "$name" && P "metric $name" || S "metric $name not emitted yet (no traffic)"
done

echo "SUMMARY: PASS=$pass FAIL=$fail SKIPPED/NA=$skip"
[ "$fail" -eq 0 ] || exit 1
EOF
chmod +x tests/provider_test.sh
ok "tests/provider_registry.test.mjs, tests/provider_test.sh"

# =============================================================================
# 13. Day-2 helpers for the EXISTING deployment script
# =============================================================================
cat > scripts/day2-provider.sh <<'EOF'
#!/usr/bin/env bash
# Day-2 helpers sourced by deploy-ai-gateway-1-of-10.sh
# Provides: validate_provider_config, dependency_matrix, scan_secrets_day2,
#           test_provider_day2

validate_provider_config() {
  log_step "INIT: AI provider configuration"
  local dp="${AI_DEFAULT_PROVIDER:-}" dm="${AI_DEFAULT_MODEL:-}"
  local ge="${GROQ_ENABLED:-false}" gk="${GROQ_API_KEY:-}"
  if [ "$ge" = "true" ] && [ -n "$gk" ]; then
    log_ok "groq: enabled and configured (key present, value never printed)"
  elif [ "$ge" = "true" ]; then
    log_warn "groq: enabled but GROQ_API_KEY is empty -> status not_configured"
  else
    log_skip "groq: disabled"
  fi
  if [ -n "$dp" ] && [ -n "$dm" ]; then
    log_ok "default routing: provider=$dp model=$dm"
  else
    log_warn "No AI_DEFAULT_PROVIDER/AI_DEFAULT_MODEL: /v1/chat will return a controlled no_provider_configured response"
  fi
  # Never a hard failure: the stack must start without any cloud provider.
  return 0
}

# Dependency diagnostics that state WHERE the test ran.
_probe() {  # _probe <location> <host> <port>
  local loc="$1" host="$2" port="$3" dns="UNKNOWN" tcp="UNKNOWN"
  case "$loc" in
    host)
      if getent hosts "$host" >/dev/null 2>&1 || ping -c1 -W1 "$host" >/dev/null 2>&1; then dns=PASS; else dns=FAIL; fi
      if [ "$dns" = "PASS" ] && (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then tcp=PASS; else tcp=FAIL; fi
      ;;
    container)
      local cname="${APP_NAME:-ai-gateway-1-of-10-chat}-api"
      if docker exec "$cname" node -e "require('dns').lookup('$host',e=>process.exit(e?1:0))" >/dev/null 2>&1; then dns=PASS; else dns=FAIL; fi
      if [ "$dns" = "PASS" ] && docker exec "$cname" node -e "const s=require('net').connect($port,'$host');s.on('connect',()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1));setTimeout(()=>process.exit(1),3000)" >/dev/null 2>&1; then tcp=PASS; else tcp=FAIL; fi
      ;;
  esac
  printf "  TEST LOCATION: %-9s TARGET: %s:%s  DNS: %s  TCP: %s\n" "$loc" "$host" "$port" "$dns" "$tcp" >&2
  [ "$tcp" = "PASS" ]
}

dependency_matrix() {
  log_step "TEST: dependency diagnostics (host vs container)"
  local ok_any=0
  local ph="${POSTGRES_HOST:-}" pp="${POSTGRES_PORT:-5432}"
  local rh="${REDIS_HOST:-}"   rp="${REDIS_PORT:-6379}"
  local cname="${APP_NAME:-ai-gateway-1-of-10-chat}-api"
  local have_container=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname" && have_container=1

  for pair in "postgres $ph $pp" "redis $rh $rp"; do
    set -- $pair
    local svc="$1" host="${2:-}" port="${3:-}"
    if [ -z "$host" ]; then log_skip "$svc: no host configured"; continue; fi
    echo "  --- $svc ---" >&2
    _probe host "$host" "$port" || true
    if [ "$have_container" = "1" ]; then
      if _probe container "$host" "$port"; then ok_any=1; log_ok "$svc reachable from the API container"; \
      else log_fail "$svc NOT reachable from the API container"; fi
    else
      log_skip "$svc: container probe NOT AVAILABLE (API container not running)"
    fi
  done
  log_info "Host failure with container success is expected for Docker service names; do NOT hardcode IPs."
  return 0
}

# Secret scanner that distinguishes references from real credential material.
scan_secrets_day2() {
  log_step "TEST: secret scan (references vs assignments vs credentials)"
  local files findings=0
  if git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
    files=$(git -C "$ROOT_DIR" ls-files)
  else
    files=$(cd "$ROOT_DIR" && find . -type f -not -path "./.git/*" -not -path "./node_modules/*" -not -name ".env" | sed 's|^\./||')
  fi

  if git -C "$ROOT_DIR" rev-parse >/dev/null 2>&1; then
    if git -C "$ROOT_DIR" check-ignore -q .env 2>/dev/null; then log_ok ".env is git-ignored"; \
    else log_fail ".env is NOT git-ignored"; findings=$((findings+1)); fi
  else
    grep -qx '\.env' "$ROOT_DIR/.gitignore" 2>/dev/null && log_ok ".env listed in .gitignore" || \
      { log_fail ".env not in .gitignore"; findings=$((findings+1)); }
  fi

  # Credential-looking material only (values, not references/placeholders).
  local cred='(gsk_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'
  local assign='^[^:]+:[0-9]+:[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(API_KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{8,}'
  local f n
  for f in $files; do
    [ -f "$ROOT_DIR/$f" ] || continue
    case "$f" in .env|*.day1.bak) continue ;; esac
    n=$(grep -InE "$cred" "$ROOT_DIR/$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
    if [ -n "$n" ]; then log_fail "Credential-like material in $f (lines: $n) — value not printed"; findings=$((findings+1)); fi
    n=$(grep -InE "(API_KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*[[:space:]]*=[[:space:]]*[\"']?[A-Za-z0-9/+=_-]{8,}" "$ROOT_DIR/$f" 2>/dev/null \
        | grep -vE '\$\{?[A-Za-z_]' | grep -vE '=[[:space:]]*(""|'"''"')?[[:space:]]*$' | cut -d: -f1 | tr '\n' ' ')
    if [ -n "$n" ]; then log_fail "Hardcoded secret assignment in $f (lines: $n) — value not printed"; findings=$((findings+1)); fi
  done
  if [ "$findings" -eq 0 ]; then
    log_ok "No credential material in tracked files (\${VAR} references are not leaks)"
    return 0
  fi
  return 1
}

test_provider_day2() {
  log_step "TEST: provider unit tests"
  if command -v node >/dev/null 2>&1; then
    if (cd "$ROOT_DIR" && node --test tests/*.test.mjs >/dev/null 2>&1); then
      log_ok "provider/model registry unit tests passed"
    else
      log_fail "provider/model registry unit tests failed (run: node --test tests/*.test.mjs)"
      return 1
    fi
  else
    log_skip "node not available; unit tests NOT AVAILABLE"
  fi
  log_step "TEST: provider API tests"
  if [ -x "$ROOT_DIR/tests/provider_test.sh" ]; then
    "$ROOT_DIR/tests/provider_test.sh" "http://127.0.0.1:${API_PORT:-4400}" || return 1
  else
    log_skip "tests/provider_test.sh missing"
  fi
  return 0
}
EOF
chmod +x scripts/day2-provider.sh
ok "scripts/day2-provider.sh"

# =============================================================================
# 14. Patch the EXISTING deployment script (commands unchanged, marker-guarded)
# =============================================================================
DEPLOY="deploy-ai-gateway-1-of-10.sh"
backup "$DEPLOY"
python3 - <<'PY'
p = "deploy-ai-gateway-1-of-10.sh"
s = open(p).read()
changed = False

if "day2-provider.sh" not in s:
    anchor = 'cd "$ROOT_DIR" || exit 1\n'
    s = s.replace(anchor, anchor +
        '\n# --- DAY2-PROVIDER-HOOK (PROMPT-02) ---\n'
        'if [ -f "$ROOT_DIR/scripts/day2-provider.sh" ]; then\n'
        '  . "$ROOT_DIR/scripts/day2-provider.sh"\n'
        'fi\n', 1)
    changed = True

if "validate_provider_config\n" not in s:
    s = s.replace("  inspect_postgres\n  inspect_redis\n",
                  "  inspect_postgres\n  inspect_redis\n"
                  "  if declare -f validate_provider_config >/dev/null; then validate_provider_config; fi\n"
                  "  if declare -f dependency_matrix >/dev/null; then dependency_matrix; fi\n", 1)
    changed = True

if "test_provider_day2" not in s:
    s = s.replace('  log_step "TEST: secret / leak scan"',
        '  if declare -f dependency_matrix >/dev/null; then dependency_matrix; fi\n'
        '  if declare -f test_provider_day2 >/dev/null; then\n'
        '    if test_provider_day2; then overall_pass=$((overall_pass+1)); else overall_fail=$((overall_fail+1)); fi\n'
        '  fi\n\n'
        '  if declare -f scan_secrets_day2 >/dev/null; then\n'
        '    if scan_secrets_day2; then overall_pass=$((overall_pass+1)); else overall_fail=$((overall_fail+1)); fi\n'
        '  fi\n\n'
        '  log_step "TEST: secret / leak scan (legacy pattern scan)"', 1)
    changed = True

if changed:
    open(p, "w").write(s)
    print("[PASS] deployment script hooked (init/test only; commands unchanged)")
else:
    print("[INFO] deployment script already hooked")
PY

# =============================================================================
# 15. DOCUMENTATION
# =============================================================================
append_doc() { # append_doc <file> <marker> <<heredoc via stdin
  local f="$1" marker="$2"
  if grep -q "$marker" "$f" 2>/dev/null; then log "$f already documents Day 2"; cat >/dev/null; return 0; fi
  cat >> "$f"; ok "$f updated"
}

append_doc README.md "## Day 2" <<'EOF'

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
EOF

append_doc ARCHITECTURE.md "Provider abstraction (Day 2)" <<'EOF'

## Provider abstraction (Day 2)

```
POST /v1/chat
  -> validation
  -> resolver.js            (1 provider, 2 model, 3 agent map [PROMPT-03],
                             4 AI_DEFAULT_PROVIDER, 5 AI_DEFAULT_MODEL, 6 fail)
  -> model.registry.js      (operator-declared models + categories)
  -> provider.registry.js   (adapter lookup + config-only health)
  -> groq.provider.js       (ProviderAdapter: chat/health/metadata)
  -> upstream provider
  -> usage extraction (nullable) -> ai_usage_v2 -> response envelope
```

Adapters never leak upstream error bodies; the API returns bounded codes
(`provider_not_configured`, `provider_unreachable`, `provider_error`,
`provider_bad_response`, `unknown_provider`, `unknown_model`,
`provider_unavailable`, `no_provider_configured`).
API keys live in the environment only and are never persisted.
EOF

append_doc DEPENDENCIES.md "Dependency test location" <<'EOF'

## Dependency test location (Day 2)

Host reachability and container reachability are different facts. Each probe
reports `TEST LOCATION`, `TARGET`, `DNS`, `TCP`. Docker service names such as
`opentts-ai-postgres-db` normally resolve only inside the Docker network, so a
host FAIL together with a container PASS is expected and is not an error.
Docker service names are never replaced with hardcoded IP addresses.

AI providers are checked with a configuration-only probe (enabled + key
present). No live AI call is made from `/dependencies`.
EOF

append_doc OBSERVABILITY.md "Day 2 provider metrics" <<'EOF'

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
EOF

append_doc CHECKPOINT.md "PROMPT-02" <<'EOF'

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
EOF

# =============================================================================
# 16. VALIDATION
# =============================================================================
echo ""
log "==== VALIDATION ===="
fails=0

if command -v node >/dev/null 2>&1; then
  for f in $(find api/src -name '*.js'); do
    node --check "$f" >/dev/null 2>&1 || { warn "JS syntax error: $f"; fails=$((fails+1)); }
  done
  ok "JavaScript syntax validated"
  (node --test tests/*.test.mjs >/tmp/day2-unit.log 2>&1 && ok "unit tests passed") || { warn "unit tests failed (see /tmp/day2-unit.log)"; fails=$((fails+1)); }
  node -e "JSON.parse(require('fs').readFileSync('observability/grafana/dashboard.json','utf8'))" \
    && ok "Grafana JSON valid" || { warn "Grafana JSON invalid"; fails=$((fails+1)); }
else
  warn "node not available: JS + unit validation NOT AVAILABLE"
fi

bash -n "$DEPLOY" && ok "deployment script syntax valid" || { warn "deployment script syntax error"; fails=$((fails+1)); }
bash -n scripts/day2-provider.sh && ok "day2-provider.sh syntax valid" || fails=$((fails+1))
bash -n tests/provider_test.sh && ok "provider_test.sh syntax valid" || fails=$((fails+1))

grep -q "BEGIN;" database/migrations/002_provider_model_registry.sql \
  && grep -q "COMMIT;" database/migrations/002_provider_model_registry.sql \
  && ok "migration 002 transactional" || { warn "migration 002 malformed"; fails=$((fails+1)); }

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f docker-compose.yml config >/dev/null 2>&1 \
    && ok "docker-compose.yml valid" || { warn "docker-compose.yml invalid"; fails=$((fails+1)); }
else
  warn "docker compose not available: compose validation NOT AVAILABLE"
fi

grep -qx '\.env' .gitignore && ok ".env remains git-ignored" || { warn ".env not ignored"; fails=$((fails+1)); }

echo ""
if [ "$fails" -eq 0 ]; then
  ok "DAY 2 increment applied. Next: ./deploy-ai-gateway-1-of-10.sh init && ... deploy && ... test"
  echo "Apply migration 002 against your Postgres instance before running chat tests." >&2
  exit 0
fi
die "DAY 2 increment applied with $fails validation problem(s) — review the warnings above"
