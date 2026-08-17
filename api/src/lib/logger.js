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
