# TLA+ spec of GUC handling in YSQL Connection Manager: plan

Tool: TLA+ checked with TLC (`~/tools/tla/tla2tools.jar`, run with
`/usr/lib/jvm/zulu-17.jdk/bin/java`). Two modules, checked separately.

| Module | File | Scope |
|---|---|---|
| Session | `GucSession.tla` + `GucSession.cfg` | one route, N clients, M backends, SET/RESET/txn/attach/deploy/'G'/'g'/'r'. LCV constant. |
| Versioning | `GucVersioning.tla` + `GucVersioning.cfg` | ALTER … SET, SIGHUP, LCV, adoption strategies, expiry. Session state abstracted. |

Both are refinement checks: a *reference* model (one dedicated backend per client, plain PG
GUC semantics) runs in lock-step with the *concrete* model (CM + pool), and invariants say
the client cannot tell them apart.

Code anchors were taken on `f9dd80f8e20` (a few commits off master); line numbers on
master `b286efd7b5c` may drift by a few lines. Odyssey paths are under
`src/odyssey/sources/`, backend paths under `src/postgres/src/backend/`. Re-read the cited
function before encoding it; the code wins over this plan.

## Module 1: GucSession

### GUC universe

`GUCS` is a small constant set of GUC *kinds*, each a record with fixed attributes:

| kind | context | GUC_REPORT | notes |
|---|---|---|---|
| `uR` | USERSET | yes | e.g. DateStyle |
| `uN` | USERSET | no | e.g. search_path |
| `sU` | SUSET | no | settable only when superuser |
| `bK` | BACKEND | no | startup packet only; SET after start is an error (guc.c:11786-11795) |

Values: `{d, v1, v2}` where `d` is the spawn-time default. Sources, ordered:
`DEFAULT < CLIENT < SESSION` (collapse everything below CLIENT into DEFAULT; PG's
`PGC_S_OVERRIDE` and `PGC_S_FILE` do not appear in this module because nothing changes
them while it runs). Contexts ordered `BACKEND < SUSET < USERSET` for the "context >=
PGC_SU_BACKEND" test.

### Reference model (per client)

`ref[c]` is a function `GUCS -> [val, src, resetVal, resetSrc, stack]` plus
`refInTxn[c]`. It is created at connect from the client's startup options
`startup[c] : GUCS -+> Value` (partial): for each `g` in `DOMAIN startup[c]`,
`val = resetVal = startup[c][g]`, `src = resetSrc = CLIENT`; otherwise `d`/`DEFAULT`.
A startup option for `bK` is allowed; for `sU` it is allowed only if the client is a
superuser (model one boolean per client, `isSuper[c]`, constant).

Statement semantics (PG `set_config_option_ext`, `gucReset` guc.c:11589, `AtEOXact_GUC`
guc.c:10400-10520, `ResetAllOptions` guc.c:9882-10013):

- `SET g v` (session): if `g` is `bK` → error, no change. If `g` is `sU` and not
  superuser → error. Else `val := v`, `src := SESSION`. Inside a txn push a stack entry
  `[prior = old record, state = SET]` if none exists for `g` in this txn, else merge per
  PG (SET after LOCAL → SET_LOCAL keeps masked SET value; implement PG's four states
  SAVE/SET/LOCAL/SET_LOCAL faithfully, see `push_old_value` guc.c and the state table in
  `AtEOXact_GUC`).
- `SET LOCAL g v`: only meaningful inside a txn (outside, PG applies it then reverts at
  statement end: treat as no-op with a WARNING). `val := v`; stack state LOCAL /
  SET_LOCAL.
- `RESET g`: `val := resetVal`, `src := resetSrc`; stack as for SET (PG treats RESET as a
  SET to the reset value with source `reset_source`).
- `RESET ALL`: for every `g` with context in {SUSET, USERSET} and `src = SESSION`:
  as `RESET g`.
- `BEGIN`, `COMMIT`, `ROLLBACK`: at COMMIT, entries in state LOCAL or SET_LOCAL restore
  the masked/prior value, entries in SET persist; at ROLLBACK every entry restores
  `prior`. Stack is cleared.
