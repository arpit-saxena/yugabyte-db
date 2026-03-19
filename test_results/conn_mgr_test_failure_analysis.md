# Connection Manager Test Failure Analysis

All three tests were run 10 times each with `--enable-ysql-conn-mgr-test`.
**All 30 iterations (10/10 for each test) failed with the identical root cause.**

## Common Root Cause: `/dev/shm` Exhaustion → SIGBUS in Shared Memory Allocator

**`/dev/shm` is 100% full** (64MB limit, 64MB used). It contains ~2700 leaked files:
- 398 `yb_shm-*` files (~143MB logical size, from crashed master/tserver processes)
- 2293 `yb_pg_*` files (~9MB, from crashed PostgreSQL backends)
- 13 `PostgreSQL.*` files (~4MB)

These are orphaned shared memory segments from previous test runs where processes
crashed and did not clean up. Because `/dev/shm` is at capacity, new `shm_open()` +
`ftruncate()` calls cannot allocate backing pages. When master processes attempt to
`memset` (zero-initialize) the `HeaderSegment` in the newly memory-mapped region, the
kernel delivers **SIGBUS** because the tmpfs filesystem cannot fulfill the page fault.

### Crash Stack Trace (identical across all failures)

```
*** SIGBUS received ***
  __memset_avx512_unaligned_erms
  yb::SharedMemoryBackingAllocator::Impl::Prepare()
  yb::SharedMemoryBackingAllocator::Prepare()
  yb::tserver::SharedMemoryManager::PrepareAllocators()
  yb::tserver::SharedMemoryManager::InitializeTServer()
  yb::tserver::DbServerBase::Init()
  yb::master::Master::Init()
  main
```

All 3 masters in each cluster crash with exit code **135** (128 + SIGBUS=7)
immediately after logging `Preparing shared memory allocator (prefix: ...)`.

The Java test framework then either:
- **Waits 120 seconds** for a "server starting" log line that never appears (iterations 1-7)
- **Detects exit code 135 immediately** when the first master is the one being
  waited on (iterations 8-10, which fail in ~8-11 seconds)

---

## Test 1: TestPgRegressMisc#testPgRegressMiscIndependent

- **Failures**: 10/10
- **Error**: `java.lang.RuntimeException: Timed out waiting for a 'server starting' message to appear. Waited for 119999.` (long iterations) or `java.lang.Exception: We tried starting a process (.../yb-master) but it exited with value=135` (short iterations)
- **Fail tag**: `signal_SIGBUS`
- **Call chain**: `BaseMiniClusterTest.setUpBefore:191 → createMiniCluster:322`
- **Root cause**: All 3 masters crash with SIGBUS in `SharedMemoryBackingAllocator::Impl::Prepare()` because `/dev/shm` is full. The test never reaches pg_regress execution.

## Test 2: TestPgListenNotify#testListenNotifyAfterSoloListenerCrash

- **Failures**: 10/10
- **Error**: `java.lang.RuntimeException: Timed out waiting for a 'server starting' message to appear. Waited for 120000.` (long iterations) or `We tried starting a process (.../yb-master) but it exited with value=135` (short iterations)
- **Fail tag**: `signal_SIGBUS`
- **Call chain**: `BaseMiniClusterTest.setUpBefore:191 → createMiniCluster:322`
- **Root cause**: Identical to Test 1. All 3 masters crash with SIGBUS in shared memory allocator. The test never reaches LISTEN/NOTIFY logic.

## Test 3: TestBindCollectionWithSubscriptedColumn#testCollectionBindUpdates (CQL)

- **Failures**: 10/10
- **Error**: `java.lang.RuntimeException: Timed out waiting for a 'server starting' message to appear. Waited for 120000.` (long iterations) or `We tried starting a process (.../yb-master) but it exited with value=135` (short iterations)
- **Fail tag**: `signal_SIGBUS`
- **Call chain**: `BaseMiniClusterTest.setUpBefore:191 → createMiniCluster:322`
- **Root cause**: Identical to Tests 1 and 2. Despite being a CQL test, the failure is in master startup, same SIGBUS in shared memory allocator. The test never reaches CQL bind/collection logic.

---

## Key Observation

**These failures are NOT caused by the YSQL connection manager.** The failures occur
during `yb-master` initialization, before any connection manager, tserver, or
PostgreSQL/CQL logic is reached. The connection manager flag (`--enable-ysql-conn-mgr-test`)
is irrelevant to these failures.

The root cause is an **infrastructure/environment issue**: the `/dev/shm` tmpfs
(limited to 64MB in this Docker/container environment) has been exhausted by leaked
shared memory segments from prior test runs. Any test that starts a MiniYBCluster
will fail with this same SIGBUS pattern until the orphaned `/dev/shm` files are
cleaned up or the `/dev/shm` size limit is increased.

## Remediation

1. **Immediate**: Clean up orphaned files: `rm /dev/shm/yb_shm-* /dev/shm/yb_pg_* /dev/shm/PostgreSQL.*`
2. **Environment**: Increase `/dev/shm` size limit (e.g., `--shm-size=512m` in Docker)
3. **Test harness**: Add cleanup of stale `/dev/shm` files before test runs, or improve
   process crash cleanup to `shm_unlink()` segments on abnormal termination
