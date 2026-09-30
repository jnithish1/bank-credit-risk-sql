/* =============================================================================
   Q10 - Regional performance and socio-economic drivers
   -----------------------------------------------------------------------------
   Business question
     Which districts bring the most deposits per customer and the worst credit
     quality, and do local economic conditions (salary, unemployment,
     urbanisation) explain the differences? Informs branch strategy and
     regional risk appetite.
   Stakeholder: Regional Network / Strategy
   Techniques: multi-level aggregation, RANK (national) and DENSE_RANK
               partitioned by region, window AVG to benchmark each district
               against its own region
   ============================================================================= */

WITH district_stats AS (
    SELECT d.district_id, d.district_name, d.region, d.population, d.avg_salary,
           d.unemployment_rate_96, d.urban_ratio_pct, d.crimes_per_1000_96,
           count(a.account_id)                                     AS accounts,
           round(avg(b.month_end_balance))                         AS avg_balance,
           sum(b.month_end_balance)                                AS deposits,
           count(l.loan_id)                                        AS loans,
           sum(l.is_default::int)                                  AS bad_loans,
           round(10000.0 * count(a.account_id) / d.population, 1)  AS accounts_per_10k_pop
    FROM mart.dim_district d
    LEFT JOIN core.account a ON a.district_id = d.district_id
    LEFT JOIN mart.fact_account_month b
           ON b.account_id = a.account_id
          AND b.month_start = date_trunc('month', mart.fn_as_of_date())
    LEFT JOIN core.loan l ON l.account_id = a.account_id
    GROUP BY d.district_id, d.district_name, d.region, d.population, d.avg_salary,
             d.unemployment_rate_96, d.urban_ratio_pct, d.crimes_per_1000_96
)
SELECT district_name,
       region,
       accounts,
       accounts_per_10k_pop                                         AS market_penetration,
       avg_balance,
       round(deposits / 1e6, 1)                                     AS deposits_czk_m,
       loans,
       round(100.0 * bad_loans / NULLIF(loans, 0), 1)               AS bad_loan_rate_pct,
       avg_salary,
       unemployment_rate_96,
       RANK()       OVER (ORDER BY deposits DESC)                   AS national_deposit_rank,
       DENSE_RANK() OVER (PARTITION BY region ORDER BY avg_balance DESC) AS rank_in_region_by_balance,
       -- how this district compares to its own region's average balance
       round(100.0 * (avg_balance / avg(avg_balance) OVER (PARTITION BY region) - 1), 1) AS balance_vs_region_pct
FROM district_stats
ORDER BY deposits DESC;
