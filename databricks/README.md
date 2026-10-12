# Running the lakehouse port on Databricks Free Edition

`berka_lakehouse.py` is a Databricks notebook in source format. It rebuilds the warehouse as
bronze, silver and gold Delta tables, runs the data-quality gate, and checks that its results
match the PostgreSQL build.

Takes about 5 minutes the first time. Everything runs on the free serverless compute.

## 1. Create a workspace

Sign up for **Databricks Free Edition** at databricks.com (search "Databricks Free Edition").
Community Edition has been retired, so use Free Edition.

## 2. Import the notebook

1. In the left sidebar, click **Workspace**.
2. Open your home folder, click the **⋮** menu (or right-click), then **Import**.
3. Choose **File**, select `databricks/berka_lakehouse.py` from this repo, and click **Import**.

Alternatively, link the whole GitHub repo with **Workspace > Create > Git folder** and open the
notebook from there.

## 3. Create the volume and upload the data

1. Open the notebook and click **Connect**, then choose **Serverless**.
2. Run only the first code cell (**0. Setup**). It creates the schemas and an empty volume,
   then stops with a message asking for the files. That is expected.
3. In the left sidebar click **Catalog**, then open **workspace > berka_bronze > Volumes > landing**.
4. Click **Upload to this volume** and upload the 8 CSV files:
   `account.csv card.csv client.csv disp.csv district.csv loan.csv order.csv trans.csv`

## 4. Run it

Back in the notebook, click **Run all**. When it finishes you should see:

- the data-quality results table with every CRITICAL check passing
- `Reconciled: Databricks results match the PostgreSQL warehouse exactly.`
- the Delta table history and time-travel query at the end

If your catalog is not called `workspace`, change the **catalog** box at the top of the
notebook before running.

## What it creates

| Schema | Tables |
|---|---|
| `berka_bronze` | 8 raw tables + the `landing` volume |
| `berka_silver` | `district`, `client`, `account`, `disposition`, `card`, `loan`, `permanent_order`, `transaction`, `code_lookup`, plus 3 SQL functions |
| `berka_audit` | `dq_result` (appended every run) |
| `berka_gold` | `loan_default_by_amount`, `pre_loan_warning_signs` |

## Differences from the PostgreSQL build

- **Liquid clustering instead of yearly partitions.** Databricks recommends clustering on the
  columns you filter by (`account_id`, `trans_date`) rather than hive-style partitions for a
  table of this size.
- **Keys are informational.** Unity Catalog records primary and foreign keys but does not
  enforce them. `CHECK` and `NOT NULL` constraints are enforced.
- **Scope.** The port covers ingestion, cleaning, the critical data-quality checks and two gold
  tables. The scorecard, RFM segmentation and other analyses stay in PostgreSQL.
