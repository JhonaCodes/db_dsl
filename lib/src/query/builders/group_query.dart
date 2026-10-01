part of '../queries.dart';

/// Rows grouped by columns, with aggregates per group (Diesel's
/// `group_by(...).select((key, count(...)))`).
///
/// ```dart
/// final perCity = await users
///     .filter(users.active.eq(true))
///     .groupBy([users.city])
///     .count('people')
///     .avg(users.age, 'average_age')
///     .having(const Field<int>('people').ge(2))
///     .order(const Field<int>('people').desc());
/// ```
///
/// Aggregates are named by an alias; [having] and [order] refer to the
/// aliases and the key columns of the group rows.
final class GroupQuery<T> with _RunsWhenAwaited<List<GroupRow>> {
  const GroupQuery._(
    this.table,
    this.condition,
    this.keys, {
    this.aggregates = const [],
    this.havingCondition,
    this.ordering = const [],
    this.maxRows,
    this.skipped,
  });

  /// The grouped table.
  final DbTable<T> table;

  /// The rows grouped; every row when `null`.
  final Expression? condition;

  /// The key columns (empty: one group over every row).
  final List<Field<Object>> keys;

  /// The aggregates, in order.
  final List<GroupAggregate> aggregates;

  /// The condition on group rows (`HAVING`).
  final Expression? havingCondition;

  /// Sort keys over the group rows.
  final List<OrderingTerm> ordering;

  /// At most this many groups.
  final int? maxRows;

  /// Groups skipped.
  final int? skipped;

  GroupQuery<T> _with({
    List<GroupAggregate>? aggregates,
    Expression? having,
    List<OrderingTerm>? ordering,
    int? maxRows,
    int? skipped,
  }) => GroupQuery._(
    table,
    condition,
    keys,
    aggregates: aggregates ?? this.aggregates,
    havingCondition: having ?? havingCondition,
    ordering: ordering ?? this.ordering,
    maxRows: maxRows ?? this.maxRows,
    skipped: skipped ?? this.skipped,
  );

  GroupQuery<T> _aggregate(
    GroupFunction function,
    String alias, [
    Field<Object>? column,
  ]) => _with(
    aggregates: [
      ...aggregates,
      GroupAggregate(function, alias, field: column?.name),
    ],
  );

  /// The rows of each group, as [alias].
  GroupQuery<T> count(String alias) => _aggregate(GroupFunction.count, alias);

  /// The rows of each group whose [column] is not `null`, as [alias].
  GroupQuery<T> countOf(Field<Object> column, String alias) =>
      _aggregate(GroupFunction.count, alias, column);

  /// The sum of [column] per group, as [alias].
  GroupQuery<T> sum(Field<num> column, String alias) =>
      _aggregate(GroupFunction.sum, alias, column);

  /// The average of [column] per group, as [alias].
  GroupQuery<T> avg(Field<num> column, String alias) =>
      _aggregate(GroupFunction.avg, alias, column);

  /// The smallest [column] per group, as [alias].
  GroupQuery<T> min(Field<Object> column, String alias) =>
      _aggregate(GroupFunction.min, alias, column);

  /// The largest [column] per group, as [alias].
  GroupQuery<T> max(Field<Object> column, String alias) =>
      _aggregate(GroupFunction.max, alias, column);

  /// Keeps the groups matching [expression] (`HAVING`), `AND` the previous
  /// conditions.
  GroupQuery<T> having(Expression expression) => _with(
    having: switch (havingCondition) {
      null => expression,
      final Expression current => current.and(expression),
    },
  );

  /// Replaces the sort keys with [term].
  GroupQuery<T> order(OrderingTerm term) => _with(ordering: [term]);

  /// Adds a less significant sort key.
  GroupQuery<T> thenOrderBy(OrderingTerm term) =>
      _with(ordering: [...ordering, term]);

  /// Returns at most [count] groups.
  GroupQuery<T> limit(int count) => _with(maxRows: count);

  /// Skips the first [count] groups.
  GroupQuery<T> offset(int count) => _with(skipped: count);

  /// The statement this query sends.
  GroupStatement get statement => GroupStatement(
    table.tableName,
    filter: condition,
    by: [for (final key in keys) key.name],
    aggregates: aggregates,
    having: havingCondition,
    order: ordering,
    limit: maxRows,
    offset: skipped,
  );

  @override
  DbTable<Object?> get _homeTable => table;

  @override
  Future<Result<List<GroupRow>, DbError>> _runOn(QueryExecutor executor) =>
      load(executor);

  /// The group rows of [on], another database than the one of the table
  /// (awaiting the query reads that one).
  Future<Result<List<GroupRow>, DbError>> load(QueryExecutor on) async =>
      (await on.run(
        statement,
      )).map((rows) => [for (final row in rows) GroupRow(row)]);
}
