# Formal spec for the Conn Mgr GUC design: options

Source design: "DB DS: GUCs in Connection Manager" + the proof in "GUC Variables with YSQL
Connection Manager" (Lemmas 1–9, Theorem). The design landed on master ungated as
e937556ca33 (flag bits + `yb_vars_startup`/`yb_vars_session`) and 450c0dd0d5b ('G'/'g'
default packets + `yb_vars_default`). The `yb_conn_mgr_use_new_guc_handling` gate on branch
`custom_param_status` never landed.

## Shipped code vs the design doc

The spec must target one of these. Targeting the code (with the doc as intent) is the only
useful choice; these are the places where they differ and the proof in the doc no longer
covers what runs:

| Doc says | Code does | Where |
|---|---|---|
| PGC_BACKEND startup var ⇒ sticky backend (Lemma 1, 9) | Not sticky. Replayed on every attach via the 'G' packet with context PGC_(SU_)BACKEND, source CLIENT; backend saves its own default in `ysql_conn_mgr_saved_default` and 'g' restores it | guc.c:10016-10084, 11431-11495; deploy.c:53-134 |
| 5 flag bits incl. `context_backend` | `REPORT_ENABLED`, `SOURCE_STARTUP`, `USERSET_OR_SUSET_SOURCE_SESSION`, `DEFAULT_VAL_RESET`, `SESSION_VAL_RESET`; no context bit | pg_yb_conn_mgr_protocol.h:25-29 |
| Report at transaction end | Report before every ReadyForQuery, incl. inside a txn block; `AtEOXact_GUC` marks `VALUE_RESET` on rollback / SET LOCAL unwind | guc.c:10588-10619, 10494-10518 |
| Attach only when LCV equal (Lemma 4) | Default strategy `gradual` attaches to server LCV ≥ client LCV; only `connection_static` enforces equality | server_pool.h:179-250 |
| RESET ALL at detach | Lazy: detach sends nothing in optimized mode; next attach does superset check → 'g' → 'G' → one `Q` of SETs | deploy.c:136-246, reset.c:284-292 |
| Lists hold PGC_USERSET only | `yb_vars_session` also holds SUSET vars set by a superuser; safe only because `ysql_conn_mgr_superuser_sticky` latches, and that gflag can be turned off | guc.c:10652, pg_yb_utils.c:8560-8574 |
| — | `yb_vars_session` is seeded with two vars (`pg_hint_plan.enable_hint_table`, `compute_query_id`) on both client and server | var.h:253-271 |
| — | Silent drops: name > 64 or value > 128 bytes never enters a list; `Q` over 4096 bytes fails deploy | var.h:157-184, deploy.c:207-231 |

## Documents reviewed and what each contributes to a spec

| Doc | What it gives the spec |
|---|---|
| GUC Variables with YSQL Connection Manager (proof doc) | Axioms 1–4, Lemmas 1–9, Theorem; the reference-model definition ("hypothetical backend spawned at connect time"); the `length(server->vars) <= length(client->vars)` TODO is an invariant candidate |
| DB FS / DS: GUCs in Connection Manager | Req1 (base values match at attach) and Req2 (session SETs replayed); DS scope is Req2 only |
| DB FS: ALTER GUC commands | The only written spec for `gradual`: FR1a new sessions see prior ALTERs; FR1b existing sessions see them within `stale_backend_ttl_ms`; **FR2 monotonicity: once observed, always observed**. `connection_static` = PG-exact or disconnect; `fluctuating` = no guarantee |
| DB DS: ALTER GUC commands | LCV algorithm per strategy, expiry randomised over TTL, cron + detach expiry; 4-tuple LCV partial order with a per-route total-order claim (fine-grained option, not shipped) |
| Fixing LCV to handle Role changes | Design-space enumeration; claim that higher-LCV matching preserves ALTER execution order across sessions (an ordering property) |
| How to Increment LCV on SIGHUP | Invariant "equal LCV ⇒ no order-inducing op between spawns" restated with a node-local component (Approach 3, shipped as the SIGHUP bump in guc.c:11745-11759); Approach 2's race (connection between postmaster signal and first increment) is a textbook model-checker target |
| Logical client version matching / LCV gaps (Rahul) | Original algorithm; the DB-vs-pool version mismatch and the kill-all-older-servers behaviour as known deviations |
| GUC Related DOCS | Five corner cases (is_superuser replay, unforwarded startup packet, replay order DB-15792, ParameterStatus for non-REPORT vars at auth, SIGHUP flooding) as regression properties |
| Making startup GUCs default (Manav) | `BEGIN; RESET x; SHOW x; END` with a startup default: the case that motivated 'G'/'g' |
| Setting GUC parameters via ALTER ROLE (Devansh) | Two anomaly traces (value flips mid-session; value goes backwards) = FR2 violations, usable as negative tests |
| ConnMgr GUC Compatibility Analysis (sheet, 633 GUCs) | Hazard classes that break "a GUC is a (value, source) pair": cross-GUC assign hooks with unreported side effects, sets via `PGC_S_DYNAMIC_DEFAULT` (unreported), non-round-trippable show hooks (`seed`), show hooks returning kernel state, process-wide side effects (locale, socket options), `GUC_NO_RESET_ALL` bypassed by 'g' |
| LCV-propagation-UFD.md (checkout) | Cross-tserver LCV propagation; without it Lemma 3 holds per node only |

