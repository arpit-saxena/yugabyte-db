# YSQL Connection Manager Test Failure Analysis

**Date:** 2026-03-19
**Branch:** `cursor/connection-manager-test-issues-f5db` (base: `wait_for_same_lcv_active_servers`)
**Command:** `yb_build.sh release --java-test <test> --enable-ysql-conn-mgr-test -n 10`
**Environment:** 4 CPUs, 15GB RAM, 64MB `/dev/shm`, AlmaLinux 9 container

## Summary Table

| # | Test | Failure Rate | Category | Root Cause |
|---|------|-------------|----------|------------|
| 1 | TestPgRegressFeature#testPgRegressFeature | 10/10 (100%) | Real | Missing ORDER BY in `pg_stat_progress_copy` query |
| 2 | TestRelcacheUpdate#testRelcacheInitConnectionStress | 10/10 (100%) | Real | Odyssey cannot handle burst of 200 concurrent connections |
| 3 | TestPgRegressThirdPartyExtensionsPgaudit#schedule | 6/10 (60%) | Real | pgaudit session state lost after `\connect` through Odyssey |
| 4 | TestPgCacheConsistency#testPgInheritsCacheConsistency | 3/10 (30%) | Real | Connection pooling breaks catalog cache persistence assumption |
| 5 | TestPgRegressIsolationWithTxnDdl#testPgRegress | 3/10 (30%) | Real | Schema version mismatch race with connection pooling |
| 6 | TestPgStatStatements#testDeleteRpcStats | 3/10 (30%) | Real | Per-backend metric accumulation differs across pooled connections |
| 7 | TestPgRegressPgAsync#schedule | **0/10 (PASS)** | Pass | N/A |
| 8 | TestPgRegressPartitions#partitionwiseJoin | 10/10 | Infra | `/dev/shm` exhaustion from 4 parallel mini-clusters |
| 9 | TestPgRegressLock#testIsolation | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 10 | TestPgStatStatements#testInsertRpcStats | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 11 | TestPgRegressTypesString#schedule | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 12 | TestPgRegressHashIndex#testPgRegressHashIndex | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 13 | TestPgRegressPgAsync#testIsolationPgRegress | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 14 | TestPgRegressMisc#testPgRegressMiscIndependent | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 15 | TestPgListenNotify#testListenNotifyAfterSoloListenerCrash | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 16 | TestPgListenNotify#testListenNotifyAfterPeerListenerCrash | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |
| 17 | TestBindCollectionWithSubscriptedColumn#testCollectionBindUpdates | 10/10 | Infra | Zombie process accumulation exhausted cgroup PID limit |

**Categories:**
- **Real** = Genuine connection manager issue identified
- **Infra** = Test environment resource exhaustion; no connection manager signal obtained
- **Pass** = Test passed all 10 iterations

---

## Detailed Analysis of Real Connection Manager Failures

### 1. TestPgRegressFeature#testPgRegressFeature — Missing ORDER BY (100% failure)

**Failed sub-test:** `yb.orig.feature_copy`

**Error:**
```
java.lang.AssertionError: pg_regress exited with error code: 1, failed tests: [yb.orig.feature_copy]
```

**Root cause:** The query in `src/postgres/src/test/regress/sql/yb.orig.feature_copy.sql` selects from `pg_stat_progress_copy` without an `ORDER BY` clause:

```sql
SELECT relid::regclass, command, yb_status, type, bytes_processed, bytes_total,
       tuples_processed, tuples_excluded FROM pg_stat_progress_copy;
```

When connection manager is enabled, COPY operations may be routed to different backend processes. The `pg_stat_progress_copy` view returns one row per backend, so the query returns 3 rows with **non-deterministic ordering**. The expected output file (`yb.orig.feature_copy_1.out`) assumes ascending order by `bytes_processed` (12, 39, 93), but actual row order varies across runs (observed: `12, 93, 39` and `93, 12, 39`).

**Relevant files:**
- `src/postgres/src/test/regress/sql/yb.orig.feature_copy.sql` (line 37-38)
- `src/postgres/src/test/regress/expected/yb.orig.feature_copy_1.out`

---

### 2. TestRelcacheUpdate#testRelcacheInitConnectionStress — Connection Burst Capacity (100% failure)

**Error:**
```
java.lang.AssertionError: Total connection successes mismatch expected:<200> but was:<104>
  at TestRelcacheUpdate.testRelcacheInitConnectionStress(TestRelcacheUpdate.java:738)
```

**Root cause:** The test attempts 200 concurrent connections across multiple databases. With connection manager (Odyssey) enabled, the connection pooler becomes saturated and drops/refuses new connection attempts. Actual successful connections ranged from 64 to 180 across iterations, never reaching the expected 200. The underlying error from `ConnectionBuilder.connect()` is `"The connection attempt failed"`.

