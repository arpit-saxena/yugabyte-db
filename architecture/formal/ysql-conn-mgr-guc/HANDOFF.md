# Handoff: state of the Conn Mgr GUC formal spec (2026-10-30)

Read in this order: `OPTIONS.md` (why TLA+, what the design docs claim and where their proof
is incomplete), `SPEC_PLAN.md` (the modelling plan), `RESULTS.md` and
`RESULTS-versioning.md` (what TLC found, how each counterexample was verified against the
code and on a live cluster, and the judgement per finding).

## Done

- `GucSession.tla`: SET / SET LOCAL / RESET / RESET ALL, transaction end, attach, deploy,
  `'G'`/`'g'` default packets, `'r'` flag bits, the CM-injected
  `yb_ycm_internal_client_addr/port` startup vars, stickiness via SET ROLE and superuser.
  Exhaustive at 1 client × 6 statements and 2 clients × 3 statements; 2 clients × 4 only
  partially (25 min cut); plan bounds by simulation. Configs in `configs/`, `N_*` are the
  faithful round-2 runs.
- `GucVersioning.tla`: ALTER … SET, SIGHUP, LCV assignment, the three adoption strategies,
  expiry, auth passthrough control backend, on_read vs pushed propagation. Safety at the
  plan's full bounds, liveness at reduced bounds.
- Every counterexample was independently re-derived from the source and, where reachable,
  reproduced on a 1-node cluster from `build/latest` (scripts and captured output in
  `repro/`). Status per finding is in the results files; summary:

| Finding | Status |
|---|---|
| F1 PGC_BACKEND startup option leaks to next client | real, reproduced |
| F3 stale entry after SET-to-current-value in a rolled-back txn | real, reproduced |
| V1 ALTER after SIGHUP never expires own node's backends | real, reproduced |
| F2 'G' on SESSION-source GUC; F3 missing entry | latent, blocked by the port var (F5) |
| V2 control backend SIGHUP counter lag | real race, code only |
| V3 gradual flips PGC_BACKEND mid-session | semantics gap (P13) |
| F4 duplicate ParameterStatus; 3a reload bumps LCV when unchanged | accepted / churn |

None are filed. GitHub issues should cite the trace in the results file and the repro script.

## Not done / next steps

1. Push the branch and open a PR: `.agents/scripts/git-push.sh -r fork` from this
   checkout (the push was blocked in the authoring session).
2. File F1, F3-stale and V1. F1 fix candidate: let `yb_reset_conn_mgr_default` run for
   BACKEND/SU_BACKEND context in `ResetAllOptions` when `yb_conn_mgr_modifying_defaults`.
   F3 fix candidate: in `AtEOXact_GUC`, under CM, report when the *source* changed, not only
   the value. V1 fix candidate: have the ALTER path send catalog + node-local counter
   (`yb_ysql_conn_mgr_helper.c` already composes it for startup). Each fix should be
   re-checked by flipping the corresponding model action and re-running the config that
   failed (`GFIX` in GucSession.cfg is the pattern: a constant that switches a hypothetical
   CM behaviour on).
3. Model gaps, deliberately out of scope for v1 (see `OPTIONS.md` decisions list):
   check-hook failures on replay, size limits (`KIWI_MAX_VAR_SIZE`, `yb_max_query_size`),
   auth backend path (only passthrough is modelled in GucVersioning), the
   `ysql_conn_mgr_optimized_session_parameters=false` eager-reset path, GUCs whose assign
   hooks write other GUCs (compatibility sheet), cross-GUC replay order (DB-15792).
4. P11 in GucVersioning is mis-stated and passes vacuously; P11b/P11c are the ones to read.
   Restate P11 as an existing-session observation property if the versioning module is
   extended.
5. Trace validation (OPTIONS.md option E): log attach/deploy/`'r'` events from Odyssey and
   check Java test runs against `GucSession`. Not started.
6. Scale: 2 clients × 4 statements with all statement kinds did not finish in 25 min on a
   loaded host; symmetry reduction on CLIENTS/SERVERS (TLC `SYMMETRY`) was not tried.

## Running

```
cd architecture/formal/ysql-conn-mgr-guc
./run.sh configs/N_B3.cfg            # session module, one config
./run-versioning.sh matrix            # versioning, all strategy × propagation
```
`run.sh` expects `TLA_JAR` and `JAVA` (defaults to `~/tools/tla/tla2tools.jar` and the
zulu-17 JDK on the authoring host). TLC writes a `states/` scratch dir; delete it before
committing.

## Sources consulted

Drive: "GUC Variables with YSQL Connection Manager" (proof), "DB FS/DS: GUCs in Connection
Manager", "DB FS/DS: ALTER GUC commands", "How to Increment LCV on SIGHUP?", "ConnMgr GUC
Compatibility Analysis" (sheet), "Logical client version matching", "Logical client
versioning gaps", "Fixing LCV to handle Role changes", "GUC Related DOCS"; checkout doc
`LCV-propagation-UFD.md`. Slack updates: #priv-arpit, 2026-10-30.
