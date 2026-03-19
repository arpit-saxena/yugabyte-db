# Test Failure Analysis: TestPgRegressFeature#testPgRegressFeature with Connection Manager

## Summary

- **Failures**: 10 out of 10 iterations failed (100% failure rate)
- **Failed sub-test**: `yb.orig.feature_copy` (1 of 10 pg_regress sub-tests)
- **Failure is deterministic** — every single iteration fails with the same root cause

## Error Message

```
java.lang.AssertionError: pg_regress exited with error code: 1, failed tests: [yb.orig.feature_copy]
  at org.yb.pgsql.TestPgRegressFeature.testPgRegressFeature(TestPgRegressFeature.java:55)
```

## Root Cause: Non-deterministic row ordering in `pg_stat_progress_copy` query

The test file `src/postgres/src/test/regress/sql/yb.orig.feature_copy.sql` (lines 37-38) runs:

```sql
SELECT relid::regclass, command, yb_status, type, bytes_processed, bytes_total,
          tuples_processed, tuples_excluded FROM pg_stat_progress_copy;
```

This query has **no `ORDER BY` clause**.

### What happens with Connection Manager enabled

When `--enable_ysql_conn_mgr=true`, the connection manager uses separate backend
processes for different connections. The `pg_stat_progress_copy` view retains one
row per backend, so with connection manager the query returns **3 rows** (one for
each of the 4 COPY operations, but some backends are reused). The expected output
file `yb.orig.feature_copy_1.out` correctly expects 3 rows:

```
 x     | COPY FROM | SUCCESS   | PIPE |              12 |           0 |                1 |               0
 x     | COPY FROM | SUCCESS   | PIPE |              39 |           0 |                4 |               0
 x     | COPY FROM | SUCCESS   | PIPE |              93 |           0 |                5 |               0
(3 rows)
```

However, the **actual row order is non-deterministic** because `pg_stat_progress_copy`
does not guarantee any ordering. Across the 10 iterations, two different orderings
were observed:

**Iteration 1** — order: 12, 93, 39 (rows 2 and 3 swapped vs expected)
```diff
  x     | COPY FROM | SUCCESS   | PIPE |              12 |           0 |                1 |               0
- x     | COPY FROM | SUCCESS   | PIPE |              39 |           0 |                4 |               0
  x     | COPY FROM | SUCCESS   | PIPE |              93 |           0 |                5 |               0
+ x     | COPY FROM | SUCCESS   | PIPE |              39 |           0 |                4 |               0
```

**Iterations 5, 9** — order: 93, 12, 39 (completely different from expected)
```diff
+ x     | COPY FROM | SUCCESS   | PIPE |              93 |           0 |                5 |               0
  x     | COPY FROM | SUCCESS   | PIPE |              12 |           0 |                1 |               0
  x     | COPY FROM | SUCCESS   | PIPE |              39 |           0 |                4 |               0
- x     | COPY FROM | SUCCESS   | PIPE |              93 |           0 |                5 |               0
```

## Fix

Add an `ORDER BY` clause to the query in `yb.orig.feature_copy.sql` (line 37-38)
to make the output deterministic. For example:

```sql
SELECT relid::regclass, command, yb_status, type, bytes_processed, bytes_total,
          tuples_processed, tuples_excluded FROM pg_stat_progress_copy
          ORDER BY bytes_processed;
```

Then update both expected output files (`yb.orig.feature_copy.out` and
`yb.orig.feature_copy_1.out`) to match the ordered output.

## Relevant Files

- `src/postgres/src/test/regress/sql/yb.orig.feature_copy.sql` — test SQL (missing ORDER BY)
- `src/postgres/src/test/regress/expected/yb.orig.feature_copy.out` — expected output without conn mgr (1 row)
- `src/postgres/src/test/regress/expected/yb.orig.feature_copy_1.out` — expected output with conn mgr (3 rows, assumed ordering)
