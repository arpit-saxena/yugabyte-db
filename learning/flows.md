# Flows you can pick from

Fourteen flows, grouped into five tracks. Each is self-contained: you can understand it
while treating its neighbours as black boxes. Pick one, copy its **`FLOW:`** and
**`SCOPE:`** blocks into [`flow-learning-prompt.md`](flow-learning-prompt.md), and go.

Tracks suggest an order; they don't enforce one. If you want a reading order from cold:
**1 → 2 → 3 → 6 → 5 → 4 → 7**, then anything.

> All `file:line` references below were verified against the tree at the commit this file
> was written on. **They will drift.** They're bookmarks, not contracts — the prompt's
> rule #1 (read the file before asserting) is what keeps the session honest.

**Legend** — each flow lists: why it's worth your time · the hop skeleton · what to treat
as a black box · the cheapest way to see it live · what to read alongside.

---

# Track A — Query and write path

## 1. Life of a single-row `SELECT`

**Why:** it's the spine everything else hangs off, and it crosses the three worlds
(PostgreSQL C, the pggate C++ bridge, the tserver) in one trip. If you only do one flow,
do this one.

```text
FLOW: Trace a single-row `SELECT * FROM t WHERE k = 1;` from the PostgreSQL backend
through the YB planner and executor, across pggate, over the PgClientService.Perform RPC,
into the tablet's read path — and back with rows.

SCOPE:
In scope, roughly these hops:
  - per-query entry and the YB retry wrapper (src/postgres/src/backend/tcop/postgres.c)
  - YB cost model and the local-vs-pushdown split of quals
  - the YbSeqScan / yb_lsm access-method layer building a pggate statement
  - pggate: PgDmlRead::Exec, PgDocOp request building, PgSession buffering, the flush
  - the RPC and its server-side handler
  - the tablet-side read entry, stopping at the DocDB boundary
Black boxes (state their contracts in Step 0, do not open them):
  - PostgreSQL parser/rewriter internals
  - Raft consensus
  - MVCC / read-time selection (that's flow 5)
  - DocDB iteration and RocksDB (flows 6-9)
```

**Skeleton (entry points):**
- `src/postgres/src/backend/tcop/postgres.c:6167` `yb_exec_query_wrapper` — the retry loop
  around every statement; this is the first thing that differs from vanilla PG
- `src/postgres/src/backend/optimizer/path/costsize.c:7228` `yb_cost_seqscan` (index side:
  `:8067` `yb_cost_index`); dispatched from
  `src/postgres/src/backend/optimizer/util/pathnode.c:1460`
- `src/postgres/src/backend/optimizer/util/ybplan.c:318` `yb_extract_pushdown_clauses` —
  splits quals into local vs remote; the predicate is
  `src/postgres/src/backend/executor/ybExpr.c:645` `YbCanPushdownExpr`
- `src/postgres/src/backend/executor/nodeYbSeqscan.c:58` `YbSeqNext` — the per-row driver
- `src/postgres/src/backend/access/yb_access/yb_scan.c:3882` `YbBeginScan` — builds the
  pggate statement, binds keys, applies pushdown, stamps the catalog version
- `src/yb/yql/pggate/pg_dml_read.cc:504` `PgDmlRead::Exec`
- `src/yb/yql/pggate/pg_doc_op.cc:352` `PgDocOp::SendRequestImpl` — where an RPC is
  actually issued (note the parallelism/fan-out and size-limit math)
- `src/yb/yql/pggate/pg_session.cc:402` `PgSession::RunHelper::Apply` — the buffer-or-send
  decision; `:501` `Flush`; `:837` `PgSession::Perform`
- `src/yb/tserver/pg_client.proto:77` — `rpc Perform`
- `src/yb/tserver/pg_client_service.cc:3364` `PgClientServiceImpl::Perform`
- `src/yb/tserver/pg_client_session.cc:3253` `PgClientSession::Impl::DoPerform`
- `src/yb/tserver/tablet_service.cc:2771` `TabletServiceImpl::Read` →
  `src/yb/tserver/read_query.cc:241` `ReadQuery::DoPerform`
- `src/yb/tablet/tablet.cc:2170` `Tablet::HandlePgsqlReadRequest` — stop here

**Watch out:** `ybc_fdw.c` and `ybc_index.c` no longer exist. The scan is a first-class
plan node (`nodeYbSeqscan.c`) and the index AM is `access/yb_access/yb_lsm.c`.

**Prove it:** `EXPLAIN (ANALYZE, DIST, DEBUG) SELECT ...` then
`SET yb_debug_log_docdb_requests = true;` and compare what you predicted against the log.

**Read alongside:** `src/yb/yql/pggate/README` (the buffering rules and `in_txn_limit_ht`
are explained there better than anywhere else),
`docs/content/stable/architecture/query-layer/_index.md`.

---

## 2. Life of a single-row `INSERT` — the DocDB write path

**Why:** the prepare / replicate / apply split is *the* structural idea in the tserver.
Every write-ish feature in the codebase is shaped by it.

```text
FLOW: Trace a single-row `INSERT INTO t VALUES (1, 'a');` from the tserver's Write RPC
through WriteQuery's prepare phase, into the DocDB write batch, and on to the apply that
lands it in RocksDB.

SCOPE:
In scope:
  - TabletServiceImpl::PerformWrite and how it validates/routes
  - WriteQuery: PrepareExecute -> DoExecute -> lock acquisition -> conflict-resolution
    callback -> DoCompleteExecute -> AssembleDocWriteBatch
  - the handoff to Raft (submit only — do not follow it in)
  - the apply side: WriteOperation::DoReplicated -> Tablet::ApplyKeyValueRowOperations
    -> WriteToRocksDB, including the transactional / non-transactional fork
Black boxes:
  - pggate and everything above the RPC (flow 1)
  - Raft replication (flow 3)
  - conflict resolution internals (flow 4)
  - key/value encoding details (flow 6)
  - what RocksDB does with the batch (flows 7-9)
```

**Skeleton:**
- `src/yb/tserver/tablet_service.cc:2616` `TabletServiceImpl::PerformWrite` (`:2726` is the
  thin `Write` wrapper)
- `src/yb/tablet/tablet.cc:2428` `Tablet::AcquireLocksAndPerformDocOperations`
- `src/yb/tablet/write_query.cc:728` `WriteQuery::Execute` — **start reading here**
- `src/yb/tablet/write_query.cc:481` `PrepareExecute` → `:612` `PgsqlPrepareExecute`
- `src/yb/tablet/write_query.cc:834` `DoExecute` → `src/yb/docdb/docdb.cc:253`
  `PrepareDocWriteOperation` → `:116` `DetermineKeysToLock`
