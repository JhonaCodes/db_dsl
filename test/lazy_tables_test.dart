import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// A table defines itself the first time it is used, on the default
/// database (the first one opened), without being listed when opening it.
void main() {
  late CountingEngine engine;
  var next = 0;

  // Every database closes after its test, even a failing one, so it never
  // stays the default of the next test.
  Future<Database> open() async {
    final db = value(await Database.open(engine, path: 'lazy-${next++}'));
    addTearDown(db.close);
    return db;
  }

  setUp(() => engine = CountingEngine());

  test('a table is defined the first time it is used', () async {
    final db = await open();
    final notes = Note.table();

    expect(value(await notes.insert(Note.all)), Note.all.length);
    expect(value(await notes.all()), Note.all);
    expect(value(await db.tables()).map((table) => table.name), ['notes']);
    expect(engine.definitions, {'notes': 1});
    await db.close();
  });

  test('concurrent first uses define it once', () async {
    final db = await open();
    final notes = Note.table();

    final results = await Future.wait([
      notes.insert([Note.all.first]),
      notes.insert([Note.all.last]),
      notes.all().count(),
    ]);

    expect(results.map((result) => result.isOk), everyElement(isTrue));
    expect(value(await notes.all().count()), 2);
    expect(engine.definitions, {'notes': 1});
    await db.close();
  });

  test('its indexes are built when it defines itself', () async {
    final db = await open();
    final notes = Note.table();

    value(await notes.insert(Note.all));

    final [schema] = value(await db.tables());
    expect(schema.indexes.map((index) => index.name), ['by_stars']);
    await db.close();
  });

  test('a first use inside a transaction is refused, not a deadlock', () async {
    final db = await open();
    final notes = Note.table();

    final result = await db
        .transaction<int>((tx) => notes.insert(Note.all))
        .timeout(const Duration(seconds: 5));

    expect(code(result), DbErrorCode.tableNotReady);
    expect(value(await notes.all().count()), 0, reason: 'usable afterwards');
    await db.close();
  });

  test('a first use inside a read transaction is refused too', () async {
    final db = await open();
    final notes = Note.table();

    final result = await db
        .readTransaction((tx) => notes.all().count())
        .timeout(const Duration(seconds: 5));

    expect(code(result), DbErrorCode.tableNotReady);
    expect(value(await notes.all().count()), 0, reason: 'usable afterwards');
  });

  test('a table used once before works inside transactions', () async {
    final db = await open();
    final notes = Note.table();
    value(await notes.all().count());

    final inserted = await db.transaction<int>((tx) => notes.insert(Note.all));

    expect(value(inserted), Note.all.length);
    await db.close();
  });

  test('an atomic batch defines the tables it writes', () async {
    final db = await open();
    final notes = Note.table();

    expect(value(await db.atomicBatch([notes.insert(Note.all)])), [
      Note.all.length,
    ]);
    expect(engine.definitions, {'notes': 1});
    await db.close();
  });

  test('watch and explain define the table too', () async {
    final db = await open();
    final notes = Note.table();
    final stars = notes.field<int>('stars');

    expect(value(await notes.filter(stars.gt(1)).explain()).table, 'notes');
    expect(value(await notes.all().watch().first), isEmpty);
    expect(engine.definitions, {'notes': 1});
    await db.close();
  });

  test('the default is the first database opened, until it closes', () async {
    final first = await open();
    final second = await open();
    final notes = Note.table();

    value(await notes.insert([Note.all.first]));
    expect(value(await notes.all().count(first)), 1);
    expect(code(await notes.all().count(second)), DbErrorCode.tableNotFound);

    await first.close();
    // No database is the default now: the second opened before it closed.
    expect(code(await Note.table().all()), DbErrorCode.notOpen);

    final third = await open();
    expect(value(await Note.table().all()), isEmpty);
    await second.close();
    await third.close();
  });

  test('without any open database a query is refused', () async {
    expect(code(await Note.table().all()), DbErrorCode.notOpen);
  });
}

/// The value of an `Ok`; fails the test on an `Err`.
T value<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => data, err: (error) => fail('Err: $error'));

/// The code of an `Err`; fails the test on an `Ok`.
DbErrorCode code<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => fail('Ok: $data'), err: (error) => error.code);

/// A note, as an app models it, with its table as a static of the model.
final class Note {
  const Note(this.id, this.stars);

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(json['id'] as String, json['stars'] as int);

  /// A fresh table object (each test starts with a table no database owns).
  static DbTable<Note> table() => DbTable<Note>(
    'notes',
    key: 'id',
    fromJson: Note.fromJson,
    indexes: [
      Index(['stars']),
    ],
  );

  static const List<Note> all = [Note('a', 1), Note('b', 5)];

  final String id;
  final int stars;

  Map<String, dynamic> toJson() => {'id': id, 'stars': stars};

  @override
  bool operator ==(Object other) =>
      other is Note && other.id == id && other.stars == stars;

  @override
  int get hashCode => Object.hash(id, stars);

  @override
  String toString() => 'Note($id, $stars)';
}

/// [MemoryEngine], counting the table definitions it receives.
final class CountingEngine implements Engine {
  final MemoryEngine _inner = MemoryEngine();

  /// Definitions received, by table name.
  final Map<String, int> definitions = {};

  @override
  Future<Result<EngineConnection, DbError>> open(
    String path,
    DbOptions options,
  ) async => (await _inner.open(
    path,
    options,
  )).map((connection) => _CountingConnection(connection, definitions));
}

final class _CountingConnection implements EngineConnection {
  _CountingConnection(this._inner, this._definitions);

  final EngineConnection _inner;
  final Map<String, int> _definitions;

  @override
  Future<Result<Map<String, Object?>, DbError>> send(
    ProtocolRequest<Object?> request,
  ) {
    if (request case DefineTableRequest(:final schema)) {
      _definitions.update(schema.name, (n) => n + 1, ifAbsent: () => 1);
    }

    return _inner.send(request);
  }

  @override
  Future<Result<(), DbError>> close() => _inner.close();
}
