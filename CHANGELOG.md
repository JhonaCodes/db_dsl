## 0.2.7

### Added
- `NativeEngine` runs on the C ABI v2 of offline_first_core (0.7.6 and
  later) when `NativeSymbols.abiV2` is given (`AbiV2Symbols`): `u64`
  handles the library validates, so a handle used after it was closed
  answers an error instead of undefined behaviour, and requests and
  responses travel as bytes with a length. Without it, the ABI v1 is used
  as before; the key-value API stays on the ABI v1.
  `NativeConnection.usesAbiV2` says which one a connection uses.

### Changed
- One worker isolate per library and ABI (before: per library).

## 0.2.6

Documentation only; no change in behaviour.

- `DbErrorCode.mapFull` and PROTOCOL.md: besides the maximum size, a
  transaction that writes past the end of the memory map before it grows
  answers `MapFull`, and running it again finds room. offline_first_core
  0.7.6 grows the map ahead, so only a transaction that alone writes more
  than half of the map meets it.

## 0.2.5

### Added
- `JoinQuery.explain()` and `Database.explainJoin`: how the engine would
  run a join, without running it (`JoinPlan`: the strategy, every table in
  join order with its alias and access path, and where the filter runs).
  The protocol's `explain` with a join `query` is now part of version 1:
  `MemoryEngine` answers it as offline_first_core does (`hash_join` over
  full scans), with a conformance case and a replayed example.

### Changed
- The sealed `ProtocolRequest` family gained `ExplainJoinRequest` (see
  "Status" in the README).

## 0.2.4

### Added
- Offline-first sync (PROTOCOL.md, "Sync"): `DbTable(..., syncWith:
  'primary')` makes every write record a change in the same transaction
  as the row, and `db.sync` claims leased batches (`claim`), records the
  server's answers by mutation and revision (`applyPushResult`), releases
  and retries deliveries (`release`, `retry`), applies remote pages with
  their checkpoint atomically (`applyRemote`), keeps and resolves
  conflicts (`conflicts`, `resolveConflict`), and reports `stateOf`,
  `pending` and `status`.
- Ten protocol operations (`sync_claim`, `sync_push_result`,
  `sync_release`, `sync_retry`, `sync_apply_remote`, `sync_resolve`,
  `sync_state`, `sync_pending`, `sync_conflicts`, `sync_status`), the
  `sync` field of a table definition, and eight error codes, each in an
  existing `DbError` family: `syncNotTracked` (schema), `unknownMutation`,
  `acknowledgementMismatch`, `conflictNotFound`, `tombstonePending`
  (constraint), `staleCheckpoint`, `rowVersionMismatch`, `mutationInFlight`
  (transaction).
- `MemoryEngine` implements sync with the rules of offline_first_core
  0.7.5; six conformance cases and an example scenario of every sync
  operation in PROTOCOL.md run on every engine.

### Changed
- The sealed `ProtocolRequest` family and `DbErrorCode` grew (see
  "Status" in the README): an engine written in Dart that switches over
  requests must add the sync cases.
- The protocol replay captures `$lease`, `$mutation` and `$conflict`
  besides `$transaction`.

## 0.2.3

### Added
- `Relation<A, B>`: a many-to-many relation through a bridge table of its
  own, one row per linked pair (keyed by the pair, with an index on each
  side). `attach` (1, or 0 when already linked), `detach` (removes the
  link, never the rows), `targetsOf` and `sourcesOf` (only the neighbours:
  an index range, then primary key lookups). A row without its key answers
  `missingPrimaryKey`. Links are ordinary rows: they follow the transaction
  they are awaited in.
- A conformance case for relations, replayed on every engine.

### Changed
- PROTOCOL.md notes two engine behaviours: an `eq_any` may be answered by
  lookups of only the named keys (offline_first_core 0.7.4), and
  offline_first_core 0.7.3 also explains a join query, an engine extension
  outside the v1 conformance.

## 0.2.2

Documentation and tests; no change in behaviour.

- PROTOCOL.md has a replayed example of every operation: `tables`,
  `explain`, `info`, a read transaction (and the write it refuses), a
  savepoint `release`, `rollback` of a whole transaction, and `drop_table`.
  Every engine of the conformance suite (MemoryEngine and the native one)
  gives the documented answers; plan and storage values, which may differ
  between engines, are shown as `…`.
- A test checks that every operation and statement of the protocol has an
  example: its switches are exhaustive over the sealed request and
  statement families, so a new kind cannot ship without one.

