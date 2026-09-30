/* =============================================================================
   Q07 - RFM customer segmentation (last 12 months)
   -----------------------------------------------------------------------------
   Business question
     Which customers are the bank's most valuable and engaged, which are
     slipping away, and how do the segments differ in balances and product
     holdings? Output feeds CRM campaign targeting.
   Stakeholder: Marketing / CRM
   Techniques: NTILE quintile scoring, CASE-based segment rules,
               client-initiated activity only (bank fees/interest excluded)
   R = days since last client-initiated transaction
   F = number of client-initiated transactions
   M = total money moved through the account (inflow + outflow)
   Volume trend (last 3 months vs prior 9, monthly average) validates the
   'cooling' label with a behavioural signal, not just recency.
   ============================================================================= */

WITH window_12m AS (
    SELECT f.account_id,
           mart.fn_as_of_date() - max(f.trans_date) FILTER (WHERE f.n_client_transactions > 0) AS recency_days,
           sum(f.n_client_transactions)                                                       AS frequency,
           sum(f.inflow + f.outflow)                                                          AS monetary,
           -- engagement trend: monthly volume in the last 3 months vs the 9 before
           (sum(f.inflow + f.outflow) FILTER (WHERE f.trans_date >  mart.fn_as_of_date() - INTERVAL '3 months') / 3)
             / NULLIF(sum(f.inflow + f.outflow) FILTER (WHERE f.trans_date <= mart.fn_as_of_date() - INTERVAL '3 months') / 9, 0)
             - 1                                                                              AS volume_trend
    FROM mart.fact_account_day f
    WHERE f.trans_date > mart.fn_as_of_date() - INTERVAL '12 months'
    GROUP BY f.account_id
),
scored AS (
    SELECT w.*,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- recent = 5
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,
           NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM window_12m w
    WHERE recency_days IS NOT NULL
),
segmented AS (
    SELECT s.*,
           CASE
             WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1. Champions'
             WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN '2. Loyal'
             WHEN r_score >= 4 AND m_score <= 2                  THEN '3. Low-value active'
             WHEN r_score <= 2 AND m_score >= 3                  THEN '4. Cooling (high value)'
             WHEN r_score <= 2                                   THEN '5. Hibernating'
             ELSE                                                     '6. Needs attention'
           END AS rfm_segment
    FROM scored s
)
SELECT sg.rfm_segment,
       count(*)                                                        AS accounts,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)              AS pct_of_accounts,
       round(avg(sg.recency_days))                                     AS avg_recency_days,
       round(avg(sg.frequency))                                        AS avg_transactions_12m,
       round(avg(sg.monetary) / 1000)                                  AS avg_volume_12m_czk_k,
       round(100 * percentile_cont(0.5) WITHIN GROUP (ORDER BY sg.volume_trend)::numeric, 1) AS median_volume_trend_pct,
       round(avg(b.month_end_balance))                                 AS avg_balance_czk,
       round(100.0 * sum(b.month_end_balance) / sum(sum(b.month_end_balance)) OVER (), 1) AS pct_of_deposits,
       round(100.0 * avg(a.has_card::int), 1)                          AS pct_with_card,
       round(100.0 * avg(a.has_loan::int), 1)                          AS pct_with_loan
FROM segmented sg
JOIN mart.dim_account a USING (account_id)
JOIN mart.fact_account_month b
  ON b.account_id = sg.account_id
 AND b.month_start = date_trunc('month', mart.fn_as_of_date())
GROUP BY sg.rfm_segment
ORDER BY sg.rfm_segment;