- `src/yb/tablet/write_query.cc:1067` `DoCompleteExecute` → `src/yb/docdb/docdb.cc:308`
  `AssembleDocWriteBatch`
- `src/yb/docdb/pgsql_operation.cc:1501` `PgsqlWriteOperation::ApplyInsert`
- `src/yb/tablet/write_query.cc:269` `DoStartSynchronization` — the three terminal cases
  (schema mismatch / read restart / error) before submitting to Raft
- `src/yb/tablet/operations/write_operation.cc:120` `WriteOperation::DoReplicated`
- `src/yb/tablet/tablet.cc:1938` `ApplyKeyValueRowOperations` — transactional →
  `:1878` `WriteTransactionalBatch` (intents), else direct to regular
- `src/yb/tablet/tablet.cc:1987` `Tablet::WriteToRocksDB`

**Prove it:** `--TEST_file_to_dump_docdb_writes=/tmp/writes.txt`
(`src/yb/tablet/tablet.cc:242`) on a single-node cluster, then insert one row and read the
file. Or breakpoint `WriteQuery::Execute` in a debug build.

---

# Track B — Replication and consistency

## 3. Raft replication of one write

**Why:** every durability and availability guarantee in the product is a statement about
this code. Also where the YB-specific extensions (leader leases, pre-elections) live.

```text
FLOW: Follow one already-prepared write operation through Raft: enqueue on the leader,
WAL append, fan-out to followers, majority acknowledgement, commit index advance, apply.
Then follow a leader election.

SCOPE:
In scope:
  - RaftConsensus::DoReplicateBatch and the queue append (incl. where the hybrid time is
    stamped and where leases are checked)
  - the WAL: LogCache -> Log::AsyncAppendReplicates -> Appender -> DoAppend -> Sync
  - PeerManager/Peer fan-out and RequestForPeer
  - ResponseFromPeer and the majority-replicated watermark computation
  - ReplicaState: commit index advance -> ApplyPendingOperationsUnlocked
  - the follower side: RaftConsensus::Update
  - leader election: DoStartElection -> LeaderElection::Run -> BecomeLeaderUnlocked
Black boxes:
  - what the operation actually is (flow 2)
  - what apply does to RocksDB (flow 2)
  - remote bootstrap
```

**Skeleton:**
- `src/yb/consensus/raft_consensus.cc:1239` `DoReplicateBatch` → `:1345`
  `DoAppendNewRoundsToQueueUnlocked` (OpId assignment, `NotifyAddedToLeader`,
  `:1274` `CheckLeasesUnlocked`)
- `src/yb/consensus/consensus_queue.cc:430` `PeerMessageQueue::AppendOperations`
- `src/yb/consensus/log.cc:933` `Log::AsyncAppendReplicates` → `:904` `AsyncAppend` →
  `:511` `Appender::ProcessBatch` → `:954` `DoAppend`
- `src/yb/consensus/consensus_queue.cc:473` `RequestForPeer`
- `src/yb/consensus/consensus_queue.cc:1483` `ResponseFromPeer` — the watermark math
- `src/yb/consensus/raft_consensus.cc:1423` `UpdateMajorityReplicated` →
  `src/yb/consensus/replica_state.cc:937` `ApplyPendingOperationsUnlocked`
- Follower: `src/yb/consensus/raft_consensus.cc:1576` `Update` → `:1939` `UpdateReplica`
- Election: `src/yb/consensus/raft_consensus.cc:603` `DoStartElection` →
  `src/yb/consensus/leader_election.cc:191` `LeaderElection::Run` →
  `src/yb/consensus/raft_consensus.cc:1114` `BecomeLeaderUnlocked`

**Prove it:** `raft_consensus-itest.cc` / `src/yb/integration-tests/` election tests; or run
a 3-node local cluster with `--collect_end_to_end_traces=true
--rpc_slow_query_threshold_ms=0` and read one write's trace across all three logs.

**Read alongside:** `src/yb/consensus/consensus.txt` (concepts — read this first),
`src/yb/consensus/README` (WAL format and durability),
`architecture/design/docdb-raft-enhancements.md` (leader leases, pre-elections),
`docs/content/stable/architecture/docdb-replication/raft.md`.

---

## 4. Distributed transaction lifecycle

**Why:** the coordinator/participant protocol is the part people get wrong when reasoning
about YB. This flow is about the *protocol*; flow 7 is about the *storage*.

```text
FLOW: Follow a multi-tablet transaction from BEGIN through COMMIT: status tablet
selection, the transaction record, participants registering, conflict resolution,
the commit record, and the APPLYING fan-out that makes the writes visible.

SCOPE:
In scope:
  - client side: YBTransaction picking a status tablet, Prepare, Commit
  - coordinator: TransactionState::HandleCommit, ProcessReplicated, StartApply
  - participant: ProcessReplicated -> ProcessApply, SetLocalCommitData, NotifyApplied
  - conflict resolution: policy selection, fail-on-conflict vs wait-on-conflict
Black boxes:
  - the physical layout of intents and the intents->regular rewrite (flow 7 — you only
    need its contract here: "apply makes this txn's provisional writes visible at
    commit_ht")
  - Raft (flow 3)
  - MVCC read-time selection (flow 5)
```

**Skeleton:**
- `src/yb/client/transaction.cc:437` `Impl::Prepare`, `:603` `Commit`, `:1493` `DoCommit`,
  `:2038` `SendHeartbeat`
- `src/yb/tablet/transaction_coordinator.cc:818` `TransactionState::HandleCommit`,
  `:346` `ProcessReplicated`, `:1026` `StartApply`
- `src/yb/tablet/transaction_participant.cc:875` `Impl::ProcessReplicated`,
  `:962` `ProcessApply` — read `:1008` (`SetLocalCommitData`) carefully; that line is what
  makes a transaction visible *before* its intents have physically moved
- `src/yb/docdb/conflict_resolution.cc:1546` `ResolveTransactionConflicts`,
  `:1600` `ResolveOperationConflicts`
- `src/yb/tablet/write_query.cc:763` `GetConflictManagementPolicy`
- `src/yb/docdb/wait_queue.cc`, `src/yb/docdb/deadlock_detector.cc` (wait-on-conflict)

**Prove it:** `/transactions?id=<tablet>` on the tserver web UI while a transaction is
open; `src/yb/client/ql-transaction-test.cc` (`ResolveIntentsWriteReadUpdateRead:787`,
`ResendApplying:509`).

**Read alongside:** `docs/content/stable/architecture/transactions/transactional-io-path.md`,
`architecture/design/wait-on-conflict-functional-spec.md`,
`architecture/design/savepoints.md`.

