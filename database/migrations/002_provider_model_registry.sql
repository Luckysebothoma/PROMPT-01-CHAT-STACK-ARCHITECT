-- 002_provider_model_registry.sql
-- PROMPT-02 / Day 2: provider + model registry.
-- API keys are NEVER stored here. Secrets remain in environment configuration.

BEGIN;

CREATE TABLE IF NOT EXISTS providers (
    id            BIGSERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    enabled       BOOLEAN NOT NULL DEFAULT FALSE,
    base_url      TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS models (
    id                   BIGSERIAL PRIMARY KEY,
    provider_id          BIGINT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
    model_key            TEXT NOT NULL,
    display_name         TEXT NOT NULL,
    category             TEXT NOT NULL DEFAULT 'chat',
    enabled              BOOLEAN NOT NULL DEFAULT TRUE,
    temperature_default  NUMERIC(3,2),
    context_window       INTEGER,
    supports_streaming   BOOLEAN,
    supports_json        BOOLEAN,
    supports_tools       BOOLEAN,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider_id, model_key)
);

-- Structure that allows logical aliases (e.g. "fast-chat") to be added later.
-- No alias resolution is implemented in this iteration.
CREATE TABLE IF NOT EXISTS model_aliases (
    id          BIGSERIAL PRIMARY KEY,
    alias       TEXT NOT NULL UNIQUE,
    model_id    BIGINT NOT NULL REFERENCES models(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Usage table that can represent "provider did not report usage" (NULL).
CREATE TABLE IF NOT EXISTS ai_usage_v2 (
    id              BIGSERIAL PRIMARY KEY,
    request_id      UUID NOT NULL REFERENCES ai_requests(request_id) ON DELETE CASCADE,
    provider        TEXT,
    model           TEXT,
    input_tokens    INTEGER CHECK (input_tokens  IS NULL OR input_tokens  >= 0),
    output_tokens   INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
    total_tokens    INTEGER CHECK (total_tokens  IS NULL OR total_tokens  >= 0),
    usage_reported  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_models_provider_id   ON models(provider_id);
CREATE INDEX IF NOT EXISTS idx_models_category      ON models(category);
CREATE INDEX IF NOT EXISTS idx_ai_usage_v2_request  ON ai_usage_v2(request_id);

-- Register only the provider that has an implemented adapter.
-- enabled=false by default: enablement is driven by environment configuration.
INSERT INTO providers (name, display_name, enabled, base_url)
VALUES ('groq', 'Groq', FALSE, 'https://api.groq.com/openai/v1')
ON CONFLICT (name) DO NOTHING;

-- No models are seeded: model identifiers are operator-declared
-- (<PROVIDER>_MODELS) and must not be fabricated by the gateway.

COMMIT;
