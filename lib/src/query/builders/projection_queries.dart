part of '../queries.dart';

/// The values of one column (`SELECT column`), optionally distinct.
final class PluckQuery<T, V extends Object> with _RunsWhenAwaited<List<V?>> {
  const PluckQuery._(this._query, this.column, {this.unique = false});

  final SelectQuery<T> _query;

  /// The column read.
  final Field<V> column;

  /// Equal values are returned once.
  final bool unique;

  /// Each value once (`SELECT DISTINCT column`); `1` equals `1.0`.
  PluckQuery<T, V> distinct() => PluckQuery._(_query, column, unique: true);

  /// The statement this query sends.
  SelectStatement get statement =>
      _query._statement(fields: [column.name], distinct: unique);

  @override
  DbTable<Object?> get _homeTable => _query.table;

  @override
  Future<Result<List<V?>, DbError>> _runOn(QueryExecutor executor) =>
      load(executor);

  /// The values in [on], another database than the one of the table
  /// (awaiting the query reads that one), in the query's order; `null`
  /// where a row has none.
  Future<Result<List<V?>, DbError>> load(QueryExecutor on) async =>
      (await on.run(statement)).flatMap((rows) {
        final values = <V?>[];

        for (final row in rows) {
          switch (_Values.read(row, column.name, column)) {
            case Ok(:final data):
              values.add(data);
            case Err(:final error):
              return Err(error);
          }
        }

        return Ok(values);
      });
}

/// Rows reduced to some columns (`SELECT a, b`), optionally distinct.
final class ProjectionQuery<T> with _RunsWhenAwaited<List<ProjectedRow>> {
  const ProjectionQuery._(this._query, this.columns, {this.unique = false});

  final SelectQuery<T> _query;

  /// The columns kept.
  final List<Field<Object>> columns;

  /// Equal rows are returned once.
  final bool unique;

  /// Each combination of values once (`SELECT DISTINCT a, b`).
  ProjectionQuery<T> distinct() =>
      ProjectionQuery._(_query, columns, unique: true);

  /// The statement this query sends.
  SelectStatement get statement => _query._statement(
    fields: [for (final column in columns) column.name],
    distinct: unique,
  );

  @override
  DbTable<Object?> get _homeTable => _query.table;

  @override
  Future<Result<List<ProjectedRow>, DbError>> _runOn(QueryExecutor executor) =>
      load(executor);

  /// The projected rows in [on], another database than the one of the
  /// table (awaiting the query reads that one), in the query's order.
  Future<Result<List<ProjectedRow>, DbError>> load(QueryExecutor on) async =>
      (await on.run(
        statement,
      )).map((rows) => [for (final row in rows) ProjectedRow(row)]);
}
