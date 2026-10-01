/// Tables: where the rows of a model live, and the entry point of every query
/// and write.
library;

import 'package:meta/meta.dart';
import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../query/expression.dart';
import '../query/ordering.dart';
import '../query/queries.dart';
import 'field.dart';
import 'json_convention.dart';
import 'table_schema.dart';

/// The table of the rows of a model [T], declared in one line with the
/// model the app already has:
///
/// ```dart
/// final users = DbTable<User>('users', key: 'id', fromJson: User.fromJson);
///
/// await users.insert([ada]);
/// final adults = await users.filter(users.field<int>('age').ge(18));
/// ```
///
/// A row is stored as the model writes itself: its `toJson()`, by Dart's
/// JSON convention. Pass [toJson] only when the model names that method
/// otherwise (`toJson: (user) => user.toMap()`).
///
/// Why [fromJson] must be given: it is a constructor, and Dart can neither
/// require a constructor of a type nor call one through a type parameter
/// (`T.fromJson` does not compile). Everything else follows from the model.
///
/// Why `final`: a table is a value built from the model, never a class to
/// extend, so every table behaves the same.
final class DbTable<T> {
  /// The table [tableName] (non-empty, without `:`, not starting with `__`)
  /// of rows identified by the field [key], read back with [fromJson].
  ///
  /// With [autoIncrement], a row inserted without its key gets the next
  /// integer (the key must then be a top-level integer field). [indexes]
  /// are maintained in the same transaction as the rows.
  DbTable(
    this.tableName, {
    required String key,
    required T Function(Map<String, Object?> json) fromJson,
    Map<String, Object?> Function(T row)? toJson,
    this.autoIncrement = false,
    this.indexes = const [],
  }) : primaryKey = Field<Object>(key, table: tableName),
       _fromJson = fromJson,
       _toJson = toJson;

  /// Name of the table.
  final String tableName;

  /// The field that identifies a row.
  final Field<Object> primaryKey;

  /// Rows inserted without a primary key get the next integer.
  final bool autoIncrement;

  /// Secondary indexes, maintained in the same transaction as the rows.
  final List<Index> indexes;

  final T Function(Map<String, Object?> json) _fromJson;
  final Map<String, Object?> Function(T row)? _toJson;

  /// The field at [name] of the rows, compared and read as values of [V]
  /// (see [Field] for how values are encoded, and [encode] / [decode] for a
  /// model that stores a value another way).
  Field<V> field<V extends Object>(
    String name, {
    Object? Function(V value)? encode,
    V? Function(Object stored)? decode,
  }) => Field<V>(name, table: tableName, encode: encode, decode: decode);

  /// The row of a stored [json], or [DbErrorCode.rowMapping] when the
  /// model cannot read it: a stored row that does not fit the model is data
  /// to report, not a crash.
  Result<T, DbError> mapRow(Map<String, Object?> json) {
    try {
      return Ok(_fromJson(json));
    } on Object catch (error) {
      return Err(
        DbError(
          DbErrorCode.rowMapping,
          '`$tableName` cannot read a stored row ($error): $json',
        ),
      );
    }
  }

  /// The rows of [json], or the error of the first one that does not fit.
  Result<List<T>, DbError> mapRows(List<Map<String, Object?>> json) {
    final rows = <T>[];

    for (final stored in json) {
      switch (mapRow(stored)) {
        case Ok(:final data):
          rows.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(rows);
  }

  /// The JSON stored for [row], or [DbErrorCode.rowMapping] when it has no
  /// JSON form. Used by the writes.
  @internal
  Result<Map<String, Object?>, DbError> encodeRow(T row) =>
      JsonConvention.object(
        () => switch (_toJson) {
          final Map<String, Object?> Function(T row) toJson => toJson(row),
          null => row,
        },
        tableName,
      );

  /// The definition sent to the engine.
  TableSchema get schema => TableSchema(
    name: tableName,
    primaryKey: primaryKey.name,
    autoIncrement: autoIncrement,
    indexes: [for (final index in indexes) index.schema],
  );

  /// Every row (`SELECT * FROM table`).
  SelectQuery<T> all() => SelectQuery<T>(this);

  /// Rows matching [condition].
  SelectQuery<T> filter(Expression condition) => all().filter(condition);

  /// Every row, sorted by [term].
  SelectQuery<T> order(OrderingTerm term) => all().order(term);

  /// The row whose primary key is [key].
  FindQuery<T> find(Object key) => FindQuery<T>(this, key);

  /// Inserts [rows] (`insert_into(table).values(rows)`).
  InsertQuery<T> insert(Iterable<T> rows) => InsertQuery<T>(this, rows);

  /// Updates rows (`update(table).filter(...).set(...)`).
  UpdateQuery<T> update() => UpdateQuery<T>(this);

  /// Deletes rows (`delete(table).filter(...)`).
  DeleteQuery<T> delete() => DeleteQuery<T>(this);

  /// Every row grouped by [keys] (`GROUP BY`).
  GroupQuery<T> groupBy(List<Field<Object>> keys) => all().groupBy(keys);

  /// This table joined with [table] where the [equals] field of [table]
  /// equals the [on] field of this one (`INNER JOIN`).
  JoinQuery innerJoin(
    DbTable<Object?> table, {
    required Field<Object> on,
    required Field<Object> equals,
  }) => JoinQuery.start(this).innerJoin(table, on: on, equals: equals);

  /// Like [innerJoin], keeping the rows of this table without a match
  /// (`LEFT JOIN`).
  JoinQuery leftJoin(
    DbTable<Object?> table, {
    required Field<Object> on,
    required Field<Object> equals,
  }) => JoinQuery.start(this).leftJoin(table, on: on, equals: equals);

  /// The rows whose [foreignKey] is one of [parentKeys]: the children of
  /// some parents, in one query (Diesel's `belonging_to`). Group them with
  /// `Associations.groupedBy`.
  SelectQuery<T> belongingTo<V extends Object>(
    Iterable<V> parentKeys,
    Field<V> foreignKey,
  ) => filter(foreignKey.eqAny(parentKeys));

  @override
  String toString() => 'DbTable($tableName)';
}

/// A secondary index over one or more fields of a table.
final class Index {
  /// A non-unique index over [fields], named `by_<fields>` unless [name] is
  /// given.
  const Index(this.fields, {String? name}) : unique = false, _name = name;

  /// A unique index: two rows cannot hold equal values in [fields]; rows
  /// with a `null` among them are exempt, as in SQL. Named
  /// `unique_<fields>` unless [name] is given.
  const Index.unique(this.fields, {String? name}) : unique = true, _name = name;

  /// Indexed field paths, in order: `['city', 'age']` serves filters on
  /// `city` alone and on `city` plus a range of `age`.
  final List<String> fields;

  /// Whether the index rejects duplicates.
  final bool unique;

  final String? _name;

  /// Index name, unique within its table.
  String get name => switch (_name) {
    final String given => given,
    null =>
      '${unique ? 'unique' : 'by'}_'
          '${fields.join('_').replaceAll('.', '_')}',
  };

  /// The definition sent to the engine.
  IndexSchema get schema =>
      IndexSchema(name: name, fields: fields, unique: unique);
}
