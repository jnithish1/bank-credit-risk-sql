/* =============================================================================
   Q11 - Do local economics explain customer value and credit risk?
   -----------------------------------------------------------------------------
   Business question
     Across the 77 districts, how strongly do average salary, unemployment and
     urbanisation correlate with customer balances and loan default rates?
     If correlations are weak, regional risk pricing is NOT justified and the
     bank should price on individual behaviour instead.
   Stakeholder: Strategy / Credit Risk policy
   Techniques: statistical aggregates CORR() and REGR_R2(),
               unpivot with CROSS JOIN LATERAL (VALUES ...), minimum-sample
               filter to drop districts with fewer than 5 loans
   ============================================================================= */

WITH district_stats AS (
    SELECT d.district_id, d.avg_salary, d.unemployment_rate_96, d.urban_ratio_pct,
           d.entrepreneurs_per_1000, d.crimes_per_1000_96,
           avg(b.month_end_balance)                              AS avg_balance,
           count(l.loan_id)                                      AS loans,
           avg(l.is_default::int)                                AS default_rate
    FROM mart.dim_district d
    JOIN core.account a ON a.district_id = d.district_id
    JOIN mart.fact_account_month b
      ON b.account_id = a.account_id
     AND b.month_start = date_trunc('month', mart.fn_as_of_date())
    LEFT JOIN core.loan l ON l.account_id = a.account_id
    GROUP BY d.district_id, d.avg_salary, d.unemployment_rate_96, d.urban_ratio_pct,
             d.entrepreneurs_per_1000, d.crimes_per_1000_96
),
pairs AS (
    SELECT s.district_id, s.loans, x.driver, x.x_value, y.outcome, y.y_value
    FROM district_stats s
    CROSS JOIN LATERAL (VALUES
        ('Average salary',              s.avg_salary::numeric),
        ('Unemployment rate 1996',      s.unemployment_rate_96),
        ('Urban population %',          s.urban_ratio_pct),
        ('Entrepreneurs per 1,000',     s.entrepreneurs_per_1000::numeric),
        ('Crimes per 1,000',            s.crimes_per_1000_96)
    ) AS x(driver, x_value)
    CROSS JOIN LATERAL (VALUES
        ('Avg customer balance',        s.avg_balance),
        ('Loan default rate',           s.default_rate)
    ) AS y(outcome, y_value)
    -- default-rate correlations only use districts with >= 5 loans
    WHERE y.outcome <> 'Loan default rate' OR s.loans >= 5
)
SELECT outcome,
       driver,
       count(*)                                             AS districts,
       round(corr(y_value, x_value)::numeric, 3)            AS pearson_r,
       round(regr_r2(y_value, x_value)::numeric, 3)         AS r_squared,
       CASE WHEN abs(corr(y_value, x_value)) >= 0.5 THEN 'strong'
            WHEN abs(corr(y_value, x_value)) >= 0.3 THEN 'moderate'
            WHEN abs(corr(y_value, x_value)) >= 0.1 THEN 'weak'
            ELSE 'none' END                                 AS strength
FROM pairs
GROUP BY outcome, driver
ORDER BY outcome, abs(corr(y_value, x_value)) DESC;
