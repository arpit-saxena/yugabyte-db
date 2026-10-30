---------------------------- MODULE GucVersioning ----------------------------
(***************************************************************************)
(* Module 2 of SPEC_PLAN.md: ALTER ... SET / SIGHUP versioning of pooled   *)
(* backends in YSQL Connection Manager (logical client version, LCV).      *)
(*                                                                         *)
(* A backend's GUC state is abstracted to the pair <<sCat, sSig>>: the     *)
(* pg_yb_logical_client_version catalog value and the postmaster's SIGHUP  *)
(* counter that were in force when it was spawned; its reported LCV is the *)
(* sum (postinit.c:1594-1606). Session overlays are Module 1's concern.    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    NODES,          \* tservers, each with its own CM, pool and postmaster
    CLIENTS,        \* logical clients
    SPN,            \* transactional backend slots per node (pool size)
    STRATEGY,       \* "fluctuating" | "gradual" | "connection_static"
    PROPAGATION,    \* "on_read" (today) | "pushed" (LCV-propagation-UFD.md)
    TTL,            \* ysql_conn_mgr_alter_guc_stale_backend_ttl_ms: "zero" | "timed" | "never"
    AUTH,           \* "passthrough" (default) | "backend" (ysql_conn_mgr_use_auth_backend)
    STALE_READS,    \* TRUE: a node's catalog reads may lag catalogLcv until its heartbeat
    MAXSTMTS,       \* statements per session
    MAXSESS,        \* sessions (connects) per client
    MAXALTER,
    MAXSIGHUP

NoServer == <<"none", 0>>
SERVERS  == NODES \X (1..SPN)          \* s[1] is the node of server s
Live     == {"idle", "active"}

VARIABLES
    catalogLcv,  \* pg_yb_logical_client_version.current_version, db_oid 0 row
    alters, sighups,
    sighupLcv,   \* [NODES -> Nat] postmaster's yb_conn_mgr_sighup_logical_client_version
    ctlSig,      \* [NODES -> Nat] the auth-passthrough control backend's copy of it
    tsLcv,       \* [NODES -> Nat] catalog LCV as last learnt by the node's tserver (heartbeat)
    routerMax,   \* [NODES -> Nat] router->yb_max_logical_client_version
    sState,      \* [SERVERS -> {"free","idle","active"}]
    lcvS,        \* server->yb_logical_client_version
    sCat, sSig,  \* the defaults the backend actually holds (its spawn-time versions)
    sExp,        \* "none" | "marked" (yb_marked_for_close) | "timed" (expiry set) | "due" (now >= expiry)
    cState,      \* "off" | "idle" | "attached"
    cNode, cSrv,
    lcvC,        \* client->yb_logical_client_version
    authLcv,     \* LCV assigned at auth (for P12)
    catAtAuth, sigAtAuth, \* true catalog/SIGHUP versions when auth completed (FR1)
    authCat, authSig,     \* components of the auth-assigned LCV
    obsLcv, obsCat, obsSig, \* max observed in this session, -1 = none yet
    stmts, sess

vars == <<catalogLcv, alters, sighups, sighupLcv, ctlSig, tsLcv, routerMax,
          sState, lcvS, sCat, sSig, sExp, cState, cNode, cSrv, lcvC, authLcv,
          catAtAuth, sigAtAuth, authCat, authSig, obsLcv, obsCat, obsSig,
          stmts, sess>>
serverVars == <<sState, lcvS, sCat, sSig, sExp>>
clientVars == <<cState, cNode, cSrv, lcvC, authLcv, catAtAuth, sigAtAuth,
                authCat, authSig, obsLcv, obsCat, obsSig, stmts, sess>>
globalVars == <<catalogLcv, alters, sighups, sighupLcv, ctlSig, tsLcv>>

TypeOK ==
    /\ catalogLcv \in 0..MAXALTER
    /\ sighupLcv \in [NODES -> 0..MAXSIGHUP]
    /\ ctlSig \in [NODES -> 0..MAXSIGHUP]
    /\ tsLcv \in [NODES -> 0..MAXALTER]
    /\ routerMax \in [NODES -> Nat]
    /\ sState \in [SERVERS -> {"free", "idle", "active"}]
    /\ sExp \in [SERVERS -> {"none", "marked", "timed", "due"}]
    /\ cState \in [CLIENTS -> {"off", "idle", "attached"}]
    /\ cSrv \in [CLIENTS -> SERVERS \cup {NoServer}]

Init ==
    /\ catalogLcv = 0 /\ alters = 0 /\ sighups = 0
    /\ sighupLcv = [n \in NODES |-> 0]
    /\ ctlSig = [n \in NODES |-> 0]
    /\ tsLcv = [n \in NODES |-> 0]
    /\ routerMax = [n \in NODES |-> 0]
    /\ sState = [s \in SERVERS |-> "free"]
    /\ lcvS = [s \in SERVERS |-> 0]
    /\ sCat = [s \in SERVERS |-> 0]
    /\ sSig = [s \in SERVERS |-> 0]
    /\ sExp = [s \in SERVERS |-> "none"]
    /\ cState = [c \in CLIENTS |-> "off"]
    /\ cNode = [c \in CLIENTS |-> CHOOSE n \in NODES : TRUE]
    /\ cSrv = [c \in CLIENTS |-> NoServer]
    /\ lcvC = [c \in CLIENTS |-> 0]
    /\ authLcv = [c \in CLIENTS |-> 0]
    /\ catAtAuth = [c \in CLIENTS |-> 0]
    /\ sigAtAuth = [c \in CLIENTS |-> 0]
    /\ authCat = [c \in CLIENTS |-> 0]
    /\ authSig = [c \in CLIENTS |-> 0]
    /\ obsLcv = [c \in CLIENTS |-> -1]
    /\ obsCat = [c \in CLIENTS |-> -1]
    /\ obsSig = [c \in CLIENTS |-> -1]
    /\ stmts = [c \in CLIENTS |-> 0]
    /\ sess = [c \in CLIENTS |-> 0]

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

\* The catalog LCV a backend on node n reads at spawn/auth
\* (yb_logical_client_version.c YbGetMasterLogicalClientVersion). With
\* STALE_READS the prefetched read may be served from the node's cache.
ReadCat(n) == IF STALE_READS THEN tsLcv[n] ELSE catalogLcv

\* router.c:395 yb_od_router_expire_stale_lcv_servers +
\* router.c:338 yb_od_router_expire_stale_lcv_server_cb.
\* Applied to the post-step pool (live, lcv, expBase) of node n.
NewMax(n, v) == IF v > routerMax[n] THEN [routerMax EXCEPT ![n] = v] ELSE routerMax
NewExp(n, v, live, lcv, expBase) ==
    IF v > routerMax[n] /\ TTL # "never"
    THEN [s \in SERVERS |->
            IF s[1] = n /\ live[s] \in Live /\ lcv[s] < v
            THEN (IF TTL = "zero" THEN "marked"
                  ELSE IF expBase[s] = "none" THEN "timed" ELSE expBase[s])
            ELSE expBase[s]]
    ELSE expBase

OnNode(n, st) == {s \in SERVERS : s[1] = n /\ sState[s] = st}

\* server_pool.h:179 yb_idle_server_version_matches (gradual / static) and
\* router.c:1169 od_pg_server_pool_next (fluctuating: any idle, marked or not).
IdleMatch(c) ==
    LET n == cNode[c] IN
    CASE STRATEGY = "fluctuating" -> OnNode(n, "idle")
      [] STRATEGY = "gradual" ->
            {s \in OnNode(n, "idle") : sExp[s] # "marked" /\ lcvS[s] >= lcvC[c]}
      [] STRATEGY = "connection_static" ->
            {s \in OnNode(n, "idle") : sExp[s] # "marked" /\ lcvS[s] = lcvC[c]}

\* router.c:1122-1157: connection_static with an outdated client may not spawn
OutdatedStatic(c) ==
    STRATEGY = "connection_static" /\ routerMax[cNode[c]] > lcvC[c]
\* server_pool.h:259 yb_od_server_pool_active_has_matching_version
ActiveMatch(c) ==
    \E s \in OnNode(cNode[c], "active") : sExp[s] # "marked" /\ lcvS[s] = lcvC[c]

ObsUpdate(c, lv, ct, sg) ==
    /\ obsLcv' = [obsLcv EXCEPT ![c] = IF lv > @ THEN lv ELSE @]
    /\ obsCat' = [obsCat EXCEPT ![c] = IF ct > @ THEN ct ELSE @]
    /\ obsSig' = [obsSig EXCEPT ![c] = IF sg > @ THEN sg ELSE @]

(***************************************************************************)
(* Client actions                                                          *)
(***************************************************************************)

\* Auth passthrough: postinit.c:1971-1984 (control backend reads the catalog
\* afresh per auth, adds its own SIGHUP counter) -> yb_auth_passthrough.c:729-749
\* (client LCV := reported value, expire_stale). Auth backend: postinit.c:1594-1606
\* + 1715-1716 (fresh fork, postmaster counter) -> backend.c:1053-1070 and
\* frontend.c:3531-3535.
Connect(c, n) ==
    /\ cState[c] = "off" /\ sess[c] < MAXSESS
    /\ LET cat == ReadCat(n)
           sig == IF AUTH = "passthrough" THEN ctlSig[n] ELSE sighupLcv[n]
           v   == cat + sig
       IN /\ routerMax' = NewMax(n, v)
          /\ sExp' = NewExp(n, v, sState, lcvS, sExp)
          /\ lcvC' = [lcvC EXCEPT ![c] = v]
          /\ authLcv' = [authLcv EXCEPT ![c] = v]
          /\ authCat' = [authCat EXCEPT ![c] = cat]
          /\ authSig' = [authSig EXCEPT ![c] = sig]
    /\ catAtAuth' = [catAtAuth EXCEPT ![c] = catalogLcv]
    /\ sigAtAuth' = [sigAtAuth EXCEPT ![c] = sighupLcv[n]]
    /\ cState' = [cState EXCEPT ![c] = "idle"]
    /\ cNode' = [cNode EXCEPT ![c] = n]
    /\ obsLcv' = [obsLcv EXCEPT ![c] = -1]
    /\ obsCat' = [obsCat EXCEPT ![c] = -1]
    /\ obsSig' = [obsSig EXCEPT ![c] = -1]
    /\ stmts' = [stmts EXCEPT ![c] = 0]
    /\ sess' = [sess EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<globalVars, sState, lcvS, sCat, sSig, cSrv>>

\* router.c:1092-1110 (match) -> router.c:1323 attach -> frontend.c:380-388
\* (client LCV := server LCV unconditionally). The statement runs here; its
\* observation is the server's spawn-time defaults.
AttachIdle(c) ==
    /\ cState[c] = "idle" /\ stmts[c] < MAXSTMTS
    /\ \E s \in IdleMatch(c) :
        /\ sState' = [sState EXCEPT ![s] = "active"]
        /\ cSrv' = [cSrv EXCEPT ![c] = s]
        /\ cState' = [cState EXCEPT ![c] = "attached"]
        /\ lcvC' = [lcvC EXCEPT ![c] = lcvS[s]]
        /\ ObsUpdate(c, lcvS[s], sCat[s], sSig[s])
    /\ UNCHANGED <<globalVars, routerMax, lcvS, sCat, sSig, sExp,
                   cNode, authLcv, catAtAuth, sigAtAuth, authCat, authSig,
                   stmts, sess>>

\* Spawn: router.c:1185-1335 (allowed when no idle match, a slot is free and,
\* for connection_static, the client is not outdated) -> postinit.c:1594-1606
\* (LCV = catalog + postmaster SIGHUP counter) -> backend.c:1053-1070
\* (server LCV, expire_stale) -> frontend.c:423-450 (connection_static rejects
\* a client older than the new backend; otherwise client LCV := server LCV).
AttachSpawn(c) ==
    /\ cState[c] = "idle" /\ stmts[c] < MAXSTMTS
    /\ IdleMatch(c) = {}
    /\ ~OutdatedStatic(c)
    /\ LET n == cNode[c] IN
       \E s \in OnNode(n, "free") :
         LET cat == ReadCat(n)
             sig == sighupLcv[n]
             v   == cat + sig
             reject == STRATEGY = "connection_static" /\ lcvC[c] < v
             live1 == [sState EXCEPT ![s] = "active"]
             lcv1  == [lcvS EXCEPT ![s] = v]
             exp1  == [sExp EXCEPT ![s] = "none"]
         IN /\ routerMax' = NewMax(n, v)
            /\ IF reject
               THEN \* frontend.c:432-439 -> OD_ESERVER_CONNECT -> od_router_close
                    /\ sState' = sState
                    /\ lcvS' = lcvS /\ sCat' = sCat /\ sSig' = sSig
                    /\ sExp' = NewExp(n, v, sState, lcvS, sExp)
                    /\ cState' = [cState EXCEPT ![c] = "off"]
                    /\ UNCHANGED <<cSrv, lcvC, obsLcv, obsCat, obsSig>>
               ELSE /\ sState' = live1
                    /\ lcvS' = lcv1
                    /\ sCat' = [sCat EXCEPT ![s] = cat]
                    /\ sSig' = [sSig EXCEPT ![s] = sig]
                    /\ sExp' = NewExp(n, v, live1, lcv1, exp1)
                    /\ cSrv' = [cSrv EXCEPT ![c] = s]
                    /\ cState' = [cState EXCEPT ![c] = "attached"]
                    /\ lcvC' = [lcvC EXCEPT ![c] = v]
                    /\ ObsUpdate(c, v, cat, sig)
    /\ UNCHANGED <<globalVars, cNode, authLcv, catAtAuth, sigAtAuth, authCat,
                   authSig, stmts, sess>>

\* router.c:1122-1157: connection_static, outdated client, no idle match and
\* no non-marked active backend with its LCV -> OD_ROUTER_ERROR (disconnect).
StaticRouteError(c) ==
    /\ cState[c] = "idle" /\ stmts[c] < MAXSTMTS
    /\ IdleMatch(c) = {}
    /\ OutdatedStatic(c)
    /\ ~ActiveMatch(c)
    /\ cState' = [cState EXCEPT ![c] = "off"]
    /\ UNCHANGED <<globalVars, routerMax, serverVars, cNode, cSrv, lcvC, authLcv,
                   catAtAuth, sigAtAuth, authCat, authSig, obsLcv, obsCat,
                   obsSig, stmts, sess>>

\* ALTER ROLE/DATABASE ... SET on the attached backend:
\* pg_yb_utils.c:3590-3591 (catalog row ++ at commit) and :3722-3726, which sends
\* YbSendMasterLogicalClientVersionToFrontend() = the catalog value only, WITHOUT
\* the node's SIGHUP component; backend.c:1670-1681 feeds it to expire_stale.
\* The executing backend's own LCV and the client's LCV do not change.
Alter(c) ==
    /\ cState[c] = "attached" /\ alters < MAXALTER
    /\ LET n == cNode[c]
           v == catalogLcv + 1
       IN /\ catalogLcv' = v
          /\ routerMax' = NewMax(n, v)
          /\ sExp' = NewExp(n, v, sState, lcvS, sExp)
    /\ alters' = alters + 1
    /\ UNCHANGED <<sighups, sighupLcv, ctlSig, tsLcv, sState, lcvS, sCat, sSig,
                   clientVars>>

\* frontend.c:1116 -> router.c:1494-1546 od_router_detach: closed if past its
\* expiry time (marked_for_close is NOT checked here), else back to idle.
Detach(c) ==
    /\ cState[c] = "attached"
    /\ LET s == cSrv[c] IN
       /\ sState' = [sState EXCEPT ![s] = IF sExp[s] = "due" THEN "free" ELSE "idle"]
       /\ sExp' = [sExp EXCEPT ![s] = IF sExp[s] = "due" THEN "none" ELSE @]
    /\ cSrv' = [cSrv EXCEPT ![c] = NoServer]
    /\ cState' = [cState EXCEPT ![c] = "idle"]
    /\ stmts' = [stmts EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<globalVars, routerMax, lcvS, sCat, sSig, cNode, lcvC, authLcv,
                   catAtAuth, sigAtAuth, authCat, authSig, obsLcv, obsCat,
                   obsSig, sess>>

\* Client closes its connection while detached.
Disconnect(c) ==
    /\ cState[c] = "idle"
    /\ cState' = [cState EXCEPT ![c] = "off"]
    /\ UNCHANGED <<globalVars, routerMax, serverVars, cNode, cSrv, lcvC, authLcv,
                   catAtAuth, sigAtAuth, authCat, authSig, obsLcv, obsCat,
                   obsSig, stmts, sess>>

(***************************************************************************)
(* Node / server actions                                                   *)
(***************************************************************************)

\* postmaster.c:3171-3181: SIGHUP that changed a PGC_BACKEND GUC
\* (guc.c:11829 sets yb_conn_mgr_sighup_had_backend_guc_change) bumps the
\* postmaster's counter; later forks inherit it. Nothing is reported to CM.
Sighup(n) ==
    /\ sighups < MAXSIGHUP
    /\ sighupLcv' = [sighupLcv EXCEPT ![n] = @ + 1]
    /\ sighups' = sighups + 1
    /\ UNCHANGED <<catalogLcv, alters, ctlSig, tsLcv, routerMax, serverVars, clientVars>>

\* postgres.c:7144-7188: the auth-passthrough control backend handles the
\* signal from SignalChildren asynchronously (ConfigReloadPending) and bumps
\* its own copy of the counter.
ControlReload(n) ==
    /\ AUTH = "passthrough"
    /\ ctlSig[n] < sighupLcv[n]
    /\ ctlSig' = [ctlSig EXCEPT ![n] = sighupLcv[n]]
    /\ UNCHANGED <<catalogLcv, alters, sighups, sighupLcv, tsLcv, routerMax,
                   serverVars, clientVars>>

\* Tserver heartbeat: the node learns the current catalog LCV (catalog-version
\* cache refresh; with "pushed" also the UFD's TSHeartbeatResponsePB field).
Heartbeat(n) ==
    /\ (STALE_READS \/ PROPAGATION = "pushed")
    /\ tsLcv[n] < catalogLcv
    /\ tsLcv' = [tsLcv EXCEPT ![n] = catalogLcv]
    /\ UNCHANGED <<catalogLcv, alters, sighups, sighupLcv, ctlSig, routerMax,
                   serverVars, clientVars>>

\* LCV-propagation-UFD.md 5.1: CM cron feeds
\* shmem.logical_client_version + shmem.sighup_logical_client_version
\* to the existing expiry path.
Cron(n) ==
    /\ PROPAGATION = "pushed"
    /\ LET v == tsLcv[n] + sighupLcv[n] IN
       /\ v > routerMax[n]
       /\ routerMax' = NewMax(n, v)
       /\ sExp' = NewExp(n, v, sState, lcvS, sExp)
    /\ UNCHANGED <<globalVars, sState, lcvS, sCat, sSig, clientVars>>

\* Time passes the randomized expiry (router.c:372, now + rand % ttl).
TimePass(s) ==
    /\ sExp[s] = "timed"
    /\ sExp' = [sExp EXCEPT ![s] = "due"]
    /\ UNCHANGED <<globalVars, routerMax, sState, lcvS, sCat, sSig, clientVars>>

\* cron.c:292 -> router.c:238-262 od_router_expire_server_tick_cb: an idle
\* backend that is marked or past expiry is closed. (Only when the pool's
\* idle ttl is non-zero, router.c:314-317; assumed here.)
CronClose(s) ==
    /\ sState[s] = "idle" /\ sExp[s] \in {"marked", "due"}
    /\ sState' = [sState EXCEPT ![s] = "free"]
    /\ sExp' = [sExp EXCEPT ![s] = "none"]
    /\ UNCHANGED <<globalVars, routerMax, lcvS, sCat, sSig, clientVars>>

Next ==
    \/ \E c \in CLIENTS :
        \/ \E n \in NODES : Connect(c, n)
        \/ AttachIdle(c) \/ AttachSpawn(c) \/ StaticRouteError(c)
        \/ Alter(c) \/ Detach(c) \/ Disconnect(c)
    \/ \E n \in NODES : Sighup(n) \/ ControlReload(n) \/ Heartbeat(n) \/ Cron(n)
    \/ \E s \in SERVERS : TimePass(s) \/ CronClose(s)

Fairness ==
    /\ \A c \in CLIENTS : WF_vars(Detach(c))
    /\ \A n \in NODES : WF_vars(ControlReload(n)) /\ WF_vars(Heartbeat(n)) /\ WF_vars(Cron(n))
    /\ \A s \in SERVERS : WF_vars(TimePass(s)) /\ WF_vars(CronClose(s))

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

LiveSrv == {s \in SERVERS : sState[s] \in Live}

\* P5: equal LCV on one node => same defaults (no ALTER/SIGHUP between spawns).
P5 == \A s, t \in LiveSrv :
        (s[1] = t[1] /\ lcvS[s] = lcvS[t]) => (sCat[s] = sCat[t] /\ sSig[s] = sSig[t])
\* P5 cross-node; expected to fail (SIGHUP component is node-local).
P5x == \A s, t \in LiveSrv :
        lcvS[s] = lcvS[t] => (sCat[s] = sCat[t] /\ sSig[s] = sSig[t])

\* A statement of client c starts on server s in this step.
ExecOn(c, s) == cSrv[c] = NoServer /\ cSrv'[c] = s

\* P10 (plan): the LCV a session runs on never goes below what it already saw.
P10 == [][\A c \in CLIENTS, s \in SERVERS :
            ExecOn(c, s) => lcvS'[s] >= obsLcv[c]]_vars
\* P10d: same, on the defaults actually held (catalog and SIGHUP components).
P10d == [][\A c \in CLIENTS, s \in SERVERS :
            ExecOn(c, s) => (sCat'[s] >= obsCat[c] /\ sSig'[s] >= obsSig[c])]_vars

\* P12: connection_static never runs a client on an LCV other than its auth LCV.
P12 == [][\A c \in CLIENTS, s \in SERVERS :
            ExecOn(c, s) => lcvS'[s] = authLcv[c]]_vars

\* FR1a: a client authenticating after an ALTER completed gets an LCV whose
\* catalog component includes that ALTER.
AuthStep(c) == sess'[c] = sess[c] + 1
FR1a == [][\A c \in CLIENTS : AuthStep(c) => authCat'[c] = catalogLcv]_vars
\* FR1s: same for a SIGHUP completed on the client's node.
FR1s == [][\A c \in CLIENTS : AuthStep(c) => authSig'[c] = sighupLcv[cNode'[c]]]_vars
\* FR1b: every statement of a session runs with defaults at least as new as
\* the ALTERs / SIGHUPs completed before the session authenticated.
FR1b == [][\A c \in CLIENTS, s \in SERVERS :
            ExecOn(c, s) => (sCat'[s] >= catAtAuth[c] /\ sSig'[s] >= sigAtAuth[c])]_vars
\* FR1c: the ALTER half of FR1b alone.
FR1c == [][\A c \in CLIENTS, s \in SERVERS :
            ExecOn(c, s) => sCat'[s] >= catAtAuth[c]]_vars

\* P13: PG semantics for a PGC_BACKEND change from a SIGHUP: it never reaches
\* an existing session, so the SIGHUP component a session runs on is fixed.
P13 == [][\A c \in CLIENTS, s \in SERVERS :
            (ExecOn(c, s) /\ obsSig[c] # -1) => sSig'[s] = obsSig[c]]_vars

\* P11 (plan): eventually every live backend has lcvServer = routerMax[n].
P11 == \A n \in NODES :
        <>[](\A s \in LiveSrv : s[1] = n => lcvS[s] = routerMax[n])
\* P11b: eventually every live backend holds the current defaults.
P11b == \A n \in NODES :
        <>[](\A s \in LiveSrv : s[1] = n =>
                (sCat[s] = catalogLcv /\ sSig[s] = sighupLcv[n]))
\* P11c: the ALTER half of P11b alone (a SIGHUP on an idle node is never
\* reported under on_read, which fails P11b on its own).
P11c == \A n \in NODES :
        <>[](\A s \in LiveSrv : s[1] = n => sCat[s] = catalogLcv)

=============================================================================
