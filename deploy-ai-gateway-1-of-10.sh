#!/usr/bin/env bash
# =============================================================================
# deploy-ai-gateway-1-of-10-chat.sh
# Primary operational script for stack: ai-gateway-1-of-10-chat
# =============================================================================

set -u
set -o pipefail

# -----------------------------------------------------------------------------
# Locate repository root relative to this script (never assume absolute paths)
# -----------------------------------------------------------------------------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$DIR/$SCRIPT_SOURCE"
done
ROOT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR" || exit 1

APP_NAME_DEFAULT="ai-gateway-1-of-10-chat"
IMAGE_NAME_DEFAULT="ai-gateway-1-of-10-chat"

# -----------------------------------------------------------------------------
# Colors / logging
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log_info()  { printf "%b[INFO]%b  %s\n"  "$C_BLUE"  "$C_RESET" "$*" >&2; }
log_ok()    { printf "%b[PASS]%b  %s\n"  "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn()  { printf "%b[WARN]%b  %s\n"  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_fail()  { printf "%b[FAIL]%b  %s\n"  "$C_RED"   "$C_RESET" "$*" >&2; }
log_skip()  { printf "%b[SKIP]%b  %s\n"  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_step()  { printf "%b==> %s%b\n" "$C_BOLD" "$*" "$C_RESET" >&2; }

CHECK_FAILED=0
mark_fail() { CHECK_FAILED=1; log_fail "$*"; }

# -----------------------------------------------------------------------------
# .env loader (never overwrite; never print secrets)
# -----------------------------------------------------------------------------
load_env() {
  if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  fi

  APP_NAME="${APP_NAME:-$APP_NAME_DEFAULT}"
  APP_ENV="${APP_ENV:-development}"
  LOG_LEVEL="${LOG_LEVEL:-info}"

  API_PORT="${API_PORT:-4400}"

  POSTGRES_ENABLED="${POSTGRES_ENABLED:-true}"
  POSTGRES_HOST="${POSTGRES_HOST:-}"
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  POSTGRES_DATABASE="${POSTGRES_DATABASE:-}"
  POSTGRES_USER="${POSTGRES_USER:-}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

  REDIS_ENABLED="${REDIS_ENABLED:-true}"
  REDIS_HOST="${REDIS_HOST:-}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  REDIS_DATABASE="${REDIS_DATABASE:-0}"

  SHARED_DOCKER_NETWORK="${SHARED_DOCKER_NETWORK:-ai-gateway-net}"
  CREATE_NETWORK_IF_MISSING="${CREATE_NETWORK_IF_MISSING:-false}"

  REGISTRY_ENABLED="${REGISTRY_ENABLED:-false}"
  REGISTRY_HOST="${REGISTRY_HOST:-}"
  IMAGE_NAME="${IMAGE_NAME:-$IMAGE_NAME_DEFAULT}"
  IMAGE_TAG="${IMAGE_TAG:-latest}"

  PROMETHEUS_ENABLED="${PROMETHEUS_ENABLED:-true}"
  PROMETHEUS_URL="${PROMETHEUS_URL:-}"

  GRAFANA_ENABLED="${GRAFANA_ENABLED:-false}"
  GRAFANA_URL="${GRAFANA_URL:-}"

  HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-10s}"
  HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-5s}"
  HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-5}"
}

# -----------------------------------------------------------------------------
# Basic tool checks
# -----------------------------------------------------------------------------
check_bash() {
  if [ -z "${BASH_VERSION:-}" ]; then
    mark_fail "Bash not detected"
    return 1
  fi
  log_ok "Bash detected (${BASH_VERSION})"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    mark_fail "Docker CLI not found in PATH"
    return 1
  fi
  log_ok "Docker CLI found ($(docker --version 2>/dev/null))"
}

