# GucSession (Module 1): TLC results

Model: `GucSession.tla`. Run with `./run.sh [cfg] [TLC args]`.
- `GucSession.cfg` uses the plan's bounds with the faithful model.
- `configs/*.cfg` are the runs below.

Code anchors are on `b286efd7b5c`. TLC 2.19 ran with `-workers 6..12` on a shared 32-core
host at load average ~100, so wall times are pessimistic.

There are two rounds of runs:
- **Round 1** (`INTERNALVARS = FALSE`): the model without the CM-injected startup vars.
- **Round 2** (`INTERNALVARS = TRUE`, `N_*` configs): adds `iP`, which stands for
  `yb_ycm_internal_client_port` (F5). This is the faithful model. Its results are the
  verdict on today's code.

Round 1 results are kept because F2 and F3-missing are latent there (see F5).

## Configurations

All runs use these GUC kinds and values:
- `uR`: USERSET, GUC_REPORT, string (like DateStyle).
- `uN`: USERSET, int (like work_mem).
- `sU`: SUSET.
- `bK`: BACKEND.
- Round 2 adds `iP`.
- Values are `{d, v1, v2}`; `iP` takes a fresh model value from `PORTS` for each
  connection.

Other terms used in the tables:
- "Statements" lists `OPS`.
- `ERR` is a SET of a GUC the session may not set.
- `GFIX` is a hypothetical CM change (F2). It is off in every product run.

| cfg | clients/servers | MAXSTMTS / MAXCONNS | SET values | statements | startup options | mode |
|---|---|---|---|---|---|---|
| A6, N_A6 | 1/1 | 6 / 1 | d,v1,v2 | all 10 kinds | {}, uR=v1, bK=v1, uN=v2 | exhaustive |
| S5, N_S5 | 1/1, SUPER | 5 / 2 | d,v1,v2 | all | + sU=v1 | exhaustive |
| B3, N_B3 | 2/2 | 3 / 1 | v1 | SET RESET RESETALL BEGIN COMMIT SELECT | {}, uR, bK, uN | exhaustive |
| B3nb, N_B3nb | 2/2 | 3 / 1 | v1 | as B3 | {}, uR, uN | exhaustive |
| B3fix | as B3nb, GFIX | | | | | exhaustive |
| B4fix | 2/2 | 4 / 1 | v1 | B3 + LOCAL ROLLBACK | {}, uR, uN; GFIX | exhaustive |
| N_B4 | as B4fix, no GFIX | | | | | exhaustive, cut at 25 min |
| H4, N_H4 | 2/2 | 4 / 1 | d,v1 | SET RESETALL BEGIN ROLLBACK SELECT | {}, uN | exhaustive |
| H4fix | as H4, GFIX | | | | | exhaustive |
| SIMfix | 2/2 | 4 / 2 (plan bounds) | d,v1,v2 | all | {}, uR, uN; GFIX | `-simulate num=3000000 -depth 40` |
| N_SIM | as SIMfix, no GFIX | | | | | simulation, 1300 s |

The plan's bounds with all statements do not finish exhaustively. With 2 clients, all
statements and MAXSTMTS 2, TLC passed 200k distinct states in 10 minutes. The 2-client
exhaustive runs therefore use fewer statements, and the simulation runs cover the plan's
bounds.

## Results, round 2 (faithful model, product code)

States are "generated / distinct" for the run that checked the invariant to completion. For
a FAIL, the number is where TLC found the shortest (BFS) counterexample.