---

## 5. MVCC, hybrid time, and read restarts

**Why:** the most distinctively-YugabyteDB flow in the codebase, and the one that explains
a whole class of user-visible behaviour ("why did I get a read restart error?").

```text
FLOW: How a read time is chosen and enforced. Follow HybridTime generation, safe-time
computation, the read/local_limit/global_limit triple, how the iterator detects that it
saw a record it cannot safely ignore, and how a read restart propagates back to the client
(or is retried transparently).

SCOPE:
In scope:
  - HybridClock::NowWithError and NowRange
  - MvccManager: AddLeaderPending, Replicated, DoGetSafeTime and the lease clamp
  - ReadHybridTime and FormRestartReadHybridTime
  - detection in IntentAwareIterator (max_seen_ht) and propagation up through
    DocRowwiseIterator -> ReadQuery::Complete
  - the two restart loops: server-side (read_query.cc) and PG-side (postgres.c)
Black boxes:
  - Raft (flow 3), except that leader leases bound safe time (state that as a contract)
  - intent visibility rules (flow 7)
```

**Skeleton:**
- `src/yb/server/hybrid_clock.cc:168` `NowWithError`, `:158` `NowRange`, `:265` `Update`
- `src/yb/tablet/mvcc.cc:312` `AddLeaderPending`, `:267` `Replicated`,
  `:556` `SafeTime` → `:573` `DoGetSafeTime` (the rule is in the body; read the lease clamp)
- `src/yb/common/read_hybrid_time.h:31` `ReadHybridTime`, `:117`
  `FormRestartReadHybridTime`
- `src/yb/docdb/intent_aware_iterator.cc:1476` `UpdateMaxSeenHt`, `:1391`
  `GetReadRestartData`
- `src/yb/tserver/read_query.cc:220` `PickReadTime`, `:474` `DoPickReadTime`,
  `:536` `Complete` (the local retry loop)
- `src/yb/tablet/write_query.cc:1067` `DoCompleteExecute` (the serializable in-place
  restart loop) and `:269` `DoStartSynchronization` (the bounce-to-client case)
- `src/postgres/src/backend/tcop/postgres.c:5891` `yb_restart_current_stmt`,
  `:5925` `yb_restart_transaction`, `:5289` `yb_is_retry_possible`

**Prove it:** `SET yb_debug_log_internal_restarts = true;` and run a read concurrent with
writes; `src/yb/yql/pgwrapper/pg_debug_read_restarts-test.cc`.

**Read alongside:** `docs/content/stable/architecture/transactions/read-restart-error.md`,
`isolation-levels.md`, `single-row-transactions.md`.

---

# Track C — Storage engine

## 6. SQL row → DocDB key/value encoding

**Why:** once you can read a raw DocDB key by eye, half the rest of the storage layer
becomes self-explanatory. This is the highest leverage-per-hour flow in Track C.

```text
FLOW: Take one row of one table and follow every byte: how the primary key becomes a
DocKey, how a DocKey plus subkeys plus a hybrid time becomes a SubDocKey, how the
non-key columns become either a packed row or one KV per column, and how that reaches
the RocksDB write batch.

SCOPE:
In scope:
  - DocKey encoding: cotable/colocation prefix, hash components, range components,
    sort order and the ascending/descending byte trick
  - the value-type byte table and why specific codes were chosen
  - SubDocKey = DocKey + subkeys + DocHybridTime
  - packed row V1 and V2 formats, and when each is used
  - DocWriteBatch::SetPrimitive and the handoff to the KV write batch
Black boxes:
  - who calls this (flow 2)
  - intents encoding (flow 7). Flow 7 owns the intent key/value layout; this flow owns
    the regular-DB layout that flow 7 builds on.
  - what RocksDB does with the bytes (flows 8-9)
```

**Skeleton:**
- `src/yb/dockv/doc_key.cc:228` `DocKey::Encode` → `:252` `AppendTo`
- `src/yb/dockv/primitive_value.cc:781` `KeyEntryValue::AppendToKey`, `:1232` `DecodeKey`,
  `:3112` `FromQLValuePB`
- `src/yb/dockv/value_type.h` — the whole file is the format spec. Note `kGroupEnd = '!'`
  (`:62`), `kHybridTime = '#'` (`:67`, deliberately low so newer versions sort first),
  `kIntentTypeSet = 13` (`:45`, with a comment explaining the ordering choice),
  `kColocationId = '0'` (`:82`), `kTransactionId = 'x'` (`:137`)
- `src/yb/dockv/doc_key.cc:817` `SubDocKey::DecodeFrom`, `:901` `DecodePrefixLengths`
- `src/yb/dockv/packed_row.h:35` — **the packed-row format spec** (there is no design doc;
  this comment block is it). Implementation `src/yb/dockv/packed_row.cc:424`
  `RowPackerV1::Init`, `:494` `RowPackerV2::Init`
- `src/yb/dockv/schema_packing.cc` — `SchemaPacking` / `ColumnPackingData`
- `src/yb/docdb/pgsql_operation.cc:752` `RowPackerData::Create` (V2 chosen by
  `FLAGS_ysql_use_packed_row_v2`); packed path at `:1582`, unpacked fallback at `:1608`
- `src/yb/docdb/doc_write_batch.cc:483` `SetPrimitive` → `:312` `SetPrimitiveInternal`,
  `:903` `MoveToWriteBatchPB`
- `src/yb/docdb/key_bounds.h:56` `struct DocDB` — the paired regular/intents handle

**Prove it:** `src/yb/docdb/docdb-test.cc` prints decoded DocDB via
`src/yb/docdb/docdb_debug.cc:130` `DocDBDebugDumpToStr`. Or
`sst_dump --command=scan --output_format=decoded_regulardb` against a real tablet dir.
`src/yb/docdb/kv_debug.cc:57` `DocDBKeyToDebugStr` is the decoder those use.

**Read alongside:** `docs/content/stable/architecture/docdb/data-model.md`,
`packed-rows.md`, `architecture/design/advanced-delta-encoding.md`.

---

## 7. IntentsDB — the provisional-records store

**Why:** the second RocksDB is the single most YB-specific thing in the storage layer, and
almost every subtle transaction bug lives here. This is flow 4's physical counterpart —
you can do it without having done flow 4, as long as you accept "some coordinator tells us
this transaction committed at time T" as a black box.

> **This is the biggest flow in the file — budget two sessions.** It has four independent
> axes (byte layout, the read-time merge, the write→apply→remove lifecycle, crash
> recovery). A clean split is: session 1 = layout and reading (through the visibility
> decision), session 2 = lifecycle and recovery. Use the "resume" variant in between.

