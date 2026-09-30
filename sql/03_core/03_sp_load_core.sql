/* =============================================================================
   03_sp_load_core.sql
   Stored procedure that transforms staging -> core in one transaction.
   Every step is timed and row-counted in audit.etl_run_log.

   Usage:  CALL core.sp_load_core();
   ============================================================================= */

CREATE OR REPLACE PROCEDURE core.sp_load_core()
LANGUAGE plpgsql AS $$
DECLARE
    v_run  BIGINT;
    v_rows BIGINT;
BEGIN
    -- Full refresh: children first is handled by CASCADE
    TRUNCATE core.transaction, core.permanent_order, core.loan, core.card,
             core.disposition, core.account, core.client, core.district;

    -- 1. District -----------------------------------------------------------
    v_run := audit.fn_log_start('transform', 'core.district');
    INSERT INTO core.district
    SELECT a1::smallint, trim(a2), trim(a3), a4::int,
           a5::smallint, a6::smallint, a7::smallint, a8::smallint, a9::smallint,
           a10::numeric, a11::int,
           NULLIF(trim(a12), '?')::numeric,          -- '?' = not reported
           a13::numeric, a14::smallint,
           NULLIF(trim(a15), '?')::int,
           a16::int
    FROM staging.district;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 2. Client: decode gender + birth date from the birth_number -------------
    v_run := audit.fn_log_start('transform', 'core.client');
    INSERT INTO core.client (client_id, gender, birth_date, district_id)
    SELECT client_id::int,
           core.fn_decode_gender(trim(birth_number)),
           core.fn_decode_birth_date(trim(birth_number)),
           district_id::smallint
    FROM staging.client;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 3. Account --------------------------------------------------------------
    v_run := audit.fn_log_start('transform', 'core.account');
    INSERT INTO core.account (account_id, district_id, statement_frequency, opened_date)
    SELECT s.account_id::int, s.district_id::smallint, l.label, core.fn_parse_yymmdd(s.date)
    FROM staging.account s
    JOIN core.code_lookup l
      ON l.domain = 'statement_frequency' AND l.source_code = trim(s.frequency);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 4. Disposition ----------------------------------------------------------
    v_run := audit.fn_log_start('transform', 'core.disposition');
    INSERT INTO core.disposition
    SELECT disp_id::int, client_id::int, account_id::int, upper(trim(type))
    FROM staging.disp;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 5. Card -----------------------------------------------------------------
    v_run := audit.fn_log_start('transform', 'core.card');
    INSERT INTO core.card
    SELECT card_id::int, disp_id::int, lower(trim(type)), core.fn_parse_yymmdd(issued)
    FROM staging.card;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 6. Loan -----------------------------------------------------------------
    v_run := audit.fn_log_start('transform', 'core.loan');
    INSERT INTO core.loan (loan_id, account_id, granted_date, amount, duration_months,
                           monthly_payment, status_code, status_label)
    SELECT s.loan_id::int, s.account_id::int, core.fn_parse_yymmdd(s.date),
           s.amount::numeric, s.duration::smallint, s.payments::numeric,
           trim(s.status), l.label
    FROM staging.loan s
    JOIN core.code_lookup l ON l.domain = 'loan_status' AND l.source_code = trim(s.status);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 7. Permanent (standing) orders -----------------------------------------
    v_run := audit.fn_log_start('transform', 'core.permanent_order');
    INSERT INTO core.permanent_order
    SELECT s.order_id::int, s.account_id::int, trim(s.bank_to), trim(s.account_to),
           s.amount::numeric, l.label
    FROM staging.permanent_order s
    LEFT JOIN core.code_lookup l
           ON l.domain = 'purpose' AND l.source_code = NULLIF(trim(s.k_symbol), '');
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- 8. Transactions (1M+ rows, routed to yearly partitions automatically) ---
    v_run := audit.fn_log_start('transform', 'core.transaction');
    INSERT INTO core.transaction (trans_id, account_id, trans_date, direction, operation,
                                  amount, balance_after, purpose, partner_bank, partner_account)
    SELECT s.trans_id::int,
           s.account_id::int,
           core.fn_parse_yymmdd(s.date),
           t.label,
           o.label,
           s.amount::numeric,
           s.balance::numeric,
           p.label,
           NULLIF(trim(s.bank), ''),
           NULLIF(regexp_replace(trim(s.account), '\.0+$', ''), '')
    FROM staging.trans s
    JOIN      core.code_lookup t ON t.domain = 'trans_type' AND t.source_code = trim(s.type)
    LEFT JOIN core.code_lookup o ON o.domain = 'operation'  AND o.source_code = NULLIF(trim(s.operation), '')
    LEFT JOIN core.code_lookup p ON p.domain = 'purpose'    AND p.source_code = NULLIF(trim(s.k_symbol), '');
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM audit.fn_log_end(v_run, v_rows);

    -- Refresh planner statistics after a bulk load
    ANALYZE core.district, core.client, core.account, core.disposition,
            core.card, core.loan, core.permanent_order, core.transaction;
END;
$$;
