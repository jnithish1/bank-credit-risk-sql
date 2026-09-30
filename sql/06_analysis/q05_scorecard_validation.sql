/* =============================================================================
   Q05 - Does a simple SQL scorecard work on loans it has never seen?
   -----------------------------------------------------------------------------
   Business question
     If underwriting had used a 3-signal scorecard, how well would it have
     ranked risk on held-out loans, and what would a "decline the riskiest 20%"
     policy have done to the default rate?
   Stakeholder: Chief Risk Officer
   Techniques: model validation in SQL - AUC (rank-sum), Kolmogorov-Smirnov
               statistic from cumulative distributions, policy simulation with
               PERCENT_RANK, train vs test comparison
   ============================================================================= */

WITH scored AS (
    SELECT * FROM mart.loan_scorecard
),
-- AUC: probability a random good borrower scores higher than a random bad one
ranks AS (
    SELECT sample, is_default,
           rank() OVER (PARTITION BY sample ORDER BY score)
             + (count(*) OVER (PARTITION BY sample, score) - 1) / 2.0 AS avg_rank
    FROM scored
),
auc AS (
    SELECT sample,
           count(*) FILTER (WHERE NOT is_default)                          AS n_good,
           count(*) FILTER (WHERE is_default)                              AS n_bad,
           (sum(avg_rank) FILTER (WHERE NOT is_default)
              - count(*) FILTER (WHERE NOT is_default)
                * (count(*) FILTER (WHERE NOT is_default) + 1) / 2.0)
           / (count(*) FILTER (WHERE NOT is_default)::numeric
              * count(*) FILTER (WHERE is_default))                       AS auc
    FROM ranks GROUP BY sample
),
-- KS: the maximum gap between cumulative bad% and cumulative good% by score
cumulative AS (
    SELECT sample, score,
           (sum(is_default::int) OVER w)::numeric
             / sum(is_default::int) OVER (PARTITION BY sample)         AS cum_bad,
           (sum((NOT is_default)::int) OVER w)::numeric
             / sum((NOT is_default)::int) OVER (PARTITION BY sample)   AS cum_good
    FROM scored
    WINDOW w AS (PARTITION BY sample ORDER BY score RANGE UNBOUNDED PRECEDING)
),
ks AS (
    SELECT sample, max(abs(cum_bad - cum_good)) AS ks FROM cumulative GROUP BY sample
),
-- Policy simulation: decline the lowest-scoring 20%
policy AS (
    SELECT sample,
           count(*) FILTER (WHERE declined)                                           AS n_declined,
           100.0 * count(*) FILTER (WHERE declined AND is_default)
                 / NULLIF(count(*) FILTER (WHERE is_default), 0)                      AS pct_defaults_caught,
           100.0 * count(*) FILTER (WHERE is_default) / count(*)                      AS default_rate_before,
           100.0 * count(*) FILTER (WHERE NOT declined AND is_default)
                 / NULLIF(count(*) FILTER (WHERE NOT declined), 0)                    AS default_rate_after
    FROM (SELECT *, percent_rank() OVER (PARTITION BY sample ORDER BY score) < 0.20 AS declined
          FROM scored) p
    GROUP BY sample
)
SELECT a.sample,
       a.n_good + a.n_bad                      AS loans,
       a.n_bad                                 AS defaults,
       round(a.auc, 3)                         AS auc,
       round(2 * a.auc - 1, 3)                 AS gini,
       round(k.ks, 3)                          AS ks,
       p.n_declined                            AS declined_at_20pct_cutoff,
       round(p.pct_defaults_caught, 1)         AS pct_of_defaults_caught,
       round(p.default_rate_before, 1)         AS default_rate_before_pct,
       round(p.default_rate_after, 1)          AS default_rate_after_pct
FROM auc a
JOIN ks k     USING (sample)
JOIN policy p USING (sample)
ORDER BY a.sample DESC;   -- train first, then test
