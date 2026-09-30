/* =============================================================================
   04_indexes.sql
   Indexes are created AFTER the bulk load (faster than maintaining them row by
   row during the INSERT). Each index maps to a real access pattern used by the
   analysis layer - see docs/performance.md for the before/after EXPLAIN plans.
   ============================================================================= */

-- Foreign-key lookups (PostgreSQL does NOT index FK columns automatically)
CREATE INDEX ix_client_district        ON core.client (district_id);
CREATE INDEX ix_account_district       ON core.account (district_id);
CREATE INDEX ix_disposition_client     ON core.disposition (client_id);
CREATE INDEX ix_card_disp              ON core.card (disp_id);
CREATE INDEX ix_permanent_order_acct   ON core.permanent_order (account_id);

-- The hot path: "all movements of account X in a date window".
-- Composite index, created on the partitioned parent -> cascades to every partition.
-- INCLUDE makes balance lookups index-only (no heap visit).
CREATE INDEX ix_trans_account_date
    ON core.transaction (account_id, trans_date)
    INCLUDE (signed_amount, balance_after);

-- Partial index: loan instalments are <2% of rows but queried constantly
CREATE INDEX ix_trans_loan_payments
    ON core.transaction (account_id, trans_date)
    WHERE purpose = 'loan_payment';

-- Partial index for overdraft / penalty analysis
CREATE INDEX ix_trans_negative_balance
    ON core.transaction (account_id, trans_date)
    WHERE balance_after < 0;