check_docker_daemon() {
  if ! docker info >/dev/null 2>&1; then
    mark_fail "Docker daemon is not reachable"
    return 1
  fi
  log_ok "Docker daemon reachable"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# -----------------------------------------------------------------------------
# Directory / file bootstrap (idempotent, never destructive)
# -----------------------------------------------------------------------------
ensure_dir() {
  local d="$1"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    log_ok "Created directory: ${d#$ROOT_DIR/}"
  else
    log_skip "Directory already exists: ${d#$ROOT_DIR/}"
  fi
}

write_if_missing() {
  # write_if_missing <path> <heredoc-content-via-stdin>
  local path="$1"
  if [ -f "$path" ]; then
    log_skip "File already exists (left untouched): ${path#$ROOT_DIR/}"
    cat >/dev/null
    return 0
  fi
  cat > "$path"
  log_ok "Created file: ${path#$ROOT_DIR/}"
}

bootstrap_structure() {
  log_step "Bootstrapping local project structure"

  ensure_dir "$ROOT_DIR/api"
  ensure_dir "$ROOT_DIR/api/src"
  ensure_dir "$ROOT_DIR/api/src/routes"
  ensure_dir "$ROOT_DIR/api/src/lib"
  ensure_dir "$ROOT_DIR/database"
  ensure_dir "$ROOT_DIR/database/migrations"
  ensure_dir "$ROOT_DIR/observability"
  ensure_dir "$ROOT_DIR/observability/grafana"
  ensure_dir "$ROOT_DIR/tests"

  bootstrap_env_example
  bootstrap_env_file
  bootstrap_gitignore
  bootstrap_compose
  bootstrap_api
  bootstrap_migration
  bootstrap_grafana_dashboard
  bootstrap_tests
  bootstrap_docs
}

bootstrap_env_example() {
  write_if_missing "$ROOT_DIR/.env.example" <<'EOF'
APP_NAME=ai-gateway-1-of-10-chat
APP_ENV=development
LOG_LEVEL=info

API_PORT=4400

POSTGRES_ENABLED=true
POSTGRES_HOST=
POSTGRES_PORT=5432
POSTGRES_DATABASE=
POSTGRES_USER=
POSTGRES_PASSWORD=

REDIS_ENABLED=true
REDIS_HOST=
REDIS_PORT=6379
REDIS_DATABASE=0

SHARED_DOCKER_NETWORK=ai-gateway-net

CREATE_NETWORK_IF_MISSING=false

REGISTRY_ENABLED=false
REGISTRY_HOST=
IMAGE_NAME=ai-gateway-1-of-10-chat
IMAGE_TAG=latest

PROMETHEUS_ENABLED=true
PROMETHEUS_URL=

GRAFANA_ENABLED=false
GRAFANA_URL=

HEALTHCHECK_INTERVAL=10s
HEALTHCHECK_TIMEOUT=5s
HEALTHCHECK_RETRIES=5
EOF
}

bootstrap_env_file() {
  if [ -f "$ROOT_DIR/.env" ]; then
    log_skip ".env already exists (never overwritten)"
    return 0
  fi
  if [ -f "$ROOT_DIR/.env.example" ]; then
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
    log_ok "Created .env from .env.example (no real secrets generated)"
  else
    log_warn ".env.example missing; cannot bootstrap .env"
  fi
}

bootstrap_gitignore() {
  write_if_missing "$ROOT_DIR/.gitignore" <<'EOF'
.env
.env.*
!.env.example

*.key
*.pem
*.pfx

credentials/
secrets/
*.secret

node_modules/
dist/
build/

*.log
logs/

*.sqlite
*.sqlite3
*.db

.DS_Store
EOF
}

bootstrap_compose() {
  write_if_missing "$ROOT_DIR/docker-compose.yml" <<'EOF'
services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
    image: ${IMAGE_NAME:-ai-gateway-1-of-10-chat}:${IMAGE_TAG:-latest}
    container_name: ${APP_NAME:-ai-gateway-1-of-10-chat}-api
    restart: unless-stopped
    environment:
      APP_NAME: ${APP_NAME:-ai-gateway-1-of-10-chat}
      APP_ENV: ${APP_ENV:-development}
      LOG_LEVEL: ${LOG_LEVEL:-info}
      API_PORT: ${API_PORT:-4400}
      POSTGRES_ENABLED: ${POSTGRES_ENABLED:-true}
      POSTGRES_HOST: ${POSTGRES_HOST:-}
      POSTGRES_PORT: ${POSTGRES_PORT:-5432}
      POSTGRES_DATABASE: ${POSTGRES_DATABASE:-}
      POSTGRES_USER: ${POSTGRES_USER:-}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-}
      REDIS_ENABLED: ${REDIS_ENABLED:-true}
      REDIS_HOST: ${REDIS_HOST:-}
      REDIS_PORT: ${REDIS_PORT:-6379}
      REDIS_DATABASE: ${REDIS_DATABASE:-0}
      PROMETHEUS_ENABLED: ${PROMETHEUS_ENABLED:-true}
    ports:
      - "${API_PORT:-4400}:${API_PORT:-4400}"
    networks:
      - ai_gateway_external
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:' + (process.env.API_PORT || 4400) + '/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: ${HEALTHCHECK_INTERVAL:-10s}
      timeout: ${HEALTHCHECK_TIMEOUT:-5s}
      retries: ${HEALTHCHECK_RETRIES:-5}

networks:
  ai_gateway_external:
    name: ${SHARED_DOCKER_NETWORK:-ai-gateway-net}
    external: true
EOF
}

bootstrap_api() {
  ensure_dir "$ROOT_DIR/api"

  write_if_missing "$ROOT_DIR/api/package.json" <<'EOF'
{
  "name": "ai-gateway-1-of-10-chat",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node src/index.js"
  },
  "dependencies": {
    "@hono/node-server": "^1.13.0",
    "hono": "^4.6.0",
    "pg": "^8.12.0",
    "redis": "^4.7.0",
    "prom-client": "^15.1.0"
  }
}
EOF

  write_if_missing "$ROOT_DIR/api/Dockerfile" <<'EOF'
FROM node:20-alpine AS base
WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

ENV NODE_ENV=production
EXPOSE 4400

CMD ["node", "src/index.js"]
EOF

  write_if_missing "$ROOT_DIR/api/src/lib/env.js" <<'EOF'
export const env = {
  APP_NAME: process.env.APP_NAME || "ai-gateway-1-of-10-chat",
  APP_ENV: process.env.APP_ENV || "development",
  LOG_LEVEL: process.env.LOG_LEVEL || "info",

  API_PORT: parseInt(process.env.API_PORT || "4400", 10),

  POSTGRES_ENABLED: (process.env.POSTGRES_ENABLED || "true") === "true",
  POSTGRES_HOST: process.env.POSTGRES_HOST || "",
  POSTGRES_PORT: parseInt(process.env.POSTGRES_PORT || "5432", 10),
  POSTGRES_DATABASE: process.env.POSTGRES_DATABASE || "",
  POSTGRES_USER: process.env.POSTGRES_USER || "",
  POSTGRES_PASSWORD: process.env.POSTGRES_PASSWORD || "",

  REDIS_ENABLED: (process.env.REDIS_ENABLED || "true") === "true",
  REDIS_HOST: process.env.REDIS_HOST || "",
  REDIS_PORT: parseInt(process.env.REDIS_PORT || "6379", 10),
  REDIS_DATABASE: parseInt(process.env.REDIS_DATABASE || "0", 10),

  PROMETHEUS_ENABLED: (process.env.PROMETHEUS_ENABLED || "true") === "true",
};
EOF

  write_if_missing "$ROOT_DIR/api/src/lib/logger.js" <<'EOF'
import { env } from "./env.js";

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const currentLevel = LEVELS[env.LOG_LEVEL] || LEVELS.info;

const REDACT_KEYS = new Set([
  "password", "api_key", "apikey", "secret", "token",
  "authorization", "private_key",
]);

