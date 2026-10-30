# GucVersioning: results

Spec `GucVersioning.tla`, default config `GucVersioning.cfg`, driver `run-versioning.sh`
(`matrix`, `liveness`, `one ...`). TLC 2026.10.28, JDK 17, 32 workers, on a host shared with
another TLC job, so times are indicative only. Each property was checked in its own run so
every violation is reported.

## Bounds used

| Run | NODES | CLIENTS | SPN | MAXSTMTS | MAXSESS | MAXALTER | MAXSIGHUP | TTL | AUTH | STALE_READS |
|---|---|---|---|---|---|---|---|---|---|---|
| safety matrix | 2 | 2 | 2 | 3 | 1 | 2 | 1 | timed | passthrough | FALSE |
| liveness, 1 node | 1 | 2 | 2 | 2 | 1 | 1 | 1 | timed | passthrough | FALSE |
| liveness, 2 nodes | 2 | 2 | 2 | 1 | 1 | 1 | 1 | timed | passthrough | FALSE |

The safety bounds are the plan's. Liveness is checked at the reduced bounds above:
2 clients x MAXSTMTS 2 x MAXALTER 2 on 2 nodes was over 5.6M distinct states after 3 minutes
and still growing, so it was stopped. No StateConstraint is needed: every action is bounded
by a counter (statements, sessions, ALTERs, SIGHUPs), so the state space is finite.
Deadlock checking is off because exhausted counters end in terminal states.

## Matrix (safety; PASS/FAIL, distinct states, seconds)

FAIL runs stop at the first counterexample; their state counts are not meaningful.

| Property | fluct/on_read | fluct/pushed | gradual/on_read | gradual/pushed | static/on_read | static/pushed |
|---|---|---|---|---|---|---|
| P5 (same node) | PASS 2.7M 20s | PASS 53.9M 549s | PASS 2.0M 16s | PASS 38.1M 299s | PASS 0.34M 5s | PASS 5.0M 101s |
| P5x (cross node) | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| P10 (LCV monotonic) | FAIL | FAIL | PASS 2.0M 17s | PASS 38.1M 445s | PASS 0.34M 6s | PASS 5.0M 116s |
| P10d (defaults monotonic) | FAIL | FAIL | PASS 2.0M 17s | PASS 38.1M 366s | PASS 0.34M 5s | PASS 5.0M 108s |
| P12 (static: LCV = auth LCV) | FAIL (n/a) | FAIL (n/a) | FAIL (n/a) | FAIL (n/a) | PASS 0.34M 6s | PASS 5.0M 166s |
| FR1a (auth LCV includes completed ALTERs) | PASS 2.7M 20s | PASS 53.9M 528s | PASS 2.0M 15s | PASS 38.1M 326s | PASS 0.34M 5s | PASS 5.0M 114s |
| FR1s (auth LCV includes completed SIGHUP) | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| FR1b (new session runs on defaults >= ALTERs+SIGHUPs before auth) | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| FR1c (FR1b, ALTER half only) | FAIL | FAIL | FAIL | FAIL | PASS 0.34M 6s | PASS 5.0M 52s |
| P13 (SIGHUP component fixed within a session) | FAIL | FAIL | FAIL | FAIL | PASS 0.34M 5s | PASS 5.0M 58s |

## Liveness (FairSpec: WF on Detach, ControlReload, Heartbeat, Cron, TimePass, CronClose)

| Property | strategy | on_read 1 node | on_read 2 nodes | pushed 1 node | pushed 2 nodes |
|---|---|---|---|---|---|
| P11 (plan: lcvServer = routerMax) | all three | PASS | PASS | PASS | PASS |
| P11b (live backends hold current catalog and SIGHUP defaults) | all three | FAIL | FAIL | PASS | PASS |
| P11c (P11b, catalog half only) | all three | FAIL | FAIL | PASS | PASS |

Pushed runs: 22K-262K distinct states, 2-25 s each. On_read failures appear within 5 s.

Isolation runs (gradual, on_read):

