// Copyright (c) YugabyteDB, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
// in compliance with the License. You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
// or implied. See the License for the specific language governing permissions and limitations
// under the License.
//
package org.yb.ysqlconnmgr;

import static org.yb.AssertionWrappers.assertEquals;
import static org.yb.AssertionWrappers.assertTrue;
import static org.yb.AssertionWrappers.fail;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.yb.minicluster.MiniYBClusterBuilder;
import org.yb.pgsql.ConnectionEndpoint;

/**
 * Regression test for GH#31189 / DB-21062.
 *
 * <p>Before the fix, {@code od_router_gc_cb} would unconditionally free a route whose
 * {@code status == YB_ROUTE_INACTIVE}, even if clients were still attached. Combined with the fact
 * that {@code od_route_free} sets {@code route->err_logger = NULL} while leaving
 * {@code route->extra_logging_enabled = true}, a racing worker coroutine entering
 * {@code od_frontend_cleanup} after the GC would dereference a freed/corrupt route and crash on
 * {@code pthread_mutex_lock(&NULL->lock)} inside {@code od_error_logger_store_err}.
 *
 * <p>In production, this race fires when:
 * <ol>
 *   <li>A client's backend responds with an error that triggers
 *       {@code yb_mark_routes_inactive} (e.g. the PG hint
 *       {@literal "Database may have been dropped and recreated"} seen after a concurrent
 *       {@code DROP DATABASE} on another node, or {@literal "invalid role OID"} after a
 *       {@code DROP ROLE}), marking the route {@code YB_ROUTE_INACTIVE}.</li>
 *   <li>Cron ticks {@code od_router_gc} in between the route being marked INACTIVE and the
 *       worker entering {@code od_frontend_cleanup}, freeing the in-use route.</li>
 * </ol>
 *
 * <p>Reproducing that specific ordering from a functional test is inherently flaky (it depends on
 * the pooler's internal detach/reset timing, whether the backend is reused or a fresh one is
 * spun up, and when cron happens to tick). To get a deterministic signal, this test uses
 * {@code TEST_ysql_conn_mgr_frontend_cleanup_delay_ms}, which at the top of
 * {@code od_frontend_cleanup}:
 * <ul>
 *   <li>marks the client's route as {@code YB_ROUTE_INACTIVE} (mirroring the production
 *       {@code yb_mark_routes_inactive} call), and</li>
 *   <li>sleeps for the configured duration, giving cron's {@code od_router_gc} several ticks
 *       to run against that INACTIVE route while the worker coroutine is mid-flight.</li>
 * </ul>
 *
 * <p>With the pre-fix code in {@code od_router_gc_cb}, the GC sees {@code status == INACTIVE}
 * and unconditionally frees the route even though the client is still in its pool. When the
 * coroutine wakes up it reads {@code route->err_logger}, which was set to {@code NULL} by
 * {@code od_route_free}, and segfaults. With the fix, the GC first checks that the route's
 * client and server pools are empty, skips the route while the client is attached, and the
 * coroutine wakes up to clean up valid memory.
 *
 * <p>The assertion is that after a client disconnects through this stalled cleanup path, the
 * Ysql Connection Manager on the same node can still accept new connections.
 */
@RunWith(value = YBTestRunnerYsqlConnMgr.class)
public class TestGcInactiveRouteUaf extends BaseYsqlConnMgr {

  /**
   * Long enough that cron (which runs every 1s and calls {@code od_router_gc}) is guaranteed
   * to tick at least twice inside the cleanup window.
   */
  private static final int CLEANUP_DELAY_MS = 4000;

  /** Node the test client connects to / pooler under test. */
  private static final int CLIENT_TS_IDX = 0;

  @Override
  protected void customizeMiniClusterBuilder(MiniYBClusterBuilder builder) {
    super.customizeMiniClusterBuilder(builder);

    // Arm the deterministic INACTIVE-route GC race reproducer described in
    // the class javadoc. With this flag > 0, od_frontend_cleanup will mark
    // the client's route INACTIVE and then sleep, giving cron multiple
    // ticks to run od_router_gc against an in-use INACTIVE route.
    builder.addCommonTServerFlag(
        "TEST_ysql_conn_mgr_frontend_cleanup_delay_ms",
        Integer.toString(CLEANUP_DELAY_MS));
  }

