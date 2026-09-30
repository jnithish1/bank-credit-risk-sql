/* =============================================================================
   Q13 - Cross-sell opportunities: who should get a card or loan offer?
   -----------------------------------------------------------------------------
   Business question
     Card and loan penetration is low. Which customers look most like our
     existing good card/loan customers but don't hold the product yet?
     Produce a ranked, region-balanced call list for the sales team
     (top 5 per region), excluding anyone with recent overdraft/penalty issues.
   Stakeholder: Sales / Product
   Techniques: product-holding matrix with CUBE, look-alike threshold taken
               from the MEDIAN of good existing borrowers (data-driven, not a
               guessed number), suitability exclusions with NOT EXISTS,
               ROW_NUMBER() partitioned by region for a balanced list
   Output: one row per recommended client (top 5 per region).
   ============================================================================= */

WITH profile AS (
    SELECT a.account_id, a.owner_client_id, a.region, a.district_name,
           a.has_card, a.has_loan, a.tenure_months,
           avg(m.month_end_balance) FILTER (WHERE m.month_start > mart.fn_as_of_date() - INTERVAL '6 months') AS avg_balance_6m,
           avg(m.inflow)            FILTER (WHERE m.month_start > mart.fn_as_of_date() - INTERVAL '6 months') AS avg_income_6m,
           min(m.min_balance)       FILTER (WHERE m.month_start > mart.fn_as_of_date() - INTERVAL '12 months') AS min_balance_12m,
           sum(m.n_penalties)       FILTER (WHERE m.month_start > mart.fn_as_of_date() - INTERVAL '12 months') AS penalties_12m
    FROM mart.dim_account a
    JOIN mart.fact_account_month m USING (account_id)
    GROUP BY a.account_id, a.owner_client_id, a.region, a.district_name,
             a.has_card, a.has_loan, a.tenure_months
),
-- Benchmark: the typical balance/income of customers who repay their loans well
benchmark AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY p.avg_balance_6m)::numeric AS good_borrower_median_balance,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY p.avg_income_6m)::numeric  AS good_borrower_median_income
    FROM profile p
    JOIN core.loan l USING (account_id)
    WHERE NOT l.is_default
),
candidates AS (
    SELECT p.*,
           CASE WHEN NOT p.has_loan AND NOT p.has_card THEN 'card + loan'
                WHEN NOT p.has_loan                     THEN 'loan'
                ELSE                                         'card' END AS offer,
           -- simple propensity index: how far above the good-borrower median
           round(p.avg_balance_6m / b.good_borrower_median_balance
               + p.avg_income_6m  / b.good_borrower_median_income, 2) AS propensity_index
    FROM profile p CROSS JOIN benchmark b
    WHERE (NOT p.has_loan OR NOT p.has_card)
      AND p.avg_balance_6m >= b.good_borrower_median_balance
      AND p.avg_income_6m  >= b.good_borrower_median_income
      AND p.tenure_months  >= 12
      AND COALESCE(p.penalties_12m, 0) = 0
      AND p.min_balance_12m > 0
      -- suitability: the account owner must be an adult
      AND NOT EXISTS (SELECT 1 FROM mart.dim_client c
                      WHERE c.client_id = p.owner_client_id AND c.age < 18)
),
ranked AS (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY c.region ORDER BY c.propensity_index DESC) AS rank_in_region,
           count(*)     OVER ()                                                       AS total_eligible
    FROM candidates c
)
SELECT region, rank_in_region, owner_client_id AS client_id, account_id, district_name,
       offer, round(avg_balance_6m) AS avg_balance_6m, round(avg_income_6m) AS avg_income_6m,
       tenure_months, propensity_index, total_eligible
FROM ranked
WHERE rank_in_region <= 5
ORDER BY region, rank_in_region;
