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
