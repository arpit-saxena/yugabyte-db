# TestPgRegressPartitions#partitionwiseJoin - Regression Diff Analysis

## Test: `yb.port.partition_join` (via pg_regress)

All 10 iterations failed. Iterations 5-10 failed due to `/dev/shm` SIGBUS during master
startup (covered in `conn_mgr_test_failure_analysis.md`). **This analysis covers iterations
1-4**, which actually started their clusters and ran the pg_regress test.

---

## Regression Diff (identical pattern across iterations 1-4)

```
diff -U3 expected/yb.port.partition_join.out results/yb.port.partition_join.out
@@ -15,2925 +15,10 @@
 CREATE TABLE prt1_p2 PARTITION OF prt1 FOR VALUES FROM (250) TO (500);
 INSERT INTO prt1 SELECT i, i % 25, to_char(i, 'FM0000') FROM generate_series(0, 599) i WHERE i % 2 = 0;
 CREATE INDEX iprt1_p1_a on prt1_p1(a);
-CREATE INDEX iprt1_p2_a on prt1_p2(a);
-CREATE INDEX iprt1_p3_a on prt1_p3(a);
-ANALYZE prt1;
-CREATE TABLE prt2 (a int, b int, c varchar) PARTITION BY RANGE(b);
-... (2925 expected lines removed) ...
+FATAL:  terminating connection due to administrator command
+FATAL:  Shutdown connection
+ERROR:  odyssey: c...: remote server read/write error s...: Resource temporarily unavailable
+server closed the connection unexpectedly
+	This probably means the server terminated abnormally
+	before or while processing the request.
+connection to server was lost
```

The test completes 14 SQL statements (SET statements, CREATE TABLE, CREATE PARTITION
tables, INSERT, CREATE INDEX iprt1_p1_a) then the **Odyssey connection manager kills
the connection** before `CREATE INDEX iprt1_p2_a` can execute. The remaining 2925 lines
of expected output are never produced.

## Per-Iteration Actual Output (the + lines)

| Iter | Actual output replacing 2925 expected lines |
|------|----------------------------------------------|
| 1    | `FATAL: terminating connection due to administrator command` / `FATAL: Shutdown connection` / `ERROR: odyssey: ...: remote server read/write error ...: Resource temporarily unavailable` / `server closed the connection unexpectedly` / `connection to server was lost` |
| 2    | `FATAL: terminating connection due to administrator command` / `FATAL: recvmsg error: Connection refused` / `server closed the connection unexpectedly` / `connection to server was lost` |
| 3    | `FATAL: terminating connection due to administrator command` / `FATAL: recvmsg error: Connection reset by peer` / `ERROR: odyssey: ...: remote server read/write error ...: Resource temporarily unavailable` / `server closed the connection unexpectedly` / `connection to server was lost` |
| 4    | `FATAL: terminating connection due to administrator command` / `FATAL: Shutdown connection` / `ERROR: odyssey: ...: remote server read/write error ...: Resource temporarily unavailable` / `server closed the connection unexpectedly` / `connection to server was lost` |

## Root Cause: `/dev/shm` Exhaustion During Parallel Test Execution

### Timeline (Iteration 1 as representative)

