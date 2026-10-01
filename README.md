# db_dsl

A Diesel-style query language for Dart that stores the models your app
already has. Your model carries its table in one line, queries use Diesel's
vocabulary (`filter`, `order`, `group_by`, `inner_join`, `insert`,
`update().set()`, `transaction`), and they run when awaited. Every
operation answers a `Result`: `Ok` with the value, or `Err` with a typed
`DbError`.

```dart
final t = User.table;

await t.insert([ada, grace]);

final adults = await t
    .filter(t.city.eq('Lima').and(t.age.gt(30)))
    .order(t.age.desc())
    .limit(20); // Result<List<User>, DbError>
```

No code generation, no macros, no table classes: `User` is the class your
app already uses (for example, the one it decodes from an API), with its
`fromJson` and `toJson`. The typed fields (`t.city`, `t.age`) are plain
code that the [db_dsl_lints](#the-analyzer-plugin) plugin writes from the
model and checks as you type.

db_dsl is pure Dart: it runs on servers, in Flutter apps and on the web. It
brings no native binary. The packages that store data bring theirs:

```
                 db_dsl  (tables, queries, transactions, PROTOCOL.md)
                    │
        ┌───────────┼──────────────────┬───────────────────┐
        │           │                  │                   │
  flutter_local_db  dart_db        MemoryEngine        your engine
  (apps: Android,   (servers:      (tests, no          (any language that
   iOS, macOS,       Linux, macOS,  binary)             answers the protocol)
   Linux, Windows)   Windows)
        │           │
        └─────┬─────┘
       offline_first_core (Rust + LMDB 1.0)
```

| You are writing | Use |
|---|---|
| A Flutter app | [flutter_local_db](https://pub.dev/packages/flutter_local_db) — it re-exports db_dsl |
| A Dart server or CLI | [dart_db](https://pub.dev/packages/dart_db) — it re-exports db_dsl |
| Tests of code that uses either | db_dsl's `MemoryEngine` |
| An engine or a translator | [PROTOCOL.md](PROTOCOL.md) and the conformance suite |

## Tables from your models

```dart
final class User {
  const User({this.id, required this.name, required this.city, required this.age});

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as int?,
    name: json['name'] as String,
    city: json['city'] as String,
    age: json['age'] as int,
  );

  // The table of this model: its name, its key and how to read a row.
  static final table = DbTable<User>(
    'users',
    key: 'id',
    fromJson: User.fromJson,
    autoIncrement: true,                 // optional: rows without an id get one
    indexes: [Index(['city', 'age'])],  // optional
  );

  final int? id;
  final String name;
  final String city;
  final int age;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'city': city, 'age': age};
}
```

- **The table lives in the model, as a `static`.** Dart has no static
  inheritance, and a query has no instance to inherit from, so a `static`
  on the class is the closest to "the class is the table" — and it is not a
  global.
- **`fromJson` is the one thing a table needs.** It is a constructor, and
  Dart can neither require a constructor of a type nor call one through a
  type parameter, so it is passed once.
- **`toJson` is implicit.** A row is stored as your model writes itself:
  its `toJson()`, the method `jsonEncode` uses. Nested values it leaves as
  objects (another model with its own `toJson`, a `DateTime`, an enum, a
  list) are converted the same way. Only when your model names it
  otherwise do you pass it: `toJson: (user) => user.toMap()`.
- A row that has no JSON form answers `Err(DbErrorCode.rowMapping)`; it
  never throws.
- Indexes are named after their fields (`by_city_age`, or
  `Index.unique(['email'])` → `unique_email`), or with `name:`.

Tables are not listed anywhere. Open the database once; each table defines
itself there the first time it is used — created if new, new indexes built
over existing rows, removed ones dropped — and its queries run there from
then on:

```dart
await Database.open(MemoryEngine(), path: 'blog');

await User.table.insert([ada]); // defines `users`, then inserts
```

With flutter_local_db it is `LocalDB.init()`, and with dart_db
`DartDb.open(path)`; everything else on this page is the same.

- **The default database is the first one opened**, until it closes. A
  table defines itself on it.
- **Concurrent first uses define a table once.**
- **A table first used inside a transaction answers
  `Err(DbErrorCode.tableNotReady)`** instead of waiting forever: defining
  needs the database to itself, which the transaction holds. Use the table
  once before, or list it when opening — `tables:` (`LocalDB.init(tables:
  [...])`, `DartDb.open(path, tables: [...])`) defines tables up front,
  which also builds their indexes at start-up.

## Typed fields

A query names a field as a getter of its table, with the type the model
stores:

```dart
extension UserFields on DbTable<User> {
  /// The stored `id`.
  Field<int> get id => field('id');

  /// The stored `name`.
  Field<String> get name => field('name');

  /// The stored `city`.
  Field<String> get city => field('city');

  /// The stored `age`.
  Field<int> get age => field('age');
}

final t = User.table;
await t.filter(t.city.eq('Lima').and(t.age.gt(30)));

t.cty;        // does not compile
t.age.eq('1') // does not compile: Field<int>.eq(int)
```

**Nobody types this extension.** A getter cannot come out of `User` itself
— `user.age` is an `int`, which does not remember which field it came from,
and Diesel declares its columns apart for the same reason — but the
[analyzer plugin](#the-analyzer-plugin) writes it from the model's
`toJson` with one quick fix, and writes it again when the model changes.
It is ordinary code in your file: no `build_runner`, no `.g.dart`.

A field is a path in the stored rows, compared as values of a Dart type.
`field<V>(path)` is the building block of those getters, and works on its
own too:

```dart
final zip = users.field<String>('address.zip');      // a nested value
final status = members.field<Status>('status');      // an enum
final joined = members.field<DateTime>('joined');
```

A value is compared in the form your model stores it, by the same Dart JSON
convention: strings, numbers and booleans as they are, a `DateTime` as ISO
8601 (`toIso8601String`), an enum by its `name`, any other object through
its `toJson()`. A model that stores a value another way says how:

```dart
final price = products.field<Money>(
  'price',
  encode: (money) => money.cents,           // how the model stores it
  decode: (stored) => Money(stored as int), // for pluck, min, max, group keys
);

await products.filter(price.gt(const Money(1000)));
```

ISO 8601 dates sort correctly when they are all UTC with the same precision;
store `toUtc()` dates, or numbers, when you sort or range over them.

## The analyzer plugin

[db_dsl_lints](https://pub.dev/packages/db_dsl_lints) reads each model's
`toJson` (a map literal, or json_serializable's generated `_$UserToJson`)
and checks every table against it, in the IDE and in `dart analyze` (which
works in Flutter projects too; `flutter analyze` does not report plugin
diagnostics yet). Enable it in `analysis_options.yaml` (no dependency in
`pubspec.yaml`), then restart the analysis server:

```yaml
plugins:
  db_dsl_lints: ^0.1.0
```

| Diagnostic | When | Quick fix |
|---|---|---|
| `missing_query_fields` (warning) | the model stores fields its table does not expose yet: no `UserFields` extension, or the model gained a field | *Write the query fields from the model* |
| `unknown_field` (error) | `field('cty')` or `Index(['cty'])` names a field the model does not store — also after renaming a field of the model | *Use 'city'*, or *Write the query fields from the model* |
| `field_type_mismatch` (error) | `Field<String> get age => field('age')` while the model stores an `int` | *Use Field<int>* |
| `unknown_key` (error) | the table's `key:` is not a stored field | *Use 'id'* |

The assist *Write the query fields of the table* (on `DbTable<User>(...)`
or on its extension) writes the same extension on demand. A `DateTime`
stored as epoch milliseconds or microseconds gets its `encode` and
`decode`; a field with its own `encode`/`decode` is not type-checked.

When a model's `toJson` is built at run time (`Map.of(values)`), the plugin
cannot read it and reports nothing: never a false positive. Plugin fixes
run from the IDE; `dart fix` does not apply them yet (a limit of Dart's
plugin system), which is why a model change is a warning you see right
away.

## Queries

Awaiting a query runs it: there is no `execute()` to call. It runs on the
database that opened the table, or on the transaction around it.

| Diesel | db_dsl |
|---|---|
| `users.filter(...)`, `.or_filter(...)` | `users.filter(...)`, `.orFilter(...)` |
| `.eq`, `.ne`, `.gt`, `.ge`, `.lt`, `.le` | same names |
| `.eq_any`, `.ne_all`, `.between`, `.like`, `.ilike`, `.is_null` | `eqAny`, `neAll`, `between`, `notBetween`, `like`, `ilike`, `isNull`, `isNotNull` |
| `.and(...)`, `.or(...)`, `not(...)` | `.and(...)`, `.or(...)`, `.not()` |
| `.order(...)`, `.then_order_by(...)` | `.order(field.desc())`, `.thenOrderBy(...)` |
| `.limit(n)`, `.offset(n)` | same |
| `.load(conn)`, `.first(conn)`, `.count()`, `exists` | `await query`, `.first()`, `.count()`, `.exists()` |
| `users.find(id).first(conn)` | `await users.find(id)` |
| `.select(col)`, `.select((a, b))`, `.distinct()` | `.pluck(field)`, `.project([a, b])`, `.distinct()` |
| `sum`, `avg`, `min`, `max` | `.sum(field)`, `.avg(field)`, `.min(field)`, `.max(field)` |
| `.group_by(...)`, `.having(...)` | `.groupBy([...]).count('n').max(field, 'oldest').having(...)` |
| `.inner_join(...)`, `.left_join(...)` | `.innerJoin(t, on: a, equals: b)`, `.leftJoin(...)` |
| `belonging_to`, `grouped_by` | `posts.belongingTo(ids, authorId)`, `Associations.groupedBy(...)` |

```dart
// GROUP BY city HAVING COUNT(*) >= 2
const people = Field<int>('people');
final cities = await users
    .groupBy([users.city])
    .count('people')
    .max(users.age, 'oldest')
    .having(people.ge(2)); // Result<List<GroupRow>, DbError>

// LEFT JOIN posts ON posts.author_id = users.id
final rows = await users
    .leftJoin(posts, on: users.id, equals: posts.authorId)
    .order(users.name.asc()); // Result<List<JoinRow>, DbError>
// row.of(users) is the user; row.maybe(posts) is null without a post.
```

Filters follow SQL: a `null` or missing value matches no comparison, and
values of different kinds never compare. `explain` shows whether a query
uses an index:

```dart
final plan = await users.filter(users.city.eq('Lima')).explain();
// offline_first_core: access index_scan over by_city_age.
// MemoryEngine always answers full_scan: it does not emulate the planner.
```

## Many-to-many

A `Relation` links the rows of two tables through a bridge table of its
own, one row per linked pair, keyed by the pair:

```dart
final skillsOf = Relation<Person, Skill>('people_skills', from: Person.table, to: Skill.table);

await skillsOf.attach(ada, dart);              // 1; 0 when already linked
await skillsOf.targetsOf(ada);                 // Result<List<Skill>, DbError>
await skillsOf.sourcesOf(dart);                // Result<List<Person>, DbError>
await skillsOf.detach(ada, dart);              // the rows stay
```

Both directions read only the neighbours of a row: an index on each side
of the bridge, then primary key lookups. Links are ordinary rows, so they
commit or roll back with the transaction they are awaited in. A row
without its key (not stored yet) answers `missingPrimaryKey`.

## Writes

```dart
await users.insert([ada, grace]);                  // affected rows
await users.insert([ada]).getResults();            // rows with their generated ids
await users.insert([ada]).onConflictReplace();
await users.insert([ada]).onConflictDoNothing();

await posts
    .update()
    .filter(posts.id.eq('p1'))
    .set(posts.title, 'Typed tables')
    .increment(posts.views, 1)                     // views = views + 1
    .expectAffectedRows(1);                        // or nothing is written

await posts.delete().filter(posts.authorId.eq(3));

await db.atomicBatch([insertA, updateB, deleteC]); // all or nothing
```

Every statement is atomic: an insert of ten rows with one duplicate writes
none of them.

## Transactions

```dart
final result = await db.transaction<bool>((tx) async {
  // Awaited inside the transaction, so it runs on it.
  final renamed = await posts.update().filter(posts.id.eq('p1')).set(posts.title, 'Typed tables');

  if (renamed case Err(:final error)) {
    return Err(error); // the whole transaction rolls back
  }

  // A savepoint: when it fails, only its own writes are undone.
  final copied = await tx.savepoint((_) => posts.insert([draft]));

  return Ok(copied.isOk);
});
```

- `transaction` commits when the body answers `Ok` and rolls back on `Err`.
- `readTransaction` gives a consistent snapshot that runs next to writes.
- One write transaction at a time; other writes of the database wait for it.
- A table used there for the first time answers `tableNotReady` (see
  [Tables from your models](#tables-from-your-models)).
- A transaction left idle for 30 seconds (`idleTimeout`) is rolled back.

## Another database

A table belongs to the first open database that defined it; when that
database closes, the next one to define the table takes it. Another database
of the same app is the exception, and is always named:

```dart
await users.all().load(archive);
await users.insert([ada]).execute(archive);
```

A query awaited while no database is open answers `Err` with
`DbErrorCode.notOpen`.

## Reactive queries

```dart
users.filter(users.city.eq('Lima')).watch().listen((result) {
  // the rows now, and again after each committed write to `users`
});
```

## Errors

`DbError` is a sealed family, grouped by how a caller reacts:

```dart
final message = switch (error) {
  ConstraintError() => 'That value already exists',   // duplicate key, unique index
  TransactionError() => 'Try again',                  // closed, aborted, expired
  SchemaError() => 'Bug: $error',                     // unknown table, row mapping, table not ready
  StorageError() => 'Storage problem: $error',        // full, corrupt, legacy format
  EngineError() => 'Engine problem: $error',          // missing or failed engine
};
```

`error.code` (`DbErrorCode`) names the exact cause; code reacts to it, never
to `error.message`.

## How it works

```
users.filter(users.city.eq('Lima'))   a builder: nothing runs yet
        │  await
        ▼
the executor                          the transaction of the current zone,
                                      else the table's database, else the
                                      default one (defining the table first)
        │
        ▼
Statement ──► JSON request            protocol v1 (PROTOCOL.md)
        │
        ▼
EngineConnection.send                 NativeEngine: FFI calls on a worker isolate
                                      MemoryEngine: the same semantics in Dart
        │
        ▼
JSON response ──► Result              rows through fromJson; errors as DbError
```

- **A query is a value until it is awaited.** Builders (`filter`, `order`,
  `insert`, `update().set()`…) only describe the statement. Each implements
  `Future<Result<…>>`, so `await` is what sends it.
- **Rows are your models' JSON.** A row is written as `toJson()` writes it
  (nested objects, dates and enums converted by Dart's JSON convention) and
  read back with the table's `fromJson`. A field compares values in that same
  stored form.
- **Choosing where a query runs.** An explicit database (`load(other)`,
  `execute(other)`) wins. Otherwise a query awaited inside a transaction body
  runs on that transaction (the body runs in a zone that carries it), and
  any other query runs on the database that holds its table. A table that no
  database holds yet defines itself on the default database (the first one
  opened) and stays there; concurrent first uses wait for one definition.
- **One writer at a time.** Each `Database` queues its writes in Dart, so a
  write sent while a transaction is open waits its turn instead of blocking
  the engine; reads do not queue.
- **Transactions** begin on the engine, send their statements with the
  transaction's id, and commit when the body answers `Ok` (rollback on
  `Err`). A savepoint is a nested level of the same transaction. One that
  receives nothing for 30 seconds (`idleTimeout`) is rolled back by the
  engine.
- **`watch`** listens to the tables each committed write touched and reloads
  the query; a burst of commits while a reload is in flight causes one more
  reload, not one per commit.
- **The native engine** runs every FFI call on a worker isolate, one per
  native library in each isolate that uses it, so a durable commit never
  blocks the caller's isolate (the UI, in an app). Isolates that open the
  same path share the process's one LMDB environment. A worker stops when
  its last database closes and no call is pending, so a program that closes
  its databases ends by itself.

## Using it well

- **Open the database once, at start-up, and keep it open.** The first one
  opened is the default one, where tables define themselves.
- **Let the analyzer plugin write the fields**, and run `dart analyze` in CI
  (also in Flutter projects; `flutter analyze` does not report plugin
  diagnostics yet).
- **Use a table once before its first transaction**, or list it when
  opening (`tables:`): a first use inside a transaction answers
  `tableNotReady`.
- **Await queries inside the transaction body.** Using the database itself
  there would wait for its own transaction, so it answers
  `transactionReentrancy`; keep the body short (it is rolled back after 30
  seconds of inactivity).
- **Group writes**: one transaction or `atomicBatch` instead of one durable
  commit per row.
- **Declare an index for each filter or order you run on a large table**,
  and check it with `explain()`; a `full_scan` reads every row.
- **Write `order` whenever order matters**: without it, the order of the
  rows is unspecified, as in SQL.
- **Store dates in UTC** (`toUtc()`), or as numbers, if you sort or range
  over them.
- **Switch on the sealed `DbError`** and on `error.code`, never on
  `error.message`.
- **Test on `MemoryEngine`**, and close each test's database in `tearDown`
  so the next test's database becomes the default one.

## Testing with MemoryEngine

`MemoryEngine` keeps every database in memory with the semantics of the
native engine — byte-ordered keys like LMDB, the same comparison and
ordering rules, transactions, savepoints and errors — and passes the same
conformance suite. Tests of code built on flutter_local_db or dart_db can
run on it without any binary:

```dart
late Database db;

setUp(() async {
  db = (await Database.open(MemoryEngine(), path: 'test'))
      .when(ok: (db) => db, err: (error) => fail('$error'));
});

// Closing gives the tables back and stops being the default database, so
// the next test's database takes them.
tearDown(() => db.close());

test('adults', () async {
  final users = User.table;
  await users.insert([ada, linus]);
  final adults = await users.filter(users.age.ge(18));
  // ...
});
```

## The protocol

Everything db_dsl sends is one JSON request, and everything it reads is one
JSON response. [PROTOCOL.md](PROTOCOL.md) specifies all of it: values and
key encoding, tables, expressions, every statement, transactions, errors and
open options, with a replayable example scenario. With it you can:

- write an engine in another language, and check it with
  `package:db_dsl/conformance.dart` (every case runs against any `Engine`);
- write a translator that builds these requests from another language and
  sends them to offline_first_core.

The examples in PROTOCOL.md are data in the conformance suite: every engine
replays them, and a test keeps the document equal to them.

## Status

db_dsl stays in **0.2.x**: releases add and fix, and never break code
written against 0.2. The protocol is version 1 and only grows (see
"Compatibility" in PROTOCOL.md).

## License

[Apache License 2.0](LICENSE). Redistributions must keep the [NOTICE](NOTICE)
file, which credits JhonaCodes as the author.
