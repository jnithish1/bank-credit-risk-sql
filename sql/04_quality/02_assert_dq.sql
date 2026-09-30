/* =============================================================================
   02_assert_dq.sql
   Pipeline gate: fails the build (non-zero exit from psql) if any CRITICAL
   check in the latest DQ run did not pass. WARNINGs are reported, not fatal.
   ============================================================================= */

DO $$
DECLARE
    v_last   TIMESTAMPTZ := (SELECT max(run_at) FROM audit.dq_result);
    v_failed TEXT;
    v_warn   INT;
BEGIN
    SELECT string_agg(check_name || ' on ' || table_name || ' (' || failed_rows || ' rows)', '; ')
      INTO v_failed
      FROM audit.dq_result
     WHERE run_at = v_last AND severity = 'CRITICAL' AND NOT passed;

    SELECT count(*) INTO v_warn
      FROM audit.dq_result
     WHERE run_at = v_last AND severity = 'WARNING' AND NOT passed;

    IF v_failed IS NOT NULL THEN
        RAISE EXCEPTION 'Data-quality gate FAILED: %', v_failed;
    END IF;

    RAISE NOTICE 'Data-quality gate passed (% warning(s)).', v_warn;
END $$;

-- Scorecard for the run log / README
SELECT check_name, table_name, severity, failed_rows, total_rows,
       metric_value, passed
FROM audit.dq_result
WHERE run_at = (SELECT max(run_at) FROM audit.dq_result)
ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END, check_id;
