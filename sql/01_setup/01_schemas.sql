/* =============================================================================
   01_schemas.sql
   Creates the layered warehouse architecture (medallion-style):

     staging  -> raw files landed 1:1, everything TEXT, no business rules
     core     -> cleaned, typed, constrained, English-labelled 3NF model
     mart     -> analytics layer: star schema, materialized aggregates, views
     audit    -> ETL run log + data-quality results (observability)

   Idempotent: safe to re-run. Drops and rebuilds the whole warehouse.
   ============================================================================= */

DROP SCHEMA IF EXISTS mart    CASCADE;
DROP SCHEMA IF EXISTS core    CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS audit   CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA core;
CREATE SCHEMA mart;
CREATE SCHEMA audit;

COMMENT ON SCHEMA staging IS 'Raw landing zone. Source files loaded as-is (TEXT columns).';
COMMENT ON SCHEMA core    IS 'Cleaned, typed and constrained operational model (3NF).';
COMMENT ON SCHEMA mart    IS 'Analytics layer: star schema, aggregates and reporting views.';
COMMENT ON SCHEMA audit   IS 'Pipeline observability: ETL run log and data-quality results.';

-- ---------------------------------------------------------------------------
-- Observability tables
-- ---------------------------------------------------------------------------
CREATE TABLE audit.etl_run_log (
    run_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    step_name     TEXT        NOT NULL,
    target_table  TEXT,
    rows_affected BIGINT,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at   TIMESTAMPTZ,
    duration_ms   NUMERIC GENERATED ALWAYS AS
                  (EXTRACT(EPOCH FROM (finished_at - started_at)) * 1000) STORED,
    status        TEXT        NOT NULL DEFAULT 'RUNNING'
                  CHECK (status IN ('RUNNING','SUCCESS','FAILED'))
);

CREATE TABLE audit.dq_result (
    check_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    check_name    TEXT        NOT NULL,
    table_name    TEXT        NOT NULL,
    severity      TEXT        NOT NULL CHECK (severity IN ('CRITICAL','WARNING','INFO')),
    failed_rows   BIGINT      NOT NULL,
    total_rows    BIGINT,
    metric_value  NUMERIC,
    threshold     NUMERIC,
    passed        BOOLEAN,    -- resolved at the end of each DQ run
    details       TEXT
);
