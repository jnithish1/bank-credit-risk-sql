# Databricks notebook source
# MAGIC %md
# MAGIC # Berka bank warehouse on Databricks (Delta Lake)
# MAGIC
# MAGIC This notebook ports the PostgreSQL warehouse in this repo to a Databricks lakehouse
# MAGIC using the **medallion pattern** on **Delta Lake** and **Unity Catalog**:
# MAGIC
# MAGIC | Layer | Schema | What happens |
# MAGIC |---|---|---|
# MAGIC | Bronze | `berka_bronze` | The 8 raw CSVs land as Delta tables, every column as text, plus ingestion metadata |
# MAGIC | Silver | `berka_silver` | Typed, cleaned, English-labelled tables with Delta constraints and liquid clustering |
# MAGIC | Audit | `berka_audit` | Data-quality results, appended on every run |
# MAGIC | Gold | `berka_gold` | Business-ready tables for the headline credit-risk findings |
# MAGIC
# MAGIC The last section **reconciles the gold numbers against the PostgreSQL build**, so both
# MAGIC platforms are proven to produce the same answers.
# MAGIC
# MAGIC **How to run (Databricks Free Edition, serverless):**
# MAGIC 1. Run the **Setup** cell below once. It creates the schemas and a volume called `landing`.
# MAGIC 2. In **Catalog**, open `workspace > berka_bronze > landing` and upload the 8 CSV files.
# MAGIC 3. Click **Run all**.

# COMMAND ----------

# MAGIC %md
# MAGIC ## 0. Setup

# COMMAND ----------

dbutils.widgets.text("catalog", "workspace", "Unity Catalog name")
CATALOG = dbutils.widgets.get("catalog")

BRONZE = f"{CATALOG}.berka_bronze"
SILVER = f"{CATALOG}.berka_silver"
AUDIT  = f"{CATALOG}.berka_audit"
GOLD   = f"{CATALOG}.berka_gold"
LANDING = f"/Volumes/{CATALOG}/berka_bronze/landing"

for schema in (BRONZE, AUDIT, GOLD):
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {schema}")
spark.sql(f"CREATE VOLUME IF NOT EXISTS {BRONZE}.landing COMMENT 'Raw Berka CSV files'")

expected_files = ["account", "card", "client", "disp", "district", "loan", "order", "trans"]
present = {f.name.replace(".csv", "") for f in dbutils.fs.ls(LANDING)}
missing = [f for f in expected_files if f not in present]
if missing:
    raise Exception(f"Upload these files to {LANDING} before continuing: {missing}")
print("All 8 source files found in", LANDING)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Bronze: land the raw files
# MAGIC Every column is read as text so a malformed value can never break ingestion.
# MAGIC Type problems are measured later by the data-quality checks instead of silently dropped.

# COMMAND ----------

from pyspark.sql import functions as F

# source file -> bronze table ("order" is a reserved word)
bronze_tables = {
    "account": "account", "card": "card", "client": "client", "disp": "disp",
    "district": "district", "loan": "loan", "order": "permanent_order", "trans": "trans",
}

