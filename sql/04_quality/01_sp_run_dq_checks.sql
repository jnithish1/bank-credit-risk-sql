/* =============================================================================
   01_sp_run_dq_checks.sql
   Automated data-quality framework. Each check writes one row to
   audit.dq_result with a severity, a failure count and a pass/fail flag.
   CRITICAL failures stop the pipeline (see 02_assert_dq.sql).

   Usage:  CALL audit.sp_run_dq_checks();
   ============================================================================= */

CREATE OR REPLACE PROCEDURE audit.sp_run_dq_checks()
LANGUAGE plpgsql AS $$
DECLARE
    v_run_at TIMESTAMPTZ := now();
BEGIN
    -- ------------------------------------------------------------------
    -- 1. Completeness: every staged row reached core (row-count reconciliation)
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity,
                                 failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'row_count_reconciliation', r.core_tbl, 'CRITICAL',
           abs(r.staged - r.loaded), r.staged, r.staged = r.loaded,
           format('staged=%s loaded=%s', r.staged, r.loaded)
    FROM (
              SELECT 'core.district' core_tbl, (SELECT count(*) FROM staging.district) staged, (SELECT count(*) FROM core.district) loaded
    UNION ALL SELECT 'core.client',          (SELECT count(*) FROM staging.client),          (SELECT count(*) FROM core.client)
    UNION ALL SELECT 'core.account',         (SELECT count(*) FROM staging.account),         (SELECT count(*) FROM core.account)
    UNION ALL SELECT 'core.disposition',     (SELECT count(*) FROM staging.disp),            (SELECT count(*) FROM core.disposition)
    UNION ALL SELECT 'core.card',            (SELECT count(*) FROM staging.card),            (SELECT count(*) FROM core.card)
    UNION ALL SELECT 'core.loan',            (SELECT count(*) FROM staging.loan),            (SELECT count(*) FROM core.loan)
    UNION ALL SELECT 'core.permanent_order', (SELECT count(*) FROM staging.permanent_order), (SELECT count(*) FROM core.permanent_order)
    UNION ALL SELECT 'core.transaction',     (SELECT count(*) FROM staging.trans),           (SELECT count(*) FROM core.transaction)
    ) r;

    -- ------------------------------------------------------------------
    -- 2. Code mapping: no source code may be left untranslated
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'unmapped_source_codes', 'staging.trans', 'CRITICAL',
           count(*) FILTER (WHERE
                (NULLIF(trim(operation),'') IS NOT NULL AND core.fn_label('operation', operation) IS NULL)
             OR (NULLIF(trim(k_symbol),'')  IS NOT NULL AND core.fn_label('purpose',   k_symbol)  IS NULL)),
           count(*), NULL, 'operation / k_symbol codes missing from core.code_lookup'
    FROM staging.trans;

    -- ------------------------------------------------------------------
    -- 3. Integrity: every account has exactly one owner
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'account_has_owner', 'core.disposition', 'CRITICAL',
           count(*) FILTER (WHERE d.account_id IS NULL), count(*), NULL, 'accounts with no OWNER disposition'
    FROM core.account a
    LEFT JOIN core.disposition d ON d.account_id = a.account_id AND d.disp_type = 'OWNER';

    -- ------------------------------------------------------------------
    -- 4. Business rule: loan amount = duration x monthly instalment
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'loan_amount_equals_schedule', 'core.loan', 'CRITICAL',
           count(*) FILTER (WHERE abs(amount - duration_months * monthly_payment) > 1),
           count(*), NULL, 'amount <> duration_months * monthly_payment'
    FROM core.loan;

    -- ------------------------------------------------------------------
    -- 5. Temporal logic: nothing happens before the account exists
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'loan_after_account_open', 'core.loan', 'CRITICAL',
           count(*) FILTER (WHERE l.granted_date < a.opened_date), count(*), NULL, 'loan granted before account opened'
    FROM core.loan l JOIN core.account a USING (account_id);

    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'transaction_after_account_open', 'core.transaction', 'CRITICAL',
           count(*) FILTER (WHERE t.trans_date < a.opened_date), count(*), NULL, 'transaction dated before account opened'
    FROM core.transaction t JOIN core.account a USING (account_id);

    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'card_after_account_open', 'core.card', 'WARNING',
           count(*) FILTER (WHERE c.issued_date < a.opened_date), count(*), NULL, 'card issued before account opened'
    FROM core.card c
    JOIN core.disposition d USING (disp_id)
    JOIN core.account a     ON a.account_id = d.account_id;

    -- ------------------------------------------------------------------
    -- 6. Plausibility: client age at account opening
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'owner_age_plausible', 'core.client', 'WARNING',
           count(*) FILTER (WHERE age NOT BETWEEN 0 AND 100), count(*), NULL, 'owner age at opening outside 0-100'
    FROM (SELECT date_part('year', age(a.opened_date, c.birth_date)) AS age
          FROM core.account a
          JOIN core.disposition d ON d.account_id = a.account_id AND d.disp_type = 'OWNER'
          JOIN core.client c      ON c.client_id = d.client_id) x;

    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'minor_account_owners', 'core.client', 'INFO',
           count(*) FILTER (WHERE age < 18), count(*), NULL, 'owners under 18 at opening (valid: junior accounts)'
    FROM (SELECT date_part('year', age(a.opened_date, c.birth_date)) AS age
          FROM core.account a
          JOIN core.disposition d ON d.account_id = a.account_id AND d.disp_type = 'OWNER'
          JOIN core.client c      ON c.client_id = d.client_id) x;

    -- ------------------------------------------------------------------
    -- 7. Ledger integrity: day-level balance reconciliation
    --    Intra-day order is not recorded in the source, so we reconstruct the
    --    end-of-day balance: the one transaction whose balance is not the
    --    opening balance of another same-day transaction. Then check
    --    prev_EOD + net_flow(day) = EOD, within 1 CZK: the source ledger carries
    --    sub-crown rounding drift on interest postings (profiled: ~25% of
    --    months differ by 0.10 CZK).
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows,
                                 total_rows, metric_value, threshold, passed, details)
    WITH tx AS (
        SELECT trans_id, account_id, trans_date, signed_amount, balance_after,
               balance_after - signed_amount AS opening_balance
        FROM core.transaction
    ),
    eod AS (
        SELECT DISTINCT ON (t.account_id, t.trans_date)
               t.account_id, t.trans_date, t.balance_after AS eod_balance
        FROM tx t
        WHERE NOT EXISTS (SELECT 1 FROM tx o
                          WHERE o.account_id = t.account_id AND o.trans_date = t.trans_date
                            AND o.trans_id <> t.trans_id AND o.opening_balance = t.balance_after)
        ORDER BY t.account_id, t.trans_date, t.trans_id
    ),
    daily AS (
        SELECT account_id, trans_date, sum(signed_amount) AS net_flow
        FROM core.transaction GROUP BY account_id, trans_date
    ),
    chk AS (
        SELECT d.net_flow, e.eod_balance,
               lag(e.eod_balance) OVER (PARTITION BY d.account_id ORDER BY d.trans_date) AS prev_eod
        FROM daily d JOIN eod e USING (account_id, trans_date)
    )
    SELECT v_run_at, 'daily_balance_reconciliation', 'core.transaction', 'WARNING',
           count(*) FILTER (WHERE abs(prev_eod + net_flow - eod_balance) >= 1),
           count(*),
           round(1 - count(*) FILTER (WHERE abs(prev_eod + net_flow - eod_balance) >= 1)::numeric / count(*), 4),
           0.90, NULL,
           'share of account-days where prior EOD balance + net flow = EOD balance (+/- 1 CZK)'
    FROM chk WHERE prev_eod IS NOT NULL;

    -- ------------------------------------------------------------------
    -- 8. Informational profiling
    -- ------------------------------------------------------------------
    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'negative_balance_rows', 'core.transaction', 'INFO',
           count(*) FILTER (WHERE balance_after < 0), count(*), NULL, 'overdrawn after transaction (valid but monitored)'
    FROM core.transaction;

    INSERT INTO audit.dq_result (run_at, check_name, table_name, severity, failed_rows, total_rows, passed, details)
    SELECT v_run_at, 'district_missing_stats', 'core.district', 'INFO',
           count(*) FILTER (WHERE unemployment_rate_95 IS NULL OR crimes_95 IS NULL), count(*), NULL,
           'districts with 1995 stats not reported (source value ?)'
    FROM core.district;

    -- ------------------------------------------------------------------
    -- Resolve pass/fail: CRITICAL/WARNING pass if no failures, or if a metric
    -- check meets its threshold. INFO checks always pass.
    -- ------------------------------------------------------------------
    UPDATE audit.dq_result
       SET passed = CASE
                      WHEN severity = 'INFO'       THEN TRUE
                      WHEN threshold IS NOT NULL   THEN metric_value >= threshold
                      ELSE failed_rows = 0
                    END
     WHERE run_at = v_run_at AND passed IS NULL;
END;
$$;
