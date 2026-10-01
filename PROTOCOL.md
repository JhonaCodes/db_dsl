# The db_dsl protocol, version 1

This is the language db_dsl speaks to a storage engine. Every query the DSL
builds becomes one JSON request; the engine answers with one JSON response.
Nothing else crosses the boundary, so anyone can write:

- **an engine** that answers these requests (offline_first_core over LMDB is
  one, `MemoryEngine` is another), or
- **a translator** that builds these requests from another language or
  another DSL and sends them to an existing engine.

The document is normative: an engine is correct when it answers every
request as described here. The executable form of this document is the
conformance suite (`package:db_dsl/conformance.dart`): it runs every rule
below, and the examples at the end, against any engine. See
[Checking an engine](#checking-an-engine).

## Contents

1. [Transport](#transport)
2. [Envelope](#envelope)
3. [Values](#values)
4. [Tables](#tables)
5. [Expressions](#expressions)
6. [Statements](#statements)
7. [Operations](#operations)
8. [Transactions](#transactions)
9. [Sync](#sync)
10. [Errors](#errors)
11. [Open options](#open-options)
12. [Compatibility](#compatibility)
13. [Checking an engine](#checking-an-engine)
14. [Examples](#examples)

## Transport

The protocol is a request and a response, both UTF-8 JSON text. How they
travel is up to the engine; the native one exposes four C functions:

```c
// Opens `<path>.lmdb`; writes the handle to *out (NULL on failure) and
// returns an envelope: {"v":1,"ok":{}} or an error.
const char *ofc_open(const char *path, const char *options, void **out);

// Runs one request on the handle and returns the response envelope.
const char *ofc_execute(void *handle, const char *request);

// Releases the handle.
const char *close_database(void *handle);

// Releases every string returned by the functions above, exactly once.
void ofc_free_string(char *response);
```

Every returned string belongs to the library and must be released with
`ofc_free_string`. A call blocks its thread until the engine answers (a
durable commit waits for the disk), so a UI thread should call from a worker.
db_dsl does that on one long-lived isolate (`NativeEngine`).

A translator over another transport (a socket, HTTP, a message queue) sends
the same request text and expects the same response text.

## Envelope

A request is a JSON object with the protocol version and an operation:

```json
{"v": 1, "op": "<operation>", "...": "fields of the operation"}
```

A response is exactly one of:

```json
{"v": 1, "ok": {"...": "payload of the operation"}}
```

```json
{"v": 1, "error": {"code": "<Code>", "message": "text for humans"}}
```

- `code` is stable and names the exact cause ([Errors](#errors)). Code reacts
  to `code`, never to `message`, which may change between versions.
- A request whose `v` is not `1`, or has no `v`, is answered with
  `UnsupportedProtocol`.
- A request that is not JSON, has an unknown `op`, or has a field of the
  wrong type is answered with `InvalidRequest`.
- Unknown fields are ignored, so a newer client can talk to an older engine
  as long as it does not rely on them.

## Values

Rows are JSON objects. A field is addressed by a **path**: its name, or the
names of nested objects joined by `.` (`"address.city"`). A path that does
not reach a value is **missing**, which behaves as `null` everywhere.

### Kinds

JSON has seven kinds of value, ranked in this **total order**:

```
null < false < true < numbers < strings < arrays < objects
```

- Numbers compare by value: `1` equals `1.0`, and `-0.0` equals `0`.
  Integers compare exactly when both are integers; otherwise both compare as
  64-bit floats.
- Strings compare by their UTF-8 bytes, which is Unicode code point order
  (binary collation, no locale). `"B" < "a"` and `"Z" < "É"`.
- Arrays and objects compare by their canonical JSON (object keys sorted),
  byte by byte.

The total order is what `order` and indexes use. It never fails: any two
values have an order.

### SQL comparison

Filters use SQL semantics instead:

- Only values of the **same kind** compare: numbers with numbers, strings
  with strings, booleans with booleans. `{"op": "eq", "value": 1}` does not
  match `"1"` nor `true`.
- `null` and missing values compare with nothing: `eq`, `ne`, `lt`, ... are
  all false for them, and so are `eq_any`, `ne_all`, `between`,
  `not_between`, `like`. Only `is_null` and `is_not_null` see them.
- Two arrays, or two objects, compare only when they are equal, and then as
  equal values (`eq`, `ge` and `le` match). When they differ, no comparison
  matches, not even `ne`.
- `not` is two-valued: `not(e)` matches exactly the rows `e` does not. So
  `not(eq(age, 30))` matches rows without `age`, while `ne(age, 30)` does not.

### Keys

Primary keys and index entries are stored as byte keys whose byte order is
the total order above. An engine that stores them must reproduce these rules,
because they decide which values collide:

| Value | Encoding |
|---|---|
| `null` | `0x01` |
| `false` / `true` | `0x02` / `0x03` |
| number | `0x04` + the value as an IEEE 754 double in 8 bytes, sign bit flipped for positives and every bit flipped for negatives, big endian |
| string | `0x05` + UTF-8 bytes, each `0x00` written as `0x00 0xFF`, then `0x00 0x00` |
| array / object | `0x06` / `0x07` + canonical JSON, escaped like a string |

A composite key (an index over several fields) is the concatenation of its
values, and a non-unique index key also ends with the primary key of the row.

- **Keys are at most 511 bytes**, on every platform. A primary key, or an
  index key, over that size fails the write with `KeyTooLarge`. The limit
  does not depend on the page size of the device, so a database written on
  one device can be read on another (see [Compatibility](#compatibility)).
- Numbers are keyed as doubles: integers beyond ±2^53 that round to the same
  double are the **same primary key**. Store such identifiers as strings.
- `1` and `1.0` are the same primary key; the row keeps the form it was
  inserted with.

## Tables

A table is defined with:

```json
{
  "name": "users",
  "primary_key": "id",
  "auto_increment": true,
  "indexes": [
    {"name": "by_city_age", "fields": ["city", "age"], "unique": false},
    {"name": "by_email", "fields": ["email"], "unique": true}
  ]
}
```

- `name`: non-empty, without `:`, and not starting with `__` (reserved for
  the engine). Otherwise `InvalidSchema`.
- `primary_key`: the non-empty path of the field that identifies a row.
- `auto_increment` (default `false`): a row inserted without its primary key
  gets the next integer of the table (1, 2, 3, ...). An integer given
  explicitly moves the sequence forward when it is larger. Numbers are never
  reused after deletes; dropping the table resets the sequence. Only a
  top-level primary key can be generated.
- `indexes` (default `[]`): secondary indexes. Names are unique within the
  table; `fields` is a non-empty list of paths. A `unique` index rejects two
  rows with equal values in its fields (`UniqueViolation`); rows with a
  `null` or missing value among them are exempt, as in SQL.
- `sync` (absent by default): the remote the table synchronizes with, a
  logical name such as `"primary"` (see [Sync](#sync)). A non-empty string;
  an empty one is `InvalidSchema`.

Defining an existing table again with the same primary key and
`auto_increment` adds the new indexes (built over the rows already stored)
and removes the ones no longer listed. Changing the primary key or
`auto_increment` fails with `SchemaMismatch`, and so does changing or
removing the `sync` of a synchronized table (adding it to a local table is
allowed: its existing rows are `unknown`).

## Expressions

A filter is an expression. Every comparison names a path in `field` and
compares it with values as stored (the DSL encodes dates, enums and other
types before sending them).

| `op` | Fields | Matches when the value at `field` |
|---|---|---|
| `eq`, `ne`, `gt`, `ge`, `lt`, `le` | `field`, `value` | compares with `value` as `=`, `<>`, `>`, `>=`, `<`, `<=` |
| `eq_any` | `field`, `values` | equals one of `values` (`IN`) |
| `ne_all` | `field`, `values` | differs from every value in `values` (`NOT IN`) |
| `between` | `field`, `low`, `high` | is `>= low` and `<= high` |
| `not_between` | `field`, `low`, `high` | is `< low` or `> high` |
| `is_null` | `field` | is `null` or missing |
| `is_not_null` | `field` | is present and not `null` |
| `like` | `field`, `pattern` | is a string matching `pattern` |
| `ilike` | `field`, `pattern` | is a string matching `pattern`, ignoring the case of ASCII letters |
| `and` | `args`: expressions | matches every argument (an empty list matches every row) |
| `or` | `args`: expressions | matches some argument (an empty list matches no row) |
| `not` | `arg`: expression | does not match `arg` |

All comparisons follow [SQL comparison](#sql-comparison): a `null`, a missing
value or a value of another kind never matches, not even `ne`, `ne_all` or
`not_between`.

In a `like` pattern, `%` matches any sequence of characters and `_` exactly
one character (a Unicode code point, not a byte). There is no escape
character. `ilike` folds only `A`–`Z`: the string `"AÑO"` matches the
pattern `"a_o"` (`_` takes the `Ñ`), but not `"añ_"`, because `ñ` and `Ñ`
are different characters to it.

```json
{"op": "and", "args": [
  {"op": "eq", "field": "city", "value": "Lima"},
  {"op": "not", "arg": {"op": "is_null", "field": "email"}}
]}
```

### Sort keys

`order` is a list of sort keys, most significant first:

```json
[{"field": "age", "desc": true}, {"field": "name"}]
```

`desc` defaults to `false`. Values sort by the [total order](#kinds), so
`null` and missing values come first ascending and last descending. Rows
that tie on every key come in an unspecified order.

## Statements

A statement is what `execute`, `batch` and `tx_execute` run. Each one reads
or writes one table (`join` reads several) and has one answer shape.

| `op` | Answer |
|---|---|
| `select` | `{"rows": [row, ...]}` |
| `find` | `{"row": row \| null}` |
| `count` | `{"count": n}` |
| `aggregate` | `{"value": v}` |
| `group` | `{"rows": [group row, ...]}` |
| `join` | `{"rows": [combined row, ...]}` |
| `insert`, `update`, `delete` | `{"affected": n, "rows": [...]}` |

A statement on a table that is not defined fails with `TableNotFound`.
Rows are answered as stored.

### `select`

```json
{
  "op": "select",
  "table": "users",
  "filter": {"op": "eq", "field": "city", "value": "Lima"},
  "order": [{"field": "age", "desc": true}],
  "limit": 10,
  "offset": 0,
  "fields": ["name", "address.city"],
  "distinct": true
}
```

Every field but `table` is optional.

- `filter`: the rows returned; every row when absent.
- `order`: sort keys over the stored rows (a sort key need not be in
  `fields`). Without `order`, the order of the rows is unspecified.
- `limit`, `offset`: non-negative integers.
- `fields`: the paths each output row keeps (`SELECT name, address.city`).
  Each output row holds, for every path, the value at that path — `null`
  when missing — placed at the same path: `"address.city"` gives
  `{"address": {"city": "Lima"}}`. A path that is empty, repeated or a prefix
  of another (`"a"` with `"a.b"`) is `InvalidRequest`.
- `distinct` (default `false`): equal output rows are returned once, keeping
  the first in output order. Two rows are equal when their values, in
  `fields` order, have equal [keys](#keys) (so `1` equals `1.0`). Without
  `fields`, whole rows are compared.

Evaluation order: filter → order → projection → distinct → offset → limit.

### `find`

```json
{"op": "find", "table": "users", "key": 1}
```

The row whose primary key equals `key` (by [key](#keys) equality), or
`null`.

### `count`

```json
{"op": "count", "table": "users", "filter": {"op": "is_null", "field": "email"}}
```

The number of rows matching `filter` (every row when absent).

### `aggregate`

```json
{"op": "aggregate", "table": "users", "function": "avg", "field": "age", "filter": {"...": "optional"}}
```

One value over the non-null values at `field` of the matching rows:

| `function` | Value |
|---|---|
| `sum` | the sum of the numbers; integers stay an integer unless the sum overflows a signed 64-bit integer, then it is a double |
| `avg` | the mean of the numbers, as a double |
| `min`, `max` | the smallest or largest value in the [total order](#kinds) |

The value is `null` when no row has a value. `sum` and `avg` ignore values
that are not numbers.

### `group`

```json
{
  "op": "group",
  "table": "users",
  "filter": {"...": "optional"},
  "by": ["city"],
  "aggregates": [
    {"function": "count", "as": "people"},
    {"function": "count", "field": "email", "as": "with_email"},
    {"function": "max", "field": "age", "as": "oldest"}
  ],
  "having": {"op": "ge", "field": "people", "value": 2},
  "order": [{"field": "oldest", "desc": true}],
  "limit": 10,
  "offset": 0
}
```

`GROUP BY`: the rows matching `filter` are grouped by their values at the
`by` paths. Two rows are in the same group when those values have equal
[keys](#keys); a missing value is `null`, and `null` forms a group of its
own, as in SQL.

- Each group gives one output row: the `by` values at their paths (nested
  like `fields` of `select`) plus one top-level field per aggregate, named
  by its `as`.
- `function` is `count`, `sum`, `avg`, `min` or `max`, with the semantics of
  [`aggregate`](#aggregate). `count` without `field` counts the rows of the
  group; with `field`, the rows whose value there is not `null`. The other
  functions need `field`.
- `as` is non-empty, has no `.`, is unique, and differs from the first
  segment of every `by` path. `by` paths and `field` paths are non-empty.
  Anything else is `InvalidRequest`.
- `by` may be empty: then there is one group over all matching rows, and it
  exists even when no row matches (`count` is 0, the other aggregates
  `null`). With a non-empty `by` and no matching row there are no groups.
- `aggregates` may be empty (`SELECT DISTINCT by`).
- `having` is an expression over the output rows: their fields are the `by`
  paths and the aliases.
- Without `order`, groups come in ascending order of the keys of their `by`
  values. With `order`, the sort keys apply to the output rows.

Evaluation order: filter → group → having → order → offset → limit.

### `join`

```json
{
  "op": "join",
  "from": {"table": "users", "as": "u"},
  "joins": [
    {"table": "posts", "as": "p", "kind": "left", "on": {"left": "u.id", "right": "author_id"}}
  ],
  "filter": {"op": "eq", "field": "u.city", "value": "Lima"},
  "order": [{"field": "p.title"}],
  "limit": 10,
  "offset": 0
}
```

Each output row combines one row per table under its alias:
`{"u": {...}, "p": {...}}`.

1. Combined rows start as `{"<from.as>": row}` for every row of `from`, in
   primary key order.
2. Each join, in order, takes each combined row, reads the value at the path
   `on.left` of the combined row, and finds the rows of its table whose value
   at `on.right` is `eq` to it ([SQL comparison](#sql-comparison): `null`
   and missing never match), in primary key order. It emits one combined row
   per match, with `"<as>": row` added.
3. When a combined row has no match, `"kind": "inner"` drops it and
   `"kind": "left"` keeps it once with `"<as>": null`.

- `as` defaults to the table name. Every alias is non-empty, has no `.`, and
  is unique; otherwise `InvalidRequest`. `kind` is `inner` or `left`.
- `filter` and `order` use paths into the combined row (`"u.name"`). Without
  `order`, rows come in the order built above.
- `joins` may be empty: the rows of `from`, each wrapped as `{"u": row}`.
- An engine may find matches through the primary key, an index whose first
  field is `on.right`, or a hash of the joined table; the result is the same.

Evaluation order: build → filter → order → offset → limit.

### `insert`

```json
{"op": "insert", "table": "users", "rows": [{"name": "Ada"}], "on_conflict": "error"}
```

Inserts every row, or none: the first failing row fails the statement.

- `on_conflict` (default `error`) decides what happens when a primary key
  already exists: `error` fails with `DuplicateKey`, `replace` replaces the
  stored row, `ignore` keeps the stored row and skips the new one.
- A row without its primary key fails with `MissingPrimaryKey`, unless the
  table is `auto_increment`.
- A value of a unique index held by another row fails with
  `UniqueViolation`, whatever `on_conflict` says (`replace` frees the values
  of the row it replaces).
- The answer lists the rows written, as stored (with generated keys);
  `affected` is their number, so ignored rows are not counted.

### `update`

```json
{
  "op": "update",
  "table": "posts",
  "filter": {"op": "eq", "field": "author_id", "value": 1},
  "set": {"title": "Updated", "meta.edited": true},
  "increment": {"views": 1, "score": 0.5},
  "expect": 2
}
```

Changes the rows matching `filter` (every row when absent).

- `set` (default `{}`): new values by path. A path through missing objects
  creates them; `null` stores `null`.
- `increment` (default `{}`): numbers added to the current values by path
  (`SET views = views + 1`). A missing or `null` value counts as `0`; any
  other non-number fails with `InvalidRequest` and nothing is written. Two
  integers give an integer (an overflow of a signed 64-bit integer is
  `InvalidRequest`); anything else gives a double, which must be finite
  (JSON has no infinity: a sum that overflows is `InvalidRequest`).
- A path in both `set` and `increment`, or the primary key (or a path under
  it) in either, is `InvalidRequest`.
- `expect`: the statement fails with `AffectedRowsMismatch`, writing
  nothing, unless exactly this many rows match.
- The answer is `{"affected": n, "rows": []}`.

### `delete`

```json
{"op": "delete", "table": "posts", "filter": {"...": "optional"}, "expect": 1}
```

Deletes the rows matching `filter` (every row when absent), with `expect` as
in `update`. The answer is `{"affected": n, "rows": []}`.

## Operations

| `op` | Fields | `ok` payload |
|---|---|---|
| `define_table` | `table`: a [table](#tables) | `{"changed": bool}` |
| `drop_table` | `name` | `{"dropped": bool}` |
| `tables` | — | `{"tables": [table, ...]}` |
| `execute` | `statement` | the answer of the statement |
| `batch` | `statements`: a list | `{"results": [answer, ...]}` |
| `explain` | `query`: a `select` without `op` | `{"plan": plan}` |
| `begin` | `mode`, `timeout_ms` | `{"transaction": id}` |
| `tx_execute` | `transaction`, `statement` | the answer of the statement |
| `savepoint`, `release`, `rollback_to`, `commit`, `rollback` | `transaction` | `{}` |
| `info` | — | `{"protocol": 1, "tables": n, "lmdb": "1.0.2", "map_size": n}` |
| `sync_claim` | `remote`, `max_changes`, `max_bytes`, `lease_ms` | `{"lease_id": n\|null, "envelopes": [envelope, ...]}` |
| `sync_push_result` | `remote`, `lease_id`, `acknowledged`, `rejected` | `{"acknowledged": n, "rejected": n, "released": n, "ignored": [id, ...]}` |
| `sync_release` | `remote`, `lease_id`, `reason` | `{"released": n}` |
| `sync_retry` | `remote`, `mutation_ids` | `{"retried": n}` |
| `sync_apply_remote` | `remote`, `expected_checkpoint`, `next_checkpoint`, `changes` | `{"applied": n, "conflicts": n, "acknowledged": n, "skipped": n}` |
| `sync_resolve` | `conflict`, `expected_row_version`, `resolution` | `{}` |
| `sync_state` | `table`, `key` | `{"state": state\|null}` |
| `sync_pending` | `remote`, `table`, `limit` | `{"count": n, "changes": [change, ...]}` |
| `sync_conflicts` | `remote` | `{"conflicts": [conflict, ...]}` |
| `sync_status` | `remote` | `{"checkpoint": value, "pending": n, "conflicts": n}` |

- `define_table` answers whether anything changed; defining an identical
  table again answers `false`.
- `drop_table` deletes the table with its rows and indexes, and answers
  whether it existed.
- `tables` answers every definition, in name order.
- `execute` runs one statement in its own transaction: a snapshot for reads,
  a write transaction committed on success for writes.
- `batch` runs its statements in order in **one** transaction and answers
  one result per statement. If any fails, nothing is written and the answer
  is that error.
- `explain` answers how the engine would run a query, without running it:

  ```json
  {"table": "users", "access": "index_scan", "index": "by_city_age",
   "descending": false, "presorted": true, "exact": false}
  ```

  `access` is `primary_key_lookup`, `primary_key_range`, `index_scan` or
  `full_scan`; `index` names the index of an `index_scan`; `presorted` means
  the rows come out in the requested order; `exact` means the visited keys
  alone satisfy the filter. Plans are advice for humans: two correct engines
  may choose different plans. An `eq_any` on the primary key or on the
  leading field of an index may be answered with lookups of only the named
  keys (offline_first_core does from 0.7.4).

  Engine extension, not part of the v1 conformance: offline_first_core 0.7.3
  and later also explain a **join** query (a `query` with `from` instead of
  `table`), answering `{"strategy": "hash_join", "tables": [{"table",
  "as", "access"}, ...], "filter": "after_join" | "none"}`. Clients should
  not rely on other engines answering it.
- `info` describes the database: `lmdb` is the storage and its version
  (`"memory"` for `MemoryEngine`), `map_size` the current size of the memory
  map in bytes (0 when nothing is mapped).

## Transactions

`execute` and `batch` are transactions of their own. `begin` opens an
**interactive** transaction that later requests use by its id:

```json
{"v": 1, "op": "begin", "mode": "write", "timeout_ms": 30000}
```

- `mode` (default `write`): `write` reads and writes; `read` is a consistent
  snapshot that runs next to writes and never sees them.
- `timeout_ms` (default 30000): a transaction that receives nothing for
  this long is rolled back, so an abandoned one cannot hold the writer.
  Later requests on it fail with `TransactionExpired`.
- `tx_execute` runs a statement inside it. A write in a `read` transaction
  fails with `ReadOnlyTransaction`, and so do its savepoint operations;
  `commit` and `rollback` both end it.
- There is **one writer at a time** per database. `begin` of a write
  transaction, and a write `execute` or `batch`, wait while another write
  transaction is open. A client that sends every request from one thread
  must not start a second write while its own is open: it would wait for
  itself. The native engine answers `TransactionReentrancy` when it detects
  that; db_dsl's `Database` queues writes so it never happens.
- `commit` makes the writes durable ([durability](#open-options)); `rollback`
  undoes them. After either, the id answers `TransactionClosed`. An id the
  database never gave answers `UnknownTransaction`.

### Savepoints

Savepoints nest inside an interactive transaction:

- `savepoint` opens a level; `release` keeps its writes and closes it;
  `rollback_to` undoes its writes and closes it.
- `release` or `rollback_to` with no level open fails with `NoSavepoint`;
  `commit` with a level open fails with `SavepointOpen`.

### Failed writes

A write statement that fails inside an interactive transaction writes
nothing, and marks the **innermost open level** (the savepoint, or the
transaction itself) as rollback-only. A read that fails marks nothing.

In a rollback-only level:

- every statement, reads included, and `savepoint` fail with
  `TransactionAborted`;
- `rollback_to` undoes the writes of the level and closes it: the level
  around it goes on as it was when the savepoint was opened;
- `release` also undoes the writes and closes the level, but answers
  `TransactionAborted`, so the caller knows they were not kept;
- `commit` of a rollback-only transaction rolls it back and answers
  `TransactionAborted`; the transaction is closed;
- `rollback` always succeeds.

That is how a caller retries a part of its work: open a savepoint before the
part, and `rollback_to` it when a statement fails.

## Sync

A table defined with `sync` records every **effective** write (an insert,
an update that changes the row, a delete) as an immutable *change* in the
same transaction as the row: a statement, a savepoint or a transaction that
fails takes its changes with it, and a committed row always has its change
(RFC-001 §13). Remote changes come back through `sync_apply_remote` and
never produce local changes. The network is the client's; every sync
operation is a short transaction of its own.

**Push.** `sync_claim` leases the next eligible changes of a remote, in
commit order, **one per row**: the first open change of a row that has no
conflict, is not blocked and is not held by a live lease. Each answers an
*envelope*:

```json
{"mutation_id": "…", "table": "notes", "key": "n1", "generation": 1,
 "local_revision": 1, "local_transaction_id": "…", "operation": "upsert",
 "row": {"id": "n1", "title": "Draft"}, "base_version": null,
 "predecessor": null, "attempt": 1}
```

- `mutation_id` is stable: every claim of the change sends the same id and
  the same bytes, so the server deduplicates retries.
- `base_version` is the server version the change builds on (`null` when
  the server never confirmed the row), fixed at the first claim.
- `local_transaction_id` is shared by the changes of one commit; it does
  not ask the server for atomicity.
- `generation` grows when a deleted key is created again.
- `max_bytes` bounds the JSON size of the batch, except that an envelope
  larger than it alone is sent alone. A lease expires after `lease_ms`;
  then the same envelopes can be claimed again.

`sync_push_result` records what the server answered:

- each item of `acknowledged` (`mutation_id`, `table`, `key`,
  `local_revision`, `server_version`) settles **exactly that mutation**: the
  acknowledgement of revision 7 never settles revision 8. It is accepted
  even after the lease expired. One that names an unknown mutation is
  `UnknownMutation`; one whose table, key, revision or remote do not match,
  or of a change never claimed, is `AcknowledgementMismatch`. Either fails
  the whole call, which then changes nothing. A duplicate is answered as
  success and changes nothing.
- each item of `rejected` (`mutation_id`, `reason`, `retryable`) applies
  only while `lease_id` still holds the change: `retryable` makes it pending
  again, otherwise it is blocked until `sync_retry`. Others are listed in
  `ignored`.
- with `lease_id`, the changes of the lease the result leaves out are
  released (pending again).

`sync_release` releases what a lease still holds; a lease that moved on
releases nothing.

**Pull.** `sync_apply_remote` applies a page of remote changes (`table`,
`key`, `operation`: `upsert` or `delete`, `row` for an upsert, whose
primary key must be `key`, `server_version`, and optionally the
`mutation_id` it echoes) and stores `next_checkpoint`, in one transaction:
everything or nothing. The page must have been read after the current
checkpoint (`expected_checkpoint`, `null` before the first page), else
`StaleCheckpoint`. Per change:

1. an echo of an open local mutation that was claimed acknowledges it; an
   echo of a settled one is skipped;
2. a change the row already holds (same `server_version`, nothing pending)
   is skipped;
3. over a pending local change or an open conflict it becomes a
   **conflict**: the local row stays, and the remote variant is kept;
4. otherwise the row takes it (indexes included), without a local change.

**Conflicts.** `sync_conflicts` lists them with the current
`local_row_version`, the local row, the open local mutations, the remote
variant and the `base_version` the local changes built on. `sync_resolve`
takes the row version as precondition (`RowVersionMismatch` when the row
changed since) and refuses while a change of the row is leased
(`MutationInFlight`). The `resolution` is `{"kind": "accept_remote"}` (the
row takes the remote variant; the local changes are settled as resolved,
never as acknowledged), `{"kind": "keep_local"}` (the local row is sent
again on the remote version) or `{"kind": "merged", "row": {...}}`.

**Deletes.** A deleted row leaves a tombstone in the sync records until the
server acknowledged the deletion; creating the key again meanwhile is
`TombstonePending`.

**States.** `sync_state` answers `local_only` (the table is not
synchronized), `unknown` (no evidence of the server state, such as rows
written before the table was synchronized), `pending`, `synced`, `conflict`
or `blocked`, with the revisions: `local_revision`,
`acknowledged_local_revision`, `settled_local_revision` (every revision up
to it is acknowledged or resolved), and `row_version`, which changes with
every change of the local row.

## Errors

| Code | Meaning |
|---|---|
| `TableNotFound` | A statement names a table that is not defined. |
| `InvalidSchema` | A table definition is invalid (empty name, repeated index, ...). |
| `SchemaMismatch` | A table is defined again with another primary key or `auto_increment`. |
| `DuplicateKey` | An insert used a primary key that already exists. |
| `UniqueViolation` | A write would duplicate a value of a unique index. |
| `MissingPrimaryKey` | A row has no primary key and the table does not generate one. |
| `InvalidRequest` | The request does not follow this protocol. |
| `AffectedRowsMismatch` | A write did not match the number of rows in `expect`. |
| `CorruptRecord` | A stored row cannot be decoded. |
| `KeyTooLarge` | A primary key or index key is over 511 bytes. |
| `MapFull` | The database reached its maximum size. |
| `LegacyFormat` | The files were written by LMDB 0.9 (flutter_local_db 1.x, dart_db 0.2); they are left untouched. |
| `StorageError` | The storage reported an error. |
| `IoError` | A file system operation failed. |
| `TransactionClosed` | The transaction was committed or rolled back. |
| `TransactionAborted` | A write failed in this level, which can only be rolled back. |
| `TransactionExpired` | The transaction was rolled back after staying idle too long. |
| `ReadOnlyTransaction` | A write was sent to a `read` transaction. |
| `NoSavepoint` | `release` or `rollback_to` with no savepoint open. |
| `SavepointOpen` | `commit` with a savepoint open. |
| `TransactionReentrancy` | A write would wait for a write transaction of the same thread. |
| `UnknownTransaction` | The transaction id does not belong to this database. |
| `AlreadyOpen` | The files are already open by another engine instance of this process. |
| `Closed` | The database is closed. |
| `SyncNotTracked` | The table (or the remote) of a sync operation is not synchronized. |
| `UnknownMutation` | A sync operation names a mutation the database does not know. |
| `AcknowledgementMismatch` | An acknowledgement does not match its mutation, or the mutation was never claimed. |
| `StaleCheckpoint` | A page was read after another checkpoint than the current one. |
| `ConflictNotFound` | The conflict does not exist, or was resolved. |
| `RowVersionMismatch` | The row changed since the conflict was read. |
| `MutationInFlight` | A change of the row is leased: acknowledge or release it first. |
| `TombstonePending` | The key was deleted and the deletion is not acknowledged yet. |
| `UnsupportedProtocol` | The request speaks another protocol version. |
| `InternalPanic` | The engine failed internally; the process goes on. |

A code never changes its meaning. A client must accept codes it does not
know (a newer engine), treating them as generic failures; db_dsl maps them
to `DbErrorCode.unknown` and keeps the original text in `wireCode`.

## Open options

`ofc_open` takes the options of the database as JSON (or `NULL` for the
defaults). They apply when the files are first opened in the process.

```json
{"max_dbs": 1024, "initial_map_size": 67108864, "max_map_size": 17179869184, "durability": "full"}
```

- `max_dbs` (1024): maximum number of tables plus indexes.
- `initial_map_size` (64 MiB): initial size of the memory map. It is address
  space, not disk: the file grows with the data.
- `max_map_size` (16 GiB, 1 GiB on 32-bit targets): the map doubles when full
  up to this size; beyond it writes fail with `MapFull`.
- `durability` (`full`): how commits reach stable storage.
  - `full`: every commit is flushed before it completes; a committed
    transaction survives a power loss.
  - `no_meta_sync`: data is flushed but the metadata page is not; a system
    crash may undo the last transaction, never corrupt the database.
  - `no_sync`: flushing is left to the operating system; a system crash may
    undo the last transactions. An app crash loses nothing.

## Compatibility

- Version 1 only grows: new operations, new statements and new optional
  fields may appear, always with a default that keeps the old meaning.
  Anything that changes the meaning of an existing request is version 2.
- An engine answers a version it does not speak with `UnsupportedProtocol`,
  so a client can tell an old engine from a bad request.
- The files of the native engine are LMDB 1.0 files, which depend on the
  word size and byte order of the CPU: a database opens on any device with
  the same ones (every 64-bit little-endian target, for instance). Keys
  never depend on the device ([Keys](#keys)).

## Checking an engine

`package:db_dsl/conformance.dart` holds the whole suite as data: each case
opens a fresh database, sends requests through the `Engine` interface, and
checks the answers. It does not depend on any test framework:

```dart
import 'dart:io';

import 'package:db_dsl/conformance.dart';
import 'package:test/test.dart';

void main() {
  final host = ConformanceHost(
    MyEngine(),
    () async => '${Directory.systemTemp.createTempSync().path}/db',
  );

  for (final ConformanceCase(:group, :name, :run) in Conformance.cases) {
    test('$group: $name', () => run(host));
  }
}
```

An engine written in another language needs a thin `Engine` in Dart that
forwards the request text (`ProtocolRequest.toJson`) to it and decodes the
envelope (`ProtocolEnvelope.decode`). `NativeEngine` is exactly that, over
the C functions of [Transport](#transport).

The examples below are part of the suite: it replays them, in order, on a
fresh database, and a test checks that this document shows exactly them. In
an expected answer, `"…"` matches any value, and `"$transaction"` stands for
the id answered by `begin`.

## Examples

A scenario on a fresh database; each request runs on the state the previous
ones left.

<!-- examples:start -->

#### Define a table with a composite index and a unique index

```json
{
  "v": 1,
  "op": "define_table",
  "table": {
    "name": "users",
    "primary_key": "id",
    "auto_increment": true,
    "indexes": [
      {
        "name": "by_city_age",
        "fields": [
          "city",
          "age"
        ],
        "unique": false
      },
      {
        "name": "by_email",
        "fields": [
          "email"
        ],
        "unique": true
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "changed": true
  }
}
```

#### Define a second table

```json
{
  "v": 1,
  "op": "define_table",
  "table": {
    "name": "posts",
    "primary_key": "id",
    "auto_increment": false,
    "indexes": [
      {
        "name": "by_author",
        "fields": [
          "author_id"
        ],
        "unique": false
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "changed": true
  }
}
```

#### Insert rows; the auto-increment key is generated

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "insert",
    "table": "users",
    "on_conflict": "error",
    "rows": [
      {
        "name": "Ada",
        "email": "ada@example.com",
        "city": "Lima",
        "age": 36
      },
      {
        "name": "Grace",
        "email": "grace@example.com",
        "city": "Bogotá",
        "age": 45
      },
      {
        "name": "Linus",
        "email": null,
        "city": "Lima",
        "age": 28
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 3,
    "rows": [
      {
        "name": "Ada",
        "email": "ada@example.com",
        "city": "Lima",
        "age": 36,
        "id": 1
      },
      {
        "name": "Grace",
        "email": "grace@example.com",
        "city": "Bogotá",
        "age": 45,
        "id": 2
      },
      {
        "name": "Linus",
        "email": null,
        "city": "Lima",
        "age": 28,
        "id": 3
      }
    ]
  }
}
```

#### A duplicate value of a unique index fails the whole insert

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "insert",
    "table": "users",
    "rows": [
      {
        "name": "Ada II",
        "email": "ada@example.com",
        "city": "Lima"
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "error": {
    "code": "UniqueViolation",
    "message": "…"
  }
}
```

#### Select with a filter, an order and a limit

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "select",
    "table": "users",
    "filter": {
      "op": "and",
      "args": [
        {
          "op": "eq",
          "field": "city",
          "value": "Lima"
        },
        {
          "op": "gt",
          "field": "age",
          "value": 30
        }
      ]
    },
    "order": [
      {
        "field": "age",
        "desc": true
      }
    ],
    "limit": 10
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "rows": [
      {
        "name": "Ada",
        "email": "ada@example.com",
        "city": "Lima",
        "age": 36,
        "id": 1
      }
    ]
  }
}
```

#### Project two fields, each value once

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "select",
    "table": "users",
    "order": [
      {
        "field": "city",
        "desc": false
      }
    ],
    "fields": [
      "city"
    ],
    "distinct": true
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "rows": [
      {
        "city": "Bogotá"
      },
      {
        "city": "Lima"
      }
    ]
  }
}
```

#### Count and aggregate

```json
{
  "v": 1,
  "op": "batch",
  "statements": [
    {
      "op": "count",
      "table": "users",
      "filter": {
        "op": "is_null",
        "field": "email"
      }
    },
    {
      "op": "aggregate",
      "table": "users",
      "function": "avg",
      "field": "age"
    }
  ]
}
```

```json
{
  "v": 1,
  "ok": {
    "results": [
      {
        "count": 1
      },
      {
        "value": 36.333333333333336
      }
    ]
  }
}
```

#### Group by with aggregates and having

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "group",
    "table": "users",
    "by": [
      "city"
    ],
    "aggregates": [
      {
        "function": "count",
        "as": "people"
      },
      {
        "function": "max",
        "field": "age",
        "as": "oldest"
      }
    ],
    "having": {
      "op": "ge",
      "field": "people",
      "value": 2
    }
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "rows": [
      {
        "city": "Lima",
        "people": 2,
        "oldest": 36
      }
    ]
  }
}
```

#### Insert into the second table

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "insert",
    "table": "posts",
    "rows": [
      {
        "id": "p1",
        "author_id": 1,
        "title": "Types",
        "views": 0
      },
      {
        "id": "p2",
        "author_id": 1,
        "title": "Joins"
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 2,
    "rows": [
      {
        "id": "p1",
        "author_id": 1,
        "title": "Types",
        "views": 0
      },
      {
        "id": "p2",
        "author_id": 1,
        "title": "Joins"
      }
    ]
  }
}
```

#### Left join: every user, with their posts or null

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "join",
    "from": {
      "table": "users",
      "as": "users"
    },
    "joins": [
      {
        "table": "posts",
        "as": "posts",
        "kind": "left",
        "on": {
          "left": "users.id",
          "right": "author_id"
        }
      }
    ],
    "filter": {
      "op": "eq",
      "field": "users.city",
      "value": "Lima"
    },
    "order": [
      {
        "field": "posts.id",
        "desc": false
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "rows": [
      {
        "users": {
          "name": "Linus",
          "email": null,
          "city": "Lima",
          "age": 28,
          "id": 3
        },
        "posts": null
      },
      {
        "users": {
          "name": "Ada",
          "email": "ada@example.com",
          "city": "Lima",
          "age": 36,
          "id": 1
        },
        "posts": {
          "id": "p1",
          "author_id": 1,
          "title": "Types",
          "views": 0
        }
      },
      {
        "users": {
          "name": "Ada",
          "email": "ada@example.com",
          "city": "Lima",
          "age": 36,
          "id": 1
        },
        "posts": {
          "id": "p2",
          "author_id": 1,
          "title": "Joins"
        }
      }
    ]
  }
}
```

#### Update with a counter; a missing value counts as 0

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "update",
    "table": "posts",
    "filter": {
      "op": "eq",
      "field": "author_id",
      "value": 1
    },
    "set": {
      "title": "Updated"
    },
    "increment": {
      "views": 1
    },
    "expect": 2
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 2,
    "rows": []
  }
}
```

#### Begin a write transaction

```json
{
  "v": 1,
  "op": "begin",
  "mode": "write",
  "timeout_ms": 30000
}
```

```json
{
  "v": 1,
  "ok": {
    "transaction": "$transaction"
  }
}
```

#### Write inside the transaction

```json
{
  "v": 1,
  "op": "tx_execute",
  "transaction": "$transaction",
  "statement": {
    "op": "delete",
    "table": "posts",
    "filter": {
      "op": "eq",
      "field": "id",
      "value": "p2"
    }
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 1,
    "rows": []
  }
}
```

#### Open a savepoint

```json
{
  "v": 1,
  "op": "savepoint",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### A failed write inside the savepoint

```json
{
  "v": 1,
  "op": "tx_execute",
  "transaction": "$transaction",
  "statement": {
    "op": "insert",
    "table": "posts",
    "rows": [
      {
        "id": "p1",
        "author_id": 2,
        "title": "Duplicate"
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "error": {
    "code": "DuplicateKey",
    "message": "…"
  }
}
```

#### Roll the savepoint back; the transaction goes on

```json
{
  "v": 1,
  "op": "rollback_to",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### Commit

```json
{
  "v": 1,
  "op": "commit",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### The committed state

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "find",
    "table": "posts",
    "key": "p1"
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "row": {
      "id": "p1",
      "author_id": 1,
      "title": "Updated",
      "views": 1
    }
  }
}
```

#### A closed transaction cannot be used

```json
{
  "v": 1,
  "op": "commit",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "error": {
    "code": "TransactionClosed",
    "message": "…"
  }
}
```

#### Every table definition, in name order

```json
{
  "v": 1,
  "op": "tables"
}
```

```json
{
  "v": 1,
  "ok": {
    "tables": [
      {
        "name": "posts",
        "primary_key": "id",
        "auto_increment": false,
        "indexes": [
          {
            "name": "by_author",
            "fields": [
              "author_id"
            ],
            "unique": false
          }
        ]
      },
      {
        "name": "users",
        "primary_key": "id",
        "auto_increment": true,
        "indexes": [
          {
            "name": "by_city_age",
            "fields": [
              "city",
              "age"
            ],
            "unique": false
          },
          {
            "name": "by_email",
            "fields": [
              "email"
            ],
            "unique": true
          }
        ]
      }
    ]
  }
}
```

#### Explain a query; each engine chooses its own plan

```json
{
  "v": 1,
  "op": "explain",
  "query": {
    "table": "users",
    "filter": {
      "op": "eq",
      "field": "city",
      "value": "Lima"
    }
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "plan": {
      "table": "users",
      "access": "…",
      "index": "…",
      "descending": "…",
      "presorted": "…",
      "exact": "…"
    }
  }
}
```

#### Describe the database

```json
{
  "v": 1,
  "op": "info"
}
```

```json
{
  "v": 1,
  "ok": {
    "protocol": 1,
    "tables": 2,
    "lmdb": "…",
    "map_size": "…"
  }
}
```

#### Begin a read transaction

```json
{
  "v": 1,
  "op": "begin",
  "mode": "read",
  "timeout_ms": 30000
}
```

```json
{
  "v": 1,
  "ok": {
    "transaction": "$transaction"
  }
}
```

#### Read inside it, from its snapshot

```json
{
  "v": 1,
  "op": "tx_execute",
  "transaction": "$transaction",
  "statement": {
    "op": "count",
    "table": "users"
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "count": 3
  }
}
```

#### A read transaction refuses writes

```json
{
  "v": 1,
  "op": "tx_execute",
  "transaction": "$transaction",
  "statement": {
    "op": "delete",
    "table": "users"
  }
}
```

```json
{
  "v": 1,
  "error": {
    "code": "ReadOnlyTransaction",
    "message": "…"
  }
}
```

#### End it

```json
{
  "v": 1,
  "op": "rollback",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### Begin another write transaction

```json
{
  "v": 1,
  "op": "begin",
  "mode": "write",
  "timeout_ms": 30000
}
```

```json
{
  "v": 1,
  "ok": {
    "transaction": "$transaction"
  }
}
```

#### Open a savepoint in it

```json
{
  "v": 1,
  "op": "savepoint",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### Write inside the savepoint

```json
{
  "v": 1,
  "op": "tx_execute",
  "transaction": "$transaction",
  "statement": {
    "op": "insert",
    "table": "posts",
    "rows": [
      {
        "id": "p9",
        "author_id": 1,
        "title": "Kept"
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 1,
    "rows": [
      {
        "id": "p9",
        "author_id": 1,
        "title": "Kept"
      }
    ]
  }
}
```

#### Release the savepoint; its write stays in the transaction

```json
{
  "v": 1,
  "op": "release",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### Roll the whole transaction back

```json
{
  "v": 1,
  "op": "rollback",
  "transaction": "$transaction"
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### Nothing of a rolled back transaction is stored

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "find",
    "table": "posts",
    "key": "p9"
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "row": null
  }
}
```

#### Drop a table with its rows and indexes

```json
{
  "v": 1,
  "op": "drop_table",
  "name": "posts"
}
```

```json
{
  "v": 1,
  "ok": {
    "dropped": true
  }
}
```

#### Dropping it again answers false

```json
{
  "v": 1,
  "op": "drop_table",
  "name": "posts"
}
```

```json
{
  "v": 1,
  "ok": {
    "dropped": false
  }
}
```

#### Define a synchronized table: every write records a change

```json
{
  "v": 1,
  "op": "define_table",
  "table": {
    "name": "notes",
    "primary_key": "id",
    "auto_increment": false,
    "indexes": [],
    "sync": "primary"
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "changed": true
  }
}
```

#### Write to it as to any table

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "insert",
    "table": "notes",
    "rows": [
      {
        "id": "n1",
        "title": "Draft"
      }
    ]
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 1,
    "rows": [
      {
        "id": "n1",
        "title": "Draft"
      }
    ]
  }
}
```

#### The change is pending, committed with the row

```json
{
  "v": 1,
  "op": "sync_status",
  "remote": "primary"
}
```

```json
{
  "v": 1,
  "ok": {
    "checkpoint": null,
    "pending": 1,
    "conflicts": 0
  }
}
```

#### Claim a batch to push: a lease and immutable envelopes

```json
{
  "v": 1,
  "op": "sync_claim",
  "remote": "primary",
  "max_changes": 10,
  "max_bytes": null,
  "lease_ms": 30000
}
```

```json
{
  "v": 1,
  "ok": {
    "lease_id": "$lease",
    "envelopes": [
      {
        "mutation_id": "$mutation",
        "table": "notes",
        "key": "n1",
        "generation": 1,
        "local_revision": 1,
        "local_transaction_id": "…",
        "operation": "upsert",
        "row": {
          "id": "n1",
          "title": "Draft"
        },
        "base_version": null,
        "predecessor": null,
        "attempt": 1
      }
    ]
  }
}
```

#### List the open changes

```json
{
  "v": 1,
  "op": "sync_pending",
  "remote": "primary",
  "table": null,
  "limit": null
}
```

```json
{
  "v": 1,
  "ok": {
    "count": 1,
    "changes": [
      {
        "mutation_id": "$mutation",
        "table": "notes",
        "key": "n1",
        "local_revision": 1,
        "operation": "upsert",
        "state": "leased",
        "attempts": 1,
        "last_error": null
      }
    ]
  }
}
```

#### Record what the server stored: one mutation and revision

```json
{
  "v": 1,
  "op": "sync_push_result",
  "remote": "primary",
  "lease_id": "$lease",
  "acknowledged": [
    {
      "mutation_id": "$mutation",
      "table": "notes",
      "key": "n1",
      "local_revision": 1,
      "server_version": "v1"
    }
  ],
  "rejected": []
}
```

```json
{
  "v": 1,
  "ok": {
    "acknowledged": 1,
    "rejected": 0,
    "released": 0,
    "ignored": []
  }
}
```

#### A duplicate acknowledgement changes nothing

```json
{
  "v": 1,
  "op": "sync_push_result",
  "remote": "primary",
  "lease_id": null,
  "acknowledged": [
    {
      "mutation_id": "$mutation",
      "table": "notes",
      "key": "n1",
      "local_revision": 1,
      "server_version": "v1"
    }
  ],
  "rejected": []
}
```

```json
{
  "v": 1,
  "ok": {
    "acknowledged": 0,
    "rejected": 0,
    "released": 0,
    "ignored": []
  }
}
```

#### The row is synchronized

```json
{
  "v": 1,
  "op": "sync_state",
  "table": "notes",
  "key": "n1"
}
```

```json
{
  "v": 1,
  "ok": {
    "state": {
      "state": "synced",
      "deleted": false,
      "sending": false,
      "attempts": 0,
      "last_error": null,
      "pending": 0,
      "local_revision": 1,
      "acknowledged_local_revision": 1,
      "settled_local_revision": 1,
      "row_version": 1,
      "server_version": "v1",
      "conflict": null
    }
  }
}
```

#### Edit it locally

```json
{
  "v": 1,
  "op": "execute",
  "statement": {
    "op": "update",
    "table": "notes",
    "filter": {
      "op": "eq",
      "field": "id",
      "value": "n1"
    },
    "set": {
      "title": "Edited"
    }
  }
}
```

```json
{
  "v": 1,
  "ok": {
    "affected": 1,
    "rows": []
  }
}
```

#### A server change over the pending edit becomes a conflict

```json
{
  "v": 1,
  "op": "sync_apply_remote",
  "remote": "primary",
  "expected_checkpoint": null,
  "next_checkpoint": "c1",
  "changes": [
    {
      "table": "notes",
      "key": "n1",
      "operation": "upsert",
      "row": {
        "id": "n1",
        "title": "Remote"
      },
      "server_version": "v2",
      "mutation_id": null
    }
  ]
}
```

```json
{
  "v": 1,
  "ok": {
    "applied": 0,
    "conflicts": 1,
    "acknowledged": 0,
    "skipped": 0
  }
}
```

#### The conflict keeps both variants

```json
{
  "v": 1,
  "op": "sync_conflicts",
  "remote": "primary"
}
```

```json
{
  "v": 1,
  "ok": {
    "conflicts": [
      {
        "id": "$conflict",
        "table": "notes",
        "key": "n1",
        "local_row_version": 2,
        "local_row": {
          "id": "n1",
          "title": "Edited"
        },
        "outstanding": [
          "…"
        ],
        "remote_version": "v2",
        "remote_operation": "upsert",
        "remote_row": {
          "id": "n1",
          "title": "Remote"
        },
        "base_version": "v1"
      }
    ]
  }
}
```

#### A resolution on an old row version is refused

```json
{
  "v": 1,
  "op": "sync_resolve",
  "conflict": "$conflict",
  "expected_row_version": 1,
  "resolution": {
    "kind": "accept_remote"
  }
}
```

```json
{
  "v": 1,
  "error": {
    "code": "RowVersionMismatch",
    "message": "…"
  }
}
```

#### Accept the server variant

```json
{
  "v": 1,
  "op": "sync_resolve",
  "conflict": "$conflict",
  "expected_row_version": 2,
  "resolution": {
    "kind": "accept_remote"
  }
}
```

```json
{
  "v": 1,
  "ok": {}
}
```

#### A page read after an old checkpoint is refused

```json
{
  "v": 1,
  "op": "sync_apply_remote",
  "remote": "primary",
  "expected_checkpoint": null,
  "next_checkpoint": "c2",
  "changes": []
}
```

```json
{
  "v": 1,
  "error": {
    "code": "StaleCheckpoint",
    "message": "…"
  }
}
```

#### Releasing a lease that holds nothing releases nothing

```json
{
  "v": 1,
  "op": "sync_release",
  "remote": "primary",
  "lease_id": "$lease",
  "reason": "timeout"
}
```

```json
{
  "v": 1,
  "ok": {
    "released": 0
  }
}
```

#### Retrying a settled mutation retries nothing

```json
{
  "v": 1,
  "op": "sync_retry",
  "remote": "primary",
  "mutation_ids": [
    "$mutation"
  ]
}
```

```json
{
  "v": 1,
  "ok": {
    "retried": 0
  }
}
```

#### An acknowledgement of an unknown mutation is refused

```json
{
  "v": 1,
  "op": "sync_push_result",
  "remote": "primary",
  "lease_id": null,
  "acknowledged": [
    {
      "mutation_id": "nobody-1",
      "table": "notes",
      "key": "n1",
      "local_revision": 1,
      "server_version": "v9"
    }
  ],
  "rejected": []
}
```

```json
{
  "v": 1,
  "error": {
    "code": "UnknownMutation",
    "message": "…"
  }
}
```

#### Everything is settled, at the checkpoint of the last page

```json
{
  "v": 1,
  "op": "sync_status",
  "remote": "primary"
}
```

```json
{
  "v": 1,
  "ok": {
    "checkpoint": "c1",
    "pending": 0,
    "conflicts": 0
  }
}
```

#### Another protocol version is refused

```json
{
  "v": 2,
  "op": "tables"
}
```

```json
{
  "v": 1,
  "error": {
    "code": "UnsupportedProtocol",
    "message": "…"
  }
}
```

<!-- examples:end -->
