/* =============================================================================
   Q01 - Executive portfolio snapshot (as of 31-Dec-1998)
   -----------------------------------------------------------------------------
   Business question
     What does the bank's retail book look like today: customer base, deposits,
     lending exposure, credit quality and product penetration?
   Stakeholder: Head of Retail Banking (monthly board pack)
   Techniques: CTEs, conditional aggregation with FILTER, ordered-set
               aggregates (PERCENTILE_CONT), scalar subqueries
   ============================================================================= */

WITH latest_balance AS (
    SELECT account_id, month_end_balance
    FROM mart.fact_account_month
    WHERE month_start = date_trunc('month', mart.fn_as_of_date())
),
recent_activity AS (
    SELECT account_id, bool_or(is_active) AS active_6m
    FROM mart.fact_account_month
    WHERE month_start > mart.fn_as_of_date() - INTERVAL '6 months'
    GROUP BY account_id
),
loans AS (
    SELECT count(*)                                        AS n_loans,
           sum(amount)                                     AS loan_book,
           count(*) FILTER (WHERE is_active)               AS n_active_loans,
           count(*) FILTER (WHERE is_default)              AS n_bad_loans,
           sum(amount) FILTER (WHERE is_default)           AS bad_loan_amount
    FROM core.loan
)
SELECT
    (SELECT count(*) FROM core.client)                                      AS clients,
    count(*)                                                                AS accounts,
    count(*) FILTER (WHERE r.active_6m)                                     AS active_accounts_6m,
    round(100.0 * count(*) FILTER (WHERE r.active_6m) / count(*), 1)        AS pct_active_6m,
    round(sum(b.month_end_balance) / 1e6, 1)                                AS total_deposits_czk_m,
    round(avg(b.month_end_balance))                                         AS avg_balance_czk,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY b.month_end_balance)::numeric) AS median_balance_czk,
    count(*) FILTER (WHERE b.month_end_balance < 0)                         AS overdrawn_accounts,
    l.n_loans,
    round(l.loan_book / 1e6, 1)                                             AS loan_book_czk_m,
    l.n_active_loans,
    l.n_bad_loans,
    round(100.0 * l.n_bad_loans / l.n_loans, 1)                             AS bad_loan_rate_pct_count,
    round(100.0 * l.bad_loan_amount / l.loan_book, 1)                       AS bad_loan_rate_pct_value,
    round(100.0 * count(*) FILTER (WHERE a.has_card) / count(*), 1)         AS card_penetration_pct,
    round(100.0 * count(*) FILTER (WHERE a.has_loan) / count(*), 1)         AS loan_penetration_pct
FROM mart.dim_account a
JOIN latest_balance  b USING (account_id)
JOIN recent_activity r USING (account_id)
CROSS JOIN loans l
GROUP BY l.n_loans, l.loan_book, l.n_active_loans, l.n_bad_loans, l.bad_loan_amount;
