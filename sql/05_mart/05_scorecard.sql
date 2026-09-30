/* =============================================================================
   05_scorecard.sql
   A transparent points-based credit scorecard built entirely in SQL.

   Method (standard retail-credit approach)
   1. Split loans into TRAIN (2/3) and TEST (1/3) by a deterministic hash of
      loan_id, so results are reproducible and the model is judged on loans it
      never saw.
   2. For three signals from different risk families
         liquidity     -> min_balance_90d
         affordability -> balance_to_instalment
         stability     -> income_volatility_cv
      cut TRAIN into 5 quantile bins and compute each bin's Weight of Evidence.
   3. Apply the TRAIN bin edges + WoE to every loan and convert to points:
         score = 600 + (20 / ln 2) * sum(WoE)
      i.e. +20 points doubles the good:bad odds ("points to double odds" = 20).
      Higher score = safer borrower.
   ============================================================================= */

CREATE MATERIALIZED VIEW mart.loan_scorecard_bins AS
WITH features AS (
    SELECT f.*,
           CASE WHEN f.loan_id % 3 = 0 THEN 'test' ELSE 'train' END AS sample
    FROM mart.v_loan_feature_long f
    WHERE f.feature IN ('min_balance_90d', 'balance_to_instalment', 'income_volatility_cv')
),
train_binned AS (
    SELECT feature, value, is_default,
           NTILE(5) OVER (PARTITION BY feature ORDER BY value) AS bin
    FROM features WHERE sample = 'train'
),
bin_stats AS (
    SELECT feature, bin,
           min(value)                   AS lower_edge,
           max(value)                   AS upper_edge,
           sum(is_default::int)         AS bad,
           sum((NOT is_default)::int)   AS good
    FROM train_binned GROUP BY feature, bin
)
SELECT b.feature, b.bin, b.lower_edge, b.upper_edge, b.good, b.bad,
       round(ln( ((b.good + 0.5) / (sum(b.good) OVER w + 0.5))
               / ((b.bad  + 0.5) / (sum(b.bad)  OVER w + 0.5)) ), 4) AS woe,
       round(20 / ln(2.0) * ln( ((b.good + 0.5) / (sum(b.good) OVER w + 0.5))
                            / ((b.bad  + 0.5) / (sum(b.bad)  OVER w + 0.5)) ), 1) AS points
FROM bin_stats b
WINDOW w AS (PARTITION BY b.feature);

CREATE UNIQUE INDEX ux_loan_scorecard_bins ON mart.loan_scorecard_bins (feature, bin);
COMMENT ON MATERIALIZED VIEW mart.loan_scorecard_bins IS
  'Scorecard definition: bin edges, WoE and points per feature (fitted on TRAIN loans only).';

CREATE MATERIALIZED VIEW mart.loan_scorecard AS
WITH features AS (
    SELECT f.*,
           CASE WHEN f.loan_id % 3 = 0 THEN 'test' ELSE 'train' END AS sample
    FROM mart.v_loan_feature_long f
    WHERE f.feature IN ('min_balance_90d', 'balance_to_instalment', 'income_volatility_cv')
),
assigned AS (
    -- Each loan falls in the first TRAIN bin whose upper edge covers its value;
    -- anything above the last edge goes to the top bin.
    SELECT f.loan_id, f.sample, f.is_default, f.feature, sb.bin, sb.woe
    FROM features f
    CROSS JOIN LATERAL (
        SELECT s.bin, s.woe FROM mart.loan_scorecard_bins s
        WHERE s.feature = f.feature AND (f.value <= s.upper_edge OR s.bin = 5)
        ORDER BY s.bin LIMIT 1
    ) sb
)
SELECT loan_id, sample, is_default,
       round(600 + 20 / ln(2.0) * sum(woe))::int AS score
FROM assigned
GROUP BY loan_id, sample, is_default
HAVING count(*) = 3;          -- scored only when all three signals are present

CREATE UNIQUE INDEX ux_loan_scorecard ON mart.loan_scorecard (loan_id);
COMMENT ON MATERIALIZED VIEW mart.loan_scorecard IS 'Grain: one row per loan with its scorecard points.';
