/* =============================================================================
   build_all.sql - builds the whole warehouse from inside psql.
   Works on Windows, Mac and Linux, with no bash scripts needed.

   In "SQL Shell (psql)", connected to the berka database:
       \cd 'C:/path/to/berka-bank-analytics'
       \i build_all.sql
   (Use forward slashes in the path, even on Windows.)
   ============================================================================= */

\set ON_ERROR_STOP on
\timing off
\echo '==> 1/6  Creating schemas'
\i sql/01_setup/01_schemas.sql

\echo '==> 2/6  Loading raw CSVs from data/raw'
\i sql/02_staging/01_staging_tables.sql
\cd data/raw
\i ../../sql/02_staging/02_load_raw.sql
\cd ../..

\echo '==> 3/6  Building the core model (about 15 seconds)'
\i sql/03_core/01_core_tables.sql
\i sql/03_core/02_transform_functions.sql
\i sql/03_core/03_sp_load_core.sql
CALL core.sp_load_core();
\i sql/03_core/04_indexes.sql

\echo '==> 4/6  Running data-quality checks'
\i sql/04_quality/01_sp_run_dq_checks.sql
CALL audit.sp_run_dq_checks();
\i sql/04_quality/02_assert_dq.sql

\echo '==> 5/6  Building the analytics mart (about 15 seconds)'
\i sql/05_mart/01_dimensions.sql
\i sql/05_mart/02_facts.sql
\i sql/05_mart/03_functions.sql
\i sql/05_mart/04_loan_features.sql
\i sql/05_mart/05_scorecard.sql

\echo '==> 6/6  Applying security roles'
\i sql/07_security/01_roles_and_access.sql

\echo ''
\echo '==> DONE. The warehouse is built. Open pgAdmin and run any file in sql/06_analysis.'
