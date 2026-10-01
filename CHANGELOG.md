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
