part of '../queries.dart';

/// A query over one table, built like Diesel: [filter], [orFilter], [order],
/// [thenOrderBy], [limit], [offset]. Awaiting it answers the rows:
///
/// ```dart
/// final adults = await users.filter(users.age.ge(18)).order(users.name.asc());
/// ```
///
/// Other terminals: [first], [count], [exists], [sum], [avg], [min], [max],
/// [explain], [watch]. Everything runs on the database that opened the
/// table (or the transaction around it); [load] and the optional `on`
/// arguments name another database.
///
/// Builders are immutable; the engine filters and sorts. Without [order] the
/// order of the rows is unspecified.
final class SelectQuery<T> with _RunsWhenAwaited<List<T>> {
  /// Every row of [table].
  const SelectQuery(this.table)
    : condition = null,
      ordering = const [],
      maxRows = null,
      skipped = null;

  const SelectQuery._(
    this.table,
    this.condition,
    this.ordering,
    this.maxRows,
    this.skipped,
  );

  /// The queried table.
  final DbTable<T> table;

  /// The filter, if any.
  final Expression? condition;

  /// The sort keys.
  final List<OrderingTerm> ordering;

  /// The maximum number of rows, if any.
  final int? maxRows;

  /// The number of rows skipped, if any.
  final int? skipped;

  /// Adds a condition, `AND` the previous ones.
  SelectQuery<T> filter(Expression expression) => SelectQuery._(
    table,
    switch (condition) {
      null => expression,
      final Expression current => current.and(expression),
    },
    ordering,
    maxRows,
    skipped,
  );

  /// Adds an alternative, `OR` the conditions so far.
  SelectQuery<T> orFilter(Expression expression) => SelectQuery._(
    table,
    switch (condition) {
      null => expression,
      final Expression current => current.or(expression),
    },
    ordering,
    maxRows,
    skipped,
  );

  /// Replaces the sort keys with [term].
  SelectQuery<T> order(OrderingTerm term) =>
      SelectQuery._(table, condition, [term], maxRows, skipped);

  /// Adds a less significant sort key.
  SelectQuery<T> thenOrderBy(OrderingTerm term) =>
      SelectQuery._(table, condition, [...ordering, term], maxRows, skipped);

  /// Returns at most [count] rows.
  SelectQuery<T> limit(int count) =>
      SelectQuery._(table, condition, ordering, count, skipped);

  /// Skips the first [count] rows.
  SelectQuery<T> offset(int count) =>
      SelectQuery._(table, condition, ordering, maxRows, count);

  /// The statement this query sends.
  SelectStatement get statement => _statement();

  @override
  DbTable<Object?> get _homeTable => table;

  @override
  Future<Result<List<T>, DbError>> _runOn(QueryExecutor executor) =>
      load(executor);

  SelectStatement _statement({
    List<String> fields = const [],
    bool distinct = false,
  }) => SelectStatement(
    table.tableName,
    filter: condition,
    order: ordering,
    limit: maxRows,
    offset: skipped,
    fields: fields,
    distinct: distinct,
  );

  /// The values of [column] only (`SELECT column`); add `distinct()` for
  /// each value once.
  PluckQuery<T, V> pluck<V extends Object>(Field<V> column) =>
      PluckQuery._(this, column);

  /// The rows reduced to [columns] (`SELECT a, b`); add `distinct()` for
  /// each combination once.
  ProjectionQuery<T> project(List<Field<Object>> columns) =>
      ProjectionQuery._(this, columns);

  /// The matching rows grouped by [keys] (`GROUP BY`); add aggregates,
  /// `having`, order and limits on the result. The filter of this query
  /// applies before grouping; its order and limits do not carry over.
  GroupQuery<T> groupBy(List<Field<Object>> keys) =>
      GroupQuery._(table, condition, keys);

  /// Whether any row matches (`SELECT EXISTS`).
  Future<Result<bool, DbError>> exists([QueryExecutor? on]) async =>
      (await count(on)).map((count) => count > 0);

  /// The matching rows on [on], another database than the one of the table
  /// (awaiting the query runs it on that one).
  Future<Result<List<T>, DbError>> load(QueryExecutor on) async =>
      (await on.run(statement)).flatMap(table.mapRows);

  /// The first matching row, or `null` when none matches.
  Future<Result<T?, DbError>> first([QueryExecutor? on]) => QueryExecutor.using(
    table,
    on,
    (executor) async =>
        (await limit(1).load(executor)).map((rows) => rows.firstOrNull),
  );

  /// How many rows match ([limit] and [offset] do not apply).
  Future<Result<int, DbError>> count([QueryExecutor? on]) =>
      QueryExecutor.using(
        table,
        on,
        (executor) =>
            executor.run(CountStatement(table.tableName, filter: condition)),
      );

  /// Sum of [column] over the matching rows; `null` when no row has a number.
  Future<Result<num?, DbError>> sum(
    Field<num> column, [
    QueryExecutor? on,
  ]) async =>
      (await _aggregate(AggregateFunction.sum, column, on)).flatMap(_number);

  /// Average of [column] over the matching rows; `null` when no row has a
  /// number.
  Future<Result<double?, DbError>> avg(
    Field<num> column, [
    QueryExecutor? on,
  ]) async => (await _aggregate(
    AggregateFunction.avg,
    column,
    on,
  )).flatMap(_number).map((value) => value?.toDouble());

  /// Smallest value of [column] in the total order, or `null`.
  Future<Result<V?, DbError>> min<V extends Object>(
    Field<V> column, [
    QueryExecutor? on,
  ]) async => (await _aggregate(
    AggregateFunction.min,
    column,
    on,
  )).flatMap((value) => _typed(column, value));

  /// Largest value of [column] in the total order, or `null`.
  Future<Result<V?, DbError>> max<V extends Object>(
    Field<V> column, [
    QueryExecutor? on,
  ]) async => (await _aggregate(
    AggregateFunction.max,
    column,
    on,
  )).flatMap((value) => _typed(column, value));

  /// The plan the engine chooses, without running the query: on the
  /// database of the table, or [on].
  Future<Result<QueryPlan, DbError>> explain([Database? on]) =>
      switch (on ?? Database.homeOf(table)) {
        final Database database => database.explain(this),
        null => Future.value(Err(QueryExecutor.notOpen(table))),
      };

  /// The matching rows now, and again after every committed write of the
  /// database of the table (or of [on]) to this table.
  Stream<Result<List<T>, DbError>> watch([Database? on]) =>
      switch (on ?? Database.homeOf(table)) {
        final Database database => database.watch(this),
        null => Stream.value(Err(QueryExecutor.notOpen(table))),
      };

  Future<Result<Object?, DbError>> _aggregate(
    AggregateFunction function,
    Field<Object> column,
    QueryExecutor? on,
  ) => QueryExecutor.using(
    table,
    on,
    (executor) => executor.run(
      AggregateStatement(
        table.tableName,
        function,
        column.name,
        filter: condition,
      ),
    ),
  );

  static Result<num?, DbError> _number(Object? value) => switch (value) {
    null => Ok(null),
    final num number => Ok(number),
    _ => Err(
      DbError(DbErrorCode.unsupportedProtocol, 'Number expected: $value'),
    ),
  };

  static Result<V?, DbError> _typed<V extends Object>(
    Field<V> column,
    Object? value,
  ) => switch (value) {
    null => Ok(null),
    final Object stored => column.decode(stored),
  };

  @override
  String toString() => 'SelectQuery(${statement.toJson()})';
}