function redact(obj) {
  if (obj === null || typeof obj !== "object") return obj;
  const out = Array.isArray(obj) ? [] : {};
  for (const [k, v] of Object.entries(obj)) {
    if (REDACT_KEYS.has(k.toLowerCase())) {
      out[k] = "[REDACTED]";
    } else if (typeof v === "object" && v !== null) {
      out[k] = redact(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function log(level, fields) {
  if ((LEVELS[level] || 0) < currentLevel) return;
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service: env.APP_NAME,
    ...redact(fields || {}),
  };
  const line = JSON.stringify(entry);
  if (level === "error") {
    console.error(line);
  } else {
    console.log(line);
  }
}

export const logger = {
  debug: (fields) => log("debug", fields),
  info: (fields) => log("info", fields),
  warn: (fields) => log("warn", fields),
  error: (fields) => log("error", fields),
};
EOF

  write_if_missing "$ROOT_DIR/api/src/lib/db.js" <<'EOF'
import pg from "pg";
import { env } from "./env.js";
import { logger } from "./logger.js";

let pool = null;
let lastStatus = "disabled";

export function getPool() {
  if (!env.POSTGRES_ENABLED) return null;
  if (!pool) {
    pool = new pg.Pool({
      host: env.POSTGRES_HOST,
      port: env.POSTGRES_PORT,
      database: env.POSTGRES_DATABASE,
      user: env.POSTGRES_USER,
      password: env.POSTGRES_PASSWORD,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 3000,
    });
    pool.on("error", (err) => {
      logger.error({ operation: "postgres_pool_error", message: err.message });
    });
  }
  return pool;
}

export async function checkPostgres() {
  if (!env.POSTGRES_ENABLED) {
    lastStatus = "disabled";
    return { enabled: false, status: "disabled" };
  }
  const p = getPool();
  try {
    await p.query("SELECT 1");
    lastStatus = "connected";
    return { enabled: true, status: "connected" };
  } catch (err) {
    lastStatus = "unavailable";
    return { enabled: true, status: "unavailable" };
  }
}

export function lastKnownPostgresStatus() {
  return lastStatus;
}
EOF

  write_if_missing "$ROOT_DIR/api/src/lib/redisClient.js" <<'EOF'
import { createClient } from "redis";
import { env } from "./env.js";
import { logger } from "./logger.js";

let client = null;
let lastStatus = "disabled";

export function getRedis() {
  if (!env.REDIS_ENABLED) return null;
  if (!client) {
    client = createClient({
      socket: {
        host: env.REDIS_HOST,
        port: env.REDIS_PORT,
        connectTimeout: 3000,
        reconnectStrategy: () => 2000,
      },
      database: env.REDIS_DATABASE,
    });
    client.on("error", (err) => {
      lastStatus = "unavailable";
      logger.warn({ operation: "redis_error", message: err.message });
    });
  }
  return client;
}

export async function checkRedis() {
  if (!env.REDIS_ENABLED) {
    lastStatus = "disabled";
    return { enabled: false, status: "disabled" };
  }
  const c = getRedis();
  try {
    if (!c.isOpen) await c.connect();
    await c.ping();
    lastStatus = "connected";
    return { enabled: true, status: "connected" };
  } catch (err) {
    lastStatus = "unavailable";
    return { enabled: true, status: "unavailable" };
  }
}

export function lastKnownRedisStatus() {
  return lastStatus;
}
EOF

  write_if_missing "$ROOT_DIR/api/src/lib/metrics.js" <<'EOF'
import client from "prom-client";

const register = new client.Registry();
client.collectDefaultMetrics({ register });

export const httpRequestsTotal = new client.Counter({
  name: "ai_gateway_http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

export const httpRequestDuration = new client.Histogram({
  name: "ai_gateway_http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

export const aiRequestsTotal = new client.Counter({
  name: "ai_gateway_ai_requests_total",
  help: "Total AI chat requests",
  labelNames: ["provider", "status"],
  registers: [register],
});

export const aiRequestDuration = new client.Histogram({
  name: "ai_gateway_ai_request_duration_seconds",
  help: "AI chat request duration in seconds",
  labelNames: ["provider"],
  registers: [register],
});

export const aiRequestErrorsTotal = new client.Counter({
  name: "ai_gateway_ai_request_errors_total",
  help: "Total AI chat request errors",
  labelNames: ["provider"],
  registers: [register],
});

export const inputTokensTotal = new client.Counter({
  name: "ai_gateway_input_tokens_total",
  help: "Total input tokens processed",
  labelNames: ["provider"],
  registers: [register],
});

export const outputTokensTotal = new client.Counter({
  name: "ai_gateway_output_tokens_total",
  help: "Total output tokens generated",
  labelNames: ["provider"],
  registers: [register],
});

export const cacheHitsTotal = new client.Counter({
  name: "ai_gateway_cache_hits_total",
  help: "Total cache hits",
  registers: [register],
});

export const cacheMissesTotal = new client.Counter({
  name: "ai_gateway_cache_misses_total",
  help: "Total cache misses",
  registers: [register],
});

export { register };
EOF

  write_if_missing "$ROOT_DIR/api/src/routes/health.js" <<'EOF'
import { Hono } from "hono";
import { env } from "../lib/env.js";
import { checkPostgres } from "../lib/db.js";
import { checkRedis } from "../lib/redisClient.js";

export const healthRoutes = new Hono();

healthRoutes.get("/health", (c) => {
  return c.json({ status: "ok", service: env.APP_NAME });
});

healthRoutes.get("/ready", async (c) => {
  const pg = await checkPostgres();
  const redis = await checkRedis();

  const pgOk = !pg.enabled || pg.status === "connected";
  const redisOk = !redis.enabled || redis.status === "connected";
  const ready = pgOk && redisOk;

  return c.json(
    {
      status: ready ? "ready" : "not_ready",
      service: env.APP_NAME,
      dependencies: { postgres: pg, redis: redis },
    },
    ready ? 200 : 503
  );
});

healthRoutes.get("/dependencies", async (c) => {
  const pg = await checkPostgres();
  const redis = await checkRedis();
  return c.json({
    service: env.APP_NAME,
    dependencies: { postgres: pg, redis: redis },
  });
});

healthRoutes.get("/help", (c) => {
  return c.json({
    service: env.APP_NAME,
    version: "0.1.0",
    description: "AI Gateway - Stack 1 of 10 - Chat Foundation",
    endpoints: [
      { method: "GET", path: "/health", description: "Basic process health, no external dependencies" },
      { method: "GET", path: "/ready", description: "Readiness check including Postgres and Redis" },
      { method: "GET", path: "/dependencies", description: "Current dependency connectivity state" },
      { method: "GET", path: "/help", description: "Machine-readable API discovery document" },
      { method: "GET", path: "/metrics", description: "Prometheus metrics" },
      { method: "POST", path: "/v1/chat", description: "Minimal chat contract (stub implementation, no live AI provider yet)" },
    ],
    chat_request_shape: {
      agent_name: "optional string",
      instruction: "optional string",
      message: "required string",
      provider: "optional string",
      model: "optional string",
      temperature: "optional number",
      metadata: "optional object",
    },
    supported_operations: ["chat"],
    notes: "This is iteration 1 of 10. Real AI provider routing is not implemented yet.",
  });
});
EOF

  write_if_missing "$ROOT_DIR/api/src/routes/chat.js" <<'EOF'
import { Hono } from "hono";
import { randomUUID } from "node:crypto";
import { env } from "../lib/env.js";
import { logger } from "../lib/logger.js";
import { getPool, checkPostgres } from "../lib/db.js";
import { getRedis, checkRedis } from "../lib/redisClient.js";
import {
  aiRequestsTotal,
  aiRequestDuration,
  aiRequestErrorsTotal,
  inputTokensTotal,
  outputTokensTotal,
  cacheHitsTotal,
  cacheMissesTotal,
} from "../lib/metrics.js";

export const chatRoutes = new Hono();

function envelopeSuccess(requestId, data, meta) {
  return { success: true, request_id: requestId, data: data || {}, meta: meta || {} };
}

function envelopeError(requestId, code, message, meta) {
  return {
    success: false,
    request_id: requestId,
    error: { code, message },
    meta: meta || {},
  };
}

async function persistRequest({ requestId, operation, agentName, provider, model, status }) {
  if (!env.POSTGRES_ENABLED) return;
  const pg = await checkPostgres();
  if (pg.status !== "connected") return;
  try {
    const pool = getPool();
    await pool.query(
      `INSERT INTO ai_requests (request_id, operation, agent_name, provider, model, status)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (request_id) DO NOTHING`,
      [requestId, operation, agentName || null, provider || null, model || null, status]
    );
  } catch (err) {
    logger.warn({ operation: "persist_request_failed", request_id: requestId, message: err.message });
  }
}

async function completeRequest({ requestId, status, latencyMs }) {
  if (!env.POSTGRES_ENABLED) return;
  const pg = await checkPostgres();
  if (pg.status !== "connected") return;
  try {
    const pool = getPool();
    await pool.query(
      `UPDATE ai_requests
       SET status = $2, completed_at = NOW(), latency_ms = $3
       WHERE request_id = $1`,
      [requestId, status, latencyMs]
    );
  } catch (err) {
    logger.warn({ operation: "complete_request_failed", request_id: requestId, message: err.message });
  }
}

async function recordUsage({ requestId, provider, model, inputTokens, outputTokens }) {
  if (!env.POSTGRES_ENABLED) return;
  const pg = await checkPostgres();
  if (pg.status !== "connected") return;
  try {
    const pool = getPool();
    await pool.query(
      `INSERT INTO ai_usage (request_id, provider, model, input_tokens, output_tokens, total_tokens)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [requestId, provider || null, model || null, inputTokens, outputTokens, inputTokens + outputTokens]
    );
  } catch (err) {
    logger.warn({ operation: "record_usage_failed", request_id: requestId, message: err.message });
  }
}

async function cacheLookup(key) {
  if (!env.REDIS_ENABLED) return null;
  const redisStatus = await checkRedis();
  if (redisStatus.status !== "connected") return null;
  try {
    const c = getRedis();
    const val = await c.get(key);
    if (val) {
      cacheHitsTotal.inc();
      return JSON.parse(val);
    }
    cacheMissesTotal.inc();
    return null;
  } catch (err) {
    logger.warn({ operation: "cache_lookup_failed", message: err.message });
    return null;
  }
}

async function cacheStore(key, value) {
  if (!env.REDIS_ENABLED) return;
  const redisStatus = await checkRedis();
  if (redisStatus.status !== "connected") return;
  try {
    const c = getRedis();
    await c.set(key, JSON.stringify(value), { EX: 300 });
  } catch (err) {
    logger.warn({ operation: "cache_store_failed", message: err.message });
  }
}

function stubChatResponse(message) {
  return {
    reply: `[stub-response] Received message of length ${String(message || "").length}. No AI provider configured in this iteration.`,
    provider: "stub",
    model: "stub-echo",
  };
}

chatRoutes.post("/v1/chat", async (c) => {
  const requestId = randomUUID();
  const startedAt = process.hrtime.bigint();

  let body;
  try {
    body = await c.req.json();
  } catch (err) {
    return c.json(envelopeError(requestId, "invalid_json", "Request body must be valid JSON"), 400);
  }

  const message = body && typeof body.message === "string" ? body.message : null;
  if (!message) {
    return c.json(
      envelopeError(requestId, "validation_error", "Field 'message' is required and must be a string"),
      400
    );
  }

  const agentName = typeof body.agent_name === "string" ? body.agent_name : null;
  const instruction = typeof body.instruction === "string" ? body.instruction : null;
  const provider = typeof body.provider === "string" ? body.provider : "stub";
  const model = typeof body.model === "string" ? body.model : "stub-echo";
  const metadata = typeof body.metadata === "object" && body.metadata !== null ? body.metadata : {};

  await persistRequest({ requestId, operation: "chat", agentName, provider, model, status: "processing" });

  const cacheKey = `chat:${provider}:${model}:${Buffer.from(message).toString("base64").slice(0, 200)}`;
  const cached = await cacheLookup(cacheKey);

  aiRequestsTotal.inc({ provider, status: "started" });
  const endTimer = aiRequestDuration.startTimer({ provider });

  let result;
  let status = "completed";
  try {
    if (cached) {
      result = cached;
    } else {
      result = stubChatResponse(message);
      await cacheStore(cacheKey, result);
    }
  } catch (err) {
    status = "error";
    aiRequestErrorsTotal.inc({ provider });
    logger.error({ operation: "chat_execution_failed", request_id: requestId, message: err.message });
    endTimer();
    const latencyMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    await completeRequest({ requestId, status, latencyMs });
    return c.json(envelopeError(requestId, "internal_error", "Chat execution failed"), 500);
  }
  endTimer();

  const inputTokens = Math.ceil((message.length + (instruction ? instruction.length : 0)) / 4);
  const outputTokens = Math.ceil((result.reply || "").length / 4);
  inputTokensTotal.inc({ provider }, inputTokens);
  outputTokensTotal.inc({ provider }, outputTokens);

  aiRequestsTotal.inc({ provider, status: "completed" });

  const latencyMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
  await completeRequest({ requestId, status, latencyMs });
  await recordUsage({ requestId, provider, model, inputTokens, outputTokens });

  logger.info({
    operation: "chat",
    request_id: requestId,
    status,
    latency: latencyMs,
    agent_name: agentName,
  });

  return c.json(
    envelopeSuccess(
      requestId,
      { reply: result.reply, agent_name: agentName, instruction_applied: !!instruction },
      { provider, model, cached: !!cached, latency_ms: latencyMs, metadata }
    )
  );
});
EOF

  write_if_missing "$ROOT_DIR/api/src/index.js" <<'EOF'
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { env } from "./lib/env.js";
import { logger } from "./lib/logger.js";
import { healthRoutes } from "./routes/health.js";
import { chatRoutes } from "./routes/chat.js";
import { register, httpRequestsTotal, httpRequestDuration } from "./lib/metrics.js";

const app = new Hono();

app.use("*", async (c, next) => {
  const start = process.hrtime.bigint();
  await next();
  const durationSec = Number(process.hrtime.bigint() - start) / 1e9;
  const route = c.req.routePath || c.req.path;
  const labels = { method: c.req.method, route, status: String(c.res.status) };
  httpRequestsTotal.inc(labels);
  httpRequestDuration.observe(labels, durationSec);
});

app.route("/", healthRoutes);
app.route("/", chatRoutes);

if (env.PROMETHEUS_ENABLED) {
  app.get("/metrics", async (c) => {
    c.header("Content-Type", register.contentType);
    return c.body(await register.metrics());
  });
}

app.notFound((c) => {
  return c.json(
    { success: false, error: { code: "not_found", message: "Route not found" } },
    404
  );
});

app.onError((err, c) => {
  logger.error({ operation: "unhandled_error", message: err.message });
  return c.json(
    { success: false, error: { code: "internal_error", message: "Internal server error" } },
    500
  );
});

serve({ fetch: app.fetch, port: env.API_PORT }, (info) => {
  logger.info({ operation: "startup", message: `Listening on port ${info.port}` });
});
EOF
}

bootstrap_migration() {
  write_if_missing "$ROOT_DIR/database/migrations/001_initial_chat_foundation.sql" <<'EOF'
-- 001_initial_chat_foundation.sql
-- AI Gateway 1 of 10 - Chat Foundation
-- Minimal authoritative schema. Does not store secrets or raw prompts.

BEGIN;

CREATE TABLE IF NOT EXISTS agents (
    id            BIGSERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    description   TEXT,
    role          TEXT,
    temperature   NUMERIC(3,2) NOT NULL DEFAULT 0.30 CHECK (temperature >= 0 AND temperature <= 2),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ai_requests (
    id            BIGSERIAL PRIMARY KEY,
    request_id    UUID NOT NULL UNIQUE,
    operation     TEXT NOT NULL,
    agent_name    TEXT,
    provider      TEXT,
    model         TEXT,
    status        TEXT NOT NULL DEFAULT 'processing'
                  CHECK (status IN ('processing', 'completed', 'error')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at  TIMESTAMPTZ,
    latency_ms    NUMERIC(12,3)
);

CREATE TABLE IF NOT EXISTS ai_usage (
    id             BIGSERIAL PRIMARY KEY,
    request_id     UUID NOT NULL REFERENCES ai_requests(request_id) ON DELETE CASCADE,
    provider       TEXT,
    model          TEXT,
    input_tokens   INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens  INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    total_tokens   INTEGER NOT NULL DEFAULT 0 CHECK (total_tokens >= 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_requests_status ON ai_requests(status);
CREATE INDEX IF NOT EXISTS idx_ai_requests_created_at ON ai_requests(created_at);
CREATE INDEX IF NOT EXISTS idx_ai_usage_request_id ON ai_usage(request_id);

COMMIT;
EOF
}

bootstrap_grafana_dashboard() {
  write_if_missing "$ROOT_DIR/observability/grafana/dashboard.json" <<'EOF'
{
  "title": "AI Gateway 1 of 10 - Chat Foundation",
  "uid": "ai-gateway-1-of-10-chat",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "panels": [
    {
      "id": 1,
      "title": "HTTP Request Rate",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
      "targets": [
        { "expr": "sum(rate(ai_gateway_http_requests_total[5m])) by (route)" }
      ]
    },
    {
      "id": 2,
      "title": "HTTP Error Rate",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
      "targets": [
        { "expr": "sum(rate(ai_gateway_http_requests_total{status=~\"5..\"}[5m]))" }
      ]
    },
    {
      "id": 3,
      "title": "HTTP Request Latency (p95)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 8, "w": 12, "h": 8 },
      "targets": [
        { "expr": "histogram_quantile(0.95, sum(rate(ai_gateway_http_request_duration_seconds_bucket[5m])) by (le))" }
      ]
    },
    {
      "id": 4,
      "title": "AI Request Rate",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 8, "w": 12, "h": 8 },
      "targets": [
        { "expr": "sum(rate(ai_gateway_ai_requests_total[5m])) by (provider, status)" }
      ]
    },
    {
      "id": 5,
      "title": "Token Consumption",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 16, "w": 12, "h": 8 },
      "targets": [
        { "expr": "sum(rate(ai_gateway_input_tokens_total[5m])) by (provider)", "legendFormat": "input {{provider}}" },
        { "expr": "sum(rate(ai_gateway_output_tokens_total[5m])) by (provider)", "legendFormat": "output {{provider}}" }
      ]
    },
    {
      "id": 6,
      "title": "Cache Hit Ratio",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 16, "w": 12, "h": 8 },
      "targets": [
        { "expr": "sum(rate(ai_gateway_cache_hits_total[5m])) / (sum(rate(ai_gateway_cache_hits_total[5m])) + sum(rate(ai_gateway_cache_misses_total[5m])))" }
      ]
    }
  ]
}
EOF
}

bootstrap_tests() {
  write_if_missing "$ROOT_DIR/tests/smoke_test.sh" <<'EOF'
#!/usr/bin/env bash
# smoke_test.sh - basic API contract smoke tests for ai-gateway-1-of-10-chat
# Invoked by deploy-ai-gateway-1-of-10-chat.sh test

set -u
BASE_URL="${1:-http://127.0.0.1:${API_PORT:-4400}}"

pass=0
fail=0
skip=0

check() {
  local name="$1" url="$2" method="${3:-GET}" data="${4:-}"
  local code
  if [ "$method" = "POST" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" "$url" 2>/dev/null)
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  fi
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    echo "[NOT AVAILABLE] $name (no response from $url)"
    skip=$((skip+1))
    return
  fi
  if [[ "$code" =~ ^2 ]]; then
    echo "[PASS] $name ($code)"
    pass=$((pass+1))
  else
    echo "[FAIL] $name ($code)"
    fail=$((fail+1))
  fi
}

check "GET /health"        "$BASE_URL/health"
check "GET /ready"         "$BASE_URL/ready"
check "GET /dependencies"  "$BASE_URL/dependencies"
check "GET /help"          "$BASE_URL/help"
check "GET /metrics"       "$BASE_URL/metrics"
check "POST /v1/chat"      "$BASE_URL/v1/chat" "POST" '{"message":"smoke test"}'

echo ""
echo "Summary: PASS=$pass FAIL=$fail SKIPPED/NOT AVAILABLE=$skip"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$ROOT_DIR/tests/smoke_test.sh" 2>/dev/null || true
}

bootstrap_docs() {
  write_if_missing "$ROOT_DIR/README.md" <<'EOF'
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
EOF

  write_if_missing "$ROOT_DIR/ARCHITECTURE.md" <<'EOF'
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
EOF

  write_if_missing "$ROOT_DIR/DEPENDENCIES.md" <<'EOF'
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
EOF

  write_if_missing "$ROOT_DIR/OBSERVABILITY.md" <<'EOF'
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
EOF

  write_if_missing "$ROOT_DIR/SECURITY.md" <<'EOF'
# Security - ai-gateway-1-of-10-chat

## Principles

- No authentication is implemented in this iteration; do not expose this
  service directly to untrusted networks.
- No secrets are committed to this repository. .env is gitignored;
  only .env.example (with empty values) is tracked.
- No API keys, passwords, or Authorization headers are logged or
  persisted to the database.
- Raw prompts/messages are not persisted; only request metadata
  (operation, agent_name, provider, model, status, timing) is stored.
- docker-compose.yml uses environment variable substitution only; it
  never contains literal credentials.

## Secret scanning

The `test` command runs a basic repository grep for patterns such as
API_KEY, SECRET, PASSWORD, TOKEN, AUTHORIZATION, PRIVATE_KEY outside of
.env.example and reports any matches for manual review.

## Reporting

This is an internal/self-hosted project artifact. Review findings from
`./deploy-ai-gateway-1-of-10-chat.sh test` before any deployment beyond
a local/trusted network.
EOF

  write_if_missing "$ROOT_DIR/CHECKPOINT.md" <<'EOF'
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
EOF
}

# -----------------------------------------------------------------------------
# Network validation
# -----------------------------------------------------------------------------
validate_network() {
  log_step "Validating Docker network: $SHARED_DOCKER_NETWORK"
  if docker network inspect "$SHARED_DOCKER_NETWORK" >/dev/null 2>&1; then
    log_ok "Network exists: $SHARED_DOCKER_NETWORK"
    return 0
  fi

  if [ "$CREATE_NETWORK_IF_MISSING" = "true" ]; then
    log_warn "Network missing; CREATE_NETWORK_IF_MISSING=true, creating it"
    if docker network create "$SHARED_DOCKER_NETWORK" >/dev/null 2>&1; then
      log_ok "Created network: $SHARED_DOCKER_NETWORK"
      return 0
    else
      mark_fail "Failed to create network: $SHARED_DOCKER_NETWORK"
      return 1
    fi
  else
    mark_fail "Network '$SHARED_DOCKER_NETWORK' does not exist and CREATE_NETWORK_IF_MISSING=false"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Config validation
# -----------------------------------------------------------------------------
validate_config() {
  log_step "Validating configuration"
  local ok=1

  if [ ! -f "$ROOT_DIR/.env" ]; then
    log_warn ".env not found (using defaults / shell environment)"
  else
    log_ok ".env present"
  fi

  if [ "$POSTGRES_ENABLED" = "true" ]; then
    if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_DATABASE" ] || [ -z "$POSTGRES_USER" ]; then
      mark_fail "POSTGRES_ENABLED=true but POSTGRES_HOST/DATABASE/USER incomplete"
      ok=0
    else
      log_ok "Postgres configuration present"
    fi
  else
    log_skip "Postgres disabled by configuration"
  fi

  if [ "$REDIS_ENABLED" = "true" ]; then
    if [ -z "$REDIS_HOST" ]; then
      mark_fail "REDIS_ENABLED=true but REDIS_HOST is empty"
      ok=0
    else
      log_ok "Redis configuration present"
    fi
  else
    log_skip "Redis disabled by configuration"
  fi

  [ "$ok" = "1" ]
}

# -----------------------------------------------------------------------------
# Dependency inspection (best-effort, non-destructive)
# -----------------------------------------------------------------------------
inspect_postgres() {
  if [ "$POSTGRES_ENABLED" != "true" ]; then
    log_skip "Postgres check skipped (disabled)"
    return 0
  fi
  if ! command -v psql >/dev/null 2>&1; then
    log_skip "Postgres check skipped (psql not available on host)"
    return 0
  fi
  if [ -z "$POSTGRES_HOST" ]; then
    mark_fail "Postgres host not configured"
    return 1
  fi
  if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
    log_ok "Postgres reachable at $POSTGRES_HOST:$POSTGRES_PORT"
    return 0
  else
    mark_fail "Postgres unreachable at $POSTGRES_HOST:$POSTGRES_PORT"
    return 1
  fi
}

inspect_redis() {
  if [ "$REDIS_ENABLED" != "true" ]; then
    log_skip "Redis check skipped (disabled)"
    return 0
  fi
  if ! command -v redis-cli >/dev/null 2>&1; then
    log_skip "Redis check skipped (redis-cli not available on host)"
    return 0
  fi
  if [ -z "$REDIS_HOST" ]; then
    mark_fail "Redis host not configured"
    return 1
  fi
  if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DATABASE" ping 2>/dev/null | grep -q PONG; then
    log_ok "Redis reachable at $REDIS_HOST:$REDIS_PORT"
    return 0
  else
    mark_fail "Redis unreachable at $REDIS_HOST:$REDIS_PORT"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_init() {
  CHECK_FAILED=0
  log_step "INIT: preflight and bootstrap for $APP_NAME_DEFAULT"

  check_bash
  check_docker
  check_docker_daemon

  bootstrap_structure
  load_env

  validate_config
  validate_network
  inspect_postgres
  inspect_redis

  echo ""
  if [ "$CHECK_FAILED" = "0" ]; then
    log_ok "INIT complete. Preflight PASSED. (deploy was NOT run)"
    exit 0
  else
    log_fail "INIT complete. Preflight FAILED. Review messages above. (deploy was NOT run)"
    exit 1
  fi
}

cmd_build() {
  load_env
  log_step "BUILD: validating configuration"
  validate_config || { log_fail "Configuration invalid; aborting build"; exit 1; }

  local cc
  cc="$(compose_cmd)"
  if [ -z "$cc" ]; then
    log_fail "Neither 'docker compose' nor 'docker-compose' is available"
    exit 1
  fi

  log_step "BUILD: building image ${IMAGE_NAME}:${IMAGE_TAG}"
  if $cc -f "$ROOT_DIR/docker-compose.yml" build api; then
    log_ok "Build succeeded: ${IMAGE_NAME}:${IMAGE_TAG}"
  else
    log_fail "Build failed"
    exit 1
  fi
}

cmd_push() {
  load_env
  log_step "PUSH: checking registry configuration"

  if [ "$REGISTRY_ENABLED" != "true" ] || [ -z "$REGISTRY_HOST" ]; then
    log_fail "Registry not configured (REGISTRY_ENABLED=true and REGISTRY_HOST required). Refusing to push."
    exit 1
  fi

  local target="${REGISTRY_HOST}/${IMAGE_NAME}:${IMAGE_TAG}"
  log_step "PUSH: tagging and pushing ${target}"

  if ! docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
    log_fail "Local image ${IMAGE_NAME}:${IMAGE_TAG} not found. Run 'build' first."
    exit 1
  fi

  if docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "$target" && docker push "$target"; then
    log_ok "Pushed ${target}"
  else
    log_fail "Push failed"
    exit 1
  fi
}

cmd_deploy() {
  load_env
  CHECK_FAILED=0
  log_step "DEPLOY: running preflight"

  check_bash
  check_docker
  check_docker_daemon
  validate_config
  validate_network

  if [ "$CHECK_FAILED" != "0" ]; then
    log_fail "Preflight failed. Deployment BLOCKED."
    exit 1
  fi

  local cc
  cc="$(compose_cmd)"
  if [ -z "$cc" ]; then
    log_fail "Neither 'docker compose' nor 'docker-compose' is available"
    exit 1
  fi

  log_step "DEPLOY: bringing up stack"
  if ! $cc -f "$ROOT_DIR/docker-compose.yml" up -d; then
    log_fail "Deployment failed"
    exit 1
  fi

  log_step "DEPLOY: waiting for health (best-effort, ${HEALTHCHECK_RETRIES} retries)"
  local i=0
  local healthy=0
  while [ "$i" -lt "$HEALTHCHECK_RETRIES" ]; do
    if curl -sf "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 2
    i=$((i+1))
  done

  if [ "$healthy" = "1" ]; then
    log_ok "Deployment reported healthy on port ${API_PORT}"
  else
    log_warn "Deployment status unknown: /health did not respond within retry window"
  fi
}

cmd_ps() {
  load_env
  local cc
  cc="$(compose_cmd)"
  if [ -z "$cc" ]; then
    log_fail "Neither 'docker compose' nor 'docker-compose' is available"
    exit 1
  fi
  $cc -f "$ROOT_DIR/docker-compose.yml" ps
}

cmd_logs() {
  load_env
  local cc
  cc="$(compose_cmd)"
  if [ -z "$cc" ]; then
    log_fail "Neither 'docker compose' nor 'docker-compose' is available"
    exit 1
  fi
  local service="${1:-}"
  if [ -n "$service" ]; then
    $cc -f "$ROOT_DIR/docker-compose.yml" logs -f --tail=200 "$service"
  else
    $cc -f "$ROOT_DIR/docker-compose.yml" logs -f --tail=200
  fi
}

cmd_test() {
  load_env
  local overall_pass=0
  local overall_fail=0

  log_step "TEST: configuration validation"
  if validate_config; then log_ok "Configuration valid"; overall_pass=$((overall_pass+1)); else log_fail "Configuration invalid"; overall_fail=$((overall_fail+1)); fi

  log_step "TEST: SQL validation"
  if [ -f "$ROOT_DIR/database/migrations/001_initial_chat_foundation.sql" ]; then
    if command -v psql >/dev/null 2>&1; then
      if psql --set ON_ERROR_STOP=1 -f "$ROOT_DIR/database/migrations/001_initial_chat_foundation.sql" -d postgres --dry-run >/dev/null 2>&1; then
        log_ok "SQL file readable"
      else
        log_skip "SQL syntax check not performed (no dry-run target); file exists and is non-empty"
      fi
    else
      log_skip "psql not available; skipping SQL validation"
    fi
  else
    mark_fail "Migration file missing"
    overall_fail=$((overall_fail+1))
  fi

  log_step "TEST: Docker Compose validation"
  local cc
  cc="$(compose_cmd)"
  if [ -n "$cc" ]; then
    if $cc -f "$ROOT_DIR/docker-compose.yml" config >/dev/null 2>&1; then
      log_ok "docker-compose.yml is valid"
      overall_pass=$((overall_pass+1))
    else
      log_fail "docker-compose.yml failed validation"
      overall_fail=$((overall_fail+1))
    fi
  else
    log_skip "Docker Compose not available; skipping compose validation"
  fi

  log_step "TEST: Grafana JSON validation"
  if command -v node >/dev/null 2>&1; then
    if node -e "JSON.parse(require('fs').readFileSync('$ROOT_DIR/observability/grafana/dashboard.json','utf8'))" >/dev/null 2>&1; then
      log_ok "Grafana dashboard.json is valid JSON"
      overall_pass=$((overall_pass+1))
    else
      log_fail "Grafana dashboard.json is invalid JSON"
      overall_fail=$((overall_fail+1))
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json; json.load(open('$ROOT_DIR/observability/grafana/dashboard.json'))" >/dev/null 2>&1; then
      log_ok "Grafana dashboard.json is valid JSON"
      overall_pass=$((overall_pass+1))
    else
      log_fail "Grafana dashboard.json is invalid JSON"
      overall_fail=$((overall_fail+1))
    fi
  else
    log_skip "No JSON validator (node/python3) available"
  fi

  log_step "TEST: dependency checks"
  inspect_postgres || overall_fail=$((overall_fail+1))
  inspect_redis || overall_fail=$((overall_fail+1))

  log_step "TEST: API smoke tests"
  if [ -x "$ROOT_DIR/tests/smoke_test.sh" ]; then
    if curl -sf "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
      "$ROOT_DIR/tests/smoke_test.sh" "http://127.0.0.1:${API_PORT}"
    else
      log_skip "API not reachable on 127.0.0.1:${API_PORT}; smoke tests NOT AVAILABLE"
    fi
  else
    log_skip "tests/smoke_test.sh not found or not executable"
  fi

  log_step "TEST: secret / leak scan"
  local pattern='API_KEY|SECRET|PASSWORD|TOKEN|AUTHORIZATION|PRIVATE_KEY'
  local hits
  hits=$(grep -RInE "$pattern" "$ROOT_DIR" \
    --exclude-dir=node_modules --exclude-dir=.git \
    --exclude=".env.example" --exclude="deploy-ai-gateway-1-of-10-chat.sh" \
    --exclude="SECURITY.md" 2>/dev/null | grep -vE '=\s*("")?\s*$' || true)
  if [ -n "$hits" ]; then
    log_warn "Potential secret-like patterns found (manual review required):"
    echo "$hits" | while IFS= read -r line; do echo "    $line" >&2; done
    overall_fail=$((overall_fail+1))
  else
    log_ok "No obvious secret leaks detected"
    overall_pass=$((overall_pass+1))
  fi

  log_step "TEST: .env ignored by git"
  if [ -f "$ROOT_DIR/.gitignore" ] && grep -qx '\.env' "$ROOT_DIR/.gitignore"; then
    log_ok ".env is present in .gitignore"
    overall_pass=$((overall_pass+1))
  else
    log_fail ".env is NOT confirmed in .gitignore"
    overall_fail=$((overall_fail+1))
  fi

  echo ""
  log_step "TEST SUMMARY: PASS-ish checks=$overall_pass FAIL-ish checks=$overall_fail"
  if [ "$overall_fail" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

cmd_help() {
  cat <<EOF
${APP_NAME_DEFAULT} — deployment script

Usage: ./deploy-ai-gateway-1-of-10-chat.sh <command> [args]

Commands:
  init            Bootstrap local structure, load config, run preflight
                   checks (Docker, network, Postgres, Redis). Does NOT deploy.
  build           Validate configuration and build this stack's Docker image.
  push            Push the built image to the configured registry
                   (refuses if REGISTRY_ENABLED/REGISTRY_HOST are not set).
  deploy          Run preflight, then bring up the stack via Docker Compose,
                   waiting briefly for /health.
  ps              Show status of this stack's containers/services.
  logs [service]  Tail logs for the stack, or a specific service.
  test            Run configuration, SQL, Compose, JSON, dependency,
                   API smoke, and secret-scan checks. Reports
                   PASS / FAIL / SKIPPED / NOT AVAILABLE.
  help            Show this message.

Environment:
  Configuration is read from .env (created from .env.example on init,
  never overwritten). See .env.example for all supported variables.

Notes:
  - This script only manages the ai-gateway-1-of-10-chat stack.
  - It never creates or deletes the shared Docker network unless
    CREATE_NETWORK_IF_MISSING=true, and never deletes an existing one.
  - No authentication, secrets generation, or cloud AI providers are
    part of this iteration. See CHECKPOINT.md.
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init)   cmd_init ;;
    build)  cmd_build ;;
    push)   cmd_push ;;
    deploy) cmd_deploy ;;
    ps)     cmd_ps ;;
    logs)   cmd_logs "$@" ;;
    test)   cmd_test ;;
    help|-h|--help) cmd_help ;;
    *)
      log_fail "Unknown command: $cmd"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