for source, table in bronze_tables.items():
    df = (spark.read
          .option("header", True)
          .option("sep", ";")
          .option("quote", '"')
          .option("inferSchema", False)
          .csv(f"{LANDING}/{source}.csv"))
    df = df.toDF(*[c.lower() for c in df.columns])          # district headers are A1..A16
    df = (df.withColumn("_source_file", F.col("_metadata.file_path"))
            .withColumn("_ingested_at", F.current_timestamp()))
    (df.write.mode("overwrite")
       .option("overwriteSchema", "true")
       .saveAsTable(f"{BRONZE}.{table}"))
    print(f"{BRONZE}.{table:<16} {spark.table(f'{BRONZE}.{table}').count():>9,} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Silver: clean, type and constrain
# MAGIC Full refresh: the silver schema is rebuilt from bronze on every run, which keeps the
# MAGIC notebook safe to re-run.

# COMMAND ----------

spark.sql(f"DROP SCHEMA IF EXISTS {SILVER} CASCADE")
spark.sql(f"CREATE SCHEMA {SILVER} COMMENT 'Cleaned, typed and constrained Berka model'")

# Reusable SQL functions in Unity Catalog (same logic as the PostgreSQL helpers).
# Source dates are YYMMDD, all in the 1900s. Spark's 'yy' pattern would read 93 as 2093,
# so the year is built explicitly.
spark.sql(f"""
CREATE OR REPLACE FUNCTION {SILVER}.parse_yymmdd(raw STRING)
RETURNS DATE
COMMENT 'Parses a YYMMDD source date (1900s). Returns NULL for malformed input.'
RETURN CASE
  WHEN trim(raw) RLIKE '^[0-9][0-9][0-9][0-9][0-9][0-9]'
  THEN make_date(1900 + CAST(substr(trim(raw), 1, 2) AS INT),
                 CAST(substr(trim(raw), 3, 2) AS INT),
                 CAST(substr(trim(raw), 5, 2) AS INT))
END
""")

# Czech birth numbers add 50 to the month for women (YYMM+50DD)
spark.sql(f"""
CREATE OR REPLACE FUNCTION {SILVER}.decode_gender(bn STRING)
RETURNS STRING
RETURN CASE WHEN CAST(substr(trim(bn), 3, 2) AS INT) > 50 THEN 'F' ELSE 'M' END
""")

spark.sql(f"""
CREATE OR REPLACE FUNCTION {SILVER}.decode_birth_date(bn STRING)
RETURNS DATE
RETURN make_date(
  1900 + CAST(substr(trim(bn), 1, 2) AS INT),
  CAST(substr(trim(bn), 3, 2) AS INT)
    - CASE WHEN CAST(substr(trim(bn), 3, 2) AS INT) > 50 THEN 50 ELSE 0 END,
  CAST(substr(trim(bn), 5, 2) AS INT))
""")

# COMMAND ----------

# Data-driven translation of Czech source codes (a new code is one row, not a code change)
spark.sql(f"""
CREATE OR REPLACE TABLE {SILVER}.code_lookup AS
SELECT * FROM VALUES
  ('statement_frequency', 'POPLATEK MESICNE',   'monthly'),
  ('statement_frequency', 'POPLATEK TYDNE',     'weekly'),
  ('statement_frequency', 'POPLATEK PO OBRATU', 'after_transaction'),
  ('trans_type', 'PRIJEM', 'credit'),
  ('trans_type', 'VYDAJ',  'debit'),
  ('trans_type', 'VYBER',  'debit'),
  ('operation', 'VYBER KARTOU',   'card_withdrawal'),
  ('operation', 'VKLAD',          'cash_deposit'),
  ('operation', 'PREVOD Z UCTU',  'inbound_transfer'),
  ('operation', 'VYBER',          'cash_withdrawal'),
  ('operation', 'PREVOD NA UCET', 'outbound_transfer'),
  ('purpose', 'POJISTNE',    'insurance'),
  ('purpose', 'SLUZBY',      'statement_fee'),
  ('purpose', 'UROK',        'interest_credited'),
  ('purpose', 'SANKC. UROK', 'penalty_interest'),
  ('purpose', 'SIPO',        'household'),
  ('purpose', 'DUCHOD',      'pension'),
  ('purpose', 'UVER',        'loan_payment'),
  ('purpose', 'LEASING',     'leasing'),
  ('loan_status', 'A', 'finished_ok'),
  ('loan_status', 'B', 'finished_default'),
  ('loan_status', 'C', 'running_ok'),
  ('loan_status', 'D', 'running_in_debt')
AS t(domain, source_code, label)
""")

# COMMAND ----------

S = SILVER
B = BRONZE

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.district AS
SELECT CAST(a1 AS SMALLINT)                              AS district_id,
       trim(a2)                                          AS district_name,
       trim(a3)                                          AS region,
       CAST(a4 AS INT)                                   AS population,
       CAST(a10 AS DECIMAL(5,2))                         AS urban_ratio_pct,
       CAST(a11 AS INT)                                  AS avg_salary,
       CAST(NULLIF(trim(a12), '?') AS DECIMAL(5,2))      AS unemployment_rate_95,
       CAST(a13 AS DECIMAL(5,2))                         AS unemployment_rate_96,
       CAST(a14 AS SMALLINT)                             AS entrepreneurs_per_1000,
       CAST(NULLIF(trim(a15), '?') AS INT)               AS crimes_95,
       CAST(a16 AS INT)                                  AS crimes_96
FROM {B}.district
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.client AS
SELECT CAST(client_id AS INT)                 AS client_id,
       {S}.decode_gender(birth_number)        AS gender,
       {S}.decode_birth_date(birth_number)    AS birth_date,
       CAST(district_id AS SMALLINT)          AS district_id
FROM {B}.client
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.account AS
SELECT CAST(a.account_id AS INT)           AS account_id,
       CAST(a.district_id AS SMALLINT)     AS district_id,
       l.label                             AS statement_frequency,
       {S}.parse_yymmdd(a.`date`)          AS opened_date
FROM {B}.account a
JOIN {S}.code_lookup l
  ON l.domain = 'statement_frequency' AND l.source_code = trim(a.frequency)
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.disposition AS
SELECT CAST(disp_id AS INT)     AS disp_id,
       CAST(client_id AS INT)   AS client_id,
       CAST(account_id AS INT)  AS account_id,
       upper(trim(`type`))      AS disp_type
FROM {B}.disp
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.card AS
SELECT CAST(card_id AS INT)          AS card_id,
       CAST(disp_id AS INT)          AS disp_id,
       lower(trim(`type`))           AS card_type,
       {S}.parse_yymmdd(issued)      AS issued_date
FROM {B}.card
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.loan AS
SELECT CAST(s.loan_id AS INT)               AS loan_id,
       CAST(s.account_id AS INT)            AS account_id,
       {S}.parse_yymmdd(s.`date`)           AS granted_date,
       CAST(s.amount AS DECIMAL(12,2))      AS amount,
       CAST(s.duration AS SMALLINT)         AS duration_months,
       CAST(s.payments AS DECIMAL(12,2))    AS monthly_payment,
       trim(s.status)                       AS status_code,
       l.label                              AS status_label,
       trim(s.status) IN ('B', 'D')         AS is_default,
       trim(s.status) IN ('C', 'D')         AS is_active
FROM {B}.loan s
JOIN {S}.code_lookup l ON l.domain = 'loan_status' AND l.source_code = trim(s.status)
""")

spark.sql(f"""
CREATE OR REPLACE TABLE {S}.permanent_order AS
SELECT CAST(s.order_id AS INT)          AS order_id,
       CAST(s.account_id AS INT)        AS account_id,
       trim(s.bank_to)                  AS recipient_bank,
       trim(s.account_to)               AS recipient_account,
       CAST(s.amount AS DECIMAL(12,2))  AS amount,
       l.label                          AS purpose
FROM {B}.permanent_order s
LEFT JOIN {S}.code_lookup l
       ON l.domain = 'purpose' AND l.source_code = NULLIF(trim(s.k_symbol), '')
""")

# 1M+ rows. Liquid clustering on (account_id, trans_date) replaces the yearly
# partitioning used in PostgreSQL: Databricks recommends it over hive-style partitions
# for tables this size, and it matches the main access pattern.
spark.sql(f"""
CREATE OR REPLACE TABLE {S}.transaction
CLUSTER BY (account_id, trans_date)
AS
SELECT CAST(t.trans_id AS INT)                                  AS trans_id,
       CAST(t.account_id AS INT)                                AS account_id,
       {S}.parse_yymmdd(t.`date`)                               AS trans_date,
       ty.label                                                 AS direction,
       op.label                                                 AS operation,
       CAST(t.amount AS DECIMAL(12,2))                          AS amount,
       CASE WHEN ty.label = 'credit' THEN CAST(t.amount AS DECIMAL(12,2))
            ELSE -CAST(t.amount AS DECIMAL(12,2)) END           AS signed_amount,
       CAST(t.balance AS DECIMAL(12,2))                         AS balance_after,
       pu.label                                                 AS purpose,
       NULLIF(trim(t.bank), '')                                 AS partner_bank,
       NULLIF(regexp_replace(trim(t.account), '[.]0+$', ''), '') AS partner_account
FROM {B}.trans t
JOIN      {S}.code_lookup ty ON ty.domain = 'trans_type' AND ty.source_code = trim(t.`type`)
LEFT JOIN {S}.code_lookup op ON op.domain = 'operation'  AND op.source_code = NULLIF(trim(t.operation), '')
LEFT JOIN {S}.code_lookup pu ON pu.domain = 'purpose'    AND pu.source_code = NULLIF(trim(t.k_symbol), '')
""")

spark.sql(f"OPTIMIZE {S}.transaction")
print("Silver tables built.")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Constraints
# MAGIC Delta **CHECK** and **NOT NULL** constraints are enforced: adding one validates every
# MAGIC existing row, and any future write that breaks it is rejected.
# MAGIC Primary and foreign keys are informational in Unity Catalog. They document the model for
# MAGIC BI tools and the query optimiser.

# COMMAND ----------

constraints = [
    # NOT NULL keys (required before declaring primary keys)
    f"ALTER TABLE {S}.district    ALTER COLUMN district_id SET NOT NULL",
    f"ALTER TABLE {S}.client      ALTER COLUMN client_id   SET NOT NULL",
    f"ALTER TABLE {S}.account     ALTER COLUMN account_id  SET NOT NULL",
    f"ALTER TABLE {S}.loan        ALTER COLUMN loan_id     SET NOT NULL",
    f"ALTER TABLE {S}.transaction ALTER COLUMN trans_id    SET NOT NULL",
    f"ALTER TABLE {S}.transaction ALTER COLUMN trans_date  SET NOT NULL",

    # Enforced business rules
    f"ALTER TABLE {S}.client  ADD CONSTRAINT gender_valid      CHECK (gender IN ('F', 'M'))",
    f"ALTER TABLE {S}.loan    ADD CONSTRAINT amount_positive   CHECK (amount > 0)",
    f"ALTER TABLE {S}.loan    ADD CONSTRAINT term_valid        CHECK (duration_months IN (12, 24, 36, 48, 60))",
    f"ALTER TABLE {S}.loan    ADD CONSTRAINT status_valid      CHECK (status_code IN ('A', 'B', 'C', 'D'))",
    f"ALTER TABLE {S}.card    ADD CONSTRAINT card_type_valid   CHECK (card_type IN ('junior', 'classic', 'gold'))",
    f"ALTER TABLE {S}.transaction ADD CONSTRAINT direction_valid CHECK (direction IN ('credit', 'debit'))",
    f"ALTER TABLE {S}.transaction ADD CONSTRAINT amount_non_negative CHECK (amount >= 0)",

    # Informational keys
    f"ALTER TABLE {S}.district ADD CONSTRAINT district_pk PRIMARY KEY (district_id)",
    f"ALTER TABLE {S}.client   ADD CONSTRAINT client_pk   PRIMARY KEY (client_id)",
    f"ALTER TABLE {S}.account  ADD CONSTRAINT account_pk  PRIMARY KEY (account_id)",
    f"ALTER TABLE {S}.loan     ADD CONSTRAINT loan_pk     PRIMARY KEY (loan_id)",
    f"ALTER TABLE {S}.loan     ADD CONSTRAINT loan_account_fk FOREIGN KEY (account_id) REFERENCES {S}.account",
    f"ALTER TABLE {S}.client   ADD CONSTRAINT client_district_fk FOREIGN KEY (district_id) REFERENCES {S}.district",
]
for stmt in constraints:
    spark.sql(stmt)
print(f"{len(constraints)} constraints applied.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Data-quality gate
# MAGIC The same checks as the PostgreSQL pipeline. Results are **appended** to
# MAGIC `berka_audit.dq_result`, so quality can be tracked across runs.
# MAGIC A failed CRITICAL check stops the notebook before anything reaches gold.

# COMMAND ----------

from datetime import datetime, timezone

def count_check(name, table, severity, sql):
    """sql must return one row with columns failed and total."""
    r = spark.sql(sql).first()
    return (name, table, severity, int(r["failed"]), int(r["total"]))

checks = []

# Completeness: every bronze row reached silver
for src, tgt in [("district", "district"), ("client", "client"), ("account", "account"),
                 ("disp", "disposition"), ("card", "card"), ("loan", "loan"),
                 ("permanent_order", "permanent_order"), ("trans", "transaction")]:
    checks.append(count_check(
        "row_count_reconciliation", f"silver.{tgt}", "CRITICAL",
        f"""SELECT abs((SELECT count(*) FROM {B}.{src}) - (SELECT count(*) FROM {S}.{tgt})) AS failed,
                   (SELECT count(*) FROM {B}.{src}) AS total"""))

checks += [
    count_check("unmapped_source_codes", "bronze.trans", "CRITICAL", f"""
        SELECT count_if(
                 (NULLIF(trim(t.operation), '') IS NOT NULL AND op.label IS NULL)
              OR (NULLIF(trim(t.k_symbol), '')  IS NOT NULL AND pu.label IS NULL)) AS failed,
               count(*) AS total
        FROM {B}.trans t
        LEFT JOIN {S}.code_lookup op ON op.domain = 'operation' AND op.source_code = NULLIF(trim(t.operation), '')
        LEFT JOIN {S}.code_lookup pu ON pu.domain = 'purpose'   AND pu.source_code = NULLIF(trim(t.k_symbol), '')"""),

    count_check("unparsed_dates", "silver.transaction", "CRITICAL", f"""
        SELECT count_if(trans_date IS NULL) AS failed, count(*) AS total FROM {S}.transaction"""),

    count_check("duplicate_trans_id", "silver.transaction", "CRITICAL", f"""
        SELECT count(*) - count(DISTINCT trans_id) AS failed, count(*) AS total FROM {S}.transaction"""),

    count_check("account_has_one_owner", "silver.disposition", "CRITICAL", f"""
        SELECT count_if(n_owners <> 1) AS failed, count(*) AS total
        FROM (SELECT a.account_id, count(d.disp_id) AS n_owners
              FROM {S}.account a
              LEFT JOIN {S}.disposition d ON d.account_id = a.account_id AND d.disp_type = 'OWNER'
              GROUP BY a.account_id)"""),

    count_check("loan_amount_equals_schedule", "silver.loan", "CRITICAL", f"""
        SELECT count_if(abs(amount - duration_months * monthly_payment) > 1) AS failed,
               count(*) AS total FROM {S}.loan"""),

    count_check("loan_after_account_open", "silver.loan", "CRITICAL", f"""
        SELECT count_if(l.granted_date < a.opened_date) AS failed, count(*) AS total
        FROM {S}.loan l JOIN {S}.account a USING (account_id)"""),

    count_check("transaction_after_account_open", "silver.transaction", "CRITICAL", f"""
        SELECT count_if(t.trans_date < a.opened_date) AS failed, count(*) AS total
        FROM {S}.transaction t JOIN {S}.account a USING (account_id)"""),

    count_check("card_after_account_open", "silver.card", "WARNING", f"""
        SELECT count_if(c.issued_date < a.opened_date) AS failed, count(*) AS total
        FROM {S}.card c
        JOIN {S}.disposition d USING (disp_id)
        JOIN {S}.account a ON a.account_id = d.account_id"""),

    count_check("owner_age_plausible", "silver.client", "WARNING", f"""
        SELECT count_if(floor(months_between(a.opened_date, c.birth_date) / 12) NOT BETWEEN 0 AND 100) AS failed,
               count(*) AS total
        FROM {S}.account a
        JOIN {S}.disposition d ON d.account_id = a.account_id AND d.disp_type = 'OWNER'
        JOIN {S}.client c      ON c.client_id = d.client_id"""),

    count_check("negative_balance_rows", "silver.transaction", "INFO", f"""
        SELECT count_if(balance_after < 0) AS failed, count(*) AS total FROM {S}.transaction"""),
]

run_at = datetime.now(timezone.utc)
dq = spark.createDataFrame(
    [(run_at, n, t, sev, f, tot, sev == "INFO" or f == 0) for (n, t, sev, f, tot) in checks],
    "run_at TIMESTAMP, check_name STRING, table_name STRING, severity STRING, "
    "failed_rows BIGINT, total_rows BIGINT, passed BOOLEAN")
dq.write.mode("append").saveAsTable(f"{AUDIT}.dq_result")
display(dq.orderBy("severity", "check_name"))

failed_critical = [c for c in checks if c[2] == "CRITICAL" and c[3] != 0]
if failed_critical:
    raise Exception(f"Data-quality gate FAILED: {failed_critical}")
print(f"Data-quality gate passed: {len(checks)} checks.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Gold: business-ready tables

# COMMAND ----------

G = GOLD

# Default rate by loan size, with 95% Wilson confidence intervals
spark.sql(f"""
CREATE OR REPLACE TABLE {G}.loan_default_by_amount
COMMENT 'Default rate by loan amount band with 95% Wilson confidence interval'
AS
WITH banded AS (
  SELECT CASE WHEN amount <  50000 THEN '1. <50k'
              WHEN amount < 100000 THEN '2. 50-100k'
              WHEN amount < 200000 THEN '3. 100-200k'
              WHEN amount < 400000 THEN '4. 200-400k'
              ELSE                      '5. 400k+' END AS amount_band,
         is_default
  FROM {S}.loan
),
agg AS (
  SELECT amount_band,
         count(*)                      AS n_loans,
         count_if(is_default)          AS n_default,
         CAST(count_if(is_default) AS DOUBLE) / count(*) AS p
  FROM banded GROUP BY amount_band
)
SELECT amount_band, n_loans, n_default,
       round(100 * p, 1) AS default_rate_pct,
       round(100 * (p + 1.96*1.96/(2*n_loans)
              - 1.96 * sqrt(p*(1-p)/n_loans + 1.96*1.96/(4*n_loans*n_loans)))
             / (1 + 1.96*1.96/n_loans), 1) AS ci95_low_pct,
       round(100 * (p + 1.96*1.96/(2*n_loans)
              + 1.96 * sqrt(p*(1-p)/n_loans + 1.96*1.96/(4*n_loans*n_loans)))
             / (1 + 1.96*1.96/n_loans), 1) AS ci95_high_pct
FROM agg
""")

# Did bad borrowers look different in the 90 days BEFORE approval?
# Point-in-time: only transactions strictly before the grant date are used.
spark.sql(f"""
CREATE OR REPLACE TABLE {G}.pre_loan_warning_signs
COMMENT 'Share of borrowers overdrawn or charged penalty interest in the 90 days before loan approval'
AS
WITH per_loan AS (
  SELECT l.loan_id, l.is_default,
         max(CASE WHEN t.balance_after < 0 THEN 1 ELSE 0 END)           AS overdrawn_90d,
         max(CASE WHEN t.purpose = 'penalty_interest' THEN 1 ELSE 0 END) AS penalty_90d
  FROM {S}.loan l
  LEFT JOIN {S}.transaction t
         ON t.account_id = l.account_id
        AND t.trans_date >= date_sub(l.granted_date, 90)
        AND t.trans_date <  l.granted_date
  GROUP BY l.loan_id, l.is_default
)
SELECT CASE WHEN is_default THEN 'defaulted' ELSE 'repaid / repaying' END AS outcome,
       count(*)                          AS n_loans,
       round(100 * avg(overdrawn_90d), 2) AS pct_overdrawn_90d,
       round(100 * avg(penalty_90d), 2)   AS pct_penalty_interest_90d
FROM per_loan
GROUP BY is_default
""")

display(spark.table(f"{G}.pre_loan_warning_signs"))
display(spark.table(f"{G}.loan_default_by_amount").orderBy("amount_band"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. Cross-platform reconciliation
# MAGIC The expected values below come from the PostgreSQL build in this repository
# MAGIC (`sql/06_analysis`). If Databricks produces anything different, the notebook fails.

# COMMAND ----------

expected_counts = {
    "district": 77, "client": 5369, "account": 4500, "disposition": 5369,
    "card": 892, "loan": 682, "permanent_order": 6471, "transaction": 1056320,
}
expected_warning_signs = {   # outcome -> (loans, % overdrawn, % penalty interest)
    "defaulted":         (76,  19.74, 21.05),
    "repaid / repaying": (606,  0.00,  0.33),
}
expected_by_amount = {       # band -> (loans, defaults, default rate %)
    "1. <50k": (126, 5, 4.0), "2. 50-100k": (179, 18, 10.1), "3. 100-200k": (192, 18, 9.4),
    "4. 200-400k": (159, 28, 17.6), "5. 400k+": (26, 7, 26.9),
}

problems = []
for table, n in expected_counts.items():
    got = spark.table(f"{S}.{table}").count()
    if got != n:
        problems.append(f"{table}: {got} rows, expected {n}")

for r in spark.table(f"{G}.pre_loan_warning_signs").collect():
    exp = expected_warning_signs[r["outcome"]]
    got = (r["n_loans"], float(r["pct_overdrawn_90d"]), float(r["pct_penalty_interest_90d"]))
    if got[0] != exp[0] or abs(got[1] - exp[1]) > 0.01 or abs(got[2] - exp[2]) > 0.01:
        problems.append(f"warning signs {r['outcome']}: {got}, expected {exp}")

for r in spark.table(f"{G}.loan_default_by_amount").collect():
    exp = expected_by_amount[r["amount_band"]]
    got = (r["n_loans"], r["n_default"], float(r["default_rate_pct"]))
    if got[0] != exp[0] or got[1] != exp[1] or abs(got[2] - exp[2]) > 0.05:
        problems.append(f"amount band {r['amount_band']}: {got}, expected {exp}")

if problems:
    raise Exception("Reconciliation with PostgreSQL FAILED:\n" + "\n".join(problems))
print("Reconciled: Databricks results match the PostgreSQL warehouse exactly.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Delta Lake features
# MAGIC **Time travel:** every write to a Delta table is a version. You can query any earlier
# MAGIC version for audits, debugging or reproducing a past report.

# COMMAND ----------

display(spark.sql(f"DESCRIBE HISTORY {S}.loan").select("version", "timestamp", "operation"))

# COMMAND ----------

# Version 0 is the table as first created, before any constraints were added
display(spark.sql(f"""
SELECT 'version 0' AS version, count(*) AS loans FROM {S}.loan VERSION AS OF 0
UNION ALL
SELECT 'current', count(*) FROM {S}.loan
"""))

# COMMAND ----------

# Liquid clustering and file layout of the 1M-row transaction table
display(spark.sql(f"DESCRIBE DETAIL {S}.transaction")
        .select("format", "numFiles", "sizeInBytes", "clusteringColumns"))

# COMMAND ----------

# Data-quality history across all runs
display(spark.sql(f"""
SELECT run_at, count(*) AS checks, count_if(NOT passed) AS failed
FROM {AUDIT}.dq_result GROUP BY run_at ORDER BY run_at DESC
"""))
