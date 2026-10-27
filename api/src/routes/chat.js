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
