part of '../queries.dart';

/// A row of a projection (`project`): the selected columns only.
///
/// Why a class instead of a plain map: each value is read back through its
/// column, which decodes the stored form (a `DateTime`, not micros) and
/// reports a value of the wrong kind as [DbErrorCode.rowMapping].
final class ProjectedRow {
  /// The row as the engine answered it.
  const ProjectedRow(this.json);

  /// The projected JSON.
  final Map<String, Object?> json;

  /// The value of [column], or `null` when the row has none.
  Result<V?, DbError> get<V extends Object>(Field<V> column) =>
      _Values.read(json, column.name, column);

  @override
  String toString() => 'ProjectedRow($json)';
}

/// A row of a `groupBy`: the group key and the aggregates.
final class GroupRow {
  /// The row as the engine answered it.
  const GroupRow(this.json);

  /// The group row JSON.
  final Map<String, Object?> json;

  /// The value of the group key [column], or `null` for the `NULL` group.
  Result<V?, DbError> key<V extends Object>(Field<V> column) =>
      _Values.read(json, column.name, column);

  /// The `count` named [alias].
  Result<int, DbError> count(String alias) => switch (json[alias]) {
    final int count => Ok(count),
    final other => Err(_Values.mismatch(alias, other)),
  };

  /// The `sum` or `avg` named [alias]; `null` when the group had no number.
  Result<num?, DbError> number(String alias) => switch (json[alias]) {
    null => Ok(null),
    final num value => Ok(value),
    final other => Err(_Values.mismatch(alias, other)),
  };

  /// The `min` or `max` named [alias], read as a value of [column] (the
  /// aggregated one).
  Result<V?, DbError> value<V extends Object>(String alias, Field<V> column) =>
      _Values.read(json, alias, column);

  @override
  String toString() => 'GroupRow($json)';
}

/// A row of a join: one row of each table, under its name.
final class JoinRow {
  /// The row as the engine answered it.
  const JoinRow(this.json);

  /// The combined JSON (`{"users": {...}, "posts": {...} | null}`).
  final Map<String, Object?> json;

  /// The row of [table]; [DbErrorCode.rowMapping] when it has none (a left
  /// join without match: read it with [maybe]).
  Result<T, DbError> of<T>(DbTable<T> table) => switch (json[table.tableName]) {
    final Map<String, Object?> row => table.mapRow(row),
    _ => Err(
      DbError(
        DbErrorCode.rowMapping,
        'The joined row has no `${table.tableName}`: $json',
      ),
    ),
  };

  /// The row of [table], or `null` when a left join found no match.
  Result<T?, DbError> maybe<T>(DbTable<T> table) =>
      switch (json[table.tableName]) {
        null => Ok(null),
        final Map<String, Object?> row => table.mapRow(row),
        final other => Err(_Values.mismatch(table.tableName, other)),
      };

  @override
  String toString() => 'JoinRow($json)';
}

/// Reading values of answered rows.
abstract final class _Values {
  static Result<V?, DbError> read<V extends Object>(
    Map<String, Object?> json,
    String path,
    Field<V> column,
  ) => switch (JsonValues.fieldAt(json, path)) {
    null => Ok(null),
    final Object stored => column.decode(stored),
  };

  static DbError mismatch(String name, Object? value) => DbError(
    DbErrorCode.rowMapping,
    '`$name` holds an unexpected value: $value',
  );
}
