/* =============================================================================
   Q02 - What drives loan default? (segment scan with confidence intervals)
   -----------------------------------------------------------------------------
   Business question
     Which borrower and loan characteristics are associated with higher default
     rates, and which of those differences are statistically meaningful rather
     than small-sample noise?
   Stakeholder: Credit Risk team
   Techniques: GROUPING SETS (8 breakdowns in one pass), GROUPING() to label
               the dimension, Wilson 95% confidence intervals, lift vs portfolio
   Note: "default" = status B (finished unpaid) or D (running, in debt).
   ============================================================================= */

WITH base AS (
    SELECT f.*,
           CASE WHEN owner_age_at_loan < 30 THEN '1. <30'
                WHEN owner_age_at_loan < 40 THEN '2. 30-39'
                WHEN owner_age_at_loan < 50 THEN '3. 40-49'
                ELSE                             '4. 50+' END           AS age_band,
           -- Point-in-time: only count a card issued BEFORE the loan, otherwise
           -- we would credit the card for behaviour that happened afterwards.
           CASE WHEN card_issued_date < granted_date THEN card_type
                ELSE 'no card at approval' END                         AS card_holding,
           duration_months || ' months'                                 AS term
    FROM mart.fact_loan f
),
seg AS (
    SELECT CASE
             WHEN GROUPING(term)                = 0 THEN 'Loan term'
             WHEN GROUPING(amount_band)         = 0 THEN 'Loan amount'
             WHEN GROUPING(age_band)            = 0 THEN 'Borrower age'
             WHEN GROUPING(owner_gender)        = 0 THEN 'Gender'
             WHEN GROUPING(card_holding)        = 0 THEN 'Card held'
             WHEN GROUPING(statement_frequency) = 0 THEN 'Statement frequency'
             WHEN GROUPING(has_disponent)       = 0 THEN 'Joint account'
             WHEN GROUPING(region)              = 0 THEN 'Region'
             ELSE 'Portfolio'
           END                                                          AS dimension,
           COALESCE(term, amount_band, age_band, owner_gender, card_holding,
                    statement_frequency, has_disponent::text, region, 'All loans') AS segment,
           count(*)                                                     AS n_loans,
           sum(is_default::int)                                         AS n_default
    FROM base
    GROUP BY GROUPING SETS ((term), (amount_band), (age_band), (owner_gender),
                            (card_holding), (statement_frequency), (has_disponent),
                            (region), ())
)
SELECT s.dimension,
       s.segment,
       s.n_loans,
       s.n_default,
       round(100.0 * s.n_default / s.n_loans, 1)                            AS default_rate_pct,
       round(100 * mart.fn_wilson_lower(s.n_default, s.n_loans), 1)         AS ci95_low_pct,
       round(100 * mart.fn_wilson_upper(s.n_default, s.n_loans), 1)         AS ci95_high_pct,
       round((s.n_default::numeric / s.n_loans) / (p.n_default::numeric / p.n_loans), 2) AS lift_vs_portfolio,
       -- Flag segments whose whole CI sits above/below the portfolio rate
       CASE WHEN mart.fn_wilson_lower(s.n_default, s.n_loans) > p.n_default::numeric / p.n_loans THEN 'significantly higher'
            WHEN mart.fn_wilson_upper(s.n_default, s.n_loans) < p.n_default::numeric / p.n_loans THEN 'significantly lower'
            ELSE 'not significant' END                                       AS vs_portfolio
FROM seg s
CROSS JOIN (SELECT n_loans, n_default FROM seg WHERE dimension = 'Portfolio') p
ORDER BY s.dimension = 'Portfolio' DESC, s.dimension, s.segment;
