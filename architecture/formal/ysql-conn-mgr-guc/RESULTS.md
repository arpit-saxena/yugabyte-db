# GucSession (Module 1): TLC results

Model: `GucSession.tla`. Run with `./run.sh [cfg] [TLC args]`. The default `GucSession.cfg`
uses the plan's bounds; `configs/*.cfg` are the runs below. Code anchors are on
`b286efd7b5c`. TLC 2.19, `-workers 6..12`, on a shared 32-core host with load average
around 100, so wall times are pessimistic.

## Configurations

All runs use 4 GUC kinds (`uR` USERSET+GUC_REPORT string, `uN` USERSET int, `sU` SUSET,
`bK` BACKEND) and values `{d, v1, v2}`. "Statements" lists `OPS`. `ERR` is a SET of a GUC
the session may not set (bK always, sU when not superuser). `GFIX` is a hypothetical CM change
(see F2). It is off in every product run.

| cfg | clients/servers | MAXSTMTS / MAXCONNS | SET values | statements | startup options | mode |
|---|---|---|---|---|---|---|
| A6 | 1/1 | 6 / 1 | d,v1,v2 | all 10 kinds | {}, uR=v1, bK=v1, uN=v2 | exhaustive |
| S5 | 1/1, SUPER | 5 / 2 | d,v1,v2 | all | + sU=v1 | exhaustive |
| B3 | 2/2 | 3 / 1 | v1 | SET RESET RESETALL BEGIN COMMIT SELECT | {}, uR, bK, uN | exhaustive |
| B3nb | 2/2 | 3 / 1 | v1 | as B3 | {}, uR, uN | exhaustive |
| B3fix | 2/2 | 3 / 1 | v1 | as B3 | {}, uR, uN; GFIX | exhaustive |
| B4fix | 2/2 | 4 / 1 | v1 | B3 + LOCAL ROLLBACK | {}, uR, uN; GFIX | exhaustive |
| H4 | 2/2 | 4 / 1 | d,v1 | SET RESETALL BEGIN ROLLBACK SELECT | {}, uN | exhaustive |
| H4fix | as H4; GFIX | | | | | exhaustive |
| SIMfix | 2/2 | 4 / 2 (plan bounds) | d,v1,v2 | all | {}, uR, uN; GFIX | `-simulate num=3000000 -depth 40` |
| GucSession.cfg | 2/2 | 4 / 2 (plan bounds) | d,v1,v2 | all | {}, uR, bK, uN | stops at P2 (92 states) |

The plan's bounds with all statements do not finish exhaustively: 2 clients with all
statements at MAXSTMTS 2 already exceeded 200k distinct states and 10 minutes. The 2-client
exhaustive runs therefore cut the statement set. SIMfix covers the plan's bounds by random
simulation.

## Invariant results

States are "generated / distinct" for the run that checked the invariant to completion. For
a FAIL, the number is where TLC found the shortest (BFS) counterexample.

