# db_dsl

A Diesel-style query language for Dart that stores the models your app
already has. Declare a table in one line from your model, build queries
with Diesel's vocabulary (`filter`, `order`, `group_by`, `inner_join`,
`insert`, `update().set()`, `transaction`), and await them. Every operation
answers a `Result`: `Ok` with the value, or `Err` with a typed `DbError`.

```dart
final users = DbTable<User>('users', key: 'id', fromJson: User.fromJson);

await users.insert([ada, grace]);

final adults = await users
    .filter(users.field<String>('city').eq('Lima'))
    .order(users.field<int>('age').desc())
    .limit(20); // Result<List<User>, DbError>
```

No code generation, no macros, no table classes: `User` is the class your
app already uses (for example, the one it decodes from an API), with its
`fromJson` and `toJson`.

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

  final int? id;
  final String name;
  final String city;
  final int age;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'city': city, 'age': age};
}

final users = DbTable<User>(
  'users',
  key: 'id',
  fromJson: User.fromJson,
  autoIncrement: true,                 // optional: rows without an id get one
  indexes: [Index(['city', 'age'])],  // optional
);
```

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

Opening a database defines its tables: new ones are created, new indexes
are built over existing rows, and removed indexes are dropped. From then on
the tables belong to that database, and their queries run there when
awaited.

```dart
final opened = await Database.open(MemoryEngine(), path: 'blog', tables: [users, posts]);
```

With flutter_local_db it is `LocalDB.init(tables: [...])`, and with dart_db
`DartDb.open(path, tables: [...])`; everything else on this page is the
same.

## Fields of any type

A field is a path in the stored rows, compared as values of a Dart type:

```dart
final city = users.field<String>('city');
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

Typing the field names once is optional sugar, not a requirement:

```dart
extension UserFields on DbTable<User> {
  Field<String> get city => field('city');
  Field<int> get age => field('age');
}

await users.filter(users.city.eq('Lima').and(users.age.gt(30)));
```

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
    .groupBy([city])
    .count('people')
    .max(age, 'oldest')
    .having(people.ge(2)); // Result<List<GroupRow>, DbError>

// LEFT JOIN posts ON posts.author_id = users.id
final rows = await users
    .leftJoin(posts, on: users.field<int>('id'), equals: posts.field<int>('author_id'))
    .order(users.field<String>('name').asc()); // Result<List<JoinRow>, DbError>
// row.of(users) is the user; row.maybe(posts) is null without a post.
```

Filters follow SQL: a `null` or missing value matches no comparison, and
values of different kinds never compare. `explain` shows whether a query
uses an index:

```dart
final plan = await users.filter(city.eq('Lima')).explain();
// offline_first_core: access index_scan over by_city_age.
// MemoryEngine always answers full_scan: it does not emulate the planner.
```

## Writes

```dart
await users.insert([ada, grace]);                  // affected rows
await users.insert([ada]).getResults();            // rows with their generated ids
await users.insert([ada]).onConflictReplace();
await users.insert([ada]).onConflictDoNothing();

await posts
    .update()
    .filter(postId.eq('p1'))
    .set(title, 'Typed tables')
    .increment(views, 1)                           // views = views + 1
    .expectAffectedRows(1);                        // or nothing is written

await posts.delete().filter(authorId.eq(3));

await db.atomicBatch([insertA, updateB, deleteC]); // all or nothing
```

Every statement is atomic: an insert of ten rows with one duplicate writes
none of them.

## Transactions

```dart
final result = await db.transaction<bool>((tx) async {
  // Awaited inside the transaction, so it runs on it.
  final renamed = await posts.update().filter(postId.eq('p1')).set(title, 'Typed tables');

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
- A transaction left idle for 30 seconds (`idleTimeout`) is rolled back.

## Another database

A table belongs to the first open database that defined it; when that
database closes, the next one to define the table takes it. Another database
of the same app is the exception, and is always named:

```dart
await users.all().load(archive);
await users.insert([ada]).execute(archive);
```

A query of a table that belongs to no database answers `Err` with
`DbErrorCode.notOpen`.

## Reactive queries

```dart
users.filter(city.eq('Lima')).watch().listen((result) {
  // the rows now, and again after each committed write to `users`
});
```

## Errors

`DbError` is a sealed family, grouped by how a caller reacts:

```dart
final message = switch (error) {
  ConstraintError() => 'That value already exists',   // duplicate key, unique index
  TransactionError() => 'Try again',                  // closed, aborted, expired
  SchemaError() => 'Bug: $error',                     // unknown table, row mapping
  StorageError() => 'Storage problem: $error',        // full, corrupt, legacy format
  EngineError() => 'Engine problem: $error',          // missing or failed engine
};
```

`error.code` (`DbErrorCode`) names the exact cause; code reacts to it, never
to `error.message`.

## Testing with MemoryEngine

`MemoryEngine` keeps every database in memory with the semantics of the
native engine — byte-ordered keys like LMDB, the same comparison and
ordering rules, transactions, savepoints and errors — and passes the same
conformance suite. Tests of code built on flutter_local_db or dart_db can
run on it without any binary:

```dart
late Database db;

setUp(() async {
  db = (await Database.open(MemoryEngine(), path: 'test', tables: [users]))
      .when(ok: (db) => db, err: (error) => fail('$error'));
});

// Closing gives the tables back, so the next test's database takes them.
tearDown(() => db.close());

test('adults', () async {
  await users.insert([ada, linus]);
  final adults = await users.filter(users.field<int>('age').ge(18));
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

db_dsl is at **0.1.0**: the API may still change before 1.0. The protocol is
version 1 and only grows (see "Compatibility" in PROTOCOL.md).

## License

[Apache License 2.0](LICENSE). Redistributions must keep the [NOTICE](NOTICE)
file, which credits JhonaCodes as the author.