| invariant | result | where | states | time |
|---|---|---|---|---|
| TypeOK, TxnAgree, IdleNotInTxn, P3, NoDeployError, P7 (both), P9a | PASS | N_A6, N_S5, N_B3nb; N_B4 (no violation after 179k distinct, cut); N_SIM (3.85M states, no violation) | N_S5: 4,164,986 / 600,425 | 216 s |
| P1 ValueEquality | **FAIL** | N_B3 (F1), N_H4 and N_SIM (F3-stale) | N_H4: 140,046 / 35,620 | 186 s |
| | PASS | N_A6, N_S5, N_B3nb, N_B4 (cut) | N_B3nb: 461,039 / 57,339 | 560 s |
| P1b DefaultEquality (= P4) | **FAIL** | N_B3 (F1) | 673 / 188 | 6 s |
| | PASS | N_A6, N_S5, N_B3nb, N_B4 (cut), N_SIM | | |
| P1c SourceEquality (extra) | **FAIL** | N_B3 (F1), N_H4 and N_SIM (F3-stale) | N_H4: 123,738 / 31,794 | 167 s |
| P2 ReportEquality | **FAIL** | every config (F4) | N_A6: 50 / 31 | 3 s |
| P2b ReportSound (extra) | PASS | N_A6, N_S5, N_B3nb, N_B4 (cut), N_SIM | N_B3nb as above | |
| P8 SessionListTracksRef | **FAIL** | N_A6, N_S5, N_H4, N_SIM (F3) | N_A6: 1,476 / 508 | 4 s |
| P8b SessionListSound (extra) | **FAIL** | N_A6, N_S5, N_H4, N_SIM (F3-missing, one client only, value-harmless now) | N_A6: 36,748 / 7,527 | 8 s |
| P9b ResetClearsSaved | **FAIL** | N_B3 (F1) | 801 / 222 | 5 s |
| | PASS | N_B3nb, N_B4 (cut), N_SIM | | |
| NoDoubleSave (extra) | PASS | N_A6, N_S5, N_B3nb, N_B4 (cut), N_SIM | | |
| ListInclusion | **FAIL** | N_SIM (F3-stale) | sim, 93,474 states | 19 s |
| | PASS | N_A6, N_S5, N_B3nb | | |
| GResetOnEveryClientSwitch (new) | PASS | N_A6, N_S5, N_B3nb, N_B4 (cut), N_SIM | N_B3nb as above | |
| NoAttachWithoutReset (new, witness) | **FAIL** as intended | N_A6, N_B3, N_B3nb, N_B4, N_H4, N_SIM | N_A6: 37 / 24 | 3 s |

Round 2 and round 1 differ in four places:
- F2 disappears (N_B3nb: P1/P1b/P1c/P2b/NoDoubleSave now pass).
- F3-missing no longer reaches a second client.
- F1 and F3-stale remain.
- F4 is unchanged.

Notes on the invariants:
- The "extra" invariants are not in the plan. P1c checks source equality. P2b is P2
  allowing duplicate ParameterStatus. P8b is P8 restricted to what replay needs.
  NoDoubleSave is the `yb_conn_mgr_save_default_value` "This is a bug" WARNING.
- P1/P1b/P1c/P2/P2b are also checked at the end of every statement, before a detach.
- `NoAttachWithoutReset` is a witness, and its counterexample is the expected one: the same
  connection re-attaches to the backend it last used, with nothing in between, and no 'g'
  is sent.

## Results, round 1 (model without iP; F2/F3-missing latent)

| invariant | result | where | states | time |
|---|---|---|---|---|
| TypeOK, TxnAgree, IdleNotInTxn, P3, NoDeployError, P7, P9a | PASS | A6, S5, B3nb, B3fix, B4fix | B4fix: 2,700,271 / 226,287 | 788 s |
| P1 | **FAIL** | B3 (F1), B3nb (F2), H4 (F2), H4fix (F3-stale), SIMfix (F3-missing) | B3nb: 29,073 / 6,522 | 21 s |
| P1b | **FAIL** | B3 (F1), B3nb (F2) | B3nb: 33,423 / 7,364 | 28 s |
| P1c | **FAIL** | B3, B3nb, SIMfix | B3nb: 29,804 / 6,765 | 21 s |
| P2 | **FAIL** | all (F4) | A6: 49 / 30 | 7 s |
| P2b | **FAIL** | B3, B3nb (F2) | B3nb: 31,139 / 6,898 | 21 s |
| P8, P8b | **FAIL** | A6, S5 (F3) | A6: 2,682 / 801; 40,853 / 8,515 | 10 s; 19 s |
| P9b | **FAIL** | B3 (F1) | 364 / 114 | 5 s |
| NoDoubleSave | **FAIL** | B3nb (F2) | 28,473 / 6,407 | 24 s |
| ListInclusion | **FAIL** | SIMfix (F3-stale) | sim, 79,737 states | 16 s |
| all of the above except P2/P8 | PASS | B3fix (260,808 / 30,341, 282 s), B4fix | | |

## Findings

### F1: a PGC_BACKEND startup option leaks to the next client (product bug)

Trace (N_B3 and B3, 5 states):
1. c1 connects with `-c bK=v1`.
2. c2 connects with no bK option.
3. c1 runs a statement, which spawns s1. Deploy sends 'G' bK=v1, so `sVarsDefault`
   contains bK.
