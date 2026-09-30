/* =============================================================================
   01_core_tables.sql
   Cleaned, strongly-typed operational model.

   Design decisions
   - Czech source codes are translated through a data-driven lookup table
     (core.code_lookup) rather than hard-coded CASE blocks, so a new code is a
     one-row INSERT, not a code change.
   - Every relationship is enforced with a FOREIGN KEY; domain rules with CHECK.
   - core.transaction (1M+ rows) is RANGE-partitioned by year. Queries that
     filter on trans_date only scan the partitions they need (partition pruning).
   - Business flags (is_default, is_active) are GENERATED columns so the logic
     lives in one place and can never drift between reports.
   ============================================================================= */

-- ---------------------------------------------------------------------------
-- Code translation table (Czech source code -> English business label)
-- ---------------------------------------------------------------------------
CREATE TABLE core.code_lookup (
    domain      TEXT NOT NULL,
    source_code TEXT NOT NULL,
    label       TEXT NOT NULL,
    description TEXT,
    PRIMARY KEY (domain, source_code)
);

INSERT INTO core.code_lookup (domain, source_code, label, description) VALUES
 -- account statement frequency
 ('statement_frequency','POPLATEK MESICNE','monthly','Monthly statement issuance'),
 ('statement_frequency','POPLATEK TYDNE','weekly','Weekly statement issuance'),
 ('statement_frequency','POPLATEK PO OBRATU','after_transaction','Statement issued after each transaction'),
 -- transaction type
 ('trans_type','PRIJEM','credit','Money into the account'),
 ('trans_type','VYDAJ','debit','Money out of the account'),
 ('trans_type','VYBER','debit','Cash withdrawal (legacy type code)'),
 -- transaction operation (channel)
 ('operation','VYBER KARTOU','card_withdrawal','Credit card withdrawal'),
 ('operation','VKLAD','cash_deposit','Credit in cash'),
 ('operation','PREVOD Z UCTU','inbound_transfer','Collection from another bank'),
 ('operation','VYBER','cash_withdrawal','Withdrawal in cash'),
 ('operation','PREVOD NA UCET','outbound_transfer','Remittance to another bank'),
 -- transaction / order purpose (k_symbol)
 ('purpose','POJISTNE','insurance','Insurance payment'),
 ('purpose','SLUZBY','statement_fee','Payment for statement'),
 ('purpose','UROK','interest_credited','Interest credited'),
 ('purpose','SANKC. UROK','penalty_interest','Sanction interest when balance is negative'),
 ('purpose','SIPO','household','Household payment (utilities, rent)'),
 ('purpose','DUCHOD','pension','Old-age pension'),
 ('purpose','UVER','loan_payment','Loan instalment'),
 ('purpose','LEASING','leasing','Leasing payment'),
 -- loan status
 ('loan_status','A','finished_ok','Contract finished, no problems'),
 ('loan_status','B','finished_default','Contract finished, loan not paid'),
 ('loan_status','C','running_ok','Running contract, OK so far'),
 ('loan_status','D','running_in_debt','Running contract, client in debt');

-- ---------------------------------------------------------------------------
-- Reference: districts with demographics
-- ---------------------------------------------------------------------------
CREATE TABLE core.district (
    district_id            SMALLINT PRIMARY KEY,
    district_name          TEXT     NOT NULL,
    region                 TEXT     NOT NULL,
    population             INTEGER  NOT NULL CHECK (population > 0),
    munis_lt_500           SMALLINT NOT NULL,
    munis_500_1999         SMALLINT NOT NULL,
    munis_2000_9999        SMALLINT NOT NULL,
    munis_ge_10000         SMALLINT NOT NULL,
    n_cities               SMALLINT NOT NULL,
    urban_ratio_pct        NUMERIC(5,2) NOT NULL CHECK (urban_ratio_pct BETWEEN 0 AND 100),
    avg_salary             INTEGER  NOT NULL,
    unemployment_rate_95   NUMERIC(5,2),          -- NULL where source had '?'
    unemployment_rate_96   NUMERIC(5,2) NOT NULL,
    entrepreneurs_per_1000 SMALLINT NOT NULL,
    crimes_95              INTEGER,               -- NULL where source had '?'
    crimes_96              INTEGER  NOT NULL
);

-- ---------------------------------------------------------------------------
-- Clients, accounts and who-can-operate-what (dispositions)
-- ---------------------------------------------------------------------------
CREATE TABLE core.client (
    client_id   INTEGER  PRIMARY KEY,
    gender      CHAR(1)  NOT NULL CHECK (gender IN ('F','M')),
    birth_date  DATE     NOT NULL,
    district_id SMALLINT NOT NULL REFERENCES core.district
);

