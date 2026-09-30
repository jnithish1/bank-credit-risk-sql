/* =============================================================================
   Q03 - Did bad borrowers look different BEFORE they got the loan?
   -----------------------------------------------------------------------------
   Business question
     Using only information available on the approval date, how did the account
     behaviour of borrowers who later defaulted differ from those who repaid?
     This tells underwriting which signals to add to the approval checklist.
   Stakeholder: Credit Risk / Underwriting
   Techniques: point-in-time feature store (mart.loan_features), medians via
               PERCENTILE_CONT, FILTER, side-by-side comparison with ratios
   ============================================================================= */

WITH f AS (
    SELECT CASE WHEN is_default THEN 'defaulted' ELSE 'repaying / repaid' END AS outcome, *
    FROM mart.loan_features
),
agg AS (
    SELECT outcome,
           count(*)                                                                 AS n_loans,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY twab_90d)                    AS median_avg_balance_90d,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY min_eod_balance_90d)         AS median_min_balance_90d,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY avg_monthly_inflow_3m)       AS median_monthly_income,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY payment_to_income)           AS median_payment_to_income,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY balance_to_payment)          AS median_balance_to_payment,
           avg(inflow_cv_3m)                                                        AS avg_income_volatility,
           100.0 * count(*) FILTER (WHERE min_intraday_balance_3m < 0) / count(*)   AS pct_overdrawn_3m,
           100.0 * count(*) FILTER (WHERE n_penalties_3m > 0) / count(*)            AS pct_penalty_interest_3m,
           100.0 * count(*) FILTER (WHERE balance_to_payment < 5) / count(*)        AS pct_balance_under_5x_payment
    FROM f GROUP BY outcome
),
metrics AS (
    -- Unpivot to one row per metric so the two groups sit side by side
    SELECT a.outcome, m.metric, m.sort_order, m.value
    FROM agg a
    CROSS JOIN LATERAL (VALUES
        (1,  'Loans',                                   a.n_loans::numeric),
        (2,  'Median avg daily balance, 90d (CZK)',     a.median_avg_balance_90d::numeric),
        (3,  'Median lowest balance, 90d (CZK)',        a.median_min_balance_90d::numeric),
        (4,  'Median monthly income (CZK)',             a.median_monthly_income::numeric),
        (5,  'Median instalment / income',              a.median_payment_to_income::numeric),
        (6,  'Median balance / instalment (x)',         a.median_balance_to_payment::numeric),
        (7,  'Avg income volatility (CV)',              a.avg_income_volatility),
        (8,  '% overdrawn in prior 3 months',           a.pct_overdrawn_3m),
        (9,  '% charged penalty interest, prior 3m',    a.pct_penalty_interest_3m),
        (10, '% with balance < 5x instalment',          a.pct_balance_under_5x_payment)
    ) AS m(sort_order, metric, value)
)
SELECT metric,
       round(max(value) FILTER (WHERE outcome = 'defaulted'), 2)          AS defaulted,
       round(max(value) FILTER (WHERE outcome = 'repaying / repaid'), 2)  AS repaying_or_repaid,
       round(max(value) FILTER (WHERE outcome = 'defaulted')
           / NULLIF(max(value) FILTER (WHERE outcome = 'repaying / repaid'), 0), 2) AS ratio_bad_to_good
FROM metrics
GROUP BY metric, sort_order
ORDER BY sort_order;