| Run | Result |
|---|---|
| P11c, 1 node, MAXSIGHUP 0 | PASS (2K states) |
| P11c, 2 nodes, MAXSIGHUP 0 | FAIL (cross-node, finding 4) |
| P11b, 1 node, MAXALTER 0 | FAIL (SIGHUP alone, finding 3) |
| FR1s/FR1b/FR1c, AUTH = backend | all PASS (0.9M states) |
| FR1a, STALE_READS = TRUE | FAIL |
| P5/P10/P10d, STALE_READS = TRUE | PASS (23.4M states, 240-280 s) |

## Findings

### 1. ALTER report omits the SIGHUP component, so the ALTER's own node never expires stale backends (P11b, P11c; candidate product bug)

Scenario (1 node, any strategy, on_read): a SIGHUP changes a PGC_BACKEND GUC on n1. The
postmaster counter becomes 1. Client c2 spawns backend S, which reports LCV 0+1 = 1, so
`routerMax` becomes 1. c2 runs `ALTER ROLE ... SET` on S. The catalog row becomes 1 and S
sends `yb_logical_client_version = 1`. That is the catalog value only, and it equals
`routerMax`, so `yb_od_router_expire_stale_lcv_servers` returns early. S (pre-ALTER defaults)
is never marked or timed. It serves every later gradual client whose LCV is <= 1 until some
new auth or spawn on n1 reports a value of 2 or more. With no new connections that never
happens.

Code: `pg_yb_utils.c:3722-3726` calls `YbSendMasterLogicalClientVersionToFrontend()`
(`pg_yb_utils.c:356-359`, catalog only), while every other LCV report is catalog + SIGHUP
counter (`postinit.c:1604-1605`, `1982-1983`). The value is then consumed by
`backend.c:1670-1681` and compared in `router.c:400-407`. This is the masking
LCV-propagation-UFD.md 5.2 describes for its cron path, but here it is on the existing
ALTER path. The UFD's cron repairs it within one heartbeat plus one cron tick (the pushed
columns pass). Without the UFD, a fix is to send `YbGetMasterLogicalClientVersion() +
yb_conn_mgr_sighup_logical_client_version`. That backend's counter is the one it was forked
with, so after a later SIGHUP the value is still low. In that case the next spawn or auth
corrects it.

Who is harmed: existing sessions under gradual, which keep landing on S. A session that
authenticates after the ALTER repairs the pool before its first attach, because its auth
report (catalog + counter = 2) arrives before the attach. The exception is finding 2.
This violates the documented gradual contract for ALTER: "Subsequent transactions are
routed to backends that have the latest ALTER settings" (`ycm-setup.md:273`), and the
TTL runs "after the ALTER is executed" (`ycm-setup.md:134`).

**Verification: confirmed and reproduced live** by the coordinator on `build/latest`
(1 node, auth passthrough, gradual, ttl 0, superuser_sticky=false). Scripts and logs are in
`/home/ec2-user/.claude/jobs/81b07efd/tmp/repro-lcv/` (`start.sh`, `scenario.py`, `v3.py`,
`*.out`, `*.lcv.log`).

- Sequence: client A connects. `yb-ts-cli set_flag --force ysql_pg_conf_csv
  log_disconnections=on` triggers a reload. Client C connects; its auth reports 2 and the
  router max becomes 2. C runs `ALTER DATABASE yugabyte SET work_mem='9MB'`.
- Expected: the ALTER marks every backend, and A and C move to a 9MB backend.
- Observed: the ALTER reports 2 and nothing is marked. A and C stay on the old pid with
  work_mem=7MB for 2 s. Only when a new client D connects (auth reports 3) is the stale
  backend expired, and A then moves to a 9MB backend.
- Baseline without the reload: the ALTER reports 1 > 0, every backend is marked, and A
  moves immediately.
- The code path was confirmed by reading:
  - `pg_yb_utils.c:3722-3726` and `:356-359` send catalog only.
  - Startup reports send catalog + counter (`postinit.c:1604-1605` via
    `yb_ysql_conn_mgr_helper.c:992`; passthrough `postinit.c:1982-1984`).
  - `router.c:402-407` returns early.

