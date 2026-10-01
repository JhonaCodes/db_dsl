/// The pieces the conformance cases are written with: a table of plain JSON
/// rows, checks that fail with a readable message, and a host that opens
/// fresh databases on the engine under test.
library;

import 'package:result_controller/result_controller.dart';

import '../database/database.dart';
import '../engine/db_options.dart';
import '../engine/engine.dart';
import '../errors/db_error.dart';
import '../protocol/json_values.dart';
import '../schema/table.dart';

/// A conformance check that did not hold.
///
/// Why an [Error]: a failed check means the engine breaks the protocol — a
/// bug to fix, not an outcome to handle.
final class ConformanceFailure extends Error {
  /// A failure described by [message].
  ConformanceFailure(this.message);

  /// What was expected and what the engine did.
  final String message;

  @override
  String toString() => 'ConformanceFailure: $message';
}

/// A row that is just its stored JSON, so cases can store any mix of kinds.
final class JsonRow {
  /// Wraps [json].
  const JsonRow(this.json);

  /// The stored JSON.
  final Map<String, Object?> json;

  @override
  bool operator ==(Object other) =>
      other is JsonRow && JsonValues.equals(json, other.json);

  @override
  int get hashCode => JsonValues.canonical(json).hashCode;

  @override
  String toString() => 'JsonRow($json)';
}

/// A table of [JsonRow]s whose shape each case chooses.
///
/// Why an extension type: it is exactly a `DbTable<JsonRow>` (so the
/// database keeps it as one), with a constructor that names the shape.
extension type JsonTable._(DbTable<JsonRow> _table)
    implements DbTable<JsonRow> {
  /// A table [name] keyed by [key], with [indexes] over the named fields and
  /// [uniqueIndexes] (each index is named after its fields).
  JsonTable(
    String name, {
    String key = 'id',
    bool autoIncrementKey = false,
    List<List<String>> indexes = const [],
    List<List<String>> uniqueIndexes = const [],
  }) : _table = DbTable<JsonRow>(
         name,
         key: key,
         fromJson: JsonRow.new,
         toJson: (row) => row.json,
         autoIncrement: autoIncrementKey,
         indexes: [
           for (final fields in indexes) Index(fields),
           for (final fields in uniqueIndexes) Index.unique(fields),
         ],
       );

  /// Rows from plain maps.
  static List<JsonRow> rows(Iterable<Map<String, Object?>> json) => [
    for (final row in json) JsonRow(row),
  ];
}

/// What the platform running the suite can represent.
abstract final class ConformancePlatform {
  /// Whether `int` is a 64-bit integer (the Dart VM and AOT). On the web it
  /// is a JavaScript number, exact only up to 2^53, so cases about 64-bit
  /// integers do not apply there.
  static const bool hasInt64 = !bool.fromEnvironment('dart.library.js_interop');

  /// The largest signed 64-bit integer, built at run time: the literal does
  /// not compile to JavaScript. Only meaningful when [hasInt64].
  static int get maxInt64 => int.parse('9223372036854775807');
}

/// Checks of the conformance cases.
abstract final class Check {
  /// [actual] equals [expected] (deep equality of JSON-like values).
  static void equals(Object? actual, Object? expected, String what) {
    if (!_deepEquals(actual, expected)) {
      throw ConformanceFailure('$what: expected $expected, got $actual');
    }
  }

  /// [condition] holds.
  static void isTrue(bool condition, String what) {
    if (!condition) {
      throw ConformanceFailure(what);
    }
  }

  /// [result] is `Ok`; answers its value.
  static T ok<T>(Result<T, DbError> result, String what) => result.when(
    ok: (value) => value,
    err: (error) => throw ConformanceFailure('$what: failed with $error'),
  );

  /// [result] is `Err` with [code]; answers the error.
  static DbError fails<T>(
    Result<T, DbError> result,
    DbErrorCode code,
    String what,
  ) => result.when(
    ok: (value) => throw ConformanceFailure(
      '$what: expected ${code.name}, got Ok($value)',
    ),
    err: (error) => error.code == code
        ? error
        : throw ConformanceFailure(
            '$what: expected ${code.name}, got ${error.code.name} ($error)',
          ),
  );

  static bool _deepEquals(Object? a, Object? b) => switch ((a, b)) {
    (final JsonRow x, final JsonRow y) => x == y,
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          Iterable<int>.generate(
            x.length,
          ).every((i) => _deepEquals(x[i], y[i])),
    (final Set<Object?> x, final Set<Object?> y) =>
      x.length == y.length && x.every(y.contains),
    (final Map<String, Object?> x, final Map<String, Object?> y) =>
      JsonValues.equals(x, y),
    _ => a == b,
  };
}

/// Opens fresh databases on the engine under test.
final class ConformanceHost {
  /// A host for [engine]; [freshPath] answers a path no database uses yet.
  ConformanceHost(
    this.engine,
    this.freshPath, {
    this.options = const DbOptions(),
  });

  /// The engine under test.
  final Engine engine;

  /// A path that no database uses yet (a temporary directory, for native
  /// engines).
  final Future<String> Function() freshPath;

  /// Options of every database opened.
  final DbOptions options;

  /// A fresh database at a new path with [tables].
  Future<Database> open(List<DbTable<Object?>> tables) async =>
      reopen(await freshPath(), tables);

  /// The database at [path] (which may hold data already) with [tables].
  Future<Database> reopen(String path, List<DbTable<Object?>> tables) async =>
      Check.ok(
        await Database.open(
          engine,
          path: path,
          tables: tables,
          options: options,
        ),
        'open $path',
      );
}