| invariant | result | where / bound | states | time |
|---|---|---|---|---|
| TypeOK, TxnAgree, IdleNotInTxn | PASS | A6, S5, B3nb, B3fix, B4fix | B4fix: 2,700,271 / 226,287 | 788 s |
| P1 ValueEquality | **FAIL** | B3 (F1), B3nb (F2), H4fix (F3), SIMfix (F3) | B3nb: 29,073 / 6,522 | 21 s |
| | PASS | A6, S5 (1 client); B3fix, B4fix (GFIX, no bK, no same-value SET) | B4fix as above | |
| P1b DefaultEquality (= P4) | **FAIL** | B3 (F1), B3nb (F2) | B3nb: 33,423 / 7,364 | 28 s |
| | PASS | A6, S5, B3fix, B4fix | | |
| P1c SourceEquality (extra) | **FAIL** | B3 (F1), B3nb (F2), SIMfix (F3) | B3nb: 29,804 / 6,765 | 21 s |
| P2 ReportEquality | **FAIL** | every config (F4) | A6: 49 / 30 | 7 s |
| P2b ReportSound (extra) | **FAIL** | B3, B3nb (consequence of F2) | B3nb: 31,139 / 6,898 | 21 s |
| | PASS | A6, S5, B3fix, B4fix | | |
| P3 ReplayOnlySettable, NoDeployError | PASS | all exhaustive configs | B4fix as above | |
| P7 RoleSticky, P7 StickyLatch | PASS | all exhaustive configs | B4fix as above | |
| P8 SessionListTracksRef | **FAIL** | A6, S5 (F3) | A6: 2,682 / 801 | 10 s |
| P8b SessionListSound (extra) | **FAIL** | A6, S5 (F3) | A6: 40,853 / 8,515 | 19 s |
| P9a SavedDefaultNoneMeansBoot | PASS | all exhaustive configs | B4fix as above | |
| P9b ResetClearsSaved | **FAIL** | B3 (F1) | 364 / 114 | 5 s |
| | PASS | B3nb, B3fix, B4fix | | |
| NoDoubleSave (extra) | **FAIL** | B3nb (F2) | 28,473 / 6,407 | 24 s |
| ListInclusion | **FAIL** | SIMfix only (F3) | sim, 79,737 states | 16 s |
| | PASS | all exhaustive configs | | |

The "extra" invariants are not in the plan:
- P1c: source equality, which decides what `RESET ALL` touches and what `pg_settings.source` shows.
- P2b: P2 that tolerates duplicate ParameterStatus.
- P8b: P8 restricted to the values that replay depends on.
- NoDoubleSave: the `yb_conn_mgr_save_default_value` "This is a bug" WARNING.

P1/P1b/P1c/P2/P2b are also checked at the end of every statement, before a detach. A
client outside a transaction detaches in the same atomic step, so a state-only P1 would
almost never be evaluated.

## Failures

### F1: a PGC_BACKEND startup option leaks to the next client (candidate product bug)

Trace (B3, 5 states):
1. c1 connects with `-c bK=v1`.
2. c2 connects with `-c DateStyle=v1`.
3. c1 runs `RESET ALL`. It spawns s1, and deploy sends 'G' bK=v1, so s1 has bK=v1 and
   `sVarsDefault={bK:v1}`. c1 detaches.
4. c2 runs `RESET ALL` and attaches s1. `yb_check_reset_needed` sees bK not in c2's startup
   list and sends 'g'. 'g' does not touch bK. 'G' sends DateStyle only.

c2 then sees `bK = v1`, but its own session has `bK = d`. This violates P1, P1b and P1c. P9b
fails too: 'g' leaves bK's `ysql_conn_mgr_saved_default` set.

Code: guc.c `ResetAllOptions` starts with
`if (gconf->context != PGC_SUSET && gconf->context != PGC_USERSET) continue;`, before the
`yb_conn_mgr_modifying_defaults` call to `yb_reset_conn_mgr_default`. So a PGC_BACKEND or
PGC_SU_BACKEND default that 'G' set (`YbSetYsqlConnMgrGucDefaults`, context
PGC_BACKEND/SU_BACKEND) is never restored. `sVarsDefault` keeps bK, so every later client
without that option also pays a 'g'.

