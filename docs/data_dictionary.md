# Data dictionary

Source: PKDD'99 Discovery Challenge "Financial" dataset (Berka), real
anonymised data from a Czech bank, January 1993 to December 1998.
Source files are semicolon-delimited with Czech codes. The `core` layer
translates them to English (see `core.code_lookup`).

## Source files → core tables

| Source file | Rows | Core table | Grain |
|---|---:|---|---|
| `district.csv` | 77 | `core.district` | one district (demographics) |
| `client.csv` | 5,369 | `core.client` | one person |
| `account.csv` | 4,500 | `core.account` | one bank account |
| `disp.csv` | 5,369 | `core.disposition` | which client may operate which account (OWNER / DISPONENT) |
| `card.csv` | 892 | `core.card` | one issued card |
| `loan.csv` | 682 | `core.loan` | one loan (max one per account) |
| `order.csv` | 6,471 | `core.permanent_order` | one standing payment order |
| `trans.csv` | 1,056,320 | `core.transaction` | one account movement |

## Source quirks and how they are handled

| Quirk | Handling |
|---|---|
| Dates stored as `YYMMDD` integers; card dates carry `00:00:00` | `core.fn_parse_yymmdd()` returns `NULL` on malformed input instead of failing, so bad rows are counted by DQ checks |
| `birth_number` encodes gender: women have **+50 added to the month** (`YYMM+50DD`) | `core.fn_decode_gender()` and `core.fn_decode_birth_date()` |
| Czech codes (`PRIJEM`, `VYDAJ`, `SIPO`, `UVER`, ...) | data-driven translation via `core.code_lookup` |
| Two debit type codes (`VYDAJ`, and legacy `VYBER`) | both map to `direction = 'debit'` |
| Blank and single-space `k_symbol` values | normalised to `NULL` |
| `?` in district unemployment 1995 and crimes 1995 | `NULL` (1 district) |
| No intra-day sequence for transactions | end-of-day balance reconstructed from the balance chain (see `mart.fact_account_day`) |
| Sub-crown rounding drift on interest postings | ledger reconciliation uses a 1 CZK tolerance |

## Code translations (`core.code_lookup`)

| Domain | Source code | English label |
|---|---|---|
| statement_frequency | POPLATEK MESICNE / TYDNE / PO OBRATU | monthly / weekly / after_transaction |
| trans_type | PRIJEM | credit |
| trans_type | VYDAJ, VYBER | debit |
| operation | VYBER KARTOU | card_withdrawal |
| operation | VKLAD | cash_deposit |
| operation | PREVOD Z UCTU | inbound_transfer |
| operation | VYBER | cash_withdrawal |
| operation | PREVOD NA UCET | outbound_transfer |
| purpose | POJISTNE | insurance |
| purpose | SLUZBY | statement_fee |
| purpose | UROK | interest_credited |
| purpose | SANKC. UROK | penalty_interest (charged when balance is negative) |
| purpose | SIPO | household (utilities, rent) |
| purpose | DUCHOD | pension |
| purpose | UVER | loan_payment |
| purpose | LEASING | leasing |
| loan_status | A | finished_ok |
| loan_status | B | finished_default |
| loan_status | C | running_ok |
| loan_status | D | running_in_debt |

**Default definition used throughout:** status `B` or `D` (`core.loan.is_default`, a generated column).

## District columns (source A1-A16)

| Source | Core column |
|---|---|
| A1 | district_id |
| A2 | district_name |
| A3 | region |
| A4 | population |
| A5-A8 | municipalities by size band (<500, 500-1,999, 2,000-9,999, 10,000+) |
| A9 | n_cities |
| A10 | urban_ratio_pct |
| A11 | avg_salary |
| A12 / A13 | unemployment_rate_95 / _96 |
| A14 | entrepreneurs_per_1000 |
| A15 / A16 | crimes_95 / _96 |

## Mart objects

| Object | Type | Grain | Purpose |
|---|---|---|---|
| `mart.dim_date` | table | day | calendar attributes |
| `mart.dim_district` | view | district | demographics + quartile bands |
| `mart.dim_client` | view | client | age, age band, location |
| `mart.dim_account` | materialized view | account | owner, products held, tenure |
| `mart.fact_account_day` | materialized view | account x active day | flows, reconstructed EOD balance |
| `mart.fact_account_month` | materialized view | account x month (dense) | flows, carried-forward balance, activity |
| `mart.fact_loan` | view | loan | loan with borrower/account context |
| `mart.loan_features` | materialized view | loan | point-in-time pre-loan behaviour |
| `mart.v_loan_feature_long` | view | loan x feature | unpivoted features for generic profiling |
| `mart.loan_scorecard_bins` | materialized view | feature x bin | scorecard definition (WoE, points) |
| `mart.loan_scorecard` | materialized view | loan | score per loan, train/test flag |
| `mart.v_account_regional` | secure view | account | row-restricted by analyst region |
| `mart.v_client_masked` | view | client | PII-minimised client data |
