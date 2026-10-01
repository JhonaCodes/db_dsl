part of '../queries.dart';

/// A statement that writes. Awaiting it runs it and answers the number of
/// affected rows (`await users.insert([ada])`); it is also a part of
/// `Database.atomicBatch`.
///
/// Why sealed: a batch accepts exactly inserts, updates and deletes; the
/// closed family keeps reads out of it at compile time.
sealed class WriteQuery with _RunsWhenAwaited<int> {
  const WriteQuery();

  /// The statement this write sends, or [DbErrorCode.rowMapping] when a
  /// row to insert has no JSON form: a write answers that, never throws.
  Result<WriteStatement, DbError> get prepared;

  @override
  Future<Result<int, DbError>> _runOn(QueryExecutor executor) =>
      execute(executor);

  /// Runs the write on [on], another database than the one of the table
  /// (awaiting the write runs it on that one); answers the number of
  /// affected rows.
  Future<Result<int, DbError>> execute(QueryExecutor on) => prepared.when(
    ok: (statement) async =>
        (await on.run(statement)).map((output) => output.affected),
    err: (error) async => Err(error),
  );
}

/// An insert (`insert_into(table).values(rows)`), all rows or none.
final class InsertQuery<T> extends WriteQuery {
  /// Inserts [rows] into [table].
  InsertQuery(
    this.table,
    Iterable<T> rows, {
    this.onConflict = OnConflict.error,
  }) : rows = List.unmodifiable(rows);

  /// The table.
  final DbTable<T> table;

  @override
  DbTable<Object?> get _homeTable => table;

  /// The rows.
  final List<T> rows;

  /// What happens when a primary key already exists.
  final OnConflict onConflict;

  /// Keeps the existing row when the primary key already exists.
  InsertQuery<T> onConflictDoNothing() =>
      InsertQuery(table, rows, onConflict: OnConflict.ignore);

  /// Replaces the existing row when the primary key already exists.
  InsertQuery<T> onConflictReplace() =>
      InsertQuery(table, rows, onConflict: OnConflict.replace);

  @override
  Result<InsertStatement, DbError> get prepared {
    final stored = <Map<String, Object?>>[];

    for (final row in rows) {
      switch (table.encodeRow(row)) {
        case Ok(:final data):
          stored.add(_withoutGeneratedKey(data));
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(InsertStatement(table.tableName, stored, onConflict: onConflict));
  }

  /// Runs the insert and answers the rows as stored, with generated keys:
  /// on the database of the table, or [on].
  Future<Result<List<T>, DbError>> getResults([QueryExecutor? on]) =>
      QueryExecutor.using(
        table,
        on,
        (executor) => prepared.when(
          ok: (statement) async => (await executor.run(
            statement,
          )).flatMap((output) => table.mapRows(output.rows)),
          err: (error) async => Err(error),
        ),
      );

  /// [json] without a `null` key when the table generates keys, so the
  /// engine generates it.
  Map<String, Object?> _withoutGeneratedKey(Map<String, Object?> json) {
    final key = table.primaryKey.name;

    return switch ((table.autoIncrement, json[key])) {
      (true, null) => {...json}..remove(key),
      _ => json,
    };
  }
}

/// An update (`update(table).filter(...).set(...)`).
final class UpdateQuery<T> extends WriteQuery {
  /// Updates rows of [table].
  const UpdateQuery(this.table)
    : condition = null,
      assignments = const {},
      increments = const {},
      expected = null;

  const UpdateQuery._(
    this.table,
    this.condition,
    this.assignments,
    this.expected, {
    this.increments = const {},
  });

  /// The table.
  final DbTable<T> table;

  @override
  DbTable<Object?> get _homeTable => table;

  /// Rows to update; every row when `null`.
  final Expression? condition;

  /// New stored values by field path.
  final Map<String, Object?> assignments;

  /// Numbers added to the current values by field path.
  final Map<String, num> increments;

  /// The update fails, writing nothing, unless exactly this many rows match.
  final int? expected;

  /// Restricts the updated rows (`AND` the previous conditions).
  UpdateQuery<T> filter(Expression expression) => UpdateQuery._(
    table,
    switch (condition) {
      null => expression,
      final Expression current => current.and(expression),
    },
    assignments,
    expected,
    increments: increments,
  );

  /// Sets [field] to [value], stored as the field encodes it.
  UpdateQuery<T> set<V extends Object>(Field<V> field, V value) =>
      UpdateQuery._(
        table,
        condition,
        {...assignments, field.name: field.encode(value)},
        expected,
        increments: increments,
      );

  /// Sets [field] to `null`.
  UpdateQuery<T> setNull(Field<Object> field) => UpdateQuery._(
    table,
    condition,
    {...assignments, field.name: null},
    expected,
    increments: increments,
  );

  /// Adds [delta] to [field] (`SET field = field + delta`), a counter: a
  /// missing or `null` value counts as 0.
  UpdateQuery<T> increment(Field<num> field, num delta) => UpdateQuery._(
    table,
    condition,
    assignments,
    expected,
    increments: {...increments, field.name: delta},
  );

  /// Fails, writing nothing, unless exactly [count] rows are updated.
  UpdateQuery<T> expectAffectedRows(int count) => UpdateQuery._(
    table,
    condition,
    assignments,
    count,
    increments: increments,
  );

  @override
  Result<UpdateStatement, DbError> get prepared => Ok(
    UpdateStatement(
      table.tableName,
      assignments,
      filter: condition,
      expectedRows: expected,
      increment: increments,
    ),
  );
}

/// A delete (`delete(table).filter(...)`).
final class DeleteQuery<T> extends WriteQuery {
  /// Deletes rows of [table].
  const DeleteQuery(this.table) : condition = null, expected = null;

  const DeleteQuery._(this.table, this.condition, this.expected);

  /// The table.
  final DbTable<T> table;

  @override
  DbTable<Object?> get _homeTable => table;

  /// Rows to delete; every row when `null`.
  final Expression? condition;

  /// The delete fails, deleting nothing, unless exactly this many rows match.
  final int? expected;

  /// Restricts the deleted rows (`AND` the previous conditions).
  DeleteQuery<T> filter(Expression expression) =>
      DeleteQuery._(table, switch (condition) {
        null => expression,
        final Expression current => current.and(expression),
      }, expected);

  /// Fails, deleting nothing, unless exactly [count] rows are deleted.
  DeleteQuery<T> expectAffectedRows(int count) =>
      DeleteQuery._(table, condition, count);

  @override
  Result<DeleteStatement, DbError> get prepared => Ok(
    DeleteStatement(table.tableName, filter: condition, expectedRows: expected),
  );
}