CREATE TABLE core.account (
    account_id          INTEGER  PRIMARY KEY,
    district_id         SMALLINT NOT NULL REFERENCES core.district,
    statement_frequency TEXT     NOT NULL
                        CHECK (statement_frequency IN ('monthly','weekly','after_transaction')),
    opened_date         DATE     NOT NULL
);

CREATE TABLE core.disposition (
    disp_id    INTEGER PRIMARY KEY,
    client_id  INTEGER NOT NULL REFERENCES core.client,
    account_id INTEGER NOT NULL REFERENCES core.account,
    disp_type  TEXT    NOT NULL CHECK (disp_type IN ('OWNER','DISPONENT')),
    UNIQUE (client_id, account_id)
);

-- An account has exactly one owner - enforced with a partial unique index
CREATE UNIQUE INDEX ux_disposition_one_owner_per_account
    ON core.disposition (account_id) WHERE disp_type = 'OWNER';

-- ---------------------------------------------------------------------------
-- Products: cards, loans, standing (permanent) orders
-- ---------------------------------------------------------------------------
CREATE TABLE core.card (
    card_id     INTEGER PRIMARY KEY,
    disp_id     INTEGER NOT NULL REFERENCES core.disposition,
    card_type   TEXT    NOT NULL CHECK (card_type IN ('junior','classic','gold')),
    issued_date DATE    NOT NULL
);

CREATE TABLE core.loan (
    loan_id          INTEGER       PRIMARY KEY,
    account_id       INTEGER       NOT NULL UNIQUE REFERENCES core.account,
    granted_date     DATE          NOT NULL,
    amount           NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    duration_months  SMALLINT      NOT NULL CHECK (duration_months IN (12,24,36,48,60)),
    monthly_payment  NUMERIC(12,2) NOT NULL CHECK (monthly_payment > 0),
    status_code      CHAR(1)       NOT NULL CHECK (status_code IN ('A','B','C','D')),
    status_label     TEXT          NOT NULL,
    is_default       BOOLEAN GENERATED ALWAYS AS (status_code IN ('B','D')) STORED,
    is_active        BOOLEAN GENERATED ALWAYS AS (status_code IN ('C','D')) STORED
);

CREATE TABLE core.permanent_order (
    order_id          INTEGER       PRIMARY KEY,
    account_id        INTEGER       NOT NULL REFERENCES core.account,
    recipient_bank    CHAR(2)       NOT NULL,
    recipient_account TEXT          NOT NULL,
    amount            NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    purpose           TEXT          -- NULL = unspecified
);

-- ---------------------------------------------------------------------------
-- Transactions: 1M+ rows, partitioned by year
-- ---------------------------------------------------------------------------
CREATE TABLE core.transaction (
    trans_id        INTEGER       NOT NULL,
    account_id      INTEGER       NOT NULL REFERENCES core.account,
    trans_date      DATE          NOT NULL,
    direction       TEXT          NOT NULL CHECK (direction IN ('credit','debit')),
    operation       TEXT,         -- NULL for bank-generated entries (interest)
    amount          NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    signed_amount   NUMERIC(12,2) GENERATED ALWAYS AS
                    (CASE WHEN direction = 'credit' THEN amount ELSE -amount END) STORED,
    balance_after   NUMERIC(12,2) NOT NULL,
    purpose         TEXT,
    partner_bank    CHAR(2),
    partner_account TEXT,
    PRIMARY KEY (trans_id, trans_date)          -- partition key must be in the PK
) PARTITION BY RANGE (trans_date);

DO $$
DECLARE y INT;
BEGIN
    FOR y IN 1993..1998 LOOP
        EXECUTE format(
            'CREATE TABLE core.transaction_y%s PARTITION OF core.transaction
               FOR VALUES FROM (%L) TO (%L)',
            y, make_date(y,1,1), make_date(y+1,1,1));
    END LOOP;
END $$;

-- Safety net: rows outside the expected range land here instead of failing
CREATE TABLE core.transaction_default PARTITION OF core.transaction DEFAULT;

COMMENT ON TABLE  core.transaction IS 'All account movements 1993-1998, range-partitioned by year.';
COMMENT ON COLUMN core.transaction.signed_amount IS '+amount for credits, -amount for debits.';
COMMENT ON COLUMN core.loan.is_default IS 'Bad loan: finished unpaid (B) or running in debt (D).';
