part of '../queries.dart';

/// Rows of several tables joined by equality (Diesel's `inner_join` and
/// `left_join`).
///
/// ```dart
/// final feed = await users
///     .innerJoin(posts, on: users.id, equals: posts.authorId)
///     .leftJoin(comments, on: posts.id, equals: comments.postId)
///     .filter(users.city.eq('Lima'))
///     .order(posts.createdAt.desc());
/// ```
///
/// Each row holds one row per table: `row.of(users)` answers the user, and
/// `row.maybe(comments)` answers `null` when a left join found no comment.
///
/// Filters and sort keys use the columns of any joined table; each is sent
/// qualified by its table. Each table appears under its own name, so a table
/// cannot be joined with itself here.
final class JoinQuery with _RunsWhenAwaited<List<JoinRow>> {
  /// The rows of [from], before any join; `DbTable.innerJoin` and
  /// `DbTable.leftJoin` start from here.
  const JoinQuery.start(DbTable<Object?> from) : this._(from, const []);

  const JoinQuery._(
    this.from,
    this.clauses, {
    this.condition,
    this.ordering = const [],
    this.maxRows,
    this.skipped,
  });

  /// The first table.
  final DbTable<Object?> from;

  /// The joined tables, in order.
  final List<JoinClause> clauses;

  /// The combined rows to return; every one when `null`.
  final Expression? condition;

  /// Sort keys over the combined rows.
  final List<OrderingTerm> ordering;

  /// At most this many rows.
  final int? maxRows;

  /// Rows skipped.
  final int? skipped;

  JoinQuery _with({
    List<JoinClause>? clauses,
    Expression? condition,
    List<OrderingTerm>? ordering,
    int? maxRows,
    int? skipped,
  }) => JoinQuery._(
    from,
    clauses ?? this.clauses,
    condition: condition ?? this.condition,
    ordering: ordering ?? this.ordering,
    maxRows: maxRows ?? this.maxRows,
    skipped: skipped ?? this.skipped,
  );

  JoinQuery _join(
    JoinKind kind,
    DbTable<Object?> table,
    Field<Object> on,
    Field<Object> equals,
  ) => _with(
    clauses: [
      ...clauses,
      JoinClause(
        table.tableName,
        kind: kind,
        left: on.qualifiedName,
        right: equals.name,
      ),
    ],
  );

  /// Keeps the rows that have a row of [table] whose [equals] column equals
  /// [on] (a column of a table joined before), once per such row.
  JoinQuery innerJoin(
    DbTable<Object?> table, {
    required Field<Object> on,
    required Field<Object> equals,
  }) => _join(JoinKind.inner, table, on, equals);

  /// Like [innerJoin], but a row without match stays, with no row of
  /// [table] (read it with `JoinRow.maybe`).
  JoinQuery leftJoin(
    DbTable<Object?> table, {
    required Field<Object> on,
    required Field<Object> equals,
  }) => _join(JoinKind.left, table, on, equals);

  /// Adds a condition, `AND` the previous ones.
  JoinQuery filter(Expression expression) => _with(
    condition: switch (condition) {
      null => expression,
      final Expression current => current.and(expression),
    },
  );

  /// Adds an alternative, `OR` the conditions so far.
  JoinQuery orFilter(Expression expression) => _with(
    condition: switch (condition) {
      null => expression,
      final Expression current => current.or(expression),
    },
  );

  /// Replaces the sort keys with [term].
  JoinQuery order(OrderingTerm term) => _with(ordering: [term]);

  /// Adds a less significant sort key.
  JoinQuery thenOrderBy(OrderingTerm term) =>
      _with(ordering: [...ordering, term]);

  /// Returns at most [count] rows.
  JoinQuery limit(int count) => _with(maxRows: count);

  /// Skips the first [count] rows.
  JoinQuery offset(int count) => _with(skipped: count);

  /// The statement this query sends, with every column qualified by its
  /// table.
  JoinStatement get statement => JoinStatement(
    from.tableName,
    joins: clauses,
    filter: condition?.qualified(),
    order: [for (final term in ordering) term.qualified()],
    limit: maxRows,
    offset: skipped,
  );

  @override
  DbTable<Object?> get _homeTable => from;

  @override
  Future<Result<List<JoinRow>, DbError>> _runOn(QueryExecutor executor) =>
      load(executor);

  /// The combined rows of [on], another database than the one of the
  /// tables (awaiting the query reads that one).
  Future<Result<List<JoinRow>, DbError>> load(QueryExecutor on) async =>
      (await on.run(
        statement,
      )).map((rows) => [for (final row in rows) JoinRow(row)]);
}
