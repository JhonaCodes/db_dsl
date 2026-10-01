import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// Awaiting a query runs it on the database that opened its table, or on the
/// transaction around it; naming another database is the exception.
void main() {
  late MemoryEngine engine;
  late DbTable<Note> notes;
  var next = 0;

  Future<Database> open() async => value(
    await Database.open(engine, path: 'notes-${next++}', tables: [notes]),
  );

  setUp(() {
    engine = MemoryEngine();
    notes = DbTable<Note>('notes', key: 'id', fromJson: Note.fromJson);
  });

  group('awaited on the database of the table', () {
    test('writes and reads without naming the database', () async {
      final db = await open();

      expect(value(await notes.insert(const [Note('a', 3), Note('b', 5)])), 2);
      expect(
        value(
          await notes
              .update()
              .filter(notes.field<String>('id').eq('b'))
              .increment(notes.field<int>('stars'), 1),
        ),
        1,
      );
      expect(
        value(await notes.delete().filter(notes.field<String>('id').eq('a'))),
        1,
      );

      expect(value(await notes.all().load(db)), [const Note('b', 6)]);
      expect(value(await notes.filter(notes.field<int>('stars').gt(1))), [
        const Note('b', 6),
      ]);
      expect(value(await notes.find('b')), const Note('b', 6));
      expect(value(await notes.all().count()), 1);
      expect(value(await notes.all().sum(notes.field<int>('stars'))), 6);
      expect(value(await notes.insert(const [Note('c', 1)]).getResults()), [
        const Note('c', 1),
      ]);
      await db.close();
    });
  });

  group('awaited inside a transaction', () {
    test('a rolled back transaction takes the awaited write with it', () async {
      final db = await open();

      final result = await db.transaction<void>((tx) async {
        expect(value(await notes.insert(const [Note('a', 1)])), 1);
        // Visible inside, before the commit.
        expect(value(await notes.find('a')), const Note('a', 1));
        return Err(DbError(DbErrorCode.invalidRequest, 'undo it'));
      });

      expect(code(result), DbErrorCode.invalidRequest);
      expect(value(await notes.find('a')), isNull);
      await db.close();
    });

    test('a committed transaction keeps the awaited write', () async {
      final db = await open();

      final result = await db.transaction<int>(
        (tx) => notes.insert(const [Note('a', 1)]),
      );

      expect(value(result), 1);
      expect(value(await notes.find('a')), const Note('a', 1));
      await db.close();
    });

    test('a read transaction reads its snapshot', () async {
      final db = await open();

      final seen = await db.readTransaction((tx) async {
        // Written outside the snapshot, after it began.
        expect(
          value(await notes.insert(const [Note('late', 1)]).execute(db)),
          1,
        );
        return notes.all().count();
      });

      expect(value(seen), 0);
      expect(value(await notes.all().count()), 1);
      await db.close();
    });

    test('naming the database inside its own transaction is refused', () async {
      final db = await open();

      final result = await db.transaction<List<Note>>(
        (tx) => notes.all().load(db),
      );

      expect(code(result), DbErrorCode.transactionReentrancy);
      await db.close();
    });
  });

  group('which database a table runs on', () {
    test(
      'the first database that opened it, unless another is named',
      () async {
        final home = await open();
        final other = await open();

        expect(value(await notes.insert(const [Note('home', 1)])), 1);
        expect(
          value(await notes.insert(const [Note('other', 2)]).execute(other)),
          1,
        );

        expect(value(await notes.all()), [const Note('home', 1)]);
        expect(value(await notes.all().load(other)), [const Note('other', 2)]);
        await home.close();
        await other.close();
      },
    );

    test('closing it releases the table for the next database', () async {
      final first = await open();
      await first.close();

      expect(code(await notes.all()), DbErrorCode.notOpen);

      final second = await open();
      expect(value(await notes.insert(const [Note('again', 1)])), 1);
      expect(value(await notes.all().count(second)), 1);
      await second.close();
    });

    test('a table open in no database is refused', () async {
      expect(code(await notes.all()), DbErrorCode.notOpen);
      expect(
        code(await notes.insert(const [Note('a', 1)])),
        DbErrorCode.notOpen,
      );
    });
  });
}

/// The value of an `Ok`; fails the test on an `Err`.
T value<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => data, err: (error) => fail('Err: $error'));

/// The code of an `Err`; fails the test on an `Ok`.
DbErrorCode code<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => fail('Ok: $data'), err: (error) => error.code);

/// A note with a number of stars, as an app would model it.
final class Note {
  const Note(this.id, this.stars);

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(json['id'] as String, json['stars'] as int);

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
