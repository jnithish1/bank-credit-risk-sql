/* =============================================================================
   02_facts.sql
   Fact tables at two grains + a loan fact view.

   fact_account_day   : one row per account per day with activity
                        (end-of-day balance reconstructed, flows, fee/penalty counts)
   fact_account_month : one row per account per month from opening to as-of date,
                        INCLUDING months with no activity (balance carried forward
                        with a gaps-and-islands technique)
   fact_loan          : one row per loan with account/owner/district context
   ============================================================================= */

-- ---------------------------------------------------------------------------
-- fact_account_day
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.fact_account_day AS
WITH tx AS (
    SELECT trans_id, account_id, trans_date, direction, amount, signed_amount,
           balance_after, purpose,
           balance_after - signed_amount AS opening_balance
    FROM core.transaction
),
eod AS (
    -- The source has no intra-day sequence. The closing transaction of a day is
    -- the one whose resulting balance is NOT the opening balance of another
    -- same-day transaction ("has_successor" = false). Written as a join +
    -- aggregate so the planner can use a single hash join over 1M rows
    -- instead of a correlated subquery per row. Ties fall back to max trans_id.
    SELECT DISTINCT ON (t.account_id, t.trans_date)
           t.account_id, t.trans_date, t.balance_after AS eod_balance
    FROM tx t
    LEFT JOIN tx o
           ON o.account_id      = t.account_id
          AND o.trans_date      = t.trans_date
          AND o.opening_balance = t.balance_after
          AND o.trans_id       <> t.trans_id
    GROUP BY t.account_id, t.trans_date, t.trans_id, t.balance_after
    ORDER BY t.account_id, t.trans_date,
             count(o.trans_id) > 0,          -- FALSE (no successor) sorts first
             t.trans_id DESC
),
flows AS (
    SELECT account_id, trans_date,
           count(*)                                                    AS n_transactions,
           count(*) FILTER (WHERE purpose IS DISTINCT FROM 'interest_credited'
                              AND purpose IS DISTINCT FROM 'statement_fee'
                              AND purpose IS DISTINCT FROM 'penalty_interest') AS n_client_transactions,
           COALESCE(sum(amount) FILTER (WHERE direction = 'credit'), 0) AS inflow,
           COALESCE(sum(amount) FILTER (WHERE direction = 'debit'),  0) AS outflow,
           min(balance_after)                                          AS min_balance,
           count(*) FILTER (WHERE purpose = 'penalty_interest')        AS n_penalties,
           COALESCE(sum(amount) FILTER (WHERE purpose = 'pension'), 0)  AS pension_inflow
    FROM tx
    GROUP BY account_id, trans_date
)
SELECT f.account_id,
       to_char(f.trans_date, 'YYYYMMDD')::int AS date_key,
       f.trans_date,
       f.n_transactions,
       f.n_client_transactions,
       f.inflow,
       f.outflow,
       f.inflow - f.outflow                  AS net_flow,
       e.eod_balance,
       f.min_balance,
       f.n_penalties,
       f.pension_inflow
FROM flows f
JOIN eod e USING (account_id, trans_date);

CREATE UNIQUE INDEX ux_fact_account_day ON mart.fact_account_day (account_id, trans_date);
COMMENT ON MATERIALIZED VIEW mart.fact_account_day IS 'Grain: account x day with at least one transaction.';