Additional proof gaps these surface (beyond the ones under "What there is to verify"):

- Lemma 3 is per node. The catalog version is global but an ALTER on node A reaches node B
  only when a connection authenticates there (UFD). The SIGHUP component is node-local by
  design. So "equal LCV ⇒ no order-inducing op in between" is true only if both backends are
  on the same node, which the proof does not state.
- SIGHUP vs auth passthrough: the control backend that assigns client LCVs is forked before
  the SIGHUP and is terminated on the next 'A' request (postgres.c). A client that
  authenticates in that window gets the pre-SIGHUP LCV; whether it can then attach to a
  post-SIGHUP backend under `gradual` and see a PGC_BACKEND value change mid-session is
  exactly the kind of interleaving the model should decide.
- FR2 (monotonicity) is only argued informally. It depends on client LCV being raised to the
  server LCV at every attach and on servers never being downgraded; nothing in the proof doc
  covers it because the proof doc assumes equality.
- Replay through `SET` re-runs assign hooks, so cross-GUC side effects are re-established in
  deploy order; the sheet notes ordering matters for circular dependencies (`yb_enable_cbo`
  family). The reference model has to decide whether a GUC's observable value includes the
  backing variables its hooks write.

## What there is to verify

The design's theorem is an observational-equivalence claim:

> For every GUC, the value the logical client observes (SHOW / behaviour / ParameterStatus it
> receives) equals the value a hypothetical dedicated backend spawned at the client's connect
> time would show, at every observation point.

That shape is a **refinement**: an abstract model (one dedicated PG backend per client, PG's
own GUC rules) is the spec; the concrete model (CM lists + pool of physical backends + flag
bits + LCV matching + stickiness) must agree with it on everything the client can see.

Sub-properties the hand proof relies on, each checkable on its own:

| # | Property | From |
|---|---|---|
| P1 | At every ReadyForQuery, attached backend's GUC values == reference backend's values | Theorem |
| P2 | Every ParameterStatus relayed to the client is exactly what direct PG would have sent (name, case, value, and nothing for non-GUC_REPORT vars) | Handling of ParameterStatus |
| P3 | CM only ever replays PGC_USERSET vars via SET | Lemma 9 |
| P4 | RESET lands on the right default: startup-packet value if any, else the spawn-time default | Lemma 8 |
| P5 | A non-sticky client is only ever attached to a backend with equal LCV; backends with equal LCV saw no order-inducing op between spawns | Lemmas 2–4 |
| P6 | Pool backends and non-sticky clients have Authenticated == Session == Outer == Current user | Lemmas 5–6 |
| P7 | Stickiness latches whenever a non-replayable setting is taken (role, session_authorization, superuser-ever, custom sticky GUCs); PGC_BACKEND startup vars are instead re-established by 'G' on every attach | guc.c:11599-11606, 12460, 17907 |
| P8 | SET LOCAL / rolled-back SET never leak into `yb_vars_session`; committed SET always does | txn-end reporting |
| P9 | 'G'/'g' round-trip: after 'g' every GUC's reset_val/reset_source equals the backend's spawn-time default; after 'G' it equals the client's startup value | guc.c:9795-9872, 11431-11495 |
| P10 | `gradual`: a client never observes an ALTER-derived default older than one it already observed (FR2); client LCV is non-decreasing | ALTER FS |
| P11 | `gradual` with TTL ≥ 0: every client observes the latest ALTER within TTL (liveness, real-time) | ALTER FS FR1b |
| P12 | `connection_static`: a client either observes PG-exact defaults or is disconnected, never a newer default | ALTER FS |

Places the hand proof is explicitly incomplete (a formal model forces a decision on each):

