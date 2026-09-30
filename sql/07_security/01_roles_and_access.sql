/* =============================================================================
   01_roles_and_access.sql
   Least-privilege access model, as a bank's data platform team would set it up.

     bi_reader          -> dashboards / analysts: SELECT on mart only
     data_engineer      -> owns the pipeline: full rights on staging/core/audit/mart
     regional_analyst_* -> row-level restricted: sees only their region's accounts

   Plus a PII-safe view: client birth dates are generalised to birth year.
   ============================================================================= */

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bi_reader')     THEN CREATE ROLE bi_reader NOLOGIN;     END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'data_engineer') THEN CREATE ROLE data_engineer NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'regional_analyst_prague') THEN
        CREATE ROLE regional_analyst_prague NOLOGIN;   -- deliberately NOT a bi_reader
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- bi_reader: read-only on the analytics layer, nothing else
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA staging, core, audit FROM bi_reader;
GRANT  USAGE  ON SCHEMA mart TO bi_reader;
GRANT  SELECT ON ALL TABLES IN SCHEMA mart TO bi_reader;           -- includes views & MVs
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA mart TO bi_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA mart GRANT SELECT ON TABLES TO bi_reader;

-- ---------------------------------------------------------------------------
-- data_engineer: owns the pipeline
-- ---------------------------------------------------------------------------
GRANT USAGE, CREATE ON SCHEMA staging, core, mart, audit TO data_engineer;
GRANT ALL ON ALL TABLES IN SCHEMA staging, core, mart, audit TO data_engineer;

-- ---------------------------------------------------------------------------
-- Row-level restriction for regional analysts.
-- Entitlements live in a table, so granting a region is data, not DDL.
-- security_barrier stops predicate push-down tricks from leaking hidden rows.
-- ---------------------------------------------------------------------------
CREATE TABLE mart.analyst_region_access (
    role_name TEXT NOT NULL,
    region    TEXT NOT NULL,
    PRIMARY KEY (role_name, region)
);
INSERT INTO mart.analyst_region_access VALUES ('regional_analyst_prague', 'Prague');

CREATE VIEW mart.v_account_regional WITH (security_barrier = true) AS
SELECT a.*
FROM mart.dim_account a
WHERE a.region IN (SELECT r.region FROM mart.analyst_region_access r
                   WHERE r.role_name = current_user)
   OR pg_has_role(current_user, 'data_engineer', 'MEMBER');

-- The view runs with its owner's rights, so the analyst needs no access to
-- mart.dim_account itself - only to the filtered view.
GRANT USAGE  ON SCHEMA mart TO regional_analyst_prague;
GRANT SELECT ON mart.v_account_regional TO regional_analyst_prague;

-- ---------------------------------------------------------------------------
-- PII minimisation: exact birth dates are personal data. Most analysis only
-- needs age bands, so BI users get birth year only.
-- ---------------------------------------------------------------------------
CREATE VIEW mart.v_client_masked AS
SELECT client_id, gender, extract(year FROM birth_date)::int AS birth_year,
       age_band, district_name, region
FROM mart.dim_client;

REVOKE SELECT ON mart.dim_client FROM bi_reader;
GRANT  SELECT ON mart.v_client_masked TO bi_reader;
