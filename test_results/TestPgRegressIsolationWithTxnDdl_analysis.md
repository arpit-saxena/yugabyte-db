# Test Failure Analysis: TestPgRegressIsolationWithTxnDdl#testPgRegress (Connection Manager Enabled)

## Summary

- **Iterations run:** 10
- **Failures:** 3 out of 10 (iterations 2, 5, 9) -- **30% failure rate**
- **Passes:** 7 out of 10 (iterations 1, 3, 4, 6, 7, 8, 10)
- **Failed sub-test:** `yb.orig.read_committed_test_ddl_txn` (same in all 3 failures)
- **Test flags:** `--enable_ysql_conn_mgr=true`, `ysql_yb_ddl_transaction_block_enabled=true`, `yb_enable_read_committed_isolation=true`

## Error Message

```
ERROR:  schema version mismatch for table 000034e100003000800000000000400f: expected 1, got 0
```

SQLSTATE error code: **40001** (serialization_failure)

Triggering statement: `UPDATE test SET v = 150 WHERE k = 1;` (step `update_11_row_in_s2`)

## Regression Diff (identical in all 3 failures)

```diff
 step b2: BEGIN ISOLATION LEVEL READ COMMITTED;
 step s1_add_column_a: alter table test add column a int;
 step update_11_row_in_s2: update test set v = 150 where k = 1;
-step update_11_row_in_s1: update test set v = 100 where k = 1; <waiting ...>
+ERROR:  schema version mismatch for table 000034e100003000800000000000400f: expected 1, got 0
+step update_11_row_in_s1: update test set v = 100 where k = 1;
 step c2: commit;
-step update_11_row_in_s1: <... completed>
 step c1: commit;
```

## Root Cause Pattern

This is a **race condition in schema version propagation** when using the YSQL Connection Manager (Odyssey).

### Test Scenario

The isolation test exercises concurrent DDL and DML under READ COMMITTED:

1. **Session s1** runs `ALTER TABLE test ADD COLUMN a int;` -- this changes the table's schema version from 0 to 1
2. **Session s2** runs `UPDATE test SET v = 150 WHERE k = 1;` concurrently
3. **Expected behavior:** s1's UPDATE (`v = 100`) should block waiting on s2's row lock, then complete after s2 commits
4. **Actual behavior (failure):** s2's UPDATE gets `ERROR: schema version mismatch` instead of succeeding

### Why Connection Manager Causes This

With connection manager enabled, Odyssey pools backend PostgreSQL connections. The sequence of events in the failure case:

1. s1's `ALTER TABLE` commits on a backend, bumping the table schema version to 1
2. The connection manager adds a 1-second sleep after DDL commit (`connection manager: adding sleep of 1000000 microseconds after DDL commit`) to allow schema propagation
3. However, s2's `UPDATE` is routed to a backend that still has the **stale schema version 0** cached
4. When this backend attempts the write, DocDB detects the mismatch: `expected 1, got 0`
5. The backend invalidates its cache (`invalidating table cache entry 000034e100003000800000000000400f`) but the error (SQLSTATE 40001) has already been raised

### Why Transparent Retry Fails

Under READ COMMITTED isolation, a `40001` serialization error should normally be retried transparently by the YSQL layer. However, in this scenario with connection manager:

- The error surfaces to the pg_isolation_regress test client through Odyssey before the retry logic can handle it
- The connection manager's connection pooling means the backend that receives the error may not be the same one that will handle the retry
- The result is the raw `ERROR 40001 schema version mismatch` being propagated to the client, breaking the expected test output

### Key Evidence from Logs

From all three failed iterations, the tserver logs show the same pattern:

```
LOG:  invalidating table cache entry 000034e100003000800000000000400f
STATEMENT:  update test set v = 150 where k = 1;
ERROR:  schema version mismatch for table 000034e100003000800000000000400f: expected 1, got 0
STATEMENT:  update test set v = 150 where k = 1;
```

Followed shortly after by:

```
LOG:  connection manager: adding sleep of 1000000 microseconds after DDL commit
STATEMENT:  commit;
```

This shows the DDL commit sleep (designed to allow schema propagation) happens **after** the DML on the other session has already hit the stale cache -- a timing-dependent race.

## Flakiness Nature

This is a **flaky/intermittent** failure (30% rate) because:
- It depends on the timing of schema cache invalidation propagation across connection-manager-pooled backends
- When the cache invalidation reaches the s2 backend before s2's UPDATE executes, the test passes (70% of the time)
- When s2's UPDATE hits a backend with stale cache before invalidation propagates, it fails

## Relevant Stack Trace

```
java.lang.AssertionError: pg_regress exited with error code: 1, failed tests: [yb.orig.read_committed_test_ddl_txn]
    at org.yb.pgsql.PgRegressRunner.run(PgRegressRunner.java:...)
    at org.yb.pgsql.BasePgSQLTest.runPgRegressTest(BasePgSQLTest.java:...)
    at org.yb.pgsql.TestPgRegressIsolationWithTxnDdl.testPgRegress(TestPgRegressIsolationWithTxnDdl.java:...)
```