-- ---------------------------------------------------------------------------
-- fact_account_month (dense: every month of every account's life)
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.fact_account_month AS
WITH spine AS (
    SELECT a.account_id, gs::date AS month_start
    FROM core.account a
    CROSS JOIN LATERAL generate_series(date_trunc('month', a.opened_date),
                                       date_trunc('month', mart.fn_as_of_date()),
                                       INTERVAL '1 month') AS gs
),
monthly AS (
    SELECT account_id,
           date_trunc('month', trans_date)::date                  AS month_start,
           sum(n_transactions)                                     AS n_transactions,
           sum(n_client_transactions)                              AS n_client_transactions,
           sum(inflow)                                             AS inflow,
           sum(outflow)                                            AS outflow,
           min(min_balance)                                        AS min_balance,
           sum(n_penalties)                                        AS n_penalties,
           sum(pension_inflow)                                     AS pension_inflow,
           (array_agg(eod_balance ORDER BY trans_date DESC))[1]    AS month_end_balance
    FROM mart.fact_account_day
    GROUP BY account_id, date_trunc('month', trans_date)
),
joined AS (
    SELECT s.account_id, s.month_start, m.n_transactions, m.n_client_transactions,
           m.inflow, m.outflow, m.min_balance, m.n_penalties, m.pension_inflow,
           m.month_end_balance,
           -- Gaps-and-islands: a running count of non-null balances creates one
           -- group per "island" (an active month followed by its quiet months).
           count(m.month_end_balance) OVER (PARTITION BY s.account_id
                                            ORDER BY s.month_start) AS balance_grp
    FROM spine s
    LEFT JOIN monthly m USING (account_id, month_start)
)
SELECT account_id,
       month_start,
       (date_part('year',  age(month_start, date_trunc('month', min(month_start) OVER w0))) * 12
      + date_part('month', age(month_start, date_trunc('month', min(month_start) OVER w0))))::int
                                                            AS months_since_open,
       COALESCE(n_transactions, 0)                          AS n_transactions,
       COALESCE(n_client_transactions, 0)                   AS n_client_transactions,
       COALESCE(n_client_transactions, 0) > 0               AS is_active,
       COALESCE(inflow, 0)                                  AS inflow,
       COALESCE(outflow, 0)                                 AS outflow,
       COALESCE(inflow, 0) - COALESCE(outflow, 0)           AS net_flow,
       COALESCE(n_penalties, 0)                             AS n_penalties,
       COALESCE(pension_inflow, 0)                          AS pension_inflow,
       -- carry the last known balance forward through quiet months
       first_value(month_end_balance) OVER (PARTITION BY account_id, balance_grp
                                            ORDER BY month_start) AS month_end_balance,
       COALESCE(min_balance,
                first_value(month_end_balance) OVER (PARTITION BY account_id, balance_grp
                                                     ORDER BY month_start)) AS min_balance
FROM joined
WINDOW w0 AS (PARTITION BY account_id);

CREATE UNIQUE INDEX ux_fact_account_month ON mart.fact_account_month (account_id, month_start);
CREATE INDEX ix_fact_account_month_month ON mart.fact_account_month (month_start);
COMMENT ON MATERIALIZED VIEW mart.fact_account_month IS
  'Grain: account x calendar month from opening month to as-of month (dense, balances carried forward).';

-- ---------------------------------------------------------------------------
-- fact_loan
-- ---------------------------------------------------------------------------
CREATE VIEW mart.fact_loan AS
SELECT l.loan_id,
       l.account_id,
       l.granted_date,
       date_trunc('year', l.granted_date)::date                   AS granted_year,
       l.amount,
       l.duration_months,
       l.monthly_payment,
       l.status_code,
       l.status_label,
       l.is_default,
       l.is_active,
       CASE WHEN l.amount <  50000 THEN '1. <50k'
            WHEN l.amount < 100000 THEN '2. 50-100k'
            WHEN l.amount < 200000 THEN '3. 100-200k'
            WHEN l.amount < 400000 THEN '4. 200-400k'
            ELSE                        '5. 400k+' END             AS amount_band,
       a.owner_client_id,
       a.owner_gender,
       a.owner_age_at_open,
       date_part('year', age(l.granted_date, c.birth_date))::int  AS owner_age_at_loan,
       a.district_id,
       a.district_name,
       a.region,
       a.statement_frequency,
       a.has_card,
       a.card_type,
       a.card_issued_date,
       a.has_disponent,
       (l.granted_date - a.opened_date)                           AS days_account_open_before_loan
FROM core.loan l
JOIN mart.dim_account a USING (account_id)
JOIN core.client c      ON c.client_id = a.owner_client_id;
COMMENT ON VIEW mart.fact_loan IS 'Grain: one row per loan.';

-- ---------------------------------------------------------------------------
-- Refresh orchestration (dependency order). The loan feature and scorecard
-- MVs are created in later files; plpgsql only resolves them at CALL time. CONCURRENTLY keeps the MVs
-- readable by dashboards while they refresh.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE mart.sp_refresh_mart(p_concurrently BOOLEAN DEFAULT FALSE)
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT := CASE WHEN p_concurrently THEN 'CONCURRENTLY ' ELSE '' END;
    v_mv   TEXT;
    v_run  BIGINT;
BEGIN
    FOREACH v_mv IN ARRAY ARRAY['mart.dim_account', 'mart.fact_account_day', 'mart.fact_account_month',
                              'mart.loan_features', 'mart.loan_scorecard_bins', 'mart.loan_scorecard'] LOOP
        v_run := audit.fn_log_start('refresh_mart', v_mv);
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || v_mode || v_mv;
        PERFORM audit.fn_log_end(v_run, NULL);
    END LOOP;
END;
$$;
