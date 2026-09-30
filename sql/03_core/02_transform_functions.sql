/* =============================================================================
   02_transform_functions.sql
   Reusable, IMMUTABLE parsing helpers + ETL logging helpers.
   ============================================================================= */

-- Source dates are YYMMDD (all 19xx). Card dates carry a trailing '00:00:00'.
-- Returns NULL instead of erroring on malformed input so bad rows can be
-- measured by the data-quality layer rather than aborting the load.
CREATE OR REPLACE FUNCTION core.fn_parse_yymmdd(p_raw TEXT)
RETURNS DATE
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
             WHEN left(trim(p_raw), 6) ~ '^\d{6}$'
              AND substr(trim(p_raw), 3, 2)::int BETWEEN 1 AND 12
              AND substr(trim(p_raw), 5, 2)::int BETWEEN 1 AND 31
             THEN make_date(1900 + substr(trim(p_raw), 1, 2)::int,
                                   substr(trim(p_raw), 3, 2)::int,
                                   substr(trim(p_raw), 5, 2)::int)
           END
$$;

-- Czech birth_number encodes gender: women have 50 added to the month (YYMM+50DD).
CREATE OR REPLACE FUNCTION core.fn_decode_gender(p_birth_number TEXT)
RETURNS CHAR(1)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN substr(p_birth_number, 3, 2)::int > 50 THEN 'F' ELSE 'M' END
$$;

CREATE OR REPLACE FUNCTION core.fn_decode_birth_date(p_birth_number TEXT)
RETURNS DATE
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT make_date(1900 + substr(p_birth_number, 1, 2)::int,
                     substr(p_birth_number, 3, 2)::int
                       - CASE WHEN substr(p_birth_number, 3, 2)::int > 50 THEN 50 ELSE 0 END,
                     substr(p_birth_number, 5, 2)::int)
$$;

-- Translate a source code through core.code_lookup
CREATE OR REPLACE FUNCTION core.fn_label(p_domain TEXT, p_code TEXT)
RETURNS TEXT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT label FROM core.code_lookup
    WHERE domain = p_domain AND source_code = NULLIF(trim(p_code), '')
$$;

-- ---------------------------------------------------------------------------
-- ETL logging helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.fn_log_start(p_step TEXT, p_table TEXT)
RETURNS BIGINT LANGUAGE sql AS $$
    INSERT INTO audit.etl_run_log (step_name, target_table)
    VALUES (p_step, p_table)
    RETURNING run_id
$$;

CREATE OR REPLACE FUNCTION audit.fn_log_end(p_run_id BIGINT, p_rows BIGINT)
RETURNS VOID LANGUAGE sql AS $$
    UPDATE audit.etl_run_log
       SET rows_affected = p_rows, finished_at = clock_timestamp(), status = 'SUCCESS'
     WHERE run_id = p_run_id
$$;
