/* =============================================================================
   Q09 - Deposit growth trend (monthly, bank-wide)
   -----------------------------------------------------------------------------
   Business question
     How have total deposits and the customer base grown month by month?
     What are month-over-month and year-over-year growth rates, smoothed for
     noise? (Treasury uses this for liquidity/funding planning.)
   Stakeholder: Finance / Treasury
   Techniques: LAG for MoM and YoY, moving average with a ROWS frame,
               running total with an unbounded frame, NULLIF-safe division
   ============================================================================= */

WITH monthly AS (
    SELECT month_start,
           count(*)                                           AS open_accounts,
           count(*) FILTER (WHERE months_since_open = 0)      AS new_accounts,
           sum(month_end_balance)                             AS total_deposits,
           sum(inflow)                                        AS total_inflow,
           sum(outflow)                                       AS total_outflow
    FROM mart.fact_account_month
    GROUP BY month_start
)
SELECT month_start,
       open_accounts,
       new_accounts,
       round(total_deposits / 1e6, 2)                                             AS deposits_czk_m,
       round(100 * (total_deposits / NULLIF(LAG(total_deposits) OVER w, 0) - 1), 1)     AS mom_growth_pct,
       round(100 * (total_deposits / NULLIF(LAG(total_deposits, 12) OVER w, 0) - 1), 1) AS yoy_growth_pct,
       round(avg(total_deposits) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) / 1e6, 2) AS deposits_3m_avg_czk_m,
       round((total_inflow - total_outflow) / 1e6, 2)                             AS net_flow_czk_m,
       round(sum(total_inflow - total_outflow) OVER (w ROWS UNBOUNDED PRECEDING) / 1e6, 2) AS cumulative_net_flow_czk_m,
       round(total_deposits / open_accounts)                                      AS deposits_per_account
FROM monthly
WINDOW w AS (ORDER BY month_start)
ORDER BY month_start;
