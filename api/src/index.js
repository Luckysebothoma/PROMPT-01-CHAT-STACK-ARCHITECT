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