- `SHOW g`: observation, no state change.
- `SET ROLE`: special statement, see stickiness. No GUC-map effect modelled.

Reported ParameterStatus from the reference backend at each ReadyForQuery: the set of
`g` with GUC_REPORT whose `val` changed since the last report (`ReportChangedGUCOptions`
guc.c:10588-10619 for the non-CM branch). Record it as `refReports[c]`, a set of
(g, val) pairs for the statement just completed.

### Concrete model

Per client `c`:
- `varsStartup[c]`: `GUCS -+> Value`. Filled during auth from 'r' packets with
  `SOURCE_STARTUP` (backend.c:1038-1056). Never changed afterwards.
- `varsSession[c]`: `GUCS -+> Value`. Updated from 'r' packets with
  `USERSET_OR_SUSET_SOURCE_SESSION` (upsert) / `SESSION_VAL_RESET` (remove), only when the
  packet is not consumed during deploy (`server_only = 0`, backend.c:1639-1646).
- `attached[c]`: a server id or `None`.
- `sticky[c]`: boolean latch (see stickiness).
- `cInTxn[c]`: boolean, mirrors `is_transaction` from the RFQ byte.
- `cmReports[c]`: the (g, val) pairs forwarded to the client as 'S' for the statement
  just completed (backend.c:1585-1594: only when `!server_only` and `REPORT_ENABLED`).
- `synced[c]` is not needed; model deploy as atomic (see Deploy).

Per server `s` (physical backend):
- `gucs[s]`: same record shape as `ref[c]` plus per-GUC `savedDefault` (the
  `ysql_conn_mgr_saved_default` stack, guc_tables.h:173: `None` or a `[resetVal,
  resetSrc]` pair) and status bits `needsReport`, `valueReset`, `defaultReset`
  (guc_tables.h:185-190).
- `sInTxn[s]`.
- `sVarsDefault[s]`: `GUCS -+> Value` (server.h:55). Upsert on `SOURCE_STARTUP`, remove on
  `DEFAULT_VAL_RESET` (backend.c:1625-1630).
- `sVarsSession[s]`: `GUCS -+> Value` (server.h:53). Upsert on
  `USERSET_OR_SUSET_SOURCE_SESSION`, remove on `SESSION_VAL_RESET` (backend.c:1632-1637).
- `sState[s] ∈ {Free, Idle, Active, Closed}`; `Free` = not yet spawned.
- `stickyServer[s]`: set from the RFQ byte `'i'` (backend.c:636-679).

The seed vars (`pg_hint_plan.enable_hint_table`, `compute_query_id`, var.h:253-271) are
*not* modelled: they are identical on client and server and cancel out.

### Backend-side flag computation ('r' packet)

At every ReadyForQuery the backend scans all GUCs (`ReportChangedGUCOptions`,
guc.c:10588-10619) and emits one 'r' per GUC with `needsReport`, or with
`valueReset`/`defaultReset`, computing flags per `ReportGUCOption` guc.c:10633-10724:

```
REPORT_ENABLED            iff GUC_REPORT
SESSION_VAL_RESET         iff valueReset
DEFAULT_VAL_RESET         iff defaultReset
SOURCE_STARTUP            iff src = CLIENT                      (any context >= BACKEND)
USERSET_OR_SUSET_SOURCE_SESSION iff src = SESSION ∧ context ∈ {USERSET, SUSET}
```
A GUC is reportable (`yb_should_report_guc` guc.c:9762-9789) iff GUC_REPORT ∨
valueReset ∨ defaultReset ∨ (context ≥ SU_BACKEND ∧ src ∈ {CLIENT, SESSION}).
After sending, clear `needsReport`, `valueReset`, `defaultReset` (guc.c:10718-10724).
`needsReport` is set by any `set_config_option_ext` with changeVal on a reportable GUC
(guc.c:12608-12612). `valueReset` is set by `RESET g` (guc.c:11993 etc.), by `RESET ALL`
(10004-10005) and by `AtEOXact_GUC` when the value changed, context ∈ {SUSET, USERSET}
and the popped source was SESSION (10494-10501). The whole scan happens before the RFQ,
so model "statement executes → flags computed → packets consumed by CM → RFQ" as one
atomic step per statement.

