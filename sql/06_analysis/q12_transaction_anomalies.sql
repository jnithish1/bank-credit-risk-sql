/* =============================================================================
   Q12 - Unusual withdrawals (behavioural anomaly detection)
   -----------------------------------------------------------------------------
   Business question
     Which outgoing transactions are far outside the customer's OWN normal
     behaviour? A 50,000 CZK withdrawal is routine for some clients and a red
     flag for others, so a fixed amount threshold is the wrong tool. Flagged
     items go to the fraud / AML review queue.
   Stakeholder: Fraud & Financial Crime
   Techniques: time-based window frame
               RANGE BETWEEN INTERVAL '180 days' PRECEDING AND INTERVAL '1 day' PRECEDING
               (only the customer's PAST, so no look-ahead), rolling mean and
               standard deviation, z-scores, minimum-history guard, ROW_NUMBER
               for a ranked review queue
   Rule: debit > 5 standard deviations above the client's 180-day mean,
         at least 10 prior debits of history, and amount >= 20,000 CZK.
         Thresholds tuned to ~1,770 alerts over 6 years (about one per
         business day), a volume a small review team can actually clear.
   ============================================================================= */

WITH debits AS (
    SELECT trans_id, account_id, trans_date, operation, purpose, amount, balance_after,
           avg(amount)         OVER w AS hist_mean,
           stddev_samp(amount) OVER w AS hist_std,
           count(*)            OVER w AS hist_n
    FROM core.transaction
    WHERE direction = 'debit'
      AND purpose IS DISTINCT FROM 'statement_fee'
      AND purpose IS DISTINCT FROM 'penalty_interest'
    WINDOW w AS (PARTITION BY account_id ORDER BY trans_date
                 RANGE BETWEEN INTERVAL '180 days' PRECEDING AND INTERVAL '1 day' PRECEDING)
),
flagged AS (
    SELECT d.*,
           (amount - hist_mean) / NULLIF(hist_std, 0) AS z_score
    FROM debits d
    WHERE hist_n >= 10
      AND amount >= 20000
      AND (amount - hist_mean) / NULLIF(hist_std, 0) > 5
)
SELECT ROW_NUMBER() OVER (ORDER BY z_score DESC)            AS review_priority,
       f.trans_id,
       f.account_id,
       f.trans_date,
       COALESCE(f.operation, 'n/a')                         AS channel,
       round(f.amount)                                      AS amount_czk,
       round(f.hist_mean)                                   AS usual_debit_czk,
       round(f.z_score, 1)                                  AS z_score,
       round(f.amount / NULLIF(f.hist_mean, 0), 1)          AS x_usual_amount,
       round(f.balance_after)                               AS balance_after_czk,
       -- share of all flagged items on the same account (repeat-offender signal)
       count(*) OVER (PARTITION BY f.account_id)            AS flags_on_account
FROM flagged f
ORDER BY review_priority;
