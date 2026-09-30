/* =============================================================================
   01_dimensions.sql
   Star-schema dimensions for BI tools (Power BI / Tableau / Looker) and for
   the analysis layer. Grain of each object is documented in its COMMENT.
   ============================================================================= */

-- Single source of truth for the analysis "as-of" date (last day of data).
CREATE OR REPLACE FUNCTION mart.fn_as_of_date()
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '1998-12-31' $$;

-- ---------------------------------------------------------------------------
-- dim_date: one row per calendar day 1993-1998
-- ---------------------------------------------------------------------------
CREATE TABLE mart.dim_date AS
SELECT to_char(d, 'YYYYMMDD')::int              AS date_key,
       d::date                                  AS full_date,
       extract(year    FROM d)::smallint        AS year,
       extract(quarter FROM d)::smallint        AS quarter,
       extract(month   FROM d)::smallint        AS month,
       to_char(d, 'Mon')                        AS month_name,
       date_trunc('month', d)::date             AS month_start,
       (date_trunc('month', d) + INTERVAL '1 month - 1 day')::date AS month_end,
       extract(isodow  FROM d)::smallint        AS day_of_week,
       extract(isodow  FROM d) IN (6, 7)        AS is_weekend,
       to_char(d, 'YYYY-"Q"Q')                  AS year_quarter
FROM generate_series(DATE '1993-01-01', DATE '1998-12-31', INTERVAL '1 day') AS g(d);

ALTER TABLE mart.dim_date ADD PRIMARY KEY (date_key);
CREATE UNIQUE INDEX ux_dim_date_full ON mart.dim_date (full_date);
COMMENT ON TABLE mart.dim_date IS 'Grain: one row per calendar day.';

-- ---------------------------------------------------------------------------
-- dim_district: demographics + relative bands for segmentation
-- ---------------------------------------------------------------------------
CREATE VIEW mart.dim_district AS
SELECT d.*,
       NTILE(4) OVER (ORDER BY d.avg_salary)            AS salary_quartile,
       NTILE(4) OVER (ORDER BY d.unemployment_rate_96)  AS unemployment_quartile,
       CASE WHEN d.urban_ratio_pct >= 75 THEN 'urban'
            WHEN d.urban_ratio_pct >= 50 THEN 'mixed'
            ELSE 'rural' END                            AS settlement_type,
       round(d.crimes_96 * 1000.0 / d.population, 1)    AS crimes_per_1000_96
FROM core.district d;
COMMENT ON VIEW mart.dim_district IS 'Grain: one row per district.';

-- ---------------------------------------------------------------------------
-- dim_client: demographics as of the analysis date
-- ---------------------------------------------------------------------------
CREATE VIEW mart.dim_client AS
SELECT c.client_id,
       c.gender,
       c.birth_date,
       date_part('year', age(mart.fn_as_of_date(), c.birth_date))::int AS age,
       CASE
         WHEN age(mart.fn_as_of_date(), c.birth_date) < INTERVAL '18 years' THEN 'Under 18'
         WHEN age(mart.fn_as_of_date(), c.birth_date) < INTERVAL '30 years' THEN '18-29'
         WHEN age(mart.fn_as_of_date(), c.birth_date) < INTERVAL '45 years' THEN '30-44'
         WHEN age(mart.fn_as_of_date(), c.birth_date) < INTERVAL '60 years' THEN '45-59'
         ELSE '60+'
       END AS age_band,
       c.district_id,
       d.district_name,
       d.region
FROM core.client c
JOIN core.district d USING (district_id);
COMMENT ON VIEW mart.dim_client IS 'Grain: one row per client.';

-- ---------------------------------------------------------------------------
-- dim_account: the account "profile" - owner, products held, tenure
-- Materialized because it aggregates across five tables and is joined often.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.dim_account AS
WITH owner AS (
    SELECT account_id, client_id AS owner_client_id
    FROM core.disposition WHERE disp_type = 'OWNER'
),
disponent AS (
    SELECT account_id, count(*) AS n_disponents
    FROM core.disposition WHERE disp_type = 'DISPONENT'
    GROUP BY account_id
),
cards AS (
    -- If several cards exist, keep the highest tier
    SELECT DISTINCT ON (d.account_id)
           d.account_id, c.card_type, c.issued_date AS card_issued_date
    FROM core.card c JOIN core.disposition d USING (disp_id)
    ORDER BY d.account_id,
             CASE c.card_type WHEN 'gold' THEN 1 WHEN 'classic' THEN 2 ELSE 3 END
),
orders AS (
    SELECT account_id,
           count(*)                                          AS n_standing_orders,
           sum(amount)                                       AS standing_orders_amount,
           bool_or(purpose = 'household')                    AS has_household_order,
           bool_or(purpose = 'insurance')                    AS has_insurance_order,
           bool_or(purpose = 'leasing')                      AS has_leasing_order
    FROM core.permanent_order GROUP BY account_id
)
SELECT a.account_id,
       o.owner_client_id,
       cl.gender                                                  AS owner_gender,
       date_part('year', age(a.opened_date, cl.birth_date))::int  AS owner_age_at_open,
       a.district_id,
       d.district_name,
       d.region,
       a.statement_frequency,
       a.opened_date,
       (date_part('year',  age(mart.fn_as_of_date(), a.opened_date)) * 12
      + date_part('month', age(mart.fn_as_of_date(), a.opened_date)))::int AS tenure_months,
       COALESCE(dp.n_disponents, 0) > 0                           AS has_disponent,
       ca.card_type,
       ca.card_issued_date,
       ca.account_id IS NOT NULL                                  AS has_card,
       l.loan_id IS NOT NULL                                      AS has_loan,
       l.status_code                                              AS loan_status,
       l.is_default                                               AS loan_is_default,
       COALESCE(od.n_standing_orders, 0)                          AS n_standing_orders,
       COALESCE(od.standing_orders_amount, 0)                     AS standing_orders_amount,
       COALESCE(od.has_household_order, FALSE)                    AS has_household_order,
       COALESCE(od.has_insurance_order, FALSE)                    AS has_insurance_order,
       COALESCE(od.has_leasing_order, FALSE)                      AS has_leasing_order
FROM core.account a
JOIN owner o           ON o.account_id = a.account_id
JOIN core.client cl    ON cl.client_id = o.owner_client_id
JOIN core.district d   ON d.district_id = a.district_id
LEFT JOIN disponent dp ON dp.account_id = a.account_id
LEFT JOIN cards ca     ON ca.account_id = a.account_id
LEFT JOIN core.loan l  ON l.account_id = a.account_id
LEFT JOIN orders od    ON od.account_id = a.account_id;

CREATE UNIQUE INDEX ux_dim_account ON mart.dim_account (account_id);   -- enables REFRESH ... CONCURRENTLY
COMMENT ON MATERIALIZED VIEW mart.dim_account IS 'Grain: one row per account (owner + product holdings).';
