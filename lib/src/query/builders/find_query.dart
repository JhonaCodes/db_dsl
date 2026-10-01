part of '../queries.dart';

/// A lookup by primary key: `await users.find(1)` answers the row, or
/// `null` when there is none.
final class FindQuery<T> with _RunsWhenAwaited<T?> {
  /// The row of [table] whose primary key is [key].
  const FindQuery(this.table, this.key);

  /// The table.
  final DbTable<T> table;

  /// The primary key, as a Dart value of the key column.
  final Object key;

  /// The statement this lookup sends.
  FindStatement get statement =>
      FindStatement(table.tableName, table.primaryKey.encodeKey(key));

  @override
  DbTable<Object?> get _homeTable => table;

  @override
  Future<Result<T?, DbError>> _runOn(QueryExecutor executor) => first(executor);

  /// The row in [on], another database than the one of the table (awaiting
  /// the lookup reads that one).
  Future<Result<T?, DbError>> first(QueryExecutor on) async =>
      (await on.run(statement)).flatMap(
        (row) => switch (row) {
          null => Ok(null),
          final Map<String, Object?> stored => table.mapRow(stored),
        },
      );
}
