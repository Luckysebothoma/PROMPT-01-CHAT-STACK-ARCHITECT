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