  /**
   * Returns the set of PIDs of all currently-running {@code odyssey} processes on this host.
   * The pooler runs as a child of yb-tserver, and yb-tserver's process supervisor will
   * respawn it if it crashes. So if a new PID shows up (or an old one is missing) after the
   * test's race window, Odyssey crashed.
   */
  private static Set<Long> getOdysseyPids() {
    Set<Long> pids = new HashSet<>();
    try {
      Process p = new ProcessBuilder("pgrep", "-x", "odyssey")
                      .redirectErrorStream(true)
                      .start();
      try (BufferedReader r = new BufferedReader(
               new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
        String line;
        while ((line = r.readLine()) != null) {
          line = line.trim();
          if (line.isEmpty()) continue;
          try {
            pids.add(Long.parseLong(line));
          } catch (NumberFormatException e) {
            // ignore non-PID lines
          }
        }
      }
      p.waitFor();
    } catch (Exception e) {
      LOG.warn("Failed to list odyssey PIDs via pgrep", e);
    }
    return pids;
  }

  /**
   * Verifies that the Odyssey pooler on {@link #CLIENT_TS_IDX} can still accept connections
   * after the stalled-cleanup race window closes. If the pooler had crashed with the UAF, this
   * would throw repeatedly and the test would fail.
   */
  private void assertPoolerStillServing() {
    boolean ok = false;
    Exception lastEx = null;
    // A few retries in case a connection lands mid-GC tick.
    for (int i = 0; i < 10; i++) {
      try (Connection conn = getConnectionBuilder()
                                .withTServer(CLIENT_TS_IDX)
                                .withConnectionEndpoint(ConnectionEndpoint.YSQL_CONN_MGR)
                                .connect();
          Statement stmt = conn.createStatement()) {
        stmt.execute("SELECT 1");
        ok = true;
        break;
      } catch (Exception e) {
        lastEx = e;
        try {
          Thread.sleep(500);
        } catch (InterruptedException ignored) {
          Thread.currentThread().interrupt();
        }
      }
    }
    if (!ok) {
      LOG.error("Pooler did not respond after test; likely crashed", lastEx);
      fail("Ysql Connection Manager stopped serving connections after the race window: "
          + lastEx);
    }
  }

  /**
   * Open a client connection, run a query so the route and a backend are established for the
   * client, then close the connection. Closing drives the worker coroutine through
   * od_frontend_cleanup, where the TEST_yb_frontend_cleanup_delay_ms knob marks the route
   * INACTIVE and sleeps for {@link #CLEANUP_DELAY_MS}. During that sleep cron's od_router_gc
   * ticks at least twice (cron interval is 1s). With the buggy GC this frees the in-use
   * route and the subsequent deref of client->route inside od_frontend_cleanup segfaults
   * (see GH#31189). With the fix this is a no-op: the GC skips routes whose client or server
   * pool is still non-empty.
   */
  @Test
  public void testGcDoesNotFreeInUseInactiveRoute() throws Exception {
    // Snapshot the set of running Odyssey PIDs before the race. We will
    // compare against this later to detect any crash-and-respawn: yb-tserver
    // automatically restarts odyssey when it exits (see ProcessSupervisor
    // in src/yb/yql/process_wrapper/process_wrapper.cc), so a changed PID
    // set is the direct evidence of the UAF firing.
    Set<Long> poolerPidsBefore = getOdysseyPids();
    assertTrue("Expected at least one running odyssey process before the test",
        !poolerPidsBefore.isEmpty());
    LOG.info("Odyssey PIDs before the race: " + poolerPidsBefore);

    // Connection + a single query in a dedicated thread so the test harness
    // can time out waiting for the close path (which is intentionally slow
    // due to the injected delay) without hanging forever if the pooler
    // actually crashes.
    Thread clientThread = new Thread(() -> {
      try (Connection conn = getConnectionBuilder()
                                .withTServer(CLIENT_TS_IDX)
                                .withConnectionEndpoint(ConnectionEndpoint.YSQL_CONN_MGR)
                                .connect();
          Statement stmt = conn.createStatement()) {
        stmt.execute("SELECT 1");
        // Falling out of try-with-resources triggers Connection.close(), so
        // the worker coroutine on the pooler enters od_frontend_cleanup and
        // hits the test hook: mark route INACTIVE + sleep. While sleeping,
        // cron's od_router_gc will tick, and we're checking that it does
        // NOT free the still-in-use route.
      } catch (Exception e) {
        LOG.info("Client thread got exception (non-fatal): " + e.getMessage());
      }
    }, "uaf-client-thread");

    clientThread.start();

    // The JDBC client side of close() returns as soon as the TCP socket is
    // shut; it does not wait for the pooler to finish its internal
    // od_frontend_cleanup. The cleanup (sleep + err_logger deref) runs
    // fully asynchronously inside Odyssey. Wait long enough for the
    // injected sleep to elapse AND for the err_logger deref to either
    // succeed (fixed) or crash the pooler (buggy).
    clientThread.join(CLEANUP_DELAY_MS * 2L);
    assertTrue("Client thread did not complete within timeout -- likely a pooler crash",
        !clientThread.isAlive());

    // Sleep past CLEANUP_DELAY_MS plus a healthy margin so that cron has
    // fully run multiple od_router_gc ticks against the INACTIVE route AND
    // the stalled coroutine has woken up and exercised the err_logger
    // deref. Only then is it safe to probe the pooler -- before this, a
    // "successful" new connection could just mean we beat the crash.
    Thread.sleep(CLEANUP_DELAY_MS + 3000L);

    // Check that no Odyssey process got respawned. If the UAF fired, the
    // old Odyssey process on CLIENT_TS_IDX dies with SIGSEGV and
    // yb-tserver's ProcessSupervisor restarts it under a new PID. So the
    // PID set before and after must match exactly.
    Set<Long> poolerPidsAfter = getOdysseyPids();
    LOG.info("Odyssey PIDs after the race: " + poolerPidsAfter);
    List<Long> vanished = new ArrayList<>(poolerPidsBefore);
    vanished.removeAll(poolerPidsAfter);
    List<Long> respawned = new ArrayList<>(poolerPidsAfter);
    respawned.removeAll(poolerPidsBefore);
    assertEquals(
        "Ysql Connection Manager crashed and restarted -- INACTIVE route was freed while"
            + " still in-flight (GH#31189). Vanished PIDs: " + vanished
            + ", respawned PIDs: " + respawned,
        poolerPidsBefore, poolerPidsAfter);

    // Belt-and-suspenders: even with a matching PID set the pooler should
    // be happily serving connections.
    assertPoolerStillServing();
  }
}
