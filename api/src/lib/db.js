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