- Lemma 2, PGC_INTERNAL row: "Not sure, TODO".
- Lemma 10: empty.
- "DOUBT" on whether ALTER ROLE SUPERUSER needs an LCV bump at all.
- Assumption 2 (a user who could SET a var once can always SET it again) is false for
  check hooks that depend on session state, e.g. `yb_read_after_commit_visibility`
  (`yb_check_no_txn`), `transaction_isolation` inside a txn, `client_encoding`.
- Replay order (DB-15792) is asserted "not an issue" pending a mailing-list check.
- Auth passthrough: "LCV matching doesn't work with authentication passthrough" is noted,
  not resolved.
- Capacity: oversize names/values are silently dropped at push (var.h:157-159) and the
  deploy `Q` has a 4096-byte cap, which breaks P1 outright. Either model capacity or
  declare it out of scope.
- `gradual` (the default) is outside the proof: Lemma 4 assumes equal LCV. The spec has to
  state the weaker guarantee that holds for gradual, if one does.

## Options

### Option A: TLA+ (TLC model checker, Apalache for symbolic/bounded) — recommended

Model: a state machine with actors Client×N, CM, PhysicalBackend×M, Postmaster, Catalog.
Each client carries a *reference backend* (abstract PG GUC map: value, source, context,
reset_value, txn stack). CM carries `yb_vars_startup`, `yb_vars_session`, per-server
`vars`, LCVs, sticky flags. Transitions: Connect(startup opts), SET, SET LOCAL, RESET,
RESET ALL, BEGIN/COMMIT/ROLLBACK, SHOW, Disconnect, Attach/Detach/Deploy, Spawn/Close
backend, ALTER … SET (LCV bump), SIGHUP, ALTER ROLE [NO]SUPERUSER, SET ROLE, SET SESSION
AUTHORIZATION. P1–P8 are invariants; TLC enumerates all interleavings for small bounds
(2 clients, 2 backends, ~5 GUC "kinds" × 3 values).

- Fits: concurrency between clients, pool reuse, ALTER/SIGHUP racing an attach, the
  ParameterStatus protocol. The design is a distributed-protocol-shaped problem and this is
  the standard tool for it (AWS, MongoDB, CockroachDB, TiDB all keep TLA+ specs).
- Output: counterexample traces that translate 1:1 into Java test scenarios.
- Limits: bounded instances only; no unbounded proof unless you add TLAPS (not worth it).
  Model-vs-code drift is the real risk; mitigated by trace validation (Option E).
- Toolchain: TLC is a jar, JDK 17/21 is on the box. Apalache is a JVM app. VS Code
  extension for editing. Zero install friction.
- Effort: 3–5 days to a first model with P1/P3/P4/P7/P8; +2–3 days for LCV/SIGHUP/
  superuser (P5/P6) and state-space tuning.
- Variant A′: **Quint** (Informal Systems). Same semantics, TypeScript-like syntax, built-in
  random simulator, compiles to TLA+ for TLC/Apalache. Easier to read for reviewers who
  don't know TLA+; younger tool. Needs Node (v20 present). Choose A′ if reviewers will
  push back on TLA+ syntax; the model is the same.

### Option B: Alloy 6 (relational logic, bounded SAT)

Model the *data* side rather than the protocol: GUC records with (context, source,
has_check_hook, GUC_REPORT), the source precedence lattice, which contexts each setting
path may touch, the three CM lists, and the ParameterStatus flag computation as relations.
Alloy 6 has temporal operators, so short traces (SET → RESET → attach) are expressible, but
multi-actor message protocols are awkward.

- Fits: P3, P4, P6, the flag-bit decision table (`guc.c:10617-10652`), and the "which
  of 5 bits are set" exhaustiveness question. Finds small counterexamples fast and draws
  them.
- Limits: weak on sequencing/concurrency and on anything numeric (LCV counters, capacity).
- Toolchain: Alloy is a jar; JDK present.
- Effort: 2–3 days. Best as a complement to A for the lattice/decision-table part, not as
  the main spec.

### Option C: P language (Microsoft/AWS state machines with message passing)

Write Client, ConnMgr, Backend, Postmaster as P state machines exchanging typed events
(StartupPacket, Query, ParameterStatus{flags}, ReadyForQuery{'I'/'i'}). Specs are monitors
(P1, P2 as observer machines). The P checker does systematic/randomised exploration of
schedules.

- Fits: closest structural match to Odyssey + backend processes; the spec reads like code,
  so engineers who won't read TLA+ will read it. AWS uses it for S3/EBS protocols.
- Limits: it is testing-grade exploration, not exhaustive at the same bounds as TLC;
  weaker story for "this is proven". Needs dotnet (v9 present).
