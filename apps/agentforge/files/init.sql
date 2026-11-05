-- AgentForge — Postgres Initialisation
-- Phase 0: Core tables only
-- Phase 1: Audit trail table added
-- Phase 6: pgvector extension + embeddings table added

-- ── Extensions ───────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector (Phase 6)

-- ── Audit Runs ────────────────────────────────────────────────────────────────
-- Immutable audit trail for every agent run.
-- No UPDATE or DELETE allowed on this table in production.
CREATE TABLE IF NOT EXISTS audit_runs (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          VARCHAR(64) NOT NULL UNIQUE,
    task_id         VARCHAR(64) NOT NULL,
    agent_id        VARCHAR(64) NOT NULL,
    team_id         VARCHAR(64) NOT NULL,
    status          VARCHAR(32) NOT NULL,
    task_input      TEXT,                   -- PII already redacted before insert
    tool_calls      JSONB       DEFAULT '[]',
    agent_output    TEXT,                   -- PII already redacted before insert
    guardrail_flags JSONB       DEFAULT '{}',
    tokens_used     INTEGER     DEFAULT 0,
    cost_usd        NUMERIC(10,6) DEFAULT 0,
    duration_ms     INTEGER     DEFAULT 0,
    model_used      VARCHAR(128),
    error           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_audit_runs_agent_id  ON audit_runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_audit_runs_team_id   ON audit_runs(team_id);
CREATE INDEX IF NOT EXISTS idx_audit_runs_created_at ON audit_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_runs_status    ON audit_runs(status);

-- ── Team Quotas ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_quotas (
    team_id             VARCHAR(64) PRIMARY KEY,
    tokens_per_hour     INTEGER     NOT NULL DEFAULT 100000,
    cost_ceiling_usd    NUMERIC(10,2) NOT NULL DEFAULT 50.00,
    agent_access        JSONB       DEFAULT '[]',
    slack_channel       VARCHAR(128),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed dev team for local development
INSERT INTO team_quotas (team_id, tokens_per_hour, cost_ceiling_usd, agent_access)
VALUES ('dev-team', 1000000, 999.99, '["*"]')
ON CONFLICT (team_id) DO NOTHING;

-- ── Jobs ─────────────────────────────────────────────────────────────────────
-- Async job tracking (Phase 4)
CREATE TABLE IF NOT EXISTS jobs (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id          VARCHAR(64) NOT NULL UNIQUE,
    run_id          VARCHAR(64),
    agent_id        VARCHAR(64) NOT NULL,
    team_id         VARCHAR(64) NOT NULL,
    status          VARCHAR(32) NOT NULL DEFAULT 'queued',
    celery_task_id  VARCHAR(128),
    webhook_url     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Vector Embeddings (Phase 6 — IntelliSearch) ───────────────────────────────
CREATE TABLE IF NOT EXISTS document_chunks (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    chunk_id        VARCHAR(128) NOT NULL UNIQUE,
    source_type     VARCHAR(64) NOT NULL,   -- confluence | github | jira | ...
    source_url      TEXT        NOT NULL,
    source_title    TEXT        NOT NULL,
    author          VARCHAR(256),
    access_level    VARCHAR(64) NOT NULL DEFAULT 'team',
    content         TEXT        NOT NULL,
    embedding       vector(1536),           -- text-embedding-3-small dimensions
    metadata        JSONB       DEFAULT '{}',
    indexed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_modified   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_chunks_source_type ON document_chunks(source_type);
CREATE INDEX IF NOT EXISTS idx_chunks_access_level ON document_chunks(access_level);
-- Vector similarity index (Phase 6)
-- CREATE INDEX ON document_chunks USING ivfflat (embedding vector_cosine_ops)
--   WITH (lists = 100);

COMMENT ON TABLE audit_runs IS
  'Immutable audit trail. No UPDATE or DELETE in production.';
COMMENT ON TABLE document_chunks IS
  'IntelliSearch knowledge base. Populated by ingestion pipeline (Phase 6).';
