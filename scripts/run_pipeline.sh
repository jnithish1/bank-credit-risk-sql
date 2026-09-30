#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh - builds the whole warehouse end to end
#
#   ./scripts/run_pipeline.sh            # full dataset  (data/raw)
#   ./scripts/run_pipeline.sh sample     # 10% sample    (data/sample, used by CI)
#
# Connection uses the standard libpq variables, e.g.
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGDATABASE=berka
# Exits non-zero on the first SQL error or if the data-quality gate fails.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATASET="${1:-raw}"
DATA_DIR="$ROOT/data/$DATASET"
export PGDATABASE="${PGDATABASE:-berka}"

PSQL=(psql -X -q -v ON_ERROR_STOP=1)

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
run()  { step "$1"; "${PSQL[@]}" -f "$ROOT/$1"; }
call() { step "$1"; "${PSQL[@]}" -c "$1"; }

[[ -f "$DATA_DIR/trans.csv" ]] || { echo "No CSVs in $DATA_DIR - see data/raw/README.md"; exit 1; }

start=$(date +%s)

# 1. Architecture ------------------------------------------------------------
run sql/01_setup/01_schemas.sql

# 2. Land raw files (psql resolves \copy paths from its working directory) ---
run sql/02_staging/01_staging_tables.sql
step "sql/02_staging/02_load_raw.sql  (from $DATA_DIR)"
( cd "$DATA_DIR" && "${PSQL[@]}" -f "$ROOT/sql/02_staging/02_load_raw.sql" )

# 3. Core model ----------------------------------------------------------------
run  sql/03_core/01_core_tables.sql
run  sql/03_core/02_transform_functions.sql
run  sql/03_core/03_sp_load_core.sql
call "CALL core.sp_load_core();"
run  sql/03_core/04_indexes.sql

# 4. Data-quality gate (fails the build on CRITICAL issues) -------------------
run  sql/04_quality/01_sp_run_dq_checks.sql
call "CALL audit.sp_run_dq_checks();"
step "sql/04_quality/02_assert_dq.sql"
"${PSQL[@]}" -f "$ROOT/sql/04_quality/02_assert_dq.sql" -P pager=off

# 5. Analytics mart -------------------------------------------------------------
run sql/05_mart/01_dimensions.sql
run sql/05_mart/02_facts.sql
run sql/05_mart/03_functions.sql
run sql/05_mart/04_loan_features.sql
run sql/05_mart/05_scorecard.sql

# 6. Security -------------------------------------------------------------------
run sql/07_security/01_roles_and_access.sql

step "Pipeline finished in $(( $(date +%s) - start ))s"
"${PSQL[@]}" -P pager=off -c "
  SELECT step_name, target_table, rows_affected, round(duration_ms) AS ms
  FROM audit.etl_run_log ORDER BY run_id;"
