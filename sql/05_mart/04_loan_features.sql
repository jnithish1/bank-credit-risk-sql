/* =============================================================================
   04_loan_features.sql
   "Feature store" for credit-risk analysis: one row per loan describing the
   borrower's account behaviour BEFORE the loan was granted.

   Point-in-time correctness: every feature uses only data strictly before
   granted_date, so the features are exactly what an underwriter could have
   seen on the application day (no look-ahead / target leakage).
   Every account has >= 102 days of history before its loan, so the 90-day
   window is always fully observed.
   ============================================================================= */

CREATE MATERIALIZED VIEW mart.loan_features AS
WITH loans AS (
    SELECT loan_id, account_id, granted_date, amount, duration_months,
           monthly_payment, is_default, status_code,
           granted_date - 90                          AS win_start,
           date_trunc('month', granted_date)::date    AS grant_month
    FROM core.loan
),
-- Balance "change points" inside the 90-day window, plus the balance carried
-- into the window (last EOD balance before it starts).
points AS (
    SELECT l.loan_id, l.win_start AS pt_date, ob.eod_balance AS balance
    FROM loans l
    CROSS JOIN LATERAL (
        SELECT f.eod_balance FROM mart.fact_account_day f
        WHERE f.account_id = l.account_id AND f.trans_date < l.win_start
        ORDER BY f.trans_date DESC LIMIT 1
    ) ob
    UNION ALL
    SELECT l.loan_id, f.trans_date, f.eod_balance
    FROM loans l
    JOIN mart.fact_account_day f
      ON f.account_id = l.account_id
     AND f.trans_date >= l.win_start AND f.trans_date < l.granted_date
),
-- Time-weighted average daily balance: each balance counts for the number
-- of days it was held, not once per transaction.
weighted AS (
    SELECT p.loan_id, p.balance,
           LEAD(p.pt_date, 1, l.granted_date) OVER (PARTITION BY p.loan_id ORDER BY p.pt_date)
             - p.pt_date AS days_held
    FROM points p JOIN loans l USING (loan_id)
),
balance_feats AS (
    SELECT loan_id,
           round(sum(balance * days_held) / NULLIF(sum(days_held), 0), 2) AS twab_90d,
           min(balance)                                                   AS min_eod_balance_90d
    FROM weighted GROUP BY loan_id
),
-- Monthly behaviour in the 3 complete calendar months before the grant month
flow_feats AS (
    SELECT l.loan_id,
           count(*)                                       AS history_months_used,
           round(avg(m.inflow), 2)                        AS avg_monthly_inflow_3m,
           round(avg(m.outflow), 2)                       AS avg_monthly_outflow_3m,
           round(stddev_samp(m.inflow) / NULLIF(avg(m.inflow), 0), 3) AS inflow_cv_3m,
           round(avg(m.n_client_transactions), 1)         AS avg_monthly_tx_3m,
           min(m.min_balance)                             AS min_intraday_balance_3m,
           sum(m.n_penalties)                             AS n_penalties_3m,
           bool_or(m.pension_inflow > 0)                  AS receives_pension
    FROM loans l
    JOIN mart.fact_account_month m
      ON m.account_id = l.account_id
     AND m.month_start >= l.grant_month - INTERVAL '3 months'
     AND m.month_start <  l.grant_month
    GROUP BY l.loan_id
)
SELECT l.loan_id, l.account_id, l.granted_date, l.amount, l.duration_months,
       l.monthly_payment, l.status_code, l.is_default,
       b.twab_90d,
       b.min_eod_balance_90d,
       f.avg_monthly_inflow_3m,
       f.avg_monthly_outflow_3m,
       f.inflow_cv_3m,
       f.avg_monthly_tx_3m,
       f.min_intraday_balance_3m,
       f.n_penalties_3m,
       f.receives_pension,
       f.history_months_used,
       -- Affordability ratios an underwriter would use
       round(l.monthly_payment / NULLIF(f.avg_monthly_inflow_3m, 0), 3) AS payment_to_income,
       round(b.twab_90d / l.monthly_payment, 2)                         AS balance_to_payment,
       round(l.amount / NULLIF(f.avg_monthly_inflow_3m, 0), 2)          AS loan_to_monthly_income
FROM loans l
JOIN balance_feats b USING (loan_id)
JOIN flow_feats    f USING (loan_id);

CREATE UNIQUE INDEX ux_loan_features ON mart.loan_features (loan_id);
COMMENT ON MATERIALIZED VIEW mart.loan_features IS
  'Grain: one row per loan. Point-in-time behavioural features as of the day before loan approval.';

-- ---------------------------------------------------------------------------
-- Long (unpivoted) form of the numeric features: one row per loan x feature.
-- Lets every feature be profiled with ONE generic query instead of
-- copy-pasting logic per column.
-- ---------------------------------------------------------------------------
CREATE VIEW mart.v_loan_feature_long AS
SELECT lf.loan_id, lf.is_default, v.feature, v.value
FROM mart.loan_features lf
CROSS JOIN LATERAL (VALUES
    ('avg_daily_balance_90d',   lf.twab_90d),
    ('min_balance_90d',         lf.min_eod_balance_90d),
    ('min_intraday_balance_3m', lf.min_intraday_balance_3m),
    ('monthly_income_3m',       lf.avg_monthly_inflow_3m),
    ('monthly_spend_3m',        lf.avg_monthly_outflow_3m),
    ('income_volatility_cv',    lf.inflow_cv_3m),
    ('monthly_transactions',    lf.avg_monthly_tx_3m),
    ('instalment_to_income',    lf.payment_to_income),
    ('balance_to_instalment',   lf.balance_to_payment),
    ('loan_to_monthly_income',  lf.loan_to_monthly_income),
    ('loan_amount',             lf.amount),
    ('monthly_instalment',      lf.monthly_payment)
) AS v(feature, value)
WHERE v.value IS NOT NULL;