```text
FLOW: Everything about the intents RocksDB: why it is a separate DB, the byte layout of
the records it stores, how a reader merges it with the regular DB, and the full lifecycle
write -> apply -> remove, including the cleanup paths that don't go through apply.

SCOPE:
In scope:
  - why two DBs rather than one keyspace
  - Tablet::OpenIntentsDB vs OpenRegularDB, option by option
  - the record types stored in the intents DB. Start from the comment at
    rocksdb_writer.cc:263, then check it against the writers - the comment is not
    necessarily complete
  - strong vs weak intents; which isolation level / row mark produces which
  - IntentAwareIterator: the merge, and the visibility decision in DecodeStrongWriteIntent
  - apply: ApplyIntentsContext::Entry, and chunking for large transactions
  - removal: RemoveIntentsContext, the intents compaction filter, whole-SST-file deletion,
    and IntentsDbFlushFilter
  - recovery: how TransactionLoader rebuilds state from the intents DB on startup
Method note: find the reasons in the code and its comments, not from first principles.
Black boxes:
  - the coordinator protocol (flow 4) - contract: "asks the status tablet, gets
    committed@T / aborted / pending, and the verdict is final and identical on every
    participant"
  - read-time selection (flow 5) - contract: "a read arrives with a
    read/local_limit/global_limit triple; at-or-below read is visible, above global_limit
    is ignorable, in between forces a restart". DecodeStrongWriteIntent consumes this.
  - DocKey/SubDocKey encoding (flow 6) - contract: "a key sorts in table order and its
    DocHybridTime suffix sorts newest-first". You need this to read an intent key; you
    don't need to know how it is produced.
  - Raft (flow 3)
  - generic RocksDB mechanics (flows 8-9), EXCEPT the two YB extension points this flow
    depends on - mem_table_flush_filter_factory and compaction_filter_factory. Those are
    in scope, including what the RocksDB-side consumer does with their return values.
```

**Skeleton:**
- **Why two DBs** — `src/yb/docdb/rocksdb_writer.cc:263` is the canonical comment listing
  the record types — it lists four, but check it against the writers and against
  `src/yb/docdb/docdb-internal.cc:23` `GetKeyType` before believing the count. Then find
  the *reasons*: `src/yb/tablet/tablet.cc:968` (flush
  ordering), `src/yb/tablet/tablet.cc:1427` `DoCleanupIntentFiles` (whole-file drop),
  `src/yb/docdb/intent_aware_iterator.cc:222` (iterator creation order).
- **Open** — `src/yb/tablet/tablet.cc:1258` `OpenIntentsDB` vs `:1177` `OpenRegularDB`.
  Diff them line by line; the differences *are* the design. Directory:
  `src/yb/docdb/docdb_util.cc:638` `GetStorageDir` + `:54` `kIntentsDirName` — note it's a
  **sibling** dir, `<tablet-dir>.intents`.
- **Write** — `src/yb/docdb/rocksdb_writer.cc:275` `TransactionalWriter::Apply`,
  `:125` `AddIntent` (the two records per intent),
  `src/yb/dockv/intent.cc:447` `EnumerateIntents` (one user KV → N intents)
- **Intent types** — `src/yb/dockv/intent.cc:177` `GetIntentTypesForWrite`,
  `:173` `GetIntentTypesForRead`, `:181` `GetIntentTypesForLock`;
  `src/yb/dockv/dockv_fwd.h:80` for the weak/strong definition and why weak sorts first
- **Read** — `src/yb/docdb/intent_aware_iterator.cc:243` `Seek`, `:300` `SeekForward`;
  the visibility decision is `src/yb/docdb/intent_format.cc:69` `DecodeStrongWriteIntent`;
  commit lookup is `src/yb/docdb/transaction_status_cache.cc:78`
  `GetTransactionLocalState`
- **Apply** — `src/yb/tablet/tablet.cc:2517` `Tablet::ApplyIntents` →
  `src/yb/docdb/rocksdb_writer.cc:603` `IntentsWriter::Apply` (the shared reverse-index
  walker) → **`src/yb/docdb/rocksdb_writer.cc:733` `ApplyIntentsContext::Entry`**. If you
  read one function in this flow, read that one: it rewrites the provisional hybrid time
  into the commit hybrid time, and that rewrite *is* what "commit" means physically.
- **Chunked apply** — `src/yb/docdb/rocksdb_writer.cc:701` `StoreApplyState`,
  `src/yb/tablet/apply_intents_task.cc:57` `ApplyIntentsTask::Run`
- **Remove** — `src/yb/tablet/tablet.cc:2558` `RemoveIntentsImpl` →
  `src/yb/docdb/rocksdb_writer.cc:947` `RemoveIntentsContext::Entry`
- **Cleanup beyond apply** —
  `src/yb/docdb/docdb_compaction_filter_intents.cc:133` `DocDBIntentsCompactionFilter::Filter`
  (mostly a *discovery* mechanism, not a deleter);
  `src/yb/tablet/cleanup_aborts_task.cc:47` `CleanupAbortsTask::Run`;
  `src/yb/tablet/tablet.cc:1427` `DoCleanupIntentFiles` (whole-SST deletion, gated on
  `MinRunningHybridTime`); `src/yb/tablet/tablet.cc:953` `IntentsDbFlushFilter`
- **Recovery** — `src/yb/tablet/transaction_loader.cc:130` `LoadTransactions`,
  `:191` `LoadPendingApplies`;
  `src/yb/tablet/transaction_participant.cc:1810` `LoadFinished`

**Prove it:**
- `sst_dump --file=<data>/tablet-<id>.intents --command=scan
  --output_format=decoded_intentsdb` on a cluster with an open transaction
- `/rocksdb?id=<tablet>` (dumps both DBs); `/intentsdb` needs a **debug build** *and*
  `--enable_intentsdb_page=true` (default false,
  `src/yb/tserver/tserver-path-handlers.cc:108`)
- `src/yb/client/ql-transaction-test.cc` — `FlushIntents:1565` (exercises the flush
  filter), `DeleteFlushedIntents:1676` (whole-file cleanup),
  `CheckCompactionAbortCleanup:847` (the compaction filter)
- `src/yb/docdb/docdb-test-wrapper.cc:1657` `CompactionWithTransactions` — prints intents
  with `FLAGS_TEST_docdb_sort_weak_intents` on for deterministic output

**The one invariant to carry away:** intents may only be flushed *after* the regular DB —
stated at `src/yb/tablet/tablet.cc:968`. It shows up again in
`src/yb/tablet/tablet_peer.cc:1017` `GetEarliestNeededLogIndex`. Anything that changes
flush ordering has to reason about both.

