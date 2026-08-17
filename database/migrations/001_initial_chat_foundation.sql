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