### 2. Auth-passthrough control backend's SIGHUP counter lags the postmaster's (FR1s, FR1b, FR1c; candidate product bug, narrow race)

FR1s (all strategies): SIGHUP on n1. c1 authenticates before the control backend has
processed its own SIGHUP, so its LCV is catalog + 0. Under gradual or connection_static
this LCV still matches pre-SIGHUP backends, so a session that started after the reload runs
with the old PGC_BACKEND values (FR1b trace: c2 attaches an idle pre-SIGHUP backend).

FR1c (gradual; combined with finding 1): SIGHUP on n1. Backend S spawns with (catalog 0,
SIGHUP 1), LCV 1. ALTER on S raises the catalog to 1 and is masked (finding 1). c2
authenticates through the lagging control backend and gets 1 + 0 = 1. Gradual matches S
(1 >= 1), so c2's first statement runs without the ALTER that completed before it
connected. The LCV sum cannot tell (0,1) apart from (1,0).

Code: the control backend bumps its own counter only after it handles `ConfigReloadPending`
(`postgres.c:7144-7188`, flag set at `guc.c:11826-11829`). The postmaster bumps its counter
and then calls `SignalChildren` (`postmaster.c:3171-3183`). Auth uses the control backend's
counter (`postinit.c:1971-1984`, then `yb_auth_passthrough.c:729-749`). The window is an
auth request read before the signal lands. In the idle case, step (6) of the loop runs
after `ReadCommand` and before the request is processed, so the request sees the new value.

All three properties pass with `AUTH = "backend"`, which forks a fresh auth backend from the
postmaster. FR1c passes under connection_static at this bound because a client
authenticated before the reload is rejected when it tries to spawn a newer backend
(`frontend.c:432-439`), so it never reaches S. Pushed does not close the window, because the
cron runs asynchronously.

**Verification: confirmed from code only, not run live.**
- `postmaster.c:3177-3184` bumps the counter and then calls `SignalChildren`.
- The control backend bumps its copy in step (6) of its main loop (`postgres.c:7144-7188`),
  after `ReadCommand`.
- Auth reads the control backend's copy (`postinit.c:1983`, then
  `yb_auth_passthrough.c:745-748`).
- The window: the SIGHUP lands after step (6) has already run for an auth that is in
  flight.
- In the live runs the control backend did catch up on later auths.

### 3. Under gradual, a SIGHUP reaches existing sessions, at a moment set by unrelated traffic (P11b with MAXALTER 0, P13; FS gap, not a staleness bug)

Mechanism, from the model: backend S idles on n1. A SIGHUP changes a PGC_BACKEND GUC and
the control backend reloads. Nothing reports the new LCV to the router until a new auth or
spawn on n1. Once one does, every older backend is marked or timed. An existing gradual
session is then routed to a new backend, and its PGC_BACKEND value changes mid-session.

Code: nothing pushes an LCV to Odyssey on SIGHUP.
- The wrapper only forwards its own config SIGHUP (`ysql_conn_mgr_wrapper.cc:434-438`).
- `sighandler.c:189-192` → `od_system_config_reload` has no LCV code.
- Odyssey learns LCVs only at `backend.c:1068`, `backend.c:1679` and
  `yb_auth_passthrough.c:746`.
- `postmaster.c:3177-3181` increments only a process-local counter.

Judgement, from the FS wording:
- The functional spec (`ycm-setup.md:270-278`; gflag help `ybc_gflags.cc:135-141`) covers
  only ALTER ROLE/DATABASE SET. Gradual means "existing sessions gradually adopt the new
  settings", and new sessions "always observe the effects of ALTER statements". SIGHUP and
  PGC_BACKEND are not mentioned.
- PostgreSQL's contract for a PGC_BACKEND change on reload is that it never reaches an
  existing session (`guc.c:11831-11840`).
- New sessions are not harmed. Their auth report precedes their first attach, so they get
  a fresh backend; FR1s/FR1b pass with AUTH = backend, and the exception is finding 2.
  An idle stale backend is therefore not a correctness problem in itself, and the
  "never expires" framing of this finding's first version was wrong.