A secondary failure mode occurred in 2/10 iterations where the 3rd tablet server failed to start within the 60-second timeout due to resource contention:
```
java.lang.RuntimeException: Timed out waiting for a 'server starting' message to appear. Waited for 60000.
```

**Relevant file:** `java/yb-pgsql/src/test/java/org/yb/pgsql/TestRelcacheUpdate.java:738`

---

### 3. TestPgRegressThirdPartyExtensionsPgaudit#schedule — pgaudit Session State Loss (60% failure)

**Failed sub-test:** `yb.port.pgaudit`

**Error:**
```
java.lang.AssertionError: pg_regress exited with error code: 1, failed tests: [yb.port.pgaudit]
```

**Root cause:** When the YSQL connection manager handles `\connect` commands, it can reassign the logical session to a different backend. This causes the **pgaudit extension's session-level state** to be lost or improperly initialized. Three distinct variants were observed:

- **Variant A** (iteration 2): After initial `\connect`, the first `CREATE ROLE` statement's audit NOTICE (`SESSION,1,1,...`) is silently dropped. All subsequent statement counters shift by -1.

- **Variant B** (iterations 3, 5, 6, 7): After `\connect - :current_user`, a block of SET statements (`SET pgaudit.log`, `SET pgaudit.log_client`, etc.) and subsequent DDL produce **zero** AUDIT NOTICE messages. The pgaudit hook appears not to fire at all.

- **Variant C** (iteration 8): After `\connect - :current_user`, the first `ALTER ROLE` statement's audit NOTICE is missing, subsequent counters shift.

The non-deterministic nature (60% failure rate) is consistent with connection pooling race conditions: the outcome depends on whether Odyssey reuses an existing backend connection or creates a fresh one after each `\connect`.

**Relevant file:** pgaudit third-party extension test SQL and expected output files

---

### 4. TestPgCacheConsistency#testPgInheritsCacheConsistency — Catalog Cache Invalidation (30% failure)

**Error:**
```
java.lang.AssertionError: expected:<23> but was:<24>
  at TestPgCacheConsistency.testPgInheritsCacheConsistency(TestPgCacheConsistency.java:636)
```

**Root cause:** The test relies on **per-connection catalog cache persistence** for snapshot isolation behavior. The sequence is:
1. `stmt2` starts a transaction (`BEGIN`)
2. `stmt1` creates a new partition `prt_p26` and inserts a row (commits)
3. The test expects `stmt2`'s `SELECT` to return 23 rows (not seeing the new partition due to its stale cached partition list)
4. But `stmt2` sees 24 rows

With connection manager enabled, `stmt2`'s `BEGIN` and subsequent `SELECT` may be routed to a **different backend process** than the one that had the stale cached partition list from the first loop. A fresh backend loads the catalog including the newly-created partition, breaking the snapshot isolation assumption the test relies on.

The 30% failure rate corresponds to the probability that the connection manager reassigns the connection to a different backend between the first loop's final query and the second loop's `BEGIN`/`SELECT`.

**Relevant file:** `java/yb-pgsql/src/test/java/org/yb/pgsql/TestPgCacheConsistency.java:636`

---

### 5. TestPgRegressIsolationWithTxnDdl#testPgRegress — Schema Version Mismatch Race (30% failure)

**Failed sub-test:** `yb.orig.read_committed_test_ddl_txn`

**Error (from regression diff):**
```
ERROR:  schema version mismatch for table 000034e100003000800000000000400f: expected 1, got 0
```
(SQLSTATE `40001` serialization_failure, on statement `UPDATE test SET v = 150 WHERE k = 1;`)

**Root cause:** A schema version propagation race condition with connection pooling:
1. Session s1 runs `ALTER TABLE test ADD COLUMN a int;`, bumping table schema version from 0 to 1
2. Session s2 runs `UPDATE test SET v = 150 WHERE k = 1;` through Odyssey
3. Odyssey routes s2's query to a pooled backend that still has **schema version 0** cached
4. DocDB detects the mismatch and raises `ERROR 40001`
5. The error surfaces to the client instead of being transparently retried (as READ COMMITTED isolation would normally do)

The 30% failure rate reflects the timing race between schema cache invalidation propagation and the DML execution on the pooled backend. 70% of the time propagation wins; 30% of the time the DML hits a stale-cached backend.

**Relevant file:** `yb.orig.read_committed_test_ddl_txn` isolation regress test

---

### 6. TestPgStatStatements#testDeleteRpcStats — Metric Accumulation Mismatch (30% failure)

