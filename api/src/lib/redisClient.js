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