4. c2 runs a statement on s1. `yb_check_reset_needed` is true and 'g' is sent. 'g' does not
   touch bK.

c2 then has bK=v1 instead of the default. P1, P1b, P1c and P9b fail.

Code: guc.c `ResetAllOptions` starts with
`if (gconf->context != PGC_SUSET && gconf->context != PGC_USERSET) continue;`, which comes
before `yb_reset_conn_mgr_default`. A PGC_BACKEND or PGC_SU_BACKEND default set by 'G'
(`YbSetYsqlConnMgrGucDefaults`) is therefore never restored, and `yb_vars_default` keeps it.
Every later client without the option sees the leaked value, and every attach of such a
client sends 'g'.

Judgement: (c) product bug, confirmed live.

**Verification.** CONFIRMED in code (guc.c:9960-9966) and REPRODUCED on build/latest with
one backend per pool:
- Client A connects with
  `-c post_auth_delay=7 -c yb_enable_fkey_batched_docdb_lookup_when_types_mismatch=off`.
- Client B, with no options, runs on the same pid and sees `7s` / `off`.
- Expected: the defaults.
- The leak lasts for the backend's life.

The Conn Mgr log also explains the verifier's open question: after A's 'G',
`yb_vars_default` keeps `post_auth_delay`. B's startup list lacks it, so every attach of B,
including a re-attach of the same connection, sends 'g' followed by 'G' (2 vars). Scripts
and logs are in `/home/ec2-user/.claude/jobs/81b07efd/tmp/repro/` (`f1.py`, `f1.log`, and
the Conn Mgr debug log under `data/t/ysql-conn-mgr-*.log.*`).

### F2: 'G' on a SESSION-source GUC changes only reset_val and CM never records it (latent; unreachable today)

Mechanism (guc.c `set_config_option_ext`): while `yb_conn_mgr_modifying_defaults` is set,
when `record->source > source` (current source SESSION), the code sets `changeVal = false`
but `makeDefault` still writes `reset_val` and the saved default. No 'r' is sent, so CM's
`yb_vars_default` does not learn the new default.

Round 1 trace (B3nb, 7 states, uR = DateStyle):
1. c1 connects with `-c DateStyle=v1` and runs `SET DateStyle=v1`.
2. c2 runs `SET DateStyle=v1` on the same backend. 'g' runs, and the backend's lists become
   `vd={}` and `vs={DateStyle:v1}`.
3. c1 runs again on that backend with no reset. 'G' changes only `reset_val`.
4. c2 runs `RESET ALL` with no reset and gets v1 instead of the default.

c1's next deploy resends 'G', which logs the "This is a bug" WARNING.

The step that matters is step 3, where c1 attaches to a backend that c2 used last *without*
a 'g'. With the internal port var (F5), every switch to a different connection sends 'g'
first. 'g' resets SESSION-source GUCs, so 'G' never meets a SESSION source. N_B3nb (round 2)
passes P1/P1b/P1c/P2b/NoDoubleSave, and `GResetOnEveryClientSwitch` holds in every round-2
run.

Judgement: corrected from (c) to **latent**. The mechanism is confirmed in code, but it is
unreachable today. It becomes reachable if `yb_ycm_internal_client_port` is removed from
the startup vars, made non-startup (for example SESSION-sourced), or made equal across
connections, because the lazy "no reset" path would then serve different clients again.

**Verification.** NOT REPRODUCED live (`f2.py`, `f2.log`). c2's `RESET ALL` returned
`ISO, MDY`, which is correct. The Conn Mgr log shows 'g' at every client switch, which
matches F5.

### F3: a transaction-scoped change that leaves the value unchanged desyncs the CM lists

`AtEOXact_GUC` reports, and sets `YB_GUC_VALUE_RESET`, only when the restored value differs
(`changed`). It compares values for non-string GUCs and pointers for strings. The 'r' sent
for the in-transaction change has already updated the CM lists, so the undo is never seen.

**F3-stale (product bug).**
- Client A runs `BEGIN; SET work_mem=<value equal to current>; ROLLBACK`. The same happens
  with `BEGIN; SET LOCAL work_mem=<same>; COMMIT`, or with a disconnect inside the
  transaction.
- The backend's `yb_vars_session` keeps `work_mem=<value>` while the backend's source is
  not SESSION.