Startup: `BeginReportingGUCOptions` (guc.c:10538-10572) sends every reportable GUC. For
the auth backend this is where `varsStartup[c]` comes from; for a transactional backend
on spawn it populates `sVarsDefault[s]`/`sVarsSession[s]` (backend.c:1057-1072, except
`session_authorization`, not modelled).

### 'G' and 'g' packets

`'G' pairs` (`YbSetYsqlConnMgrGucDefaults` guc.c:10016-10060): for each (g, v):
if `savedDefault[g] = None` then `savedDefault[g] := [resetVal, resetSrc]`
(`yb_conn_mgr_save_default_value` guc.c:11431-11495, saves once); then
`val := v, src := CLIENT, resetVal := v, resetSrc := CLIENT` with `needsReport`. Context
used is BACKEND (SU_BACKEND when superuser), so it succeeds for `bK` too. Then RFQ with
the usual 'r' packets, consumed with `server_only = 1`.

`'g'` (`YbResetYsqlConnMgrGucDefaults` guc.c:10067-10084 → `ResetAllOptions` with
`modifying_defaults`): for each `g` with context ∈ {SUSET, USERSET} **or** (this is
`ResetAllOptions` so BACKEND context GUCs are skipped: confirm at guc.c:9905-9919 and
model what the code does, including whether a `bK` set via 'G' is ever restored) and
(`src > OVERRIDE` ∨ `src = CLIENT`): if `savedDefault[g] ≠ None` restore `resetVal,
resetSrc` from it and clear it (`yb_reset_conn_mgr_default` guc.c:9795-9872), set
`defaultReset`; then `val := resetVal, src := resetSrc`, `valueReset`. `GUC_NO_RESET_ALL`
is ignored (no such GUC in `GUCS`).

### Attach and deploy (atomic in the model)

Trigger: a client statement arrives while `attached[c] = None`. Pick `s`:
an `Idle` server, else spawn a `Free` one (fresh `gucs` with `d`/DEFAULT, `savedDefault
= None`, lists filled from startup reporting). Then `od_deploy` (deploy.c:152-246):

1. `yb_check_reset_needed` (var.h:488-495): reset needed unless
   `sVarsDefault[s] ⊆ varsStartup[c]` and `sVarsSession[s] ⊆ varsSession[c]` as
   (key, value) sets (var.h:471-482). If needed and `sInTxn[s]`, close `s` and retry
   (deploy.c returns -2, frontend.c:2491-2498). Else send 'g', consume its 'r' packets
   with `server_only = 1`.
2. 'G' with every `(g, v) ∈ varsStartup[c]` such that `sVarsDefault[s][g] ≠ v` or `g ∉
   DOMAIN sVarsDefault[s]` (deploy.c:53-134). Consume with `server_only = 1`.
3. One query of `SET g = v` for every `(g, v) ∈ varsSession[c]` with
   `sVarsSession[s][g] ≠ v` or absent (`kiwi_vars_cas` var.h:562-600). These are ordinary
   session SETs executed on the backend (context USERSET/SUSET per superuser). Consume
   with `server_only = 1`. Vars present in `sVarsSession[s]` but absent from
   `varsSession[c]` are **not** reset here (only 'g' does that).
4. `attached[c] := s`, `sState[s] := Active`.

Deploy-time 'r' packets never reach the client (`testNoParameterStatusDuringDeploy`).

### Statement execution on the attached server

Run the reference semantics on `gucs[s]` (same function as for `ref[c]`, plus the status
bits), compute 'r' packets, consume them with `server_only = 0` (update both `sVars*`
and `varsSession[c]`; forward `REPORT_ENABLED` ones into `cmReports[c]`), then RFQ:
`cInTxn[c] := sInTxn[s]`; if the server is sticky, `sticky[c] := TRUE`,
`stickyServer[s] := TRUE`.

### Detach

After a statement completes with `cInTxn[c] = FALSE` and `¬sticky[c]`: `attached[c] :=
None`, `sState[s] := Idle` (frontend.c:1116; `od_reset` reset.c:111-306 sends nothing
GUC-related in optimized mode; `od_router_detach` router.c:1494-1520). If `sticky[c]`,
stay attached. Client disconnect: if attached and sticky → `Closed`; if attached and in
txn → ROLLBACK then Idle (pool_rollback); else Idle.

