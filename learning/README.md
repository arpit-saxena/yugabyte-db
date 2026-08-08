# Learning YugabyteDB, one flow at a time

A small kit for building real, verifiable understanding of how this system works —
one flow at a time, with a model as a pair, and with the code as the only authority.

## How to use it

1. Pick a flow from **[`flows.md`](flows.md)** (14 to choose from, in 5 tracks).
2. Copy the prompt from **[`flow-learning-prompt.md`](flow-learning-prompt.md)** into a
   fresh agent session, pasting that flow's `FLOW:` and `SCOPE:` blocks into the two slots.
3. Work through it. The agent walks one hop per message and stops to ask you what happens
   next — answer before reading on. That pause is the whole method.
4. Notes accumulate in `notes/<flow-slug>.md` as you go.

Budget 1–3 hours per flow. Two flows a week beats one marathon.

## Why it's shaped this way

Three design choices, each deliberate:

**A flow, not a component.** Components are learned by reading; flows are learned by
following. A flow forces you across the seams — PG C code into pggate C++, tserver into
DocDB into RocksDB — and the seams are where the actual design decisions live.

**Black boxes with stated contracts.** Nothing here is independent, so the prompt makes
the agent name what it's *not* opening and state each one's contract up front. If you
can't state the contract of the thing a hop calls into, you don't understand the hop.

**Every claim carries a `file:line`.** Models are confidently wrong about this codebase in
particular: it's large, it's forked from two upstreams (PostgreSQL and RocksDB), and it
changes fast. The single highest-value rule in the prompt is *read the file before
asserting*. As a concrete illustration: `ybc_fdw.c` — widely believed to be the YSQL scan
entry point — does not exist in this tree.

## One-time setup

You'll get most of the value from reading, but the "Prove it" steps need a working build.

```bash
# ~20 min the first time, much faster after
./yb_build.sh release daemons initdb --sj --skip-pg-parquet --no-odyssey --no-ybc \
  2>&1 | tee /tmp/yb-build.log
```

See `src/AGENTS.md` for prerequisites and pitfalls (build `initdb` in its own command;
`reinitdb` after system-catalog changes; `--clean` after third-party changes).

**Build a `debug` build too** if you want breakpoints — and note that the tserver's
`/intentsdb` page only exists in non-`NDEBUG` builds (and also needs
`--enable_intentsdb_page=true`, which defaults to false).

To bring up a local cluster: `docs/content/stable/quick-start/linux.md`.

Running one test:

```bash
./yb_build.sh release --cxx-test compaction-test --gtest_filter 'CompactionTest.*'
./yb_build.sh release --java-test 'org.yb.pgsql.TestPgRegressThirdPartyExtensionsPgCron'
```

## The observability toolkit

Everything below exists in this tree. These are the levers the "Prove it" steps draw on.

### From psql

| Lever | What it shows |
|---|---|
| `EXPLAIN (ANALYZE, DIST, DEBUG) <q>` | Storage read/write request counts and per-node storage metrics. `DIST` needs `ANALYZE`; `DEBUG` needs `DIST` (`src/postgres/src/backend/commands/explain.c:1112`, `:949`) |
| `SET yb_debug_log_docdb_requests = true` | The exact DocDB ops a statement issues |
| `SET yb_enable_docdb_tracing = true` | Turns on the `Trace` machinery for this session |
| `SET yb_debug_log_internal_restarts = true` | Read restarts and transaction retries |
| `SET yb_debug_log_catcache_events = true` | Catalog cache misses and invalidations |
| `SELECT * FROM yb_active_session_history` | Wait-event sampling across PG and DocDB |

### gflags

