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
