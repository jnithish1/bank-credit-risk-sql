/* =============================================================================
   Q04 - Which pre-loan signals best separate good and bad borrowers?
   -----------------------------------------------------------------------------
   Business question
     Rank every candidate underwriting signal by predictive power using the
     same metrics a bank's credit-risk modelling team uses: Information Value
     (IV, from Weight of Evidence) and AUC / Gini.
   Stakeholder: Credit Risk Modelling
   Techniques: generic unpivoted feature view, NTILE binning, Weight of Evidence
               with Laplace smoothing, Information Value, AUC via the
               Mann-Whitney rank-sum identity (average ranks for ties),
               all in pure SQL
   Reading the output
     IV  < 0.02 useless | 0.02-0.1 weak | 0.1-0.3 medium | >= 0.3 strong
     AUC 0.5 = coin flip, 1.0 = perfect. Gini = 2*AUC - 1.
   ============================================================================= */

WITH totals AS (
    SELECT feature,
           sum(is_default::int)         AS total_bad,
           sum((NOT is_default)::int)   AS total_good
    FROM mart.v_loan_feature_long
    GROUP BY feature
),
-- ---- Information Value -------------------------------------------------------
binned AS (
    SELECT feature, is_default, value,
           NTILE(5) OVER (PARTITION BY feature ORDER BY value) AS bin
    FROM mart.v_loan_feature_long
),
bins AS (
    SELECT b.feature, b.bin,
           sum(b.is_default::int)       AS bad,
           sum((NOT b.is_default)::int) AS good
    FROM binned b GROUP BY b.feature, b.bin
),
woe AS (
    -- +0.5 smoothing avoids ln(0) when a bin has no defaults
    SELECT b.feature, b.bin,
           (b.good + 0.5) / (t.total_good + 0.5) AS pct_good,
           (b.bad  + 0.5) / (t.total_bad  + 0.5) AS pct_bad
    FROM bins b JOIN totals t USING (feature)
),
iv AS (
    SELECT feature,
           sum((pct_good - pct_bad) * ln(pct_good / pct_bad)) AS information_value
    FROM woe GROUP BY feature
),
-- ---- AUC (Mann-Whitney U) -----------------------------------------------------
ranked AS (
    SELECT feature, is_default,
           -- average rank for ties
           rank() OVER (PARTITION BY feature ORDER BY value)
             + (count(*) OVER (PARTITION BY feature, value) - 1) / 2.0 AS avg_rank
    FROM mart.v_loan_feature_long
),
auc AS (
    SELECT r.feature,
           (sum(r.avg_rank) FILTER (WHERE r.is_default) - t.total_bad * (t.total_bad + 1) / 2.0)
             / (t.total_bad::numeric * t.total_good)    AS auc_high_is_risky
    FROM ranked r JOIN totals t USING (feature)
    GROUP BY r.feature, t.total_bad, t.total_good
)
SELECT RANK() OVER (ORDER BY i.information_value DESC)                    AS rank,
       i.feature,
       round(i.information_value, 3)                                        AS information_value,
       CASE WHEN i.information_value >= 0.3  THEN 'strong'
            WHEN i.information_value >= 0.1  THEN 'medium'
            WHEN i.information_value >= 0.02 THEN 'weak'
            ELSE 'not predictive' END                                        AS iv_strength,
       round(greatest(a.auc_high_is_risky, 1 - a.auc_high_is_risky), 3)     AS auc,
       round(2 * greatest(a.auc_high_is_risky, 1 - a.auc_high_is_risky) - 1, 3) AS gini,
       CASE WHEN a.auc_high_is_risky >= 0.5 THEN 'higher value = riskier'
            ELSE 'lower value = riskier' END                                AS direction
FROM iv i JOIN auc a USING (feature)
ORDER BY i.information_value DESC;
