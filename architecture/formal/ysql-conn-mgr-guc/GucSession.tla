---------------------------- MODULE GucSession ----------------------------
(***************************************************************************)
(* GUC handling for one Connection Manager route: N logical clients share *)
(* M transactional backends.  A reference model (one dedicated plain-PG    *)
(* backend per client) runs in lock-step with the concrete model (CM +     *)
(* pool + YB backend hooks); the invariants say the client cannot tell     *)
(* them apart.  See SPEC_PLAN.md, Module 1.                                *)
(*                                                                         *)
(* Anchors are file:function on master b286efd7b5c.  guc.c is              *)
(* src/postgres/src/backend/utils/misc/guc.c; Odyssey files are under      *)
(* src/odyssey/.                                                           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    CLIENTS,      \* logical clients
    SERVERS,      \* backend slots of the route's pool
    NoServer,     \* model value: client not attached
    MAXSTMTS,     \* statements per client (all sessions together)
    MAXCONNS,     \* connects per client
    SUPER,        \* the route's user is a superuser (one route = one user)
    SETVALS,      \* values a SET statement may use, subset of Vals
    OPS,          \* statement kinds clients may issue (see STMTS)
    STARTUPKEYS,  \* startup option choices (see STARTUPS)
    GFIX,         \* FALSE = product code; TRUE = hypothetical fix, see Deploy
    TRACE         \* record the last action in lastAct (for readable traces)

GUCS == {"uR", "uN", "sU", "bK"}
Vals == {"d", "v1", "v2"}
NoVal == "-"                                \* absent from a kiwi var list

\* GucSource, collapsed.  PGC_S_OVERRIDE sits between CLIENT and SESSION, so
\* "source <= PGC_S_OVERRIDE" is "src \in {DFLT, CLIENT}".
DFLT == 0
CLIENT == 1
SESSION == 2

\* uR ~ DateStyle (string), uN ~ work_mem (int), sU ~ a PGC_SUSET enum,
\* bK ~ a PGC_BACKEND bool.
Ctx(g) == CASE g = "uR" -> "USERSET"
            [] g = "uN" -> "USERSET"
            [] g = "sU" -> "SUSET"
            [] g = "bK" -> "BACKEND"
IsReport(g) == g = "uR"
IsString(g) == g = "uR"
SetCtx(g) == Ctx(g) \in {"SUSET", "USERSET"}

\* guc.c:set_config_option_ext context switch, for a SQL SET/RESET/SET LOCAL
\* (context PGC_USERSET, or PGC_SUSET for a superuser).  No parameter ACLs.
SqlAllowed(g) == Ctx(g) = "USERSET" \/ (Ctx(g) = "SUSET" /\ SUPER)
\* Same switch for 'G' (guc.c:YbSetYsqlConnMgrGucDefaults uses PGC_BACKEND,
\* or PGC_SU_BACKEND for a superuser).
GAllowed(g) == Ctx(g) # "SUSET" \/ SUPER

\* Startup option choices from the plan ({}, uR=v1, bK=v1, uN=v2), plus sU=v1
\* for a superuser route; STARTUPKEYS (a constant) selects among them.
NoVars == [g \in GUCS |-> NoVal]
StartupOpt(k) == CASE k = "-"  -> NoVars
                   [] k = "uR" -> [NoVars EXCEPT !["uR"] = "v1"]
                   [] k = "bK" -> [NoVars EXCEPT !["bK"] = "v1"]
                   [] k = "uN" -> [NoVars EXCEPT !["uN"] = "v2"]
                   [] k = "sU" -> [NoVars EXCEPT !["sU"] = "v1"]
STARTUPS == { StartupOpt(k) : k \in {x \in STARTUPKEYS : x # "sU" \/ SUPER} }

(***************************************************************************)
(* Statements.  A GUC the session can never SET contributes only one       *)
(* statement ("SET g v1"): SET, SET LOCAL and RESET of it fail the same    *)
(* way, before any state change.                                           *)
(***************************************************************************)
S(k, g, v) == [k |-> k, g |-> g, v |-> v]
\* OPS (a constant) selects statement kinds, "ERR" being the failing SETs.
SetG == {h \in GUCS : SqlAllowed(h)}
AllStmts ==
    { S("SET", g, v)   : g \in SetG, v \in SETVALS }
 \cup { S("LOCAL", g, v) : g \in SetG, v \in SETVALS }
 \cup { S("RESET", g, "-") : g \in SetG }
 \cup { S("ERR", g, "v1") : g \in GUCS \ SetG }
 \cup { S(k, "-", "-") : k \in {"RESETALL", "BEGIN", "COMMIT", "ROLLBACK",
                                  "SELECT", "SETROLE"} }
STMTS == {st \in AllStmts : st.k \in OPS}

(***************************************************************************)
(* Per-GUC record (struct config_generic).                                 *)
(*   val/src        current value and source                               *)
(*   rv/rs          reset_val / reset_source                               *)
(*   st,pv,ps,mv    the single nest-level-1 GucStack entry: state, prior   *)
(*                  value/source, masked value (masked source is SESSION)  *)
(*   sd,sdv,sds     ysql_conn_mgr_saved_default                            *)
(*   nr,vr,dr       GUC_NEEDS_REPORT, YB_GUC_VALUE_RESET,                  *)
(*                  YB_GUC_DEFAULT_RESET                                   *)
(* Unused fields are normalised to fixed values.                           *)
(***************************************************************************)
FreshRec == [val |-> "d", src |-> DFLT, rv |-> "d", rs |-> DFLT,
             st |-> "NONE", pv |-> "d", ps |-> DFLT, mv |-> "d",
             sd |-> FALSE, sdv |-> "d", sds |-> DFLT,
             nr |-> FALSE, vr |-> FALSE, dr |-> FALSE]
FreshMap == [g \in GUCS |-> FreshRec]

Recs == [val : Vals, src : {DFLT, CLIENT, SESSION}, rv : Vals,
         rs : {DFLT, CLIENT, SESSION},
         st : {"NONE", "SET", "LOCAL", "SET_LOCAL"}, pv : Vals,
         ps : {DFLT, CLIENT, SESSION}, mv : Vals,
         sd : BOOLEAN, sdv : Vals, sds : {DFLT, CLIENT, SESSION},
         nr : BOOLEAN, vr : BOOLEAN, dr : BOOLEAN]

\* guc.c:yb_should_report_guc (CM client).  Every kind here has
\* context >= PGC_SU_BACKEND.
Reportable(r, g) == IsReport(g) \/ r.vr \/ r.dr \/ r.src \in {CLIENT, SESSION}

\* guc.c:set_config_option_ext tail: changeVal && yb_should_report_guc.
MarkReport(r, g) == IF Reportable(r, g) THEN [r EXCEPT !.nr = TRUE] ELSE r

\* guc.c:push_old_value, nest level 1 only (no savepoints).
PushOld(r, a) ==
    IF r.st = "NONE" THEN [r EXCEPT !.st = a, !.pv = r.val, !.ps = r.src]
    ELSE IF a = "SET" THEN [r EXCEPT !.st = "SET", !.mv = "d"]
    ELSE IF r.st = "SET" THEN [r EXCEPT !.st = "SET_LOCAL", !.mv = r.val]
    ELSE r

Pop(r) == [r EXCEPT !.st = "NONE", !.pv = "d", !.ps = DFLT, !.mv = "d"]

\* guc.c:set_config_option_ext, SET / SET LOCAL from SQL: source SESSION is
\* the highest, so changeVal stays true; makeDefault is false.
SetValue(r, g, v, a) ==
    MarkReport([PushOld(r, a) EXCEPT !.val = v, !.src = SESSION], g)

\* guc.c:set_config_option_ext with value NULL, source SESSION (gucReset):
\* value and source come from reset_val/reset_source; YB_GUC_VALUE_RESET set.
ResetOne(r, g) ==
    MarkReport([PushOld(r, "SET") EXCEPT !.val = r.rv, !.src = r.rs,
                                         !.vr = TRUE], g)

\* guc.c:yb_reset_conn_mgr_default
ResetConnMgrDefault(r) ==
    IF ~r.sd THEN r
    ELSE [r EXCEPT !.rv = r.sdv, !.rs = r.sds, !.dr = TRUE,
                   !.sd = FALSE, !.sdv = "d", !.sds = DFLT]

\* guc.c:ResetAllOptions.  Only PGC_SUSET/PGC_USERSET are visited, also
\* when modifying defaults ('g'), so a PGC_BACKEND saved default is never
\* restored.
ResetAllOne(r, g, mod) ==
    IF ~SetCtx(g) THEN r
    ELSE LET r1 == IF mod THEN ResetConnMgrDefault(r) ELSE r
             skip == IF mod THEN r1.src = DFLT ELSE r1.src \in {DFLT, CLIENT}
         IN IF skip THEN r1
            ELSE MarkReport([PushOld(r1, "SET") EXCEPT !.val = r1.rv,
                                 !.src = r1.rs, !.vr = TRUE], g)

\* guc.c:YbSetYsqlConnMgrGucDefaults -> set_config_option_ext(source
\* PGC_S_CLIENT, yb_conn_mgr_modifying_defaults): makeDefault is true; the
\* value is only changed if the current source is not higher than CLIENT;
\* yb_conn_mgr_save_default_value saves (reset_val, reset_source) once.
SetDefaultOne(r, g, v) ==
    LET changeVal == r.src # SESSION
        r1 == IF r.sd THEN r ELSE [r EXCEPT !.sd = TRUE, !.sdv = r.rv,
                                            !.sds = r.rs]
        r2 == IF changeVal THEN [r1 EXCEPT !.val = v, !.src = CLIENT] ELSE r1
        r3 == IF r2.rs <= CLIENT THEN [r2 EXCEPT !.rv = v, !.rs = CLIENT]
              ELSE r2
        r4 == IF r3.st # "NONE" /\ r3.ps <= CLIENT
              THEN [r3 EXCEPT !.pv = v, !.ps = CLIENT] ELSE r3
    IN IF changeVal THEN MarkReport(r4, g) ELSE r4

\* guc.c:AtEOXact_GUC, nestLevel 1.  "changed" compares values for
\* non-string GUCs and pointers for PGC_STRING; a restored string pointer
\* almost always differs from the current one (each SET allocates), so it is
\* modelled as always changed.  (It is equal only when the stacked and
\* current pointers are both reset_val, e.g. BEGIN; RESET x; ROLLBACK at the
\* default; then the code reports nothing and the model reports a duplicate.)
EOX(r, g, commit) ==
    IF r.st = "NONE" THEN r
    ELSE IF commit /\ r.st = "SET" THEN Pop(r)
    ELSE LET masked == commit /\ r.st = "SET_LOCAL"
             nv == IF masked THEN r.mv ELSE r.pv
             ns == IF masked THEN SESSION ELSE r.ps
             changed == IsString(g) \/ nv # r.val
             vrSet == changed /\ SetCtx(g) /\ r.src = SESSION
             r1 == [Pop(r) EXCEPT !.val = nv, !.src = ns, !.vr = r.vr \/ vrSet]
         IN IF changed /\ (vrSet \/ Reportable(r1, g))
            THEN [r1 EXCEPT !.nr = TRUE] ELSE r1

EOXMap(M, commit) == [g \in GUCS |-> EOX(M[g], g, commit)]

\* One non-transaction-control statement on map M.  Errors happen before
\* any change.
Op(M, s) ==
    CASE s.k \in {"SET", "LOCAL", "RESET", "ERR"} /\ ~SqlAllowed(s.g) ->
            [m |-> M, err |-> TRUE]
      [] s.k = "SET" ->
            [m |-> [M EXCEPT ![s.g] = SetValue(M[s.g], s.g, s.v, "SET")],
             err |-> FALSE]
      [] s.k = "LOCAL" ->
            [m |-> [M EXCEPT ![s.g] = SetValue(M[s.g], s.g, s.v, "LOCAL")],
             err |-> FALSE]
      [] s.k = "RESET" ->
            [m |-> [M EXCEPT ![s.g] = ResetOne(M[s.g], s.g)], err |-> FALSE]
      [] s.k = "RESETALL" ->
            [m |-> [g \in GUCS |-> ResetAllOne(M[g], g, FALSE)], err |-> FALSE]
      [] OTHER -> [m |-> M, err |-> FALSE]          \* SELECT, SET ROLE

(***************************************************************************)
(* Statement execution with transaction state t in {IDLE, INTX, FAILED}.   *)
(* Outside a block every statement is an implicit transaction (commit at   *)
(* end, so SET LOCAL reverts).  An error inside a block aborts at once     *)
(* (AbortTransaction -> AtEOXact_GUC(false)) and leaves the block FAILED.  *)
(***************************************************************************)
Exec(M, t, s) ==
    CASE s.k = "BEGIN" ->
            IF t = "FAILED" THEN [m |-> M, t |-> t, err |-> TRUE]
            ELSE [m |-> M, t |-> "INTX", err |-> FALSE]
      [] s.k = "COMMIT" ->
            IF t = "INTX" THEN [m |-> EOXMap(M, TRUE), t |-> "IDLE", err |-> FALSE]
            ELSE [m |-> M, t |-> "IDLE", err |-> FALSE]
      [] s.k = "ROLLBACK" ->
            IF t = "INTX" THEN [m |-> EOXMap(M, FALSE), t |-> "IDLE", err |-> FALSE]
            ELSE [m |-> M, t |-> "IDLE", err |-> FALSE]
      [] OTHER ->
            IF t = "FAILED" THEN [m |-> M, t |-> t, err |-> TRUE]
            ELSE LET o == Op(M, s) IN
                 IF t = "IDLE"
                 THEN IF o.err THEN [m |-> M, t |-> "IDLE", err |-> TRUE]
                      ELSE [m |-> EOXMap(o.m, TRUE), t |-> "IDLE", err |-> FALSE]
                 ELSE IF o.err THEN [m |-> EOXMap(M, FALSE), t |-> "FAILED", err |-> TRUE]
                      ELSE [m |-> o.m, t |-> "INTX", err |-> FALSE]

(***************************************************************************)
(* 'r' packets.  guc.c:ReportChangedGUCOptions sends one per GUC with      *)
(* GUC_NEEDS_REPORT; guc.c:ReportGUCOption computes the flags and clears   *)
(* NEEDS_REPORT, VALUE_RESET, DEFAULT_VAL_RESET of the reported GUC only.  *)
(* SOURCE_STARTUP iff src = CLIENT (BACKEND and SUSET/USERSET alike);      *)
(* USERSET_OR_SUSET_SOURCE_SESSION iff src = SESSION and SUSET/USERSET.    *)
(***************************************************************************)
FStartup(r) == r.src = CLIENT
FSession(r, g) == r.src = SESSION /\ SetCtx(g)

ClearReported(M) ==
    [g \in GUCS |-> IF M[g].nr
                    THEN [M[g] EXCEPT !.nr = FALSE, !.vr = FALSE, !.dr = FALSE]
                    ELSE M[g]]

\* backend.c:od_backend_update_parameter, server->yb_vars_default
ApplyDefault(VD, M) ==
    [g \in GUCS |-> IF ~M[g].nr THEN VD[g]
                    ELSE IF FStartup(M[g]) THEN M[g].val
                    ELSE IF M[g].dr THEN NoVal
                    ELSE VD[g]]

\* backend.c:od_backend_update_parameter, server->yb_vars_session and (when
\* !server_only) client->yb_vars_session
ApplySession(VS, M) ==
    [g \in GUCS |-> IF ~M[g].nr THEN VS[g]
                    ELSE IF FSession(M[g], g) THEN M[g].val
                    ELSE IF M[g].vr THEN NoVal
                    ELSE VS[g]]

\* backend.c:od_backend_update_parameter: REPORT_ENABLED packets are
\* forwarded as 'S' when !server_only, with no comparison to what the client
\* last saw.
Fwd(M) == { <<g, M[g].val>> : g \in {h \in GUCS : M[h].nr /\ IsReport(h)} }

\* Backend processes one message: its 'r' packets are consumed by CM.
RunMsg(srv, M, t) ==
    [m |-> ClearReported(M), t |-> t,
     vd |-> ApplyDefault(srv.vd, M), vs |-> ApplySession(srv.vs, M)]

\* kiwi/var.h:yb_check_is_superset(b, a): every (key, value) of a is in b.
Sub(a, b) == \A g \in GUCS : a[g] # NoVal => b[g] = a[g]

\* Plain-PG reference: guc.c:ReportGUCOption non-CM branch dedups against
\* last_reported, so the report set is the GUC_REPORT vars whose value
\* differs from the last one sent.
RefFwd(M, last) == { <<g, M[g].val>> : g \in {h \in GUCS : IsReport(h) /\ M[h].val # last[h]} }

\* Checks made when a statement completes, before a possible detach: the
\* server map Ms against the reference map Mr, and the forwarded reports.
StmtChecks(Ms, Mr, cm, rf) ==
       (IF \A g \in GUCS : Ms[g].val = Mr[g].val THEN {} ELSE {"P1"})
  \cup (IF \A g \in GUCS : Ms[g].rv = Mr[g].rv /\ Ms[g].rs = Mr[g].rs
        THEN {} ELSE {"P1b"})
  \cup (IF \A g \in GUCS : Ms[g].src = Mr[g].src THEN {} ELSE {"P1c"})
  \cup (IF cm = rf THEN {} ELSE {"P2"})
  \cup (IF rf \subseteq cm /\ \A p \in cm : p[2] = Mr[p[1]].val
        THEN {} ELSE {"P2b"})

Strip(M) == [g \in GUCS |-> [M[g] EXCEPT !.nr = FALSE, !.vr = FALSE, !.dr = FALSE]]

(***************************************************************************)
(* Deploy: deploy.c:od_deploy with yb_optimized_session_parameters (the     *)
(* default, config.c).  Each message runs in an implicit transaction        *)
(* (postgres.c 'G'/'g': start_xact_command/finish_xact_command; the SET     *)
(* list is one simple query).  All 'r' packets are consumed server_only.   *)
(***************************************************************************)
Deploy(vstart, vsess, srv) ==
    LET \* kiwi/var.h:yb_check_reset_needed
        need == ~(Sub(srv.vd, vstart) /\ Sub(srv.vs, vsess))
        \* reset.c:yb_send_reset_backend_default_query -> 'g' ->
        \* guc.c:YbResetYsqlConnMgrGucDefaults -> ResetAllOptions
        s1 == IF need
              THEN RunMsg(srv, EOXMap([g \in GUCS |-> ResetAllOne(srv.m[g], g, TRUE)], TRUE), "IDLE")
              ELSE srv
        \* deploy.c:yb_send_set_guc_defaults
        glist == {g \in GUCS : vstart[g] # NoVal /\ s1.vd[g] # vstart[g]}
        gerr == \E g \in glist : ~GAllowed(g)
        s2a == IF glist = {} \/ gerr THEN s1
               ELSE RunMsg(s1, EOXMap([g \in GUCS |->
                        IF g \in glist THEN SetDefaultOne(s1.m[g], g, vstart[g])
                        ELSE s1.m[g]], TRUE), "IDLE")
        \* GFIX: hypothetical CM change, not product behaviour: record every
        \* var sent in 'G' in yb_vars_default even when no 'r' comes back.
        s2 == IF GFIX /\ glist # {} /\ ~gerr
              THEN [s2a EXCEPT !.vd = [g \in GUCS |->
                        IF g \in glist THEN vstart[g] ELSE s2a.vd[g]]]
              ELSE s2a
        \* kiwi/var.h:kiwi_vars_cas
        slist == {g \in GUCS : vsess[g] # NoVal /\ s2.vs[g] # vsess[g]}
        serr == \E g \in slist : ~SqlAllowed(g)
        s3 == IF slist = {} \/ serr THEN s2
              ELSE RunMsg(s2, EOXMap([g \in GUCS |->
                        IF g \in slist THEN SetValue(s2.m[g], g, vsess[g], "SET")
                        ELSE s2.m[g]], TRUE), "IDLE")
    IN [srv |-> s3,
        msgs |-> need \/ glist # {} \/ slist # {},
        leftSaved |-> need /\ \E g \in GUCS : s1.m[g].sd,
        savedTwice |-> \E g \in glist : s1.m[g].sd,
        err |-> gerr \/ serr,
        badReplay |-> \E g \in slist : ~SqlAllowed(g)]

-----------------------------------------------------------------------------
VARIABLES
    \* clients
    cState, conns, stmts, roleIssued,
    ref, refT, refLast,                    \* reference backend per client
    varsStartup, varsSession, attached, cInTxn,
    \* servers
    gucs, sT, sVarsDefault, sVarsSession, sState, srvSticky, latch,
    \* history flags for P3/P9/warnings
    badReplay, gLeftSaved, savedTwice, deployErr,
    \* names of per-statement checks (P1*, P2*) that failed at some statement
    bad,
    lastAct

cvars == <<cState, conns, stmts, roleIssued, ref, refT, refLast,
           varsStartup, varsSession, attached, cInTxn>>
svars == <<gucs, sT, sVarsDefault, sVarsSession, sState, srvSticky, latch>>
hvars == <<badReplay, gLeftSaved, savedTwice, deployErr, bad>>
vars == <<cvars, svars, hvars, lastAct>>

Act(x) == lastAct' = IF TRACE THEN x ELSE "-"

Init ==
    /\ cState = [c \in CLIENTS |-> "Off"]
    /\ conns = [c \in CLIENTS |-> 0]
    /\ stmts = [c \in CLIENTS |-> 0]
    /\ roleIssued = [c \in CLIENTS |-> FALSE]
    /\ ref = [c \in CLIENTS |-> FreshMap]
    /\ refT = [c \in CLIENTS |-> "IDLE"]
    /\ refLast = [c \in CLIENTS |-> [g \in GUCS |-> "d"]]
    /\ varsStartup = [c \in CLIENTS |-> NoVars]
    /\ varsSession = [c \in CLIENTS |-> NoVars]
    /\ attached = [c \in CLIENTS |-> NoServer]
    /\ cInTxn = [c \in CLIENTS |-> FALSE]
    /\ gucs = [s \in SERVERS |-> FreshMap]
    /\ sT = [s \in SERVERS |-> "IDLE"]
    /\ sVarsDefault = [s \in SERVERS |-> NoVars]
    /\ sVarsSession = [s \in SERVERS |-> NoVars]
    /\ sState = [s \in SERVERS |-> "Free"]
    /\ srvSticky = [s \in SERVERS |-> FALSE]
    /\ latch = [s \in SERVERS |-> FALSE]
    /\ badReplay = FALSE
    /\ gLeftSaved = FALSE
    /\ savedTwice = FALSE
    /\ deployErr = FALSE
    /\ bad = {}
    /\ lastAct = "init"

\* Client connects.  The auth backend's 'r' packets with SOURCE_STARTUP fill
\* yb_vars_startup (backend.c startup 'r' handling / yb_auth_passthrough.c).
\* Reference: startup options become value and reset value, source CLIENT.
Connect(c) ==
    /\ cState[c] = "Off"
    /\ conns[c] < MAXCONNS
    /\ \E st \in STARTUPS :
         /\ ref' = [ref EXCEPT ![c] = [g \in GUCS |->
                IF st[g] = NoVal THEN FreshRec
                ELSE [FreshRec EXCEPT !.val = st[g], !.src = CLIENT,
                                      !.rv = st[g], !.rs = CLIENT]]]
         /\ refLast' = [refLast EXCEPT ![c] = [g \in GUCS |->
                IF st[g] = NoVal \/ ~IsReport(g) THEN "d" ELSE st[g]]]
         /\ varsStartup' = [varsStartup EXCEPT ![c] = st]
         /\ Act(<<"Connect", c, st>>)
    /\ cState' = [cState EXCEPT ![c] = "On"]
    /\ conns' = [conns EXCEPT ![c] = @ + 1]
    /\ refT' = [refT EXCEPT ![c] = "IDLE"]
    /\ varsSession' = [varsSession EXCEPT ![c] = NoVars]
    /\ cInTxn' = [cInTxn EXCEPT ![c] = FALSE]
    /\ roleIssued' = [roleIssued EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<stmts, attached, svars, hvars>>

SrvRec(s) == [m |-> gucs[s], t |-> sT[s], vd |-> sVarsDefault[s],
              vs |-> sVarsSession[s]]
FreshSrv == [m |-> FreshMap, t |-> "IDLE", vd |-> NoVars, vs |-> NoVars]

\* frontend.c attach (od_frontend_attach -> router): an Idle server, or spawn
\* when none is Idle.  A transactional backend is spawned without client
\* options (backend.c startup argv), so its lists start empty.
CanAttach(s) ==
    \/ sState[s] = "Idle"
    \/ sState[s] = "Free" /\ \A s2 \in SERVERS : sState[s2] # "Idle"

(***************************************************************************)
(* One client statement, atomic: attach+deploy if detached, execute on the *)
(* server, consume 'r' packets with server_only = 0, RFQ, maybe detach      *)
(* (frontend.c: OD_DETACH when !is_transaction and not sticky).            *)
(***************************************************************************)
Statement(c, stm) ==
    /\ cState[c] = "On"
    /\ stmts[c] < MAXSTMTS
    /\ \E s \in SERVERS :
        /\ IF attached[c] = NoServer THEN CanAttach(s) ELSE s = attached[c]
        /\ LET isNew == attached[c] = NoServer
               base == IF sState[s] = "Free" THEN FreshSrv ELSE SrvRec(s)
               baseSticky == IF sState[s] = "Free" THEN SUPER ELSE srvSticky[s]
               baseLatch == IF sState[s] = "Free" THEN FALSE ELSE latch[s]
               dep == Deploy(varsStartup[c], varsSession[c], base)
               srv1 == IF isNew THEN dep.srv ELSE base
               \* backend.c:od_backend_ready: an idle RFQ is 'i' when the
               \* backend latched stickiness (pg_yb_utils.c superuser rule)
               sticky1 == IF isNew /\ dep.msgs THEN baseLatch \/ SUPER ELSE baseSticky
               e == Exec(srv1.m, srv1.t, stm)
               \* guc.c:set_config_option_ext: SET ROLE / SESSION AUTHORIZATION
               \* latches yb_ysql_conn_mgr_sticky_guc
               latch2 == baseLatch \/ (stm.k = "SETROLE" /\ ~e.err)
               srv2 == RunMsg(srv1, e.m, e.t)
               sticky2 == IF e.t = "IDLE" THEN latch2 \/ SUPER ELSE sticky1
               re == Exec(ref[c], refT[c], stm)
               detach == e.t = "IDLE" /\ ~sticky2
           IN /\ gucs' = [gucs EXCEPT ![s] = srv2.m]
              /\ sT' = [sT EXCEPT ![s] = srv2.t]
              /\ sVarsDefault' = [sVarsDefault EXCEPT ![s] = srv2.vd]
              /\ sVarsSession' = [sVarsSession EXCEPT ![s] = srv2.vs]
              /\ latch' = [latch EXCEPT ![s] = latch2]
              /\ srvSticky' = [srvSticky EXCEPT ![s] = sticky2]
              /\ sState' = [sState EXCEPT ![s] = IF detach THEN "Idle" ELSE "Active"]
              /\ attached' = [attached EXCEPT ![c] = IF detach THEN NoServer ELSE s]
              /\ varsSession' = [varsSession EXCEPT ![c] = ApplySession(@, e.m)]
              /\ cInTxn' = [cInTxn EXCEPT ![c] = e.t # "IDLE"]
              /\ ref' = [ref EXCEPT ![c] = Strip(re.m)]
              /\ refT' = [refT EXCEPT ![c] = re.t]
              /\ bad' = bad \cup StmtChecks(srv2.m, re.m, Fwd(e.m), RefFwd(re.m, refLast[c]))
              /\ refLast' = [refLast EXCEPT ![c] = [g \in GUCS |->
                                IF IsReport(g) THEN re.m[g].val ELSE "d"]]
              /\ roleIssued' = [roleIssued EXCEPT ![c] = @ \/ (stm.k = "SETROLE" /\ ~re.err)]
              /\ badReplay' = (badReplay \/ (isNew /\ dep.badReplay))
              /\ gLeftSaved' = (gLeftSaved \/ (isNew /\ dep.leftSaved))
              /\ savedTwice' = (savedTwice \/ (isNew /\ dep.savedTwice))
              /\ deployErr' = (deployErr \/ (isNew /\ dep.err))
              /\ Act(<<"Stmt", c, stm, s, IF isNew THEN IF dep.msgs THEN "attach+deploy" ELSE "attach" ELSE "", IF detach THEN "detach" ELSE "">>)
    /\ stmts' = [stmts EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<cState, conns, varsStartup>>

(***************************************************************************)
(* Client disconnect, frontend.c OD_OK/OD_ECLIENT_READ -> reset.c:od_reset *)
(* (ROLLBACK if is_transaction; nothing GUC-related in optimized mode) ->   *)
(* router.c:od_router_detach (close if sticky, else Idle).                  *)
(***************************************************************************)
Disconnect(c) ==
    /\ cState[c] = "On"
    /\ cState' = [cState EXCEPT ![c] = "Off"]
    /\ attached' = [attached EXCEPT ![c] = NoServer]
    /\ varsStartup' = [varsStartup EXCEPT ![c] = NoVars]
    /\ varsSession' = [varsSession EXCEPT ![c] = NoVars]
    /\ cInTxn' = [cInTxn EXCEPT ![c] = FALSE]
    /\ ref' = [ref EXCEPT ![c] = FreshMap]
    /\ refT' = [refT EXCEPT ![c] = "IDLE"]
    /\ refLast' = [refLast EXCEPT ![c] = [g \in GUCS |-> "d"]]
    /\ roleIssued' = [roleIssued EXCEPT ![c] = FALSE]
    /\ IF attached[c] = NoServer
       THEN UNCHANGED svars
       ELSE LET s == attached[c]
                inTx == sT[s] # "IDLE"
                e == Exec(gucs[s], sT[s], S("ROLLBACK", "-", "-"))
                srv == IF inTx THEN RunMsg(SrvRec(s), e.m, e.t) ELSE SrvRec(s)
                stk == IF inTx THEN latch[s] \/ SUPER ELSE srvSticky[s]
            IN IF stk
               THEN /\ gucs' = [gucs EXCEPT ![s] = FreshMap]
                    /\ sT' = [sT EXCEPT ![s] = "IDLE"]
                    /\ sVarsDefault' = [sVarsDefault EXCEPT ![s] = NoVars]
                    /\ sVarsSession' = [sVarsSession EXCEPT ![s] = NoVars]
                    /\ sState' = [sState EXCEPT ![s] = "Free"]
                    /\ srvSticky' = [srvSticky EXCEPT ![s] = FALSE]
                    /\ latch' = [latch EXCEPT ![s] = FALSE]
               ELSE /\ gucs' = [gucs EXCEPT ![s] = srv.m]
                    /\ sT' = [sT EXCEPT ![s] = srv.t]
                    /\ sVarsDefault' = [sVarsDefault EXCEPT ![s] = srv.vd]
                    /\ sVarsSession' = [sVarsSession EXCEPT ![s] = srv.vs]
                    /\ sState' = [sState EXCEPT ![s] = "Idle"]
                    /\ srvSticky' = [srvSticky EXCEPT ![s] = stk]
                    /\ UNCHANGED latch
    /\ Act(<<"Disconnect", c>>)
    /\ UNCHANGED <<conns, stmts, hvars>>

\* Terminal stutter so bounded runs do not report deadlock.
Done == UNCHANGED vars

Next ==
    \/ \E c \in CLIENTS : Connect(c)
    \/ \E c \in CLIENTS, stm \in STMTS : Statement(c, stm)
    \/ \E c \in CLIENTS : Disconnect(c)
    \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

On(c) == cState[c] = "On"
Att(c) == attached[c] # NoServer
StickyC(c) == Att(c) /\ srvSticky[attached[c]]
SessionOf(M) == [g \in GUCS |-> IF M[g].src = SESSION /\ SetCtx(g) THEN M[g].val ELSE NoVal]

TypeOK ==
    /\ cState \in [CLIENTS -> {"Off", "On"}]
    /\ conns \in [CLIENTS -> 0..MAXCONNS]
    /\ stmts \in [CLIENTS -> 0..MAXSTMTS]
    /\ roleIssued \in [CLIENTS -> BOOLEAN]
    /\ ref \in [CLIENTS -> [GUCS -> Recs]]
    /\ refT \in [CLIENTS -> {"IDLE", "INTX", "FAILED"}]
    /\ refLast \in [CLIENTS -> [GUCS -> Vals]]
    /\ varsStartup \in [CLIENTS -> [GUCS -> Vals \cup {NoVal}]]
    /\ varsSession \in [CLIENTS -> [GUCS -> Vals \cup {NoVal}]]
    /\ attached \in [CLIENTS -> SERVERS \cup {NoServer}]
    /\ cInTxn \in [CLIENTS -> BOOLEAN]
    /\ gucs \in [SERVERS -> [GUCS -> Recs]]
    /\ sT \in [SERVERS -> {"IDLE", "INTX", "FAILED"}]
    /\ sVarsDefault \in [SERVERS -> [GUCS -> Vals \cup {NoVal}]]
    /\ sVarsSession \in [SERVERS -> [GUCS -> Vals \cup {NoVal}]]
    /\ sState \in [SERVERS -> {"Free", "Idle", "Active"}]
    /\ srvSticky \in [SERVERS -> BOOLEAN]
    /\ latch \in [SERVERS -> BOOLEAN]
    /\ \A c \in CLIENTS : Att(c) => sState[attached[c]] = "Active"
    /\ \A c1, c2 \in CLIENTS : c1 # c2 /\ Att(c1) => attached[c1] # attached[c2]

\* The reference and the attached backend agree on transaction state.
TxnAgree ==
    \A c \in CLIENTS : On(c) =>
        IF Att(c) THEN sT[attached[c]] = refT[c] ELSE refT[c] = "IDLE"

\* Pooled servers are never in a transaction (deploy.c -2 path unreachable).
IdleNotInTxn == \A s \in SERVERS : sState[s] = "Idle" => sT[s] = "IDLE"

\* P1*: checked on attached clients and, latched in bad, at the end of every
\* statement (a client outside a transaction detaches in the same step).
P1_ValueEquality ==
    /\ "P1" \notin bad
    /\ \A c \in CLIENTS : On(c) /\ Att(c) =>
        \A g \in GUCS : gucs[attached[c]][g].val = ref[c][g].val

P1b_DefaultEquality ==
    /\ "P1b" \notin bad
    /\ \A c \in CLIENTS : On(c) /\ Att(c) =>
        \A g \in GUCS : /\ gucs[attached[c]][g].rv = ref[c][g].rv
                        /\ gucs[attached[c]][g].rs = ref[c][g].rs

\* Not in the plan: source equality (decides what RESET ALL touches and
\* what pg_settings.source shows).
P1c_SourceEquality ==
    /\ "P1c" \notin bad
    /\ \A c \in CLIENTS : On(c) /\ Att(c) =>
        \A g \in GUCS : gucs[attached[c]][g].src = ref[c][g].src

\* P2: the 'S' set CM forwards for the statement just completed equals what
\* the reference backend sends.  Checked at each statement and latched.
P2_ReportEquality == "P2" \notin bad

\* Not in the plan: weaker P2 tolerating duplicate ParameterStatus: every
\* reference report is forwarded, and every forwarded value is the client's.
P2b_ReportSound == "P2b" \notin bad

P3_ReplayOnlySettable == ~badReplay
NoDeployError == ~deployErr

P4_ResetDefault == P1b_DefaultEquality

P7_RoleSticky ==
    \A c \in CLIENTS : On(c) /\ roleIssued[c] /\ ~cInTxn[c] => StickyC(c)

P7_StickyLatch ==
    [][\A c \in CLIENTS :
          (On(c) /\ StickyC(c) /\ cState'[c] = "On") => attached'[c] = attached[c]]_vars

P8_SessionListTracksRef ==
    \A c \in CLIENTS : On(c) /\ ~cInTxn[c] => varsSession[c] = SessionOf(ref[c])

\* Not in the plan: the part of P8 that replay depends on.  Every SESSION
\* var of the reference is listed with its value, and every listed value is
\* the client's current value (an extra entry is allowed).
P8b_SessionListSound ==
    \A c \in CLIENTS : On(c) /\ ~cInTxn[c] =>
        \A g \in GUCS :
            /\ SessionOf(ref[c])[g] # NoVal => varsSession[c][g] = ref[c][g].val
            /\ varsSession[c][g] # NoVal => varsSession[c][g] = ref[c][g].val

P9a_SavedDefaultNoneMeansBoot ==
    \A s \in SERVERS : sState[s] = "Idle" =>
        \A g \in GUCS : ~gucs[s][g].sd =>
            gucs[s][g].rv = "d" /\ gucs[s][g].rs = DFLT

P9b_ResetClearsSaved == ~gLeftSaved

\* yb_conn_mgr_save_default_value WARNING "This is a bug"
NoDoubleSave == ~savedTwice

ListInclusion ==
    \A c \in CLIENTS : On(c) /\ Att(c) /\ ~cInTxn[c] =>
        \A g \in GUCS : sVarsSession[attached[c]][g] # NoVal =>
                        varsSession[c][g] # NoVal

Sym == Permutations(CLIENTS) \cup Permutations(SERVERS)
=============================================================================