- The real anomaly is the reverse. Under gradual, an existing session does see the
  PGC_BACKEND change, and whether and when depends on other clients connecting. That is
  neither PG behaviour nor any documented behaviour.
- Verdict: an FS gap. Either document that gradual applies reload-time PGC_BACKEND changes
  to existing sessions, or make the SIGHUP component not move existing sessions. Under
  connection_static the LCV is fixed per session, so PG semantics hold. Under fluctuating
  the flip is already documented.
- The UFD cron makes the flip prompt instead of traffic-dependent. It does not remove it.

Property consequence:
- P11b's SIGHUP half ("idle backends eventually hold the latest SIGHUP defaults") is not
  required by the FS or by PG, so P11b over-states the requirement.
- P11c, the ALTER half, is the FS-backed staleness property. P11b is kept in the spec for
  the record.
- The new property P13 states the PG rule: within one session, the SIGHUP component it
  runs on never changes.

P13 results:
- It passes under connection_static (on_read and pushed) and fails under gradual and
  fluctuating (both propagations).
- The gradual counterexample does not need unrelated traffic. Client c1's backend is
  expired by an ALTER (TTL timed). The SIGHUP lands, c1's next statement spawns a fresh
  backend, and that backend carries both the ALTER and the SIGHUP.
- So under gradual, any migration also carries every reload-time PGC_BACKEND change. PG's
  rule for those changes can only hold if gradual stops moving existing sessions, which is
  the same choice the FS has to make above.

**Verification: confirmed and reproduced live** (same setup and directory as finding 1).
- Sequence: A runs on a backend with `log_disconnections=on`. `set_flag` switches it to
  `off`.
- Observed: A stays on that pid, still `on`, at +5 s and at +10 s. Client D connects; its
  auth reports 4 > 3 and every backend is marked. D gets `off`, and A moves to a new
  backend and flips to `off` mid-session.

### 3a. A reload bumps the LCV even when no PGC_BACKEND value changed (pool churn; candidate product issue)

`guc.c:11817-11829` sets `yb_conn_mgr_sighup_had_backend_guc_change` for every
PGC_BACKEND or PGC_SU_BACKEND entry processed under PGC_SIGHUP with `changeVal`, whether
or not the value differs; the code comment says so. `ProcessConfigFile` applies every entry
in the file. So every reload with any such GUC in `ysql_pg.conf` raises the node's LCV and,
at the next connection, expires every pooled backend.

Consequences:
- Pointless pool churn.
- Finding 1's masking window opens on any reload, not only a real change.
- Finding 3's mid-session flip can happen with no value change at all. In that case the
  flip is invisible to the session, but the backend is replaced.

Model: `Sighup(n)` is already "a reload that bumps the counter", so the bump is covered.
What the model cannot express is that the value did not change. That needs a separate
config-content version, bumped only by a real change. With it, a property "no backend is
expired whose defaults equal the current ones" would catch this.

### 4. Cross-node ALTER not propagated under on_read (P11b/P11c, 2 nodes, MAXSIGHUP 0; expected, UFD motivation)

ALTER on n1. A backend on n2 that existed before the ALTER is never expired, because n2's
router never sees a larger LCV without new traffic. This is LCV-propagation-UFD.md 2.2, and
it passes under pushed.

### 5. P11 as stated passes vacuously (plan property mis-stated)

`lcvServer = routerMax[n]` holds in all of findings 1, 3 and 4: the router's maximum is
itself stale or masked, so stale backends agree with it. P11 is kept unchanged, and P11b
states the intended property: live backends hold the current catalog and SIGHUP defaults.
Per finding 3, judge staleness by P11c (ALTER), not P11b; P11b's SIGHUP half is not an
FS requirement.

### 6. Expected or documented failures

- **P5x**: equal LCV on different nodes with different defaults. In the trace, n1 has
  (catalog 0, SIGHUP 1) and n2 has (catalog 1, SIGHUP 0), both LCV 1. The plan expects this;
  the SIGHUP component is node-local by design.