## 0.2.1

Documentation only; no change in behaviour.

- README: "How it works" (from a builder to the engine and back, how a
  query picks its executor, the write queue, transactions, `watch`, the
  native worker isolate) and "Using it well" (the practices the library
  relies on: open once, `tableNotReady`, `transactionReentrancy`, grouping
  writes, indexes and `explain`, ordering, UTC dates, errors, tests).
- The versioning policy: releases stay in 0.2.x and never break code written
  against 0.2.

## 0.2.0

- **Tables define themselves.** No table has to be listed when a database
  opens: the first database opened is the default one, and a table no
  database holds yet defines itself there the first time it is used
  (created if new, new indexes built, removed ones dropped). Concurrent
  first uses define it once. `Database.open(..., tables:)` stays, to define
  tables up front.
- A table used for the first time inside a transaction answers
  `Err(DbErrorCode.tableNotReady)` (a `SchemaError`) instead of waiting
  forever for the database the transaction holds. `atomicBatch` defines the
  tables it writes before it begins.
- `explain()` and `watch()` without a database run on the default one too.
- `DbErrorCode.notOpen` now means that no database is open at all.
- **Breaking:** `QueryExecutor.of` and `Database.homeOf` are no longer
  public; queries resolve their database when awaited.
- The README and the example show the final form: the model carries its
  table (`static final table = DbTable<User>(...)`), and queries read
  `t.city.eq('Lima')` through an `extension UserFields on DbTable<User>`
  that the new [db_dsl_lints](https://pub.dev/packages/db_dsl_lints)
  analyzer plugin writes from the model and checks.

## 0.1.0

First release.

- Tables from the app's own models, without code generation or macros:
  `DbTable<User>('users', key: 'id', fromJson: User.fromJson)`. Rows are
  stored as the model writes itself (its `toJson()`, by Dart's JSON
  convention, with nested objects, dates and enums converted); `toJson:`
  only for a serializer with another name. Optional auto-increment keys and
  secondary indexes, unique or not, over one or more paths.
- `Field<V>` for any type: `table.field<V>('path')`, encoded as the model
  stores it (ISO 8601 dates, enums by name, objects through `toJson()`), or
  with `encode:` / `decode:` for custom forms. Text fields add `like` and
  `ilike`.
- Queries with Diesel's vocabulary: `filter`/`orFilter` with `eq`, `ne`,
  `gt`, `ge`, `lt`, `le`, `eqAny`, `neAll`, `between`, `notBetween`, `like`,
  `ilike`, `isNull`, `isNotNull`, combined with `.and()`, `.or()` and
  `.not()`; `order`/`thenOrderBy`, `limit`, `offset`; `first`, `count`,
  `exists`, `find`.
- Queries run when awaited (`await users.filter(...)`,
  `await users.insert([ada])`): on the database that opened their table, or
  on the transaction running around them. Another database is named
  explicitly (`load(other)`, `execute(other)`); a table open in no database
  answers `DbErrorCode.notOpen`.
- Projections (`pluck`, `project`, `distinct`), aggregates (`sum`, `avg`,
  `min`, `max`), `groupBy` with `count`/`countOf`/`sum`/`avg`/`min`/`max`
  and `having`, `innerJoin`/`leftJoin`, and associations (`belongingTo`,
  `Associations.groupedBy`).
- Writes: `insert` (with `getResults`, `onConflictReplace`,
  `onConflictDoNothing`), `update().set()/setNull()/increment()`, `delete`,
  `expectAffectedRows`, and `atomicBatch`.
- `transaction` with nested `savepoint`s, `readTransaction` snapshots, idle
  timeouts, and a write queue that keeps one writer at a time.
- `watch`: a query's rows now and after every committed write to its table.
- `explain`: the plan an engine chooses for a query.
- Every operation answers a `Result` (result_controller); errors are a
  sealed `DbError` family (`ConstraintError`, `SchemaError`,
  `TransactionError`, `StorageError`, `EngineError`) with a stable
  `DbErrorCode`.
- `MemoryEngine`: the protocol in memory with the semantics of
  offline_first_core, for tests without a native library.
- `package:db_dsl/native.dart`: `NativeEngine`, which runs the protocol on a
  loaded offline_first_core through one worker isolate (the binary comes
  from flutter_local_db or dart_db).
- `PROTOCOL.md`: the full specification of protocol version 1.
- `package:db_dsl/conformance.dart`: the conformance suite every engine must
  pass, including a replay of the examples of `PROTOCOL.md`.
