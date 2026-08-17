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