- The F5 'g' does not clean the entry: `ResetAllOptions` skips GUCs whose source is not
  SESSION/CLIENT, so no 'r' is sent.
- Client B then has `-c work_mem=X` and its own `SET work_mem=<value>`. On that backend
  `kiwi_vars_cas` skips B's SET because the list says it is already applied, and 'G' sets
  work_mem to X.
- Result: B sees X but should see `<value>`.

N_H4 and N_SIM P1 traces show this. N_SIM's is: c1 runs `BEGIN; SET LOCAL work_mem=d`,
then disconnects (rollback). c2 has `-c work_mem=v2` and runs `SET work_mem=d`, then a
statement on s1, and gets v2. The ListInclusion counterexample is the same stale entry.

Judgement: (c) product bug, confirmed live.

**Verification.** CONFIRMED in code and REPRODUCED in a reordered form (`f3b.py`,
`f3b.log`):
1. B connects with `-c work_mem=8MB` and runs `SET work_mem='4MB'`.
2. A, on the same pid, runs `BEGIN; SET work_mem='4MB'; ROLLBACK`.
3. B runs `select current_setting('work_mem')` and gets `8MB`; expected `4MB`.

B's following statement was correct again. The literal order in the round-1 write-up
(A first, then B connects and SETs) gives the correct value, because B's own SET runs after
the attach and re-sends the value. The bug needs B's session var to be already in B's list
when B attaches.

**F3-missing (latent; unreachable today).** Client A runs
`SET work_mem=<reset value>; BEGIN; RESET ALL; ROLLBACK` (or disconnects inside the
transaction). RESET ALL's VALUE_RESET 'r' removes work_mem from both lists. The rollback
restores the SESSION source with an unchanged value and sends no 'r'. The backend now holds
a SESSION-source work_mem that CM does not know about.

In round 1 (SIMfix), a later client B with `-c work_mem=v2` attaches without 'g', and its
'G' hits the SESSION source (F2's mechanism), so B keeps `<reset value>`. With F5, B's
attach always sends 'g', which resets the SESSION-source GUC and reports it, so the leak
does not reach B. Within one client it remains a list divergence: P8b fails in N_A6, with
no value-level effect.

Judgement: corrected from (c) to **latent**. The mechanism is confirmed. It is unreachable
across clients today and becomes reachable under the same condition as F2.

**Verification.** NOT REPRODUCED live, for the same reason as F2 (`f3.py`, `f3.log`).

### F4: duplicate ParameterStatus (known/accepted deviation)

Trace (N_A6/A6, 4 states): `BEGIN; SET LOCAL DateStyle = <current value>`. PG's
`ReportGUCOption` deduplicates against `last_reported`, so the reference sends nothing. CM
forwards every 'r' with REPORT_ENABLED (backend.c `od_backend_update_parameter`,
`!server_only && REPORT_ENABLED`). The comment in `ReportGUCOption` says CM filters these;
backend.c does not.

Judgement: (b) accepted deviation. P2b holds in round 2 wherever F1 is absent.

**Verification.** Not separately reproduced live. The F2 and F3 runs show ParameterStatus
forwarding as modelled, and protocol clients accept redundant ParameterStatus.

### F5: the internal port var forces a 'g' at every client switch (new)

From the code:
- `od_frontend_setup` (frontend.c:3015-3036) adds `yb_ycm_internal_client_addr` and
  `yb_ycm_internal_client_port` to `client->yb_startup_settings` before auth. The port is
  the client's TCP port, so it differs per connection.
- Both are forwarded in the auth backend's startup packet (backend.c:943-956 for the
  dedicated auth backend; yb_auth_passthrough.c for passthrough).
- Both are PGC_USERSET GUCs without GUC_REPORT (guc.c ConfigureNamesInt/String). They are
  set with source PGC_S_CLIENT, so `yb_should_report_guc` reports them with flags 0x2
  (SOURCE_STARTUP). The log shows exactly this.
- The startup 'r' handling (backend.c:1076-1083) and yb_auth_passthrough.c ignore only
  `yb_ycm_internal_is_client_ysqlconnmgr` and `_use_tserver_key_auth`. Address and port
  therefore land in `client->yb_vars_startup`.
- A transactional backend's startup packet does not carry them. They reach it only through
  'G' (deploy.c `yb_send_set_guc_defaults`). The 'r' reply, flags 0x2, puts them in
  `server->yb_vars_default`.