Judgement: (c) candidate product bug. The plan expected this ("check whether 'g' ever
restores a BACKEND-context default"): it never does. A superuser route hides it, because
servers are sticky and closed (S5 passes).

### F2: 'G' on a GUC whose current source is SESSION changes only reset_val, and CM never learns it (candidate product bug)

Trace (B3nb, 7 states; SQL with uR = DateStyle):
1. c1 connects with `-c DateStyle=v1`. c2 connects with no options.
2. c1 runs `SET DateStyle=v1` on s1. Deploy sends 'G' DateStyle=v1.
   s1: `vd={DateStyle:v1}`, `vs={DateStyle:v1}`.
3. c2 runs `SET DateStyle=v1` on s1. Reset is needed, so 'g' runs and restores the saved
   default. s1: `vd={}`, `vs={DateStyle:v1}`, reset_val=d.
4. c1 runs any statement on s1. No reset is needed (`{}` ⊆ startup, vs ⊆ session).
   'G' DateStyle=v1 runs while the source is SESSION. `set_config_option_ext` sets
   `changeVal = false` ("record->source > source"), but `makeDefault` still sets
   `reset_val = v1` and `yb_conn_mgr_save_default_value` saves d. No 'r' is sent
   (needs `changeVal`), so `vd` stays `{}`.
5. c2 runs `RESET ALL` (or `RESET DateStyle`) on s1. No reset is needed. DateStyle becomes
   v1, but c2 never set a default and should get d. The forwarded ParameterStatus carries
   v1 (P2b).

The next deploy of c1 resends 'G' because `vd` still lacks DateStyle, which logs the
"ysql_conn_mgr_saved_default already set ... This is a bug" WARNING (NoDoubleSave).

Code: guc.c `set_config_option_ext` (the `record->source > source` branch, `makeDefault`,
and the `changeVal && yb_should_report_guc` report), deploy.c `yb_send_set_guc_defaults`,
and backend.c `od_backend_update_parameter` (the `SOURCE_STARTUP` branch only).

Judgement: (c) candidate product bug, reachable with ordinary drivers (a startup DateStyle
plus a matching `SET`). The 'r' flags are computed from the current source, so they cannot
say "reset source is now CLIENT while the value is SESSION". With GFIX (CM records each var
it sent in 'G' in `yb_vars_default`), B3nb's P1/P1b/P1c/P2b/NoDoubleSave failures all go away
(B3fix and B4fix pass). That is a modelling experiment, not a proposed patch.

### F3: a transaction-scoped change that leaves the value unchanged desyncs the CM lists (candidate product bug)

`AtEOXact_GUC` reports, and sets `YB_GUC_VALUE_RESET`, only when the restored value differs
(`changed`). It compares values for non-string GUCs and pointers for strings. The 'r' sent
for the in-transaction change already updated the CM lists, so the undo is never seen. This
happens in two directions, shown with uN = work_mem (default d):

- **Stale entry** (P8, then P1 in H4fix). Client A runs
  `BEGIN; SET work_mem=d; ROLLBACK`. The SET's 'r' adds `work_mem=d` to the client and
  server session lists. The rollback restores d with source DEFAULT and sends no report.
  The single-client variant of this is A6's P8 trace: `BEGIN; SET LOCAL uN=d; COMMIT`.
  In H4fix, client B then connects with `-c work_mem=v2` and runs `SET work_mem=d`. B
  attaches to A's backend: the list says `work_mem=d` already, so `kiwi_vars_cas` skips the
  SET, and 'G' sets work_mem=v2. B sees v2 but expects d. This is a value-level P1 failure.
- **Missing entry** (P8b in A6, then P1c/P1 in SIMfix). Client A runs
  `SET work_mem=d; BEGIN; RESET ALL; ROLLBACK` (or disconnects inside the transaction, so
  `od_reset` sends ROLLBACK). RESET ALL's 'r' (VALUE_RESET) removes work_mem from both
  lists. The rollback restores d with source SESSION and sends no report. The backend now
  holds a session-source work_mem that CM does not know about. In SIMfix, client B then
  connects with `-c work_mem=v2` and attaches with no reset. 'G' work_mem=v2 hits the
  SESSION source (F2's `changeVal = false`), so B keeps work_mem=d instead of v2.

Code: guc.c `AtEOXact_GUC` (`changed`, and the `YbIsClientYsqlConnMgr() && changed && ...`
block), backend.c `od_backend_update_parameter`, var.h `yb_check_reset_needed` and
`kiwi_vars_cas`.

Judgement: (c) candidate product bug.
- It needs a SET to a value equal to the current or reset value, inside a transaction (or
  SET LOCAL), followed by an undo. That is rare, but the outcome is a wrong value seen by
  another client.
- String GUCs (DateStyle, search_path) are mostly immune because the pointer comparison
  almost always reports "changed".
- With one client and no value-level harm, P8/P8b stay at their plan wording and fail; they
  are kept as is.

ListInclusion's only counterexample (SIMfix) is the stale-entry case: a sticky client attaches
to a server whose `yb_vars_session` holds a stale `work_mem=d`.

### F4: duplicate ParameterStatus (known/accepted deviation)

Trace (A6, 4 states): `BEGIN; SET LOCAL DateStyle = <current value>`. PG's
`ReportGUCOption` deduplicates against `last_reported`, so the reference sends nothing. With
CM, every 'r' with `REPORT_ENABLED` is forwarded (backend.c `od_backend_update_parameter`,
`!server_only && REPORT_ENABLED`). B3's trace is a startup `DateStyle=v1` followed by
`SET DateStyle=v1`.

Judgement: (b) accepted deviation. Clients must accept redundant ParameterStatus. P2b holds
in every config without F2. The comment in `ReportGUCOption` says CM filters duplicates;
backend.c does not.

## Where the code differs from SPEC_PLAN.md

1. **Superuser is per route, not per client.** One route is one user. Superuser stickiness
   comes from `session_auth_is_superuser` on the backend (pg_yb_utils.c
   `YbIsConnectionMadeStickyUsingGUC`). `SUPER` is therefore a model constant.
2. **'r' emission.** `ReportChangedGUCOptions` sends only GUCs with `GUC_NEEDS_REPORT`. A
   pending VALUE_RESET/DEFAULT_RESET without NEEDS_REPORT waits for a later report; the plan
   says those bits alone trigger a packet.
3. **'G' does not always set the value.** When the current source is SESSION, 'G' changes
   only reset_val and the saved default and sends no 'r' (F2). The plan has
   `val := v, src := CLIENT` unconditionally.
4. **'g' skips BACKEND context entirely**, including the saved-default restore (F1).
5. **VALUE_RESET in AtEOXact_GUC** requires `changed`, and tests the source being discarded
   (before restore) against SESSION. `changed` compares pointers for strings, which the model
   treats as "always changed" for uR.
6. **SET LOCAL outside a transaction block** applies in the implicit transaction and is undone
   at its commit, with the matching 'r' packets. The plan said "no-op with a WARNING". The net
   value is the same.
7. **An error inside a transaction block** runs `AtEOXact_GUC(false)` immediately and reports
   at that RFQ. The block stays failed until COMMIT/ROLLBACK. The model includes this.
8. **'G' and 'g' run in an implicit transaction** (postgres.c `start_xact_command`), like the
   deploy SET query.
9. **ListInclusion** does not fail after RESET ALL as the plan expected. RESET ALL's
   VALUE_RESET packets remove the entry from the client and server lists together. It fails
   only through F3.
10. **The sticky RFQ 'i'** is only produced when idle (xact.c), and CM clears
    `yb_sticky_connection` on a plain 'I'. The backend's latch never clears, so stickiness
    persists anyway.

## Modelling notes

- Each statement is atomic. Attach, deploy, execute, 'r' consumption and detach happen in one
  step. Deploy-time 'r' packets are consumed with `server_only = 1` and never reach the
  client.
- Not modelled: savepoints and nest levels above 1, `GUC_NO_RESET_ALL`, parameter ACL
  grants, the sticky-object counter and lock latches, `session_authorization`/`role` list
  handling, auth passthrough, and the deploy `-2` retry path. The last is unreachable:
  `IdleNotInTxn` holds.
- Pooled servers are reused only through attach. Closed servers return to `Free` and can be
  respawned.