- Effort: ~1 week.

### Option D: Mechanised proof (Dafny, or Lean 4 / Isabelle)

Transcribe the state machine and prove the inductive invariant that implies P1 for
*unbounded* clients, backends and GUCs. Dafny: write the transition system as ghost
code, lemmas as methods, Z3 discharges most obligations (IronFleet style). Lean 4 /
Isabelle: full mathematical development of Lemmas 1–9; AI-assisted proving makes this
far less painful than it was, and it is the only option that turns the doc's proof into
a checked artifact rather than a bounded search.

- Fits: the deliverable "the design is proven", and auditing the proof's holes (Lemma 2
  INTERNAL row, Lemma 10, assumption 2) because the prover will not let you skip them.
- Limits: concurrency has to be modelled explicitly as interleaving transitions, which is
  more work than in TLA+; no counterexample traces when a proof fails, only a stuck
  obligation; highest cost; the model is still a model (drift risk unchanged).
- Toolchain: Dafny via dotnet tool (dotnet 9 present); Lean via elan.
- Effort: Dafny 2–3 weeks; Lean 3–5 weeks for the full lemma set.

### Option E: Trace validation against the real system (companion to A)

Instrument Odyssey/backend to log state transitions (attach, deploy SETs, ParameterStatus
flags, LCV decisions) as JSON, run the existing `TestSessionParameters` /
`TestYCMConfiguration` scenarios and randomised SET/RESET/ALTER/SIGHUP workloads, then
check the logged trace is a behaviour of the TLA+ spec (TLC in trace mode; the approach
MongoDB and eXtreme-modelling papers use). Alternatively, skip the spec and do
model-based testing: a Python Hypothesis stateful test drives CM and a direct-PG oracle
with the same random command sequence and diffs `SHOW ALL` plus received ParameterStatus.

- Fits: the gap every other option leaves open: does the code do what the model says.
- Limits: not a spec by itself; needs logging hooks in product code.
- Effort: 3–4 days once A exists; the Hypothesis oracle test alone ~2 days and needs no spec.

## Suggested module split (any option)

1. **Session module**: one client, one route, pool of backends; SET / SET LOCAL / RESET /
   RESET ALL / txn end / attach / detach / 'G' / 'g' / 'r' flags; P1–P4, P7–P9. No ALTER,
   no SIGHUP, LCV constant. This is where the doc's Lemmas 1, 7, 8, 9 live and where most
   bugs so far have been (corner cases 1–5, DB-15792, DB-13801).
2. **Versioning module**: multiple clients and nodes, ALTER … SET, SIGHUP, LCV assignment
   and bump propagation, the three adoption strategies, expiry; P5, P6, P10–P12. Lemmas 2–6
   and the SIGHUP invariant live here. Abstract the session module to "attach = copy
   defaults from backend".

Composing them later is straightforward in TLA+/Quint; starting with both at once is not.

## Recommendation

A (TLA+, or A′ Quint if syntax is a concern) as the spec, session module first (P1–P4,
P7–P9), then the versioning module (P5, P6, P10–P12). Add E once the model stabilises so the spec stays tied to Odyssey. B only if
the flag-bit decision table turns out to need its own exhaustiveness argument. D only if a
"proven" artifact is the goal in itself; it does not find bugs faster than A.

## Decisions needed before writing the spec (any option)

1. Scope of GUC kinds: which (context, source, check_hook, GUC_REPORT) combinations to
   model. Proposal: USERSET±hook, SUSET, BACKEND, SU_BACKEND, INTERNAL; sources DEFAULT <
   FILE < GLOBAL < DATABASE < USER < DATABASE_USER < CLIENT < OVERRIDE < SESSION.
2. Whether check-hook failures on replay (assumption 2) are in scope. If yes, the spec
   must say what CM does when a deploy SET errors.
3. Whether capacity (`KIWI_MAX_VAR_SIZE`, query buffer) is in scope.
4. Auth backend vs auth passthrough: model one, or both with LCV handling as it is today.
5. Which behaviour is the target: `yb_optimized_session_parameters` on (default, lazy reset at
   attach), off (eager 'g' at detach), or both.
7. LCV adoption strategy: `connection_static` (matches the proof) only, or also `gradual`
   (default) and `fluctuating`.
8. `ysql_conn_mgr_superuser_sticky` = false: in scope or declared unsupported.
6. Stickiness: model the three sources (object count, GUC latch, lock latch) or only the
   GUC latch. The reversible-stickiness work changes the object count; the GUC latch is
   permanent and is all this spec needs.
