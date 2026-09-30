# Performance notes

All timings on PostgreSQL 16, full dataset (1,056,320 transactions), default
`work_mem = 64MB`. Plans captured with `EXPLAIN (ANALYZE, COSTS OFF)`.

## 1. Composite covering index on the hot path

The single most common access pattern in the analysis layer is
*"movements of one account within a date window"* (pre-loan features, customer
360, repayment tracking).

```sql
SELECT count(*), sum(signed_amount)
FROM core.transaction
WHERE account_id = 2378 AND trans_date >= DATE '1998-01-01';
```

| | Plan | Execution time |
|---|---|---|
| Without index | Parallel Seq Scan on `transaction_y1998`, 2 workers, 322k rows filtered | **16.4 ms** |
| With `ix_trans_account_date (account_id, trans_date) INCLUDE (signed_amount, balance_after)` | Bitmap Index Scan, 68 rows read | **0.35 ms** |

About **47x faster**, and it stays flat as the table grows, whereas the scan
grows linearly. Because the index is defined on the partitioned parent, every
yearly partition gets its own copy automatically.

## 2. Partition pruning

`core.transaction` is range-partitioned by year. In both plans above, the
planner only touched `transaction_y1998` (plus the empty `DEFAULT` safety
partition). The five partitions for 1993-1997 were **never opened**, because
the `trans_date` predicate proves they can't contain matching rows.

Other benefits that matter in production:

- Dropping or archiving a year is `DETACH PARTITION`, which is instant, instead
  of a multi-million-row `DELETE`.
- `VACUUM` and `ANALYZE` work partition by partition.
- New data only touches the current partition's indexes.

## 3. Pre-aggregation with materialized views

Bank-wide monthly net flow:

| Source | Execution time |
|---|---|
| `core.transaction` (1.06M rows, aggregate at query time) | **251 ms** |
| `mart.fact_account_month` (186k pre-aggregated rows) | **33 ms** |

The dashboards and the 15 analysis queries read from the mart, so they all run
in under 1.4 seconds (see `scripts/run_analysis.sh` output). Each materialized
view has a `UNIQUE` index, so it can be refreshed with
`REFRESH MATERIALIZED VIEW CONCURRENTLY` without blocking readers
(`CALL mart.sp_refresh_mart(true)`).

## 4. Rewriting a correlated subquery as a hash join

The end-of-day balance logic first used a correlated `EXISTS` inside
`ORDER BY`. That forced PostgreSQL to run the subquery once per transaction
(1M executions), and it had not finished after 2 minutes.

Rewritten as a `LEFT JOIN ... GROUP BY` so the planner could use a single hash
join, the same result builds in **about 10 seconds**. See the `eod` CTE in
`sql/05_mart/02_facts.sql`.

## 5. Load-time choices

- Staging columns are `TEXT` and the bulk load uses `\copy`. That lands 1.06M
  rows in about 1 second.
- Indexes are built **after** the load. That is faster than maintaining them
  row by row during 1M inserts.
- `ANALYZE` runs at the end of `core.sp_load_core()`, so the planner has fresh
  statistics before the mart is built.

A full rebuild from raw CSVs takes **about 31 seconds** end to end.
