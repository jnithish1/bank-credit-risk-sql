/* =============================================================================
   03_functions.sql
   Reusable analytical functions.
   ============================================================================= */

-- ---------------------------------------------------------------------------
-- Wilson score interval for a proportion k/n.
-- Small segments produce noisy rates; reporting the 95% interval stops
-- stakeholders over-reacting to a "30% default rate" that is 3 loans out of 10.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_wilson_lower(k NUMERIC, n NUMERIC, z NUMERIC DEFAULT 1.96)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN n = 0 THEN NULL ELSE
      ( (k/n) + z*z/(2*n) - z*sqrt( (k/n)*(1-k/n)/n + z*z/(4*n*n) ) ) / (1 + z*z/n) END
$$;

CREATE OR REPLACE FUNCTION mart.fn_wilson_upper(k NUMERIC, n NUMERIC, z NUMERIC DEFAULT 1.96)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN n = 0 THEN NULL ELSE
      ( (k/n) + z*z/(2*n) + z*sqrt( (k/n)*(1-k/n)/n + z*z/(4*n*n) ) ) / (1 + z*z/n) END
$$;

-- ---------------------------------------------------------------------------
-- Customer 360: everything a relationship manager needs about one client,
-- returned as a single row. Used by the CRM / call-centre use case.
--   SELECT * FROM mart.fn_customer_360(2);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_customer_360(p_client_id INTEGER)
RETURNS TABLE (
    client_id            INTEGER,
    gender               CHAR(1),
    age                  INTEGER,
    district             TEXT,
    region               TEXT,
    role                 TEXT,
    account_id           INTEGER,
    customer_since       DATE,
    tenure_months        INTEGER,
    current_balance      NUMERIC,
    avg_balance_12m      NUMERIC,
    avg_monthly_inflow   NUMERIC,
    avg_monthly_outflow  NUMERIC,
    last_activity_date   DATE,
    card_type            TEXT,
    loan_status          TEXT,
    loan_amount          NUMERIC,
    penalties_12m        BIGINT,
    receives_pension     BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT c.client_id, c.gender, c.age, c.district_name, c.region,
           d.disp_type,
           a.account_id, a.opened_date, a.tenure_months,
           m.current_balance, m.avg_balance_12m, m.avg_inflow, m.avg_outflow,
           (SELECT max(f.trans_date) FROM mart.fact_account_day f
             WHERE f.account_id = a.account_id AND f.n_client_transactions > 0),
           a.card_type,
           l.status_label, l.amount,
           m.penalties_12m,
           m.pension_12m > 0
    FROM mart.dim_client c
    JOIN core.disposition d ON d.client_id = c.client_id
    JOIN mart.dim_account a ON a.account_id = d.account_id
    LEFT JOIN core.loan l   ON l.account_id = a.account_id
    LEFT JOIN LATERAL (
        SELECT (array_agg(fm.month_end_balance ORDER BY fm.month_start DESC))[1] AS current_balance,
               round(avg(fm.month_end_balance), 2)  AS avg_balance_12m,
               round(avg(fm.inflow), 2)             AS avg_inflow,
               round(avg(fm.outflow), 2)            AS avg_outflow,
               sum(fm.n_penalties)                  AS penalties_12m,
               sum(fm.pension_inflow)               AS pension_12m
        FROM mart.fact_account_month fm
        WHERE fm.account_id = a.account_id
          AND fm.month_start > mart.fn_as_of_date() - INTERVAL '12 months'
    ) m ON TRUE
    WHERE c.client_id = p_client_id
$$;

-- ---------------------------------------------------------------------------
-- Loan amortisation schedule via a RECURSIVE CTE.
-- Loans in this bank are flat-instalment: amount = duration x payment
-- (verified by DQ check loan_amount_equals_schedule).
--   SELECT * FROM mart.fn_loan_schedule(5314);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_loan_schedule(p_loan_id INTEGER)
RETURNS TABLE (instalment_no INT, due_month DATE, instalment NUMERIC, outstanding_after NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE sched AS (
        SELECT 1 AS instalment_no,
               (date_trunc('month', l.granted_date) + INTERVAL '1 month')::date AS due_month,
               l.monthly_payment AS instalment,
               l.amount - l.monthly_payment AS outstanding_after,
               l.duration_months
        FROM core.loan l WHERE l.loan_id = p_loan_id
        UNION ALL
        SELECT s.instalment_no + 1,
               (s.due_month + INTERVAL '1 month')::date,
               s.instalment,
               s.outstanding_after - s.instalment,
               s.duration_months
        FROM sched s
        WHERE s.instalment_no < s.duration_months
    )
    SELECT instalment_no, due_month, instalment, greatest(outstanding_after, 0) FROM sched
$$;
