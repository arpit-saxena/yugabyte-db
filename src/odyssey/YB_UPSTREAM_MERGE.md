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
  upstream commit is merged. A fix that upstream made only after 1.5.2 carries YB markers
  (6888a4c3b7b).
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
| 7 | 806856e2706 (#742) | 1 | affb6473255 | covered by step 8 |
| 8 | ac95c5f3bdb (tag 1.4.0) | 44 | e60d2980b14 | = master at fa841284ac8 |
| 9 | 6a25e2a43c9 (#856) | 48 | df5dad279bb | = master at 6888a4c3b7b |
| 10 | 43da5f9c6e9 (#860) | 1 | 8c214961ae6 | = master at 9dc9b245acb |

Target: the latest upstream release, v1.5.2 (2cca6bf26c1, on REL_1_5_2), 877 commits past
the import point; 266 are merged (upstream release 1.4.0 plus 49). Steps 1-3 were ~20 upstream commits each. From step 5 on
there is one step per upstream release tag and per upstream mass move or rewrite, each of
those isolated in its own step.

The local release build does not compile LDAP_FOUND code (a fresh configure, as in CI,
does); from step 8 on those files are syntax-checked with LDAP_FOUND defined.

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
- Step 8, kept as YB had it: the 512 KB machine thread stack (upstream 87999f1a1b uses
  3 * PTHREAD_STACK_MIN), YB's logger formatter, od_extension_free only inside
  OD_SYSTEM_SHUTDOWN_CLEANUP (fa841284ac8). Upstream's install and packaging rules are
  inside if(NOT YB_BUILD_ODYSSEY). Inert: storage watchdog rewrite, show fds, LDAP
  changes, group validation.
- sequential_routing (c827bb4774b) and rule groups (8ba1e233a12): the YB config template
  sets neither. The group checker is under #ifndef YB_SUPPORT_FOUND (b8004595a12).
- Step 9, under #ifndef YB_SUPPORT_FOUND: virtual SET processing and upstream's Query
  case (da7c3e4c7d7, b69c18c616d; DISCARD emptying server->prep_stmts would leave YB's
  LRU list dangling), od_frontend_should_detach_on_ready_for_query (e0b7d291258; YB keeps
  its switch), upstream's od_relay_step read part (302632f1418; one guard now),
  od_logger_shutdown at shutdown (24f49e516fe), the pgoptions target_session_attrs hint
  (854130ba9a2; 1a0872b38c9), the empty-host rejection and the ':' split of an
  unbracketed host in the new endpoint parser (46de66a5b20; 49a2569d282, d3e0d88c135),
  the idle logger log line (973d3b7fc60). test_kiwi_pgoptions.c is left out of
  odyssey_test.
- Step 9, inert: virtual_processing, maintain_params (read only in
  od_frontend_attach_and_deploy, which YB does not call), online_restart_drop_options,
  availability_zone, listen and rule target_session_attrs, endpoints_status_poll_interval,
  pause/resume (console only), sync_point_deploy_msg, bind_failed, machinarium mutex and
  wait_group, worker and logger shutdown messages.

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
- Step 8, inherited from upstream: od_relay_write sleeps 1 ms on EAGAIN instead of
  retrying at once (a5a7f59c352), in both directions; every backend connect times out
  after 30 s (40d95ad269a; no timeout before; unix socket connects never wait); a reload
  frees the previous storage templates; client coroutines are named.
- Step 8 correction: the LDAP_DBG redefinition in debug builds is new with the step 8
  merge, not older as its message suggests in one place; fixed by a98fd159321.
- Step 7 dropped three YB markers: the wait list and machine_channel_get_size() are
  upstream code now (806856e2706; YB 1e92a532afa had cherry-picked it).
- Behaviour changes inherited from upstream: queued clients are served newest first
  (de02985941c); an error-level "client is waiting in routing queue" log (ed6c55436bc); an
  external client whose socket is reset before routing now fails routing
  (f60df91a540); an external client naming the control connection db/user falls through
  to the default rule (b4033690208).
- Step 9, inherited from upstream: od_backend_connect is upstream's rewrite (endpoint
  round robin, target_session_attrs; with YB's single endpoint and "any" it connects as
  before, plus two debug lines); an idle client coroutine wakes every 10 s instead of
  60 s; worker and logger threads wake every 10 s (24f49e516fe); logger format, debug and
  stdout settings apply after the log file is opened (2606bcaa950); one maintain_params
  line per rule in the config dump; kiwi_enquote's backslash fix is upstream's now
  (29045dbf00f).
- Step 9, kept as before the merge: a killed client is stopped right after its wake-up
  (2e59ffbf91a; upstream checks before the next wait); YB sets POSTGRESQL_FOUND itself
  because it never calls find_package(PostgreSQL), and keeps -DUSE_SCRAM for the assert
  in auth.c.
- Step 9, upstream bug present in 1.5.2: mm_channel_read and mm_channel_read_back drop a
  message delivered while the wait times out; with the 10 s worker read a new client
  could be lost. 6888a4c3b7b takes the channel.c part of upstream e7cf47e7a69.
- Step 9 corrections to the merge message: its "follow-up 4" (auth.c USE_SCRAM ->
  POSTGRESQL_FOUND, deleting the #scram block) was not made; target_session_attrs is
  still a keyword but is rejected inside a storage block; the abort() list also has
  the target_session_attrs switch in backend.c (never reached with "any") and
  od_frontend_should_detach_on_ready_for_query in frontend.c (upstream branch only).
  test/odyssey/test_endpoints_parse.c does not match YB's parser guards (odyssey_test is
  built, not run). od_parse_endpoints("") returns one uninitialised endpoint (upstream;
  the template never writes an empty host string).
- The endpoint parser guards will conflict at upstream c1367cbf146 (unix socket as
  endpoint), which replaces the parser.
- Step 10 (#pragma once + C23 sweep): Odyssey, kiwi, machinarium and the PostgreSQL
  be-secure-openssl.c inside machinarium were compiled as gnu17 before the merge (the
  top-level CMAKE_C_STANDARD 17 came last; upstream's -std=gnu11 was overridden) and still
  are: 5ae420f6a18 sets 17 again after upstream's 23. The merge commit alone would compile
  them as gnu23 and does not build. Upstream returns to C11 in f361135802d.
- Step 10: mm_context_swap comes from context_swap_<arch>.S instead of a file-scope
  asm() in context.c; same instructions. YugabyteDB's add_library() wrapper is a function
  defined under the top-level policies, so the target has CMP0119 NEW and CMake passes
  "-x c" for upstream's LANGUAGE C sources; 9dc9b245acb adds -xassembler-with-cpp. Not
  built here: aarch64, gcc, debug, asan, tsan.
- Step 10: YB-only headers keep their include guards (circular_queue.h, parse_queue.h,
  yb_auth_passthrough.h, yb_oid_entry.h); yb_pg_tls_link_support.h has none by design.
- Step 10 corrections to the merge message: endpoints_reader.c lost its guard and got no
  #pragma once (161 files have one, all headers); "expected build issues: none" missed
  the "-x c" failure; f361135802d's subject is "do not use postgresql library to impl
  scram" and its CMAKE_C_STANDARD line abuts YB's lines, so expect a small conflict
  there; sources/ldap_endpoint.c does not exist (only the header).