---

## 8. Memtables, flushes, and SST files

**Why:** the write path's tail. Also where YB's most invasive RocksDB fork changes live —
the flush filter and the two-file SST split are both YB inventions.

```text
FLOW: From a WriteBatch reaching a memtable, through the decision to flush, to an SST file
on disk. Include YB's mem_table_flush_filter hook and the base-file/data-file SST split.

SCOPE:
In scope:
  - Tablet::WriteToRocksDB -> DBImpl::Write -> MemTableInserter -> MemTable::Add
  - how a memtable carries YB metadata (ConsensusFrontier: OpId, hybrid time, cutoff)
  - the full trigger inventory for a flush
  - the YB mem_table_flush_filter mechanism and its two implementations
  - flush execution: BackgroundFlush -> FlushMemTableToOutputFile -> FlushJob::Run
  - SST layout: the base .sst / .sst.sblock split, bloom policies, delta encoding
Black boxes:
  - what produced the write batch (flow 2)
  - compaction (flow 9)
  - the transaction semantics behind the intents flush filter (flow 7 — contract only)
```

**Skeleton:**
- `src/yb/tablet/tablet.cc:1987` `Tablet::WriteToRocksDB` — note `SetFrontiers` before the
  write; that's what stamps OpId/hybrid time onto the memtable
- `src/yb/rocksdb/db/write_batch.cc:730` `MemTableInserter::PutCF` →
  `src/yb/rocksdb/db/memtable.cc:394` `MemTable::Add`;
  `src/yb/rocksdb/db/write_batch.cc:920` `MemTableInserter::Frontiers` (the YB hook);
  `:929` `CheckMemtableFull`; size heuristic `src/yb/rocksdb/db/memtable.cc:135`
  `ShouldFlushNow`