### Stickiness (P7 subset for this module)

`SET ROLE` / `SET SESSION AUTHORIZATION` with source SESSION latch
`yb_ysql_conn_mgr_sticky_guc` (guc.c:11599-11606) → RFQ byte `'i'`. Superuser-ever
(pg_yb_utils.c:8560-8574) latches when `isSuper[c]`; with the gflag default this means a
superuser client is sticky from its first RFQ. `bK` startup vars do **not** latch. Model
only these; the sticky-object counter and lock latches are out of scope.

### Properties

- **P1 ValueEquality**: for every client `c` whose last statement has completed and
  `attached[c] = s`: `∀ g : gucs[s][g].val = ref[c][g].val`. (When detached, nothing to
  check; the next attach re-establishes it, which P1 then checks.)
- **P1b DefaultEquality**: same for `resetVal` and `resetSrc` (this is what RESET will
  observe; the doc's Lemma 8).
- **P2 ReportEquality**: `cmReports[c] = refReports[c]` after every statement (as sets
  of (g, val); PG sends at most one per GUC per RFQ).
- **P3 ReplayOnlySettable**: every SET the deploy step issues is for a `g` with context
  USERSET, or SUSET with `isSuper[c]`. Never `bK`.
- **P4 ResetDefault**: implied by P1b, keep as a separate named invariant for the trace.
- **P7 StickyLatch**: once `sticky[c]`, `attached[c]` never changes until disconnect; a
  client that issued SET ROLE is sticky at its next RFQ.
- **P8 SessionListTracksRef**: `varsSession[c] = { (g, v) : ref[c][g].src = SESSION ∧
  ref[c][g].val = v ∧ context(g) ∈ {USERSET, SUSET} }` whenever `cInTxn[c] = FALSE`
  (inside a txn the list may lead or lag; state what the code does).
- **P9 SavedDefaultRoundTrip**: for every Idle server `s` and every `g`:
  `savedDefault[g] = None ⇒ (resetVal, resetSrc) = (d, DEFAULT)`; and after 'g',
  `savedDefault = None` for all `g`.
- **ListInclusion** (proof doc TODO): `DOMAIN sVarsSession[s] ⊆ DOMAIN varsSession[c]`
  whenever `attached[c] = s` and no txn in progress. Expect this one to fail; report.
- **TypeOK**.

### Bounds for TLC

`CLIENTS = {c1, c2}`, `SERVERS = {s1, s2}`, `GUCS` as above, values `{d, v1, v2}`.
Each client runs at most `MAXSTMTS = 4` statements (a counter in state) and may
disconnect/reconnect once. Startup options: for each client, choose from `{}`,
`{uR ↦ v1}`, `{bK ↦ v1}`, `{uN ↦ v2}` nondeterministically at connect. Add a
`StateConstraint` on the counters so TLC terminates. Use `-workers auto`. If the state
space is too large, drop to `MAXSTMTS = 3` first, then one startup option, and say so.

### Expected findings (do not "fix" the model to hide them; report with the trace)

- P8 inside a transaction, SET LOCAL after SET, RESET inside txn then ROLLBACK (the
  `AtEOXact_GUC` path) are the likeliest places for a real divergence.
- ListInclusion probably fails after RESET ALL (server list emptied via SESSION_VAL_RESET
  while a different client's list still has entries) — that is expected and harmless;
  say whether it is.
- 'G' for a `bK` GUC after the server already served a client with a different `bK`
  value: check whether 'g' ever restores a BACKEND-context default.
- P2 when a GUC_REPORT var is RESET to a startup value: the forwarded value must be the
  startup value (DS doc rule), confirm the 'r' carries it.

## Module 2: GucVersioning

### Abstraction of Module 1

A backend's GUC state is reduced to `defaults[s]`: the vector of ALTER-derived defaults it
was spawned with, represented by its LCV. "A client observes default version `n`" when it
executes a statement on a server with `lcvServer[s] = n`. Startup/session overlays are
assumed correct by Module 1 and omitted.

### State

- Nodes `NODES = {n1, n2}`, each with its own CM, pool and postmaster.
- `catalogLcv`: global integer (pg_yb_logical_client_version, db_oid 0 row). Bumped by
  ALTER … SET (any node).
- `sighupLcv[n]`: node-local integer, bumped by a SIGHUP that changed a PGC_BACKEND GUC
  (guc.c:11745-11759, `yb_conn_mgr_sighup_had_backend_guc_change`).
- `knownLcv[n]`: what node `n`'s backends read from the catalog when they spawn. Until
  the UFD (`LCV-propagation-UFD.md` in the main checkout) lands, `knownLcv[n]` advances
  only when a backend on `n` reads the catalog, i.e. at spawn/auth. Model both:
  `PROPAGATION ∈ {"on_read", "pushed"}`.
- Backend `s` on node `n`: `lcvServer[s] = knownLcv[n] + sighupLcv[n]` at spawn;
  `sState`, `expiry[s] ∈ {None, Marked, Timed}` (TTL 0 → Marked; TTL > 0 → Timed, expires
  nondeterministically later; TTL -1 → never).
- Client `c` on node `n`: `lcvClient[c]` set at auth from the auth backend / control
  connection's LCV (note: under auth passthrough the control backend's LCV is whatever it
  had at *its* spawn, and it is terminated on the next request after a SIGHUP,
  postgres.c:6340-6354; model the control backend as a server that is re-spawned lazily).
  `observed[c]`: max `lcvServer` the client has executed on (the FR2 witness).
- `routerMax[n]`: max LCV seen on node `n` (router.c:338-380 `expire_stale_lcv`).
- `STRATEGY ∈ {fluctuating, gradual, connection_static}` (server_pool.h:179-250,
  router.c:1041-1120, frontend.c:369-378, 416-439).

### Transitions

Connect (auth assigns `lcvClient`), Statement (attach per strategy: fluctuating any Idle;
gradual `lcvServer ≥ lcvClient` then `lcvClient := lcvServer`; connection_static equality,
spawn allowed only if `lcvClient = routerMax`, else wait for an Active one with equal LCV
or error/disconnect), Detach, Spawn, AlterSet (bump `catalogLcv`; the executing backend
reports the new LCV in an 'r' packet so its node's `routerMax` and expiry run
immediately; other nodes learn per `PROPAGATION`), Sighup(n), Expire(s), Disconnect.

### Properties

- **P5 EqualLcvNoAlterBetween**: for two servers on the same node with equal
  `lcvServer`, no AlterSet or Sighup(n) happened between their spawns (track spawn
  timestamps with a logical clock). Also check the cross-node version and expect it to
  fail under `on_read`.
- **P6** is Module 1's concern (user ids); skip here.
- **P10 Monotonic (gradual)**: `observed[c]` never decreases and, once a client has
  observed `k`, every later statement runs on `lcvServer ≥ k`. Check under all three
  strategies and report which hold.
- **P11 BoundedStaleness (gradual, TTL ≥ 0)**: liveness: eventually every Active/Idle
  server has `lcvServer = routerMax[n]` (weak fairness on Expire and Spawn).
- **P12 ConnectionStatic**: a client either always runs on `lcvServer = lcvClient` or is
  disconnected with a routing error; never a higher LCV.
- **NewSessionSeesAlter (FR1a)**: a client that connects (auth completes) after an
  AlterSet completes gets `lcvClient ≥` that ALTER's version, on every node. Expect this
  to fail cross-node under `on_read`; that is the UFD's motivation.

### Bounds

2 nodes, 2 clients, 2 servers per node, at most 2 ALTERs and 1 SIGHUP, `MAXSTMTS = 3`.

## Deliverables per module

- The `.tla` and `.cfg`, a `run.sh` that invokes TLC with the right JDK and bounds.
- `RESULTS.md`: which invariants pass at which bounds (states, distinct states, time),
  and for each failure the TLC trace translated into a SQL-level scenario plus the
  code location the model took the behaviour from, and a judgement: model bug, known
  deviation, or candidate product bug.
- No product code changes. No commits (the parent session commits).
