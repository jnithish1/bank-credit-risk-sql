/* =============================================================================
   02_load_raw.sql
   Bulk-loads the 8 source CSVs into staging with client-side \copy.
   Run from the folder that holds the CSVs (psql resolves \copy paths relative
   to its working directory), e.g.:
       cd data/raw && psql -d berka -f ../../sql/02_staging/02_load_raw.sql
   scripts/run_pipeline.sh does this for you.
   Source format: semicolon-delimited, double-quoted, header row.
   ============================================================================= */

\set ON_ERROR_STOP on

TRUNCATE staging.account, staging.client, staging.disp, staging.card,
         staging.loan, staging.permanent_order, staging.trans, staging.district;

\copy staging.account         FROM 'account.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.client          FROM 'client.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.disp            FROM 'disp.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.card            FROM 'card.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.loan            FROM 'loan.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.permanent_order FROM 'order.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.trans           FROM 'trans.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')
\copy staging.district        FROM 'district.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '"')

-- Landing row counts (recorded for reconciliation against core)
INSERT INTO audit.etl_run_log (step_name, target_table, rows_affected, finished_at, status)
SELECT 'load_raw', t.tbl, t.n, clock_timestamp(), 'SUCCESS'
FROM (
          SELECT 'staging.account'         AS tbl, COUNT(*) AS n FROM staging.account
UNION ALL SELECT 'staging.client',          COUNT(*) FROM staging.client
UNION ALL SELECT 'staging.disp',            COUNT(*) FROM staging.disp
UNION ALL SELECT 'staging.card',            COUNT(*) FROM staging.card
UNION ALL SELECT 'staging.loan',            COUNT(*) FROM staging.loan
UNION ALL SELECT 'staging.permanent_order', COUNT(*) FROM staging.permanent_order
UNION ALL SELECT 'staging.trans',           COUNT(*) FROM staging.trans
UNION ALL SELECT 'staging.district',        COUNT(*) FROM staging.district
) t;
