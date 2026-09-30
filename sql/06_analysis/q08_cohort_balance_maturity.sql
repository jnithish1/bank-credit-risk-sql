/* =============================================================================
   Q08 - Cohort balance maturity curve
   -----------------------------------------------------------------------------
   Business question
     How quickly do new accounts build deposits, and do recent acquisition
     cohorts grow balances faster or slower than older ones? This sizes the
     deposit value of a new customer over time (input to acquisition-cost
     targets).
   Stakeholder: Product / Finance (customer lifetime value)
   Techniques: dense account-month fact with carried-forward balances,
               cohort pivot with FILTER, milestone denominators only include
               accounts old enough to reach each milestone (no right-censoring)
   Note: nearly every account is active every month in this extract (standing
   orders and cash withdrawals keep them transacting), so the meaningful
   lifecycle signal is balance growth, not activity churn.
   ============================================================================= */

WITH cohort AS (
    SELECT m.account_id,
           extract(year FROM a.opened_date)::int AS cohort_year,
           m.months_since_open,
           m.month_end_balance,
           m.n_client_transactions
    FROM mart.fact_account_month m
    JOIN core.account a USING (account_id)
)
SELECT cohort_year,
       count(DISTINCT account_id)                                                     AS accounts_opened,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 0))            AS bal_m0,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 3))            AS bal_m3,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 6))            AS bal_m6,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 12))           AS bal_m12,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 24))           AS bal_m24,
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 36))           AS bal_m36,
       round(avg(n_client_transactions) FILTER (WHERE months_since_open BETWEEN 1 AND 12), 1) AS tx_per_month_year1,
       -- balance at 12 months relative to 3 months: how much growth after onboarding
       round(avg(month_end_balance) FILTER (WHERE months_since_open = 12)
           / NULLIF(avg(month_end_balance) FILTER (WHERE months_since_open = 3), 0), 2)  AS growth_m3_to_m12
FROM cohort
GROUP BY cohort_year
ORDER BY cohort_year;
