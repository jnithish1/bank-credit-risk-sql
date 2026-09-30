/* =============================================================================
   Q06 - Repayment behaviour: schedule vs. actual instalments
   -----------------------------------------------------------------------------
   Business question
     For every loan, how many instalments were due by the as-of date versus
     actually paid, how far in arrears is it, and does the timing of the FIRST
     payment give an early-warning signal for collections?
   Stakeholder: Collections / Early-arrears team
   Techniques: RECURSIVE CTE (amortisation schedule via mart.fn_loan_schedule),
               CROSS JOIN LATERAL, LAG for gaps between payments,
               PERCENTILE_CONT, FILTER
   ============================================================================= */

WITH schedule AS (
    SELECT l.loan_id, count(*) AS instalments_due
    FROM core.loan l
    CROSS JOIN LATERAL mart.fn_loan_schedule(l.loan_id) s
    WHERE s.due_month <= date_trunc('month', mart.fn_as_of_date())
    GROUP BY l.loan_id
),
payments AS (
    SELECT l.loan_id, t.trans_date, t.amount,
           -- months since the previous instalment (1 = on rhythm)
           (date_part('year',  age(date_trunc('month', t.trans_date),
                                   date_trunc('month', LAG(t.trans_date) OVER w))) * 12
          + date_part('month', age(date_trunc('month', t.trans_date),
                                   date_trunc('month', LAG(t.trans_date) OVER w))))::int AS months_since_prev
    FROM core.loan l
    JOIN core.transaction t
      ON t.account_id = l.account_id
     AND t.purpose    = 'loan_payment'
     AND t.trans_date >= l.granted_date
    WINDOW w AS (PARTITION BY l.loan_id ORDER BY t.trans_date)
),
per_loan AS (
    SELECT l.loan_id, l.status_label, l.is_default, l.monthly_payment,
           COALESCE(s.instalments_due, 0)                             AS instalments_due,
           count(p.trans_date)                                        AS instalments_paid,
           greatest(COALESCE(s.instalments_due, 0) * l.monthly_payment
                    - COALESCE(sum(p.amount), 0), 0)                  AS arrears_czk,
           COALESCE(max(p.months_since_prev) - 1, 0)                  AS longest_payment_gap_months,
           min(p.trans_date) - l.granted_date                         AS days_to_first_payment
    FROM core.loan l
    LEFT JOIN schedule s USING (loan_id)
    LEFT JOIN payments p USING (loan_id)
    GROUP BY l.loan_id, l.status_label, l.is_default, l.monthly_payment, s.instalments_due
)
SELECT status_label,
       count(*)                                                               AS loans,
       round(100.0 * sum(instalments_paid) / NULLIF(sum(instalments_due), 0), 1) AS pct_due_instalments_paid,
       round(avg(arrears_czk))                                                AS avg_arrears_czk,
       round(sum(arrears_czk) / 1e6, 2)                                       AS total_arrears_czk_m,
       round(100.0 * count(*) FILTER (WHERE longest_payment_gap_months > 0) / count(*), 1) AS pct_with_skipped_month,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY days_to_first_payment)     AS median_days_to_first_payment,
       round(100.0 * count(*) FILTER (WHERE days_to_first_payment > 40) / count(*), 1)     AS pct_first_payment_after_40d
FROM per_loan
GROUP BY status_label
ORDER BY CASE status_label WHEN 'finished_ok' THEN 1 WHEN 'running_ok' THEN 2
                           WHEN 'running_in_debt' THEN 3 ELSE 4 END;
