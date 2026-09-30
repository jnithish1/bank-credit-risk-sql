/* =============================================================================
   02_staging_tables.sql
   Raw landing tables. Every column is TEXT so that a malformed value never
   breaks the load - type enforcement happens in the core layer where bad
   values can be measured and reported instead of silently dropped.
   ============================================================================= */

CREATE TABLE staging.account (
    account_id  TEXT, district_id TEXT, frequency TEXT, date TEXT
);

CREATE TABLE staging.client (
    client_id TEXT, birth_number TEXT, district_id TEXT
);

CREATE TABLE staging.disp (
    disp_id TEXT, client_id TEXT, account_id TEXT, type TEXT
);

CREATE TABLE staging.card (
    card_id TEXT, disp_id TEXT, type TEXT, issued TEXT
);

CREATE TABLE staging.loan (
    loan_id TEXT, account_id TEXT, date TEXT, amount TEXT,
    duration TEXT, payments TEXT, status TEXT
);

-- "order" is a reserved word, so the landing table is named permanent_order
CREATE TABLE staging.permanent_order (
    order_id TEXT, account_id TEXT, bank_to TEXT, account_to TEXT,
    amount TEXT, k_symbol TEXT
);

CREATE TABLE staging.trans (
    trans_id TEXT, account_id TEXT, date TEXT, type TEXT, operation TEXT,
    amount TEXT, balance TEXT, k_symbol TEXT, bank TEXT, account TEXT
);

-- District demographics use cryptic source headers A1..A16 (see docs/data_dictionary.md)
CREATE TABLE staging.district (
    a1 TEXT, a2 TEXT, a3 TEXT, a4 TEXT, a5 TEXT, a6 TEXT, a7 TEXT, a8 TEXT,
    a9 TEXT, a10 TEXT, a11 TEXT, a12 TEXT, a13 TEXT, a14 TEXT, a15 TEXT, a16 TEXT
);