| Flag | Why |
|---|---|
| `--collect_end_to_end_traces=true` + `--rpc_slow_query_threshold_ms=0` | **The single best lever for any RPC-crossing flow.** Dumps a full cross-server trace for every RPC into the log. `src/yb/rpc/inbound_call.cc:48`, `:58` |
| `--rpc_dump_all_traces=true` | All RPC traces at INFO. `src/yb/rpc/inbound_call.cc:45` |
| `--TEST_file_to_dump_docdb_writes=<path>` | Every DocDB write, decoded. `src/yb/tablet/tablet.cc:242` |
| `--log_ysql_catalog_versions=true` | The catalog-version heartbeat loop |
| `--rocksdb_disable_compactions=true` | Isolate what compaction was doing |
| `--enable_intentsdb_page=true` | Required (plus a debug build) for `/intentsdb` |

### Web UI — tserver `:9000`, master `:7000`

**tserver:** `/tablets` · `/tablet?id=` · `/transactions?id=` · `/rocksdb?id=` (dumps
*both* the regular and intents RocksDB) · `/waitqueue?id=` · `/preparer?id=` ·
`/sharedlockmanager?id=` · `/api/v1/meta-cache` · `/intentsdb` (debug builds only)

**master:** `/tables` · `/tablet-servers` · `/tasks` · `/cluster-config` ·
`/load-distribution` · `/dump-entities`

**either:** `/varz` · `/metrics` · `/rpcz` · `/threadz` · `/mem-trackers` · `/pprof/*`

### Offline

- `sst_dump --file=<dir> --command=scan --output_format=decoded_regulardb` — or
  `decoded_intentsdb` against `<tablet-dir>.intents` (intents live in a **sibling**
  directory, not a child). `src/yb/tools/sst_dump.cc`
- `ldb` — `src/yb/tools/ldb.cc`, built with the same options tablets use
- `docdb::DocDBDebugDumpToStr` — `src/yb/docdb/docdb_debug.cc:130`, what the docdb unit
  tests print
- `yb-admin`, `yb-ts-cli`

## Codebase orientation

| Path | What |
|---|---|
| `src/postgres/` | The PostgreSQL fork. YB additions are `yb`-prefixed files and functions |
| `src/yb/yql/pggate/` | The C↔C++ bridge from a PG backend to the tserver |
| `src/yb/tserver/` | Tablet server: RPC services, tablet manager, PG client session |
| `src/yb/tablet/` | Tablet: write path, MVCC, transaction participant, bootstrap |
| `src/yb/consensus/` | Raft and the WAL |
| `src/yb/docdb/` | The document layer over RocksDB: intents, iteration, compaction hooks |
| `src/yb/dockv/` | Key and value encoding |
| `src/yb/rocksdb/` | The RocksDB fork |
| `src/yb/master/` | Catalog manager, load balancer, tablet splitting |
| `src/yb/client/` | YBClient, meta-cache, batcher |

## Worth reading before your first flow

Short, and they pay for themselves:

- `docs/content/stable/architecture/key-concepts.md`
- `docs/content/stable/architecture/yb-master.md` and `yb-tserver.md`
- `docs/content/stable/architecture/docdb/lsm-sst.md`
- `src/yb/consensus/consensus.txt` — YB's Raft variant, in prose
- `src/yb/yql/pggate/README` — buffering rules and `in_txn_limit_ht`
- `src/yb/master/README` — the copy-on-write catalog protocol
- `architecture/design/README.md` — index of design docs by feature

In-tree design docs live in `architecture/design/`. Two areas have **no** design doc, and
the code comments are the spec instead: DocDB encoding (`src/yb/dockv/packed_row.h:35`,
`src/yb/dockv/value_type.h`) and Raft (`src/yb/consensus/consensus.txt`).

## A caveat about line numbers

Every `file:line` in `flows.md` was verified against the tree at the commit this was
written on. **They will drift.** Treat them as bookmarks — the function names are stable
far longer than the line numbers. The prompt's rule #1 (read the file before asserting)
is what keeps a session correct even after the numbers rot.

If you find a stale reference, `git log -L` on the function is usually the fastest way to
see what moved and why.