**Error:**
```
java.lang.AssertionError: expected:<3> but was:<2>
  at TestPgStatStatements.verifyMetrics(TestPgStatStatements.java:191)
  at TestPgStatStatements.testDeleteRpcStats(TestPgStatStatements.java:447)
```

**Root cause:** The test runs a DELETE query, records its `pg_stat_statements` docdb seek metrics as the expected baseline, then runs the same DELETE again and verifies the seek count matches. With connection pooling, the two DELETE executions can land on **different physical backends**.

The first DELETE executes on a backend that performs 3 seeks (including an initial catalog/index seek). The verification DELETE lands on a different backend where cached state eliminates one seek, producing only 2. The 30% failure rate reflects the probability of queries being routed to different backends.

**Relevant file:** `java/yb-pgsql/src/test/java/org/yb/pgsql/TestPgStatStatements.java:191,447`

---

## Test That Passed

### 7. TestPgRegressPgAsync#schedule — PASSED (0/10 failures)

This test passed all 10 iterations with connection manager enabled. No issues found.

---

## Tests With Inconclusive Results (Infrastructure Failures)

The following 10 tests could not be meaningfully evaluated due to test environment resource exhaustion. They are listed as tests 8-17 in the summary table.

### Root Cause of Infrastructure Failures

The `-n 10` flag runs 10 iterations with parallelism of 4 (4 concurrent mini-clusters). Each mini-cluster with connection manager enabled spawns:
- 3 yb-master processes
- 3 yb-tserver processes
- 3 Odyssey connection manager processes
- Multiple PostgreSQL backend processes

With 4 iterations running simultaneously, this creates ~80+ heavyweight processes competing for:
1. **`/dev/shm` (64MB limit):** Shared memory for PostgreSQL backends filled up, causing `FATAL: could not resize shared memory segment: No space left on device` and `SIGBUS` crashes in `SharedMemoryBackingAllocator::Prepare()`
2. **Cgroup PID limit (19,213):** Crashed and restarting PostgreSQL processes accumulated as zombie children of PID 1 (container init). Over ~18,000 zombies accumulated, consuming 98% of the cgroup PID limit and preventing new process creation (`pthread_create: Resource temporarily unavailable`)

### Affected Tests

| Test | Notes |
|------|-------|
| TestPgRegressPartitions#partitionwiseJoin | All iterations hit `/dev/shm` exhaustion; Odyssey reported `Resource temporarily unavailable` on backend sockets |
| TestPgRegressLock#testIsolation | Zombie PID accumulation; `pthread_create` failures |
| TestPgStatStatements#testInsertRpcStats | Zombie PID accumulation; mixed `pthread_create` + SIGBUS + connection timeout failures |
| TestPgRegressTypesString#schedule | SIGBUS during master startup |
| TestPgRegressHashIndex#testPgRegressHashIndex | SIGBUS during master startup |
| TestPgRegressPgAsync#testIsolationPgRegress | SIGBUS during master startup |
| TestPgRegressMisc#testPgRegressMiscIndependent | SIGBUS during master startup |
| TestPgListenNotify#testListenNotifyAfterSoloListenerCrash | SIGBUS during master startup |
| TestPgListenNotify#testListenNotifyAfterPeerListenerCrash | SIGBUS during master startup |
| TestBindCollectionWithSubscriptedColumn#testCollectionBindUpdates | SIGBUS during master startup |

### Recommendation

These tests need to be re-run in an environment with:
- Larger `/dev/shm` (at least 512MB)
- Higher cgroup PID limit (at least 50,000)
- A container init process that reaps zombie children (e.g., `tini` or `dumb-init`)
- Or reduce parallelism: run with `-n 1` or set `--num-iter-parallelism 1`

---

## Common Themes Across Real Failures

The 6 genuine connection manager failures fall into three categories:

### Category A: Connection Pooling Breaks Session Affinity
Tests 3 (pgaudit), 4 (cache consistency), 5 (schema version), and 6 (stat statements) all fail because the connection manager can route successive queries from the same logical session to **different physical backend processes**. This breaks assumptions about:
- Per-backend catalog cache state persistence
- Per-backend extension session state (pgaudit counters)
- Per-backend `pg_stat_statements` metric accumulation
- Schema version cache freshness across backends

### Category B: Non-Deterministic Row Ordering
Test 1 (feature_copy) fails because `pg_stat_progress_copy` returns rows from multiple backends without deterministic ordering. The test expected output assumes a specific row order.

### Category C: Connection Capacity Under Load
Test 2 (relcache stress) fails because Odyssey has limited capacity for handling large bursts of concurrent connections, dropping connections that the test expects to succeed.
