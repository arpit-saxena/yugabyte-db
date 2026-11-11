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

Upstream master is 1151 commits past the import point; 59 are merged.

## Merged but inert in YB builds

- Rule backend startup options (1cc42b10433): parsed, not sent by YB's od_backend_startup.
- Replica catchup check before authentication (d9d18b2c207): YB authenticates before
  routing.
- pool discard_query (9a4554fcfec), auth_query password cache and default internal rule
  (d0638f309b5, b4033690208): the YB config template sets none of them.
- Address-based rule matching (f60df91a540): template rules parse as "all".
- mdb_iamproxy authentication (0e44d132901): its only caller is compiled out.

## Open points

- c06dec86262 removes the YB_SUPPORT_FOUND guard that b4eb72f3e0f put around the 32-bit
  od_hash_t / od_murmur_hash, because upstream's auth_query cache uses them.
- Upstream issues left as upstream has them: od_rules_merge empties a NULL acache after a
  failed od_hashmap_create (reload crash, OOM only); every cancel request builds and frees
  a 420-bucket hashmap under the route lock; od_hashmap_lock_key's trylock loop is
  inverted (auth_query only); the SASL password is logged at debug level in
  od_auth_backend_sasl_continue (not reachable with the YB template).
- Behaviour changes inherited from upstream: queued clients are served newest first
  (de02985941c); an error-level "client is waiting in routing queue" log (ed6c55436bc); an
  external client whose socket is reset before routing now fails routing
  (f60df91a540); an external client naming the control connection db/user falls through
  to the default rule (b4033690208).