- **The flush filter (YB, not upstream)** —
  `src/yb/rocksdb/options.h:834` `MemTableFilter` typedef, `:1350` the factory field;
  consumed at `src/yb/rocksdb/db/memtable_list.cc:310` `PickMemtablesToFlush` (note it
  *breaks* rather than skips, preserving prefix order). Two implementations:
  `src/yb/tablet/tablet_peer.cc:264` (regular DB: don't flush ahead of the WAL) and
  `src/yb/tablet/tablet.cc:953` `IntentsDbFlushFilter` (intents after regular).
  Wired at `src/yb/tablet/tablet.cc:1204` and `:1282`.
- **Triggers** — `src/yb/rocksdb/listener.h:99` `FlushReason` is a typed inventory of every
  cause; read the enum first, then find each. Notably:
  `src/yb/rocksdb/db/db_impl.cc:3198` `FlushMemTable`,
  `src/yb/tserver/tablet_memory_manager.cc:355` `FlushTabletIfLimitExceeded`,
  `src/yb/tserver/tablet_service.cc:2118` `TabletServiceAdminImpl::FlushTablets`,
  `src/yb/tablet/tablet_peer.cc:1017` `GetEarliestNeededLogIndex` (WAL retention)
- **Execution** — `src/yb/rocksdb/db/db_impl.cc:3433` `SchedulePendingFlush` (the YB fork
  routes to the priority thread pool here) → `:3623` `BackgroundCallFlush` →
  `:3505` `BackgroundFlush` → `:2067` `FlushMemTableToOutputFile` →
  `src/yb/rocksdb/db/flush_job.cc:146` `FlushJob::Run`
- **YB-level** — `src/yb/tablet/tablet.cc:2439` `Tablet::Flush` (intents async *first*,
  then regular, then wait — the ordering is the point)
- **The split SST** — `src/yb/rocksdb/db/filename.cc:139` `TableBaseToDataFileName`
  (`.sst` + `.sst.sblock.0`); capability flag
  `src/yb/rocksdb/table/block_based_table_factory.h:63` `IsSplitSstForWriteSupported`;
  both files handled at `src/yb/rocksdb/db/table_cache.cc:158` and
  `src/yb/rocksdb/db/compaction_job.cc:947`. Rationale: the base file (index + filter +
  properties) is small and stays hot; the data file holds the bulk.
- **Bloom filters** — `src/yb/docdb/docdb_filter_policy.cc:23` `DocKeyComponentsExtractor`,
  and the three policy versions in `src/yb/docdb/docdb_filter_policy.h`
- **Knobs** — all in `src/yb/docdb/docdb_rocksdb_util.cc`: `memstore_size_mb`,
  `db_write_buffer_size`, `rocksdb_max_write_buffer_number`,
  `rocksdb_max_background_flushes`

**Prove it:** `src/yb/integration-tests/flush-test.cc` (`TestFlushHappens`,
`TestFlushPicksOldestInactiveTabletAfterCompaction`); `/rocksdb?id=<tablet>` before and
after; `ls` a tablet data dir and count `.sst` vs `.sst.sblock` files.

**Read alongside:** `docs/content/stable/architecture/docdb/lsm-sst.md`,
`architecture/design/advanced-delta-encoding.md`.

---

## 9. Compactions — what gets dropped and why

**Why:** compaction in YB is not generic RocksDB compaction. It is where history retention,
TTL, tombstone GC, packed-row rewriting and post-split cleanup all get decided, through a
YB-specific hook that upstream RocksDB doesn't have.

```text
FLOW: A compaction from picking to per-key decision. Cover why YB uses universal
compaction with a single level, how compactions are scheduled and rate-limited, the
CompactionContext/CompactionFeed hook YB interposes, and the per-key keep/drop rules
(history cutoff, tombstones, TTL, deleted columns).

SCOPE:
In scope:
  - compaction style selection and what num_levels=1 implies
  - UniversalCompactionPicker and the order it tries its three strategies
  - YB's PriorityThreadPool scheduling and the shared rate limiter
  - the compaction_context_factory hook and DocDBCompactionFeed::Feed
  - the overwrite_ stack, history cutoff, tombstone GC, TTL, deleted columns
  - whole-file drops: the TTL file filter and the hybrid-time file filter
  - scheduled full compactions
Black boxes:
  - flushes (flow 8)
  - key/value encoding (flow 6) — you need to be able to read a key, not to encode one
  - the intents DB compaction filter (flow 7), other than noting it is a different
    mechanism (a classic CompactionFilter, because the intents DB has no
    compaction_context_factory)
```

**Skeleton:**
- **Style** — `src/yb/docdb/docdb_rocksdb_util.cc:699` sets
  `kCompactionStyleUniversal`, and `:703` sets `num_levels = 1`. Start here and ask what
  that choice costs and buys. (The docs agree:
  `docs/content/stable/architecture/docdb/lsm-sst.md` says DocDB keeps files in only one
  level.)
- **Picking** — `src/yb/rocksdb/db/column_family.cc:747` `PickCompaction` →
  `src/yb/rocksdb/db/compaction_picker.cc:1530`
  `UniversalCompactionPicker::PickCompaction` → `:1550` `DoPickCompaction`, which tries
  `:1928` `PickCompactionUniversalDeletion` (YB's whole-file TTL drop — bypasses the
  file-count trigger entirely), then `:1993` `...SizeAmp`, then `:1736` `...ReadAmp`
- **Scheduling** — `src/yb/docdb/docdb_rocksdb_util.cc:651` `GetGlobalPriorityThreadPool`
  (one pool for the whole tserver, not per-DB threads);
  `src/yb/util/priority_thread_pool.h:99` `PriorityThreadPool`;
  `src/yb/rocksdb/db/db_impl.cc:3343` `MaybeAddToCompactionQueue` (small vs large);
  rate limiting `src/yb/docdb/docdb_rocksdb_util.cc:1128` `CreateRocksDBRateLimiter`
- **Execution** — `src/yb/rocksdb/db/db_impl.cc:3718` `BackgroundCompaction` →
  `src/yb/rocksdb/db/compaction_job.cc:521` `CompactionJob::Run` →
  `:664` `ProcessKeyValueCompaction`
- **The YB hook** — `src/yb/rocksdb/db/compaction_job.cc:736` is where
  `compaction_context_factory` interposes a `CompactionFeed` between the compaction
  iterator and the table builder. Registered at `src/yb/tablet/tablet.cc:1199`; the intents
  DB explicitly clears it at `:1279`.
  Factory: `src/yb/docdb/docdb_compaction_context.cc:1504`
  `CreateCompactionContextFactory`.
- **The per-key decision** — `src/yb/docdb/docdb_compaction_context.cc:956`
  `DocDBCompactionFeed::Feed`. Read the `overwrite_ht_` comment block at `:849-882` first;
  the whole function is that invariant in code. The core drop test is one line:
  `:1082` `bool skip = encoded_doc_ht < prev_overwrite_ht && !is_ttl_row;`
- **History retention** — `src/yb/tablet/tablet_retention_policy.cc:99`
  `GetRetentionDirective`, `:72` `ClockBasedHistoryCutoff`, `:128`
  `RegisterReaderTimestamp` (this is where `SnapshotTooOld` comes from)
- **Whole-file drops** — `src/yb/docdb/compaction_file_filter.cc:151`
  `DocDBCompactionFileFilter::Filter` (TTL, compaction-time);
  `src/yb/docdb/doc_ql_filefilter.cc:128` `HybridTimeFileFilter::Filter` (read-time)
- **Frontiers** — `src/yb/docdb/consensus_frontier.cc`; a file records its OpId, hybrid
  time, history cutoff and schema versions, which is what makes cross-restart correctness
  work
- **Scheduled full compactions** — `src/yb/tserver/full_compaction_manager.cc:105`
  `ScheduleFullCompactions`, `:229` `DoScheduleFullCompactions`, `:189`
  `ShouldCompactBasedOnStats`
- **Manual** — `src/yb/tablet/tablet.cc:4326` `ForceManualRocksDBCompact`. (There is no
  `TEST_ForceRocksDBCompact` in this tree, despite the name being widely assumed.)

**Prove it:** `src/yb/integration-tests/compaction-test.cc` —
`ManualCompactionProducesOneFilePerDb:524`,
`FilesOverMaxSizeWithTableTTLDoNotGetAutoCompacted:681`, and the whole
`ScheduledFullCompactionsTest` fixture at `:794`. Also
`src/yb/docdb/docdb-ttl-test.cc` and `src/yb/docdb/compaction_file_filter-test.cc`.
`--rocksdb_disable_compactions=true` is useful for isolating what compaction was doing.

---

# Track D — Cluster orchestration

## 10. `CREATE TABLE` end-to-end

**Why:** the clearest illustration of the master's synchronous-DDL / asynchronous-work
split, the copy-on-write `TableInfo`/`TabletInfo` discipline, `LeaderEpoch`, and the async
task framework that every other master operation reuses.

```text
FLOW: Follow CREATE TABLE from the master's CreateTable RPC through partition and tablet
creation in the sys catalog, the background task that assigns replicas, the
AsyncCreateReplica RPCs to tservers, and the client polling IsCreateTableDone.

SCOPE:
In scope:
  - CatalogManager::CreateTable: validation, colocation decision, partitioning,
    in-memory + sys-catalog persistence, and where it returns to the client
  - the handoff to the background task and ProcessPendingAssignmentsPerTable
  - replica selection and SendCreateTabletRequests
  - the RetryingTSRpcTask framework via AsyncCreateReplica
Black boxes:
  - sys catalog Raft writes (contract: "Upsert is durable and linearizable")
  - what the tserver does to create a tablet peer
  - the PG-side DDL that issued the RPC
```

**Skeleton:**
- `src/yb/master/catalog_manager.cc:4403` `CreateTable` — long; read it top to bottom once
  with `catalog_manager_bg_tasks.cc` open beside it
- `:12582` `CreatePartitions`, `:12536` `CalculateNumTabletsForTableCreation`
- `:5301` `CreateTableInMemory`, `:5170` `CreateTabletsFromTable` (note tablets are sorted
  by id for deterministic lock ordering)
- `src/yb/master/catalog_manager_bg_tasks.cc:333` `CatalogManagerBgTasks::Run` — **the
  handoff point; CreateTable returns before any tablet exists**
- `src/yb/master/catalog_manager.cc:11904` `ProcessPendingAssignmentsPerTable` →
  `:12085` `SelectReplicasForTablet` → `:12257` `SendCreateTabletRequests` →
  `:12309` `StartElectionIfReady`
- `src/yb/master/async_rpc_tasks.cc:66` / `:157` `AsyncCreateReplica`;
  framework `src/yb/master/async_rpc_tasks_base.cc:131` `RetryingRpcTask::Run`
- `src/yb/master/catalog_manager.cc:5890` `IsCreateTableDone`
- `src/yb/master/leader_epoch.h` — the `(term, pitr_count)` token threaded through DDL

**Prove it:** master `/tasks` page during a `CREATE TABLE` on a slow/large cluster;
`--collect_end_to_end_traces=true` and read the `TRACE(...)` lines that `CreateTable`
already emits. Tests: `src/yb/integration-tests/create-table-itest.cc`.

**Read alongside:** `src/yb/master/README` (the COW `TableInfo` protocol),
`docs/content/stable/architecture/yb-master.md`.

---

## 11. YSQL catalog version and cache invalidation

**Why:** it's the only flow that spans PostgreSQL C code, the master, the heartbeat, tserver
shared memory, and back into a PG backend. Understanding it explains most "why is my DDL
not visible yet" questions.

```text
FLOW: A DDL bumps the catalog version on the master; every other node learns about it and
invalidates its PostgreSQL catalog caches. Follow the whole loop.

SCOPE:
In scope:
  - the PG backend incrementing pg_yb_catalog_version on DDL
  - master reading it and shipping it in the heartbeat response (incl. the fingerprint
    short-circuit)
  - tserver receiving it and publishing into shared memory
  - the PG backend reading shared memory and invalidating caches
Black boxes:
  - how the DDL itself executes
  - DocDB reads/writes of the catalog table
  - the heartbeat's other payloads
```

**Skeleton:**
- `src/postgres/src/backend/catalog/yb_catalog/yb_catalog_version.c:628`
  `YbIncrementMasterCatalogVersionTableEntry`, `:93` `YbGetMasterCatalogVersion`
- `src/yb/master/catalog_manager.cc:10963` `GetYsqlAllDBCatalogVersionsImpl`
- `src/yb/master/master_heartbeat_service.cc:316` — and the fingerprint short-circuit just
  below it; `src/yb/master/master_heartbeat.proto` for the wire fields
- `src/yb/tserver/heartbeater.cc:500` — handling `db_catalog_version_data`
- `src/yb/tserver/tserver_shared_mem.h:142` — where it lands in shared memory
- `src/postgres/src/backend/utils/cache/inval.c:904` `YbGetSharedCatalogVersion` — the
  comparison that triggers invalidation

**Prove it:** `--log_ysql_catalog_versions=true` on master and tserver;
`SET yb_debug_log_catcache_events = true;` in psql. Tests:
`java/yb-pgsql/src/test/java/org/yb/pgsql/TestPgCacheConsistency.java`.

**Read alongside:**
`docs/content/stable/best-practices-operations/ysql-catalog-cache-tuning-guide.md`.

---

## 12. Client routing — meta-cache, leader discovery, retries

**Why:** it answers "how does an op find its tablet, and what happens when the answer is
wrong?" — which is most of the interesting failure behaviour in the system.

```text
FLOW: How a YBClient operation is routed to the right tablet and the right replica, and
how it recovers from NOT_THE_LEADER, TABLET_SPLIT, and a stale partition list.

SCOPE:
In scope:
  - Batcher: adding an op, tablet lookup, the partition-list-version check
  - MetaCache: fast path, slow path, the master lookup RPCs, RemoteTablet state
  - TabletInvoker: replica selection, FailToNewReplica, the retry classifier in Done()
  - session-level retry and partition refresh
Black boxes:
  - what the operation is
  - the master's side of the lookup RPC
  - tablet splitting itself (flow 13) — contract: "a tablet can be replaced by two children
    and the client will be told TABLET_SPLIT"
```

**Skeleton:**
- `src/yb/client/batcher.cc:325` `Add` → `:357` `LookupTabletFor` → `:372`
  `TabletLookupFinished` → `:565` `ExecuteOperations`
- `src/yb/client/meta_cache.cc:2266` `LookupTabletByKey`; fast path `:2030`
  `LookupTabletByKeyFastPathUnlocked`; slow path `:2124` `DoLookupTabletByKey`
- `src/yb/client/meta_cache.cc:1089` `ProcessTabletLocation`; `:842` `class LookupRpc`
- `RemoteTablet` state: `src/yb/client/meta_cache.cc:537` `LeaderTServer`,
  `:686` `MarkTServerAsFollower`, `:465` `MarkAsSplit`
- **`src/yb/client/tablet_rpc.cc:296` `TabletInvoker::FailToNewReplica`** — read the
  comment starting at `:302`. It is the best explanation in the tree of why
  `NOT_THE_LEADER` must not mark a replica failed, and it will change how you read the
  rest of the file.
- `src/yb/client/tablet_rpc.cc:356` `Done` — the retry classifier
- `src/yb/client/session.cc:461` `ShouldSessionRetryError`
- `src/yb/client/table.cc:239` `RefreshPartitions`

**Prove it:** `curl localhost:9000/api/v1/meta-cache` before and after a leader step-down
(`yb-admin leader_stepdown`). Tests:
`src/yb/integration-tests/metacache_refresh-itest.cc`,
`src/yb/client/client-test.cc` (the consensus-info refresh cases).

---

## 13. Automatic tablet splitting

**Why:** a capstone. It reuses Raft (3), the master task framework (10) and client routing
(12), and it's the clearest example of an operation that has to be correct across all
three at once.

```text
FLOW: From the master deciding a tablet is too big, through fetching a split key, the
Raft-replicated split operation, child tablet creation, and the client discovering the
split.

SCOPE:
In scope:
  - the master's decision loop and its validation gates
  - AsyncGetTabletSplitKey and AsyncSplitTablet
  - the tserver: GetSplitKey (how a middle key is chosen from SST index blocks) and
    SplitTablet as a replicated operation
  - child tablet creation via ApplyTabletSplit
  - post-split op rejection and how the client learns
Black boxes:
  - Raft internals (flow 3) — contract only
  - RocksDB checkpointing of the parent's files
  - post-split compaction (flow 9)
```

**Skeleton:**
- `src/yb/master/tablet_split_manager.cc:1026` `MaybeDoSplitting` → `:835` `DoSplitting`;
  gates at `:239` `ValidateSplitCandidateTable`, `:358` `ValidateSplitCandidateTablet`
- `src/yb/master/catalog_manager.cc:3361` `DoSplitTablet`
- `src/yb/master/async_rpc_tasks.cc:1202` `AsyncGetTabletSplitKey`, `:1279`
  `AsyncSplitTablet`
- `src/yb/tserver/tablet_service.cc:3424` `GetSplitKey` →
  `src/yb/tablet/tablet.cc:4915` `DoGetSplitKeys` (which asks RocksDB for a middle key)
- `src/yb/tserver/tablet_service.cc:2253` `TabletServiceAdminImpl::SplitTablet` —
  constructs a `SplitOperation` that goes through Raft
- `src/yb/tserver/ts_tablet_manager.cc:1210` `TSTabletManager::ApplyTabletSplit`
- Back to the client: `src/yb/client/tablet_rpc.cc:356` `Done` (the `TABLET_SPLIT` branch)

**Prove it:** `src/yb/integration-tests/tablet-split-itest.cc`; master `/tasks` and
tserver `/tablets` during a forced split.

**Read alongside:** `architecture/design/docdb-automatic-tablet-splitting.md`,
`docs/content/stable/architecture/docdb-sharding/tablet-splitting.md`.

---

# Track E — Extensions and singleton services

## 14. pg_cron and the stateful-service leader pattern

**Why:** the interesting question isn't "how does cron work" — it's *"there are N
PostgreSQL processes in this cluster; how does exactly one of them run the job, exactly
once, across leader crashes?"* The answer is a general YB mechanism (stateful services)
that also backs pg_auto_analyze, and it's a compact, complete distributed-systems story
you can hold in your head.

```text
FLOW: How pg_cron runs jobs exactly once cluster-wide. Follow the extension's launcher
loop, the stateful-service leadership election, the lease handshake through tserver shared
memory into the PostgreSQL backend, and the durably-persisted scheduling watermark.

SCOPE:
In scope:
  - the pg_cron background worker and its main loop, and where YB gates it on leadership
  - how the PG_CRON_LEADER stateful service gets created (triggered by CREATE EXTENSION
    creating cron.job!) and how leadership follows Raft leadership of its one tablet
  - the lease: Activate/RefreshLeaderLease -> tserver shared memory -> YbIsCronLeader
  - why last_minute is persisted in a service table and not in cron.*
  - what happens on leader crash vs graceful move
Black boxes:
  - Raft (flow 3) — contract: "exactly one tablet leader at a time, with a bounded lease"
  - how the service table's rows are read/written (it's an ordinary YSQL table)
  - PostgreSQL background-worker mechanics
```

**Skeleton:**
- **Extension** — `src/postgres/third-party-extensions/pg_cron/src/pg_cron.c:216`
  `_PG_init` (registers the worker); `:602` `PgCronLauncherMain` (the loop);
  `:756` `StartAllPendingRuns`; `:1386` `ManageCronTask`; `:2162` `CronBackgroundWorker`
- **The YB gate** — `pg_cron.c:2506` `YbIsCronLeader`, `:2530` `YbCheckLeadership`. Every
  scheduling decision short-circuits on `ybIsLeader`.
- **Service creation** — `src/yb/common/common_types.proto:178` `PG_CRON_LEADER`;
  `src/yb/master/catalog_manager.cc:954` `IsPgCronJobTable` → `:5845` `CreatePgCronService`.
  Creating the `cron.job` table is what bootstraps the service — a nice bit of plumbing to
  notice.
- **Leadership** — `src/yb/tserver/tablet_server.cc:863` registers the service;
  `src/yb/tserver/stateful_services/stateful_service_base.h:61` `StatefulServiceBase`
  (`Activate` on becoming Raft leader of the service tablet, `Deactivate` on step-down);
  `src/yb/tserver/stateful_services/stateful_service_base.cc:306`
  `StartPeriodicTaskIfNeeded`
- **The lease** — `src/yb/tserver/stateful_services/pg_cron_leader_service.cc:67`
  `Activate` (a new leader deliberately waits out the old leader's lease plus clock skew
  before doing anything — the most interesting 20 lines in the flow);
  `:114` `RefreshLeaderLease`;
  `src/yb/tserver/tserver_shared_mem.h:119` `SetCronLeaderLease`;
  `src/yb/tserver/tserver_shared_mem.cc:671` `IsCronLeader` (the PG backend reads it
  lock-free)
- **Durable watermark** —
  `src/yb/tserver/stateful_services/pg_cron_leader_service.cc:145` `SetLastMinute` /
  `:183` `GetLastMinute`, stored as JSONB in the service table. Ask why this can't live in
  a `cron.*` table or in process memory.
- **Flags** — `src/yb/server/server_common_flags.cc:31` `enable_pg_cron` (default false,
  needed on masters *and* tservers); `src/yb/yql/pgwrapper/pg_wrapper.cc:384`
  `ysql_cron_database_name`;
  `pg_cron_leader_service.cc` defines `pg_cron_leader_lease_sec` and
  `pg_cron_leadership_refresh_sec` (cross-validated so refresh < lease)

**Prove it:** `src/yb/integration-tests/pg_cron-test.cc` — the test names *are* the
failure-mode list: `LeaderCrash1:348`, `GracefulLeaderMove:422`,
`PerMinuteTaskWithLeaderMove:542`, `FailBeforeStoringLastMinute:564`,
`CancelJobOnLeaderChange:681`, `ValidateStoredLastMinute:514`. Run
`GracefulLeaderMove` first and read what it asserts.

**⚠ Trap:** `src/postgres/third-party-extensions/pg_cron/src/README.md` describes a
leader-assigns-work-to-remote-workers architecture. **That is not implemented.** There are
no remote task states in `include/task_states.h`, and `pg_cron.c:2547` defers it to a
GitHub issue. Read the code, not that README.

**Read alongside:**
`docs/content/stable/additional-features/pg-extensions/extension-pgcron.md`.

---

# If none of those appeal

Same format, less written up. All verified to exist:

| Flow | Start at |
|---|---|
| CDC logical replication (PG protocol) | `src/yb/cdc/cdc_service.cc:1609` `GetChanges`; `src/yb/cdc/cdcsdk_producer.cc:2656` `GetChangesForCDCSDK`; `src/yb/cdc/cdcsdk_virtual_wal.cc:566` `GetConsistentChangesInternal` |
| xCluster replication | producer `src/yb/cdc/xcluster_producer.cc:289`; consumer `src/yb/tserver/xcluster_poller.cc`; master `src/yb/master/xcluster/` |
| Load balancer | `src/yb/master/cluster_balance.cc:373` `RunClusterBalancerWithOptions`. Unusually easy to study: `src/yb/master/load_balancer_mocked-test.cc` runs it with **no cluster at all**. |
| Online index backfill | `src/yb/master/backfill_index.cc`; `architecture/design/online-index-backfill.md` |
| Colocation and tablegroups | `src/yb/common/colocated_util.h` (the whole scheme is table-id suffixes); `src/yb/master/catalog_manager.cc:9036` `CreateTablegroup`; `architecture/design/ysql-colocated-tables.md` then `ysql-tablegroups.md` |
| OID and sequence allocation | `src/yb/master/catalog_manager.cc:4067` `ReservePgsqlOids`; `src/yb/tserver/pg_client_service.cc:1237` `ReserveOids`; `src/postgres/src/backend/commands/sequence.c:917` `YBCFetchSequenceTuple` |
| Master leader election and sys-catalog load | `src/yb/master/sys_catalog.cc:432` `SysCatalogStateChanged` → `src/yb/master/catalog_manager.cc:1234` `LoadSysCatalogDataTask` |
| pg_auto_analyze (the other stateful service) | `src/yb/tserver/stateful_services/pg_auto_analyze_service.cc` — a natural sequel to flow 14 |