- On the next attach by a different connection, `yb_check_reset_needed` sees a port in
  `yb_vars_default` that is not in that client's `yb_vars_startup`, so 'g' is sent.
  `ResetAllOptions` with `yb_conn_mgr_modifying_defaults` restores the saved default
  (`""` / -1). It reports flags 0x18 (DEFAULT_VAL_RESET | SESSION_VAL_RESET), which removes
  them from `yb_vars_default`. 'G' then sends the new port.
- `yb_conn_mgr_client_hostname` (set from the addr assign hook on the auth backend when
  `log_hostname`) follows the same path and does not change the conclusion.

Model: `iP` is a fifth USERSET, non-REPORT kind. Its value is a fresh model value for each
connection, and it is added to the startup vars at Connect (`INTERNALVARS`, `PORTS`).
Clients never SET it. `_client_addr` is the same for clients on one host and is not
modelled separately.

Same-connection re-attach: when nothing else used the backend in between, `iP` matches, and
the lazy path skips 'g' (the `NoAttachWithoutReset` witness). The verifier's 'g' on a
same-client re-attach comes from F1: the earlier client left a BACKEND-context default
(`post_auth_delay`) in `yb_vars_default`. The second client's startup list lacks it, so
every attach of that client, whether or not it is the same connection, sends 'g'. The
Conn Mgr log shows `post_auth_delay = 7, flags: 0x2` from client A's 'G' and a "Reset to
transaction backend default" before every one of client B's statements.

`GResetOnEveryClientSwitch` (every attach to an Idle backend last used by a different
connection sends 'g') holds in every round-2 run. **The lazy "no reset needed" optimization
of `od_deploy` is effectively dead for client switches.** It only saves the 'g' when a
connection re-attaches to the backend it used last, with no other connection in between,
and no leaked BACKEND default (F1). Removing that dead path is not the fix: F2 and
F3-missing need the 'g' to stay unreachable.

## Where the code differs from SPEC_PLAN.md

1. **Superuser is per route, not per client.** One route is one user. Superuser
   stickiness comes from `session_auth_is_superuser` on the backend (pg_yb_utils.c
   `YbIsConnectionMadeStickyUsingGUC`), so `SUPER` is a model constant.
2. **'r' emission.** `ReportChangedGUCOptions` sends only GUCs with `GUC_NEEDS_REPORT`; a
   pending VALUE_RESET/DEFAULT_RESET waits for a later report.
3. **'G' does not always set the value.** With a current source of SESSION it only
   changes reset_val (F2).
4. **'g' skips BACKEND context entirely**, including the saved-default restore (F1).
5. **VALUE_RESET in AtEOXact_GUC** needs `changed`. It tests the source being discarded
   against SESSION, and `changed` compares pointers for strings; the model treats strings
   (uR) as always changed.
6. **SET LOCAL outside a block** applies in the implicit transaction and is undone at its
   commit, with 'r' packets. The plan had a no-op.
7. **Errors inside a transaction block** run `AtEOXact_GUC(false)` immediately and report
   at that RFQ.
8. **'G' and 'g' run in an implicit transaction** (postgres.c `start_xact_command`).
9. **ListInclusion does not fail after RESET ALL**: its VALUE_RESET packets remove the
   entry from both lists. It fails only through F3-stale.
10. **The sticky RFQ 'i'** is only produced when idle, and CM clears
    `yb_sticky_connection` on a plain 'I'. The backend latch keeps stickiness anyway.
11. **The plan omits the CM-injected startup vars** `yb_ycm_internal_client_addr/_port`
    (F5). The plan's "seed vars cancel out" assumption does not hold for them.

## Modelling notes

- Each statement is atomic. Attach, deploy, execute, 'r' consumption and detach happen in
  one step. Deploy-time 'r' packets are consumed with `server_only = 1`.
- Not modelled:
  - savepoints and nest levels above 1;
  - `GUC_NO_RESET_ALL` and parameter ACL grants;
  - the sticky-object counter and lock latches;
  - `session_authorization`/`role` list handling;
  - auth passthrough beyond the startup list;
  - `_client_addr` and `_hostname` (same as iP for this analysis);
  - the deploy `-2` retry path, which is unreachable (`IdleNotInTxn` holds).
- Closed servers return to `Free` and can be respawned.