- **P10, P10d, FR1b, FR1c under fluctuating**: after an ALTER, a fresh backend and a stale
  idle one coexist, and fluctuating attaches any idle backend
  (`router.c:1168-1171`, `od_pg_server_pool_next`). This is the documented semantics of
  `fluctuating` (ybc_gflags.cc:135).
- **P12 under fluctuating and gradual**: not applicable. P12 is the connection_static
  property, and both strategies intentionally move the client's LCV (`frontend.c:387`,
  `449`).
- **FR1a with STALE_READS**: if a node's catalog read can be served from a cache that lags
  the ALTER, auth on that node assigns the old catalog LCV. This is the conservative
  assumption; with fresh reads, as the code reads the table at each auth
  (`postinit.c:1973`), FR1a passes everywhere. The UFD does not change the auth read.

No model bugs remained after the runs above. P5, P10 and P10d (gradual and static) and P12
(static) pass at the full plan bounds, including under STALE_READS.

## Where the code differs from SPEC_PLAN.md (the model follows the code)

1. **The auth-passthrough control backend is not terminated on SIGHUP.** `postgres.c:6340-6354`
   is the query-retry wrapper. The control backend instead reloads and bumps its own counter
   (`postgres.c:7144-7188`) and re-reads the catalog LCV on every auth (`postinit.c:1971-1984`).
   It is modelled as `ctlSig[n]` plus the asynchronous `ControlReload(n)`.
2. **The ALTER's 'r' report is the catalog value only** (`pg_yb_utils.c:3725`), not catalog +
   SIGHUP. The plan assumed it reports "the new LCV". This is finding 1.
3. **knownLcv**: a spawn or auth does a fresh catalog read (`yb_logical_client_version.c:45-60`,
   prefetched), so `knownLcv` collapses to `catalogLcv`. `tsLcv` with `STALE_READS` covers a
   lagging read, and it is also the UFD heartbeat value.
4. **The client LCV is set to the server's LCV on every attach under every strategy**
   (`frontend.c:383-388`, `441-450`), not only under gradual. Under fluctuating it can go down.
5. **connection_static has two error points.** The router errors when the client is outdated
   and there is no idle match and no non-marked active match (`router.c:1122-1157`). Spawning
   is also rejected when the new backend is newer than the client (`frontend.c:423-439`).
6. **Expiry details**:
   - Expiry is applied only at the moment `routerMax` grows, to idle and active backends
     (`router.c:383-437`).
   - `yb_marked_for_close` is not checked at detach (`router.c:1506-1520`, expiry time
     only). A marked backend goes back to idle and is closed by the idle tick
     (`router.c:259-261`).
   - The idle tick is skipped entirely when the pool's idle ttl is 0 (`router.c:314-317`).
     The model assumes ttl > 0.
   - Fluctuating can re-attach a marked idle backend before that tick.
   - A timed backend past its expiry is still matched by gradual or static
     (`server_pool.h:179-198` checks only `marked`) and is closed at its next detach.
7. **Every auth also feeds expiry** (`backend.c:1068`, `yb_auth_passthrough.c:746`). New
   connections are therefore how on_read learns a newer LCV.
8. **Line drift**: the SIGHUP flag is set at `guc.c:11812-11829`, not 11745-11759. The
   counter increments are at `postmaster.c:3171-3181` and `postgres.c:7183-7187`.

## Modelling assumptions

- Spawn and auth are atomic. The LCV read and the `pg_db_role_setting` read
  (`process_settings`, `postinit.c:1719`) are assumed to see the same catalog state; both
  tables are in the same prefetch round. If they could differ, P5 could fail on a single
  node, and this was not checked.
- Each statement is a whole transaction (attach, run, detach). ALTER is a separate step
  while attached.
- Warmup mode (`YB_YSQL_CONN_MGR_DOWARMUP_ALL_POOLS_MODE`) and the multi-route eviction of
  other routes' idle backends are not modelled (one route per node).
