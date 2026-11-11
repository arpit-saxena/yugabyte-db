# Upstream merge status (branch upstream-odyssey-merge only)

Delete this file before the branch lands.

`src/odyssey` was squash-imported from yandex/odyssey 76ea5f7169b. This branch merges
upstream forward in small steps:

    git merge --no-ff -Xsubtree=src/odyssey <upstream commit>

- A merge commit holds conflict resolutions only; its message lists every resolution, the
  upstream changes not applied to YB code, cleanly merged code worth a look, and the
  lost-line audit. It may not compile.
- The commits after a merge, up to the next merge, are its build fixes, behaviour fixes
  and review follow-ups, one logical change each. Fixes that upstream itself makes later
  are taken as upstream wrote them and without a YB marker, so they disappear when that
  upstream commit is merged.
- YB code replacing upstream code that upstream changed: upstream's code stays under
  `#ifndef YB_SUPPORT_FOUND`, YB's under `#else`.
- New upstream features the YB path does not use are merged but not wired in.

Reviewing a step: the merge message first, then
`git diff <merge>^1 <merge> -- src/odyssey` against `git diff <previous upstream> <upstream>`.

## Steps

Tests: full org.yb.ysqlconnmgr suite, release build. "= master" means the same failing
classes and methods as master f00b9eee7a9 (TestConnMgrSslSettings,
TestHangUpOnRouteSignals#testQueuedClientServedAfterLastIdleExpires,
TestMisc#testStickySequence and #testStickySuperuserConns,
TestSessionParameters#testSeedMakesConnectionSticky).

| Step | Upstream commit | Upstream commits | Merge | Tests |
|---|---|---|---|---|
| 0 | 76ea5f7169b (ancestry, tree unchanged) | 0 | 58c8d9da9c5 | n/a |
| 1 | de02985941c (#506) | 19 | 3526951c9e5 | = master (run with step 2) |
| 2 | b2485694dab (#547) | 21 | 84cae757991 | = master at 8ed7adfe933 |
| 3 | dc2122ac90a (#578) | 19 | f9d55d894dc | = master at 1c0c66423f7 |
| 4 | ddbbb698b7f (#587) | 6 | a094c0e2c62 | = master at d69940aae41 |
| 5 | b0e2b9f811a (#623) | 24 | 0e77bad4a84 | = master at 7c6f385c034 |
| 6 | 87fa7d152d2 (#741) | 83 | 5a6c4cd2387 | = master at f2439459514; 6 classes rerun at 0891322f7d6 |

Target: the latest upstream release, v1.5.2 (2cca6bf26c1, on REL_1_5_2), 877 commits past
the import point; 172 are merged. Steps 1-3 were ~20 upstream commits each. From step 5 on
there is one step per upstream release tag and per upstream mass move or rewrite, each of
those isolated in its own step.

Only release builds are tested. Asserts and OD_DEVEL_LVL debug prints that upstream adds
are reviewed by reading, and kept out of YB builds where a YB flow can reach them.

## Merged but inert in YB builds

- Rule backend startup options (1cc42b10433): parsed, not sent by YB's od_backend_startup.
- Replica catchup check before authentication (d9d18b2c207): YB authenticates before
  routing.
- pool discard_query (9a4554fcfec), auth_query password cache and default internal rule
  (d0638f309b5, b4033690208): the YB config template sets none of them.
- Address-based rule matching (f60df91a540): template rules parse as "all".
- mdb_iamproxy authentication (0e44d132901): its only caller is compiled out.
- Upstream's transaction-pool prepared statement rework (ed8ca61c0a1, ff5b6563108,
  ddbbb698b7f): YB has its own design; upstream's Parse/Describe/Bind code and helpers sit
  under #ifndef YB_SUPPORT_FOUND, as do its extra reset sync point (9d0de5d4e5e), its
  od_relay_step read condition and its sync asserts.
- Step 6, not applied to YB: the removal of the client notify io (4fde8dbad4c). Without
  the eventfd a killed idle client is noticed only at its next packet, which YB's
  cleanup of idle clients on inactive routes (b76eff1c781) depends on. YB's code stays
  under #ifdef YB_SUPPORT_FOUND in client.h, frontend.c and system.c.
- Step 6, under #ifndef YB_SUPPORT_FOUND: the pending-aware relay read path
  (535a27e73ba; 18fa11f1663), od_relay_full_packet_required (32c1450186; YB always
  assembles full packets), the new iov assert in od_frontend_attach (f4a1986aa69), the
  group checker call on reload (849dd44198b), the client_max_routing default of
  workers * 64 (f081cf98c74; YB keeps workers * 16, 0891322f7d6).
- sequential_routing (c827bb4774b) and rule groups (8ba1e233a12): the YB config template
  sets neither. The group checker is under #ifndef YB_SUPPORT_FOUND (b8004595a12).

## Open points

- c06dec86262 removes the YB_SUPPORT_FOUND guard that b4eb72f3e0f put around the 32-bit
  od_hash_t / od_murmur_hash, because upstream's auth_query cache uses them.
- Upstream issues left as upstream has them: od_rules_merge empties a NULL acache after a
  failed od_hashmap_create (reload crash, OOM only); every cancel request builds and frees
  a 420-bucket hashmap under the route lock; od_hashmap_lock_key's trylock loop is
  inverted (auth_query only); the SASL password is logged at debug level in
  od_auth_backend_sasl_continue (not reachable with the YB template).
- Step 4: od_backend_ready_wait now waits until the server is synchronized and returns an
  error after an ErrorResponse unless told to ignore it (2848982b302). od_reset therefore
  fails, and the server is closed, when ROLLBACK or a discard query gets an ErrorResponse;
  before, the server was dropped only if still in a transaction.
- Corrections to the step 4 merge message: ysql_conn_mgr_use_auth_backend defaults to
  false; the %p debug prints are an error, not a warning, in clang debug builds
  (a36b1bb0489).
- YB bugs found while reviewing step 4, present before the merge: sync_reply overtakes
  sync_request when an extended protocol COPY FROM STDIN fails right after
  CopyInResponse; update_oid_entry_from_backend returns a control connection to the pool
  without reading ReadyForQuery when its query fails; a client that sends CopyDone or
  CopyFail in the extended protocol and disconnects without Sync leaves a pooled server
  inside the implicit transaction; od_backend_ready_wait leaks the ParameterStatus
  message.
- Step 5: od_rules_merge now re-links the live rule list in config order on every reload
  and asserts that every rule got a slot (c827bb4774b). This holds because the rules of
  the YB template have distinct keys, not for the reason given in the step 5 merge
  message: the config reader's "route is redefined" check never fires (upstream bug), and
  two rules with the same key would crash the first reload. yb_warmup walks the rule list
  without the router lock.
- Correction to 7c6f385c034's message: od_hba_reload runs on every reload; it is a no-op
  without an hba_file.
- Step 6, inherited from upstream: od_reset fails when data is still queued for the
  server (c910d21c845; no caller reaches it that way today, and the check has no NULL
  guard on the relay iov); the replica catchup lookup runs on every relay wake-up
  (c9f3fa48c14; finds nothing in YB); error counters are fixed arrays that abort above
  key 100 (0a704db190; the largest YB key is 20); SIGPIPE is ignored instead of drained;
  one "log reopened" line. Async logging (0d9fdf6aabf) is not new: YB has had it since
  7185452143e.
- Step 6 corrections: the merge message says the iov assert in od_frontend_attach is
  live in YB; f4a1986aa69 guards it. The count parameter of od_backend_ready_wait was
  removed by a7049a26d92.
- Upstream issues seen in step 6 and left: mm_socket_read_pending always returns 0;
  mm_io_read_pending dereferences on_read without a NULL check; ldap.c's retry loop uses
  serv after freeing it; the logger queue drops lines silently when full.
- Behaviour changes inherited from upstream: queued clients are served newest first
  (de02985941c); an error-level "client is waiting in routing queue" log (ed6c55436bc); an
  external client whose socket is reset before routing now fails routing
  (f60df91a540); an external client naming the control connection db/user falls through
  to the default rule (b4033690208).