| Time | Event |
|------|-------|
| 10:27:26 | Masters start (3 per iteration × 4 iterations = 12 masters) |
| 10:27:33 | TServers start (3 per iteration × 4 iterations = 12 tservers) |
| 10:27:34 | ts1 starts Odyssey connection manager on port 29931 |
| 10:27:34.140 | **ts1 PostgreSQL server terminated with signal 2 (SIGINT)** during warmup |
| 10:27:35.749 | **ts2 PostgreSQL server terminated with signal 2** during warmup |
| 10:27:36.267 | **ts3 PostgreSQL server terminated with signal 2** during warmup |
| **10:27:37.209** | **First `/dev/shm` exhaustion**: `FATAL: could not resize shared memory segment "/PostgreSQL.673945182" to 1048576 bytes: No space left on device` |
| 10:27:37-10:35:46 | **ts2 enters infinite crash loop**: PostgreSQL starts → fails to allocate shm → crashes → restarts (1144 cycles in ~8 minutes) |
| 10:27:38 | ts1 also hits shm errors: `Failed to create segment yb_pg_..._8 of size 4096: No space left on device` |
| 10:27:38.895 | ts3: `WARNING: terminating active server processes due to backend crash while acquiring LWLock` |
| 10:27:40 | pg_regress starts test `yb.port.partition_join` on ts1 (Odyssey port 29931) |
| 10:28:29-10:28:34 | Test processes CREATE TABLE prt1_p2, DDL commit with 1s sleep |
| ~10:28:xx | **Connection killed by Odyssey** after ~17 SQL statements |
| 10:35:46 | pg_regress exits after 486s (test process exit code 2) |

### Quantified Impact

| Metric | Iter 1 | Iter 2 | Iter 3 | Iter 4 |
|--------|--------|--------|--------|--------|
| "No space left on device" errors | 1,149 | 2,293 | 1,156 | 2,302 |
| PostgreSQL restart cycles | 1,146 | 2,292 | 1,147 | 2,296 |
| Test duration (ms) | 486,806 | 486,879 | 486,563 | 485,635 |
| First shm exhaustion time | 10:27:37.209 | 10:27:37.322 | 10:27:37.439 | 10:27:37.209 |

### Causal Chain

```
4 parallel test iterations start simultaneously
  → 12 masters + 12 tservers + 12 Odyssey instances + 12 PostgreSQL backends
    → All allocating shared memory in /dev/shm (64MB limit)
      → /dev/shm fills up within ~4 seconds of tserver startup
        → PostgreSQL backends on ts2/ts3 cannot start (shm allocation fails)
          → ts2/ts3 enter infinite crash-restart loop (~1 restart every 0.4s)
            → Raft consensus breaks (ts1 can't replicate to ts2/ts3)
              → DDL operations on ts1 stall (waiting for tablet replication)
                → Odyssey connection manager terminates stalled connection
                  → psql receives: "terminating connection due to administrator command"
                    → "remote server read/write error: Resource temporarily unavailable"
                      → "server closed the connection unexpectedly"
                        → pg_regress diff: 2925 lines missing, 10 error lines instead
```

## Connection Manager Involvement

The test runs with these connection manager flags:
- `--enable_ysql_conn_mgr=true`
- `--TEST_ysql_conn_mgr_dowarmup_all_pools_mode=random` (randomly triggers pool dowarmup)
- `--ysql_conn_mgr_superuser_sticky=false`
- `--graceful_shutdown=false`

The connection manager (Odyssey) is directly involved in the failure mechanism:

1. **Odyssey terminates the client connection** (`FATAL: Shutdown connection`) when it
   can no longer communicate with its PostgreSQL backend server
2. **`Resource temporarily unavailable` (EAGAIN)** on the Odyssey→PostgreSQL backend socket
   indicates the backend process is unresponsive or dead
3. The `TEST_ysql_conn_mgr_dowarmup_all_pools_mode=random` flag may have also contributed
   by triggering a pool dowarmup that killed the active backend connection

The `connection manager: adding sleep of 1000000 microseconds after DDL commit` log
message (at 10:28:33.950) shows the DDL-aware connection manager sleep was active during
the test. This 1-second post-DDL sleep is part of the `wait_for_same_lcv_active_servers`
feature.

## Conclusion

**This is NOT a `wait_for_same_lcv_active_servers` or connection manager code bug.**
The failure is caused by `/dev/shm` exhaustion from running 4 test iterations in parallel,
each spawning a 3-node cluster (12 PostgreSQL instances total). The `/dev/shm` 64MB limit
is insufficient for this workload. The connection manager is the component that
surfaces the error to the client, but it is not the root cause.

The same `/dev/shm` exhaustion also caused iterations 5-10 to fail at master startup
(SIGBUS), as documented in `conn_mgr_test_failure_analysis.md`.
