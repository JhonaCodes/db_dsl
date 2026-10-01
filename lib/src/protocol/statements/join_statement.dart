part of '../statement.dart';

/// How a [JoinClause] treats a row without matches.
enum JoinKind {
  /// Drops it (`INNER JOIN`).
  inner('inner'),

  /// Keeps it once, with `null` for the joined table (`LEFT JOIN`).
  left('left');

  const JoinKind(this.wire);

  /// The `kind` of the protocol.
  final String wire;

  /// Kinds by their `kind`.
  static final Map<String, JoinKind> byWire = {
    for (final kind in values) kind.wire: kind,
  };
}

/// One joined table of a [JoinStatement].
final class JoinClause {
  /// Joins [table] where its [right] path equals the [left] path of the
  /// combined row.
  const JoinClause(
    this.table, {
    required this.kind,
    required this.left,
    required this.right,
    String? alias,
  }) : alias = alias ?? table;

  /// The joined table.
  final String table;

  /// The key of its rows in the combined row (the table name by default).
  final String alias;

  /// Inner or left.
  final JoinKind kind;

  /// A path into the combined row built so far (`'users.id'`).
  final String left;

  /// A path into the rows of [table] (`'author_id'`).
  final String right;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'table': table,
    'as': alias,
    'kind': kind.wire,
    'on': {'left': left, 'right': right},
  };

  /// The clause encoded in [json].
  static Result<JoinClause, DbError> decode(Object? json) => switch (json) {
    {
      'table': final String table,
      'kind': final String kind,
      'on': {'left': final String left, 'right': final String right},
    }
        when JoinKind.byWire.containsKey(kind) &&
            (json['as'] == null || json['as'] is String) =>
      Ok(
        JoinClause(
          table,
          kind: JoinKind.byWire[kind]!,
          left: left,
          right: right,
          alias: json['as'] as String?,
        ),
      ),
    _ => Statement._invalid('join clause', json),
  };
}

/// `SELECT * FROM from JOIN ... WHERE filter ORDER BY order LIMIT limit
/// OFFSET offset`, with each output row combining one row per table under
/// its alias: `{"users": {...}, "posts": {...} | null}`.
///
/// Filters and sort keys use paths into the combined row (`'users.name'`).
/// Without [order], rows come in primary key order of [table], then of each
/// joined table. Evaluation order: build, filter, order, offset, limit.
final class JoinStatement extends ReadStatement<List<Map<String, Object?>>> {
  /// Joins [joins] onto the rows of [table] (the `from` table).
  const JoinStatement(
    super.table, {
    String? alias,
    this.joins = const [],
    this.filter,
    this.order = const [],
    this.limit,
    this.offset,
  }) : alias = alias ?? table;

  /// The key of the `from` rows in the combined row.
  final String alias;

  /// The joined tables, in order.
  final List<JoinClause> joins;

  /// The combined rows to return; every one when `null`.
  final Expression? filter;

  /// Sort keys over the combined rows.
  final List<OrderingTerm> order;

  /// At most this many rows.
  final int? limit;

  /// Rows skipped before the first one returned.
  final int? offset;

  @override
  Map<String, Object?> toJson() => {
    'op': 'join',
    'from': {'table': table, 'as': alias},
    'joins': [for (final join in joins) join.toJson()],
    'filter': ?filter?.toJson(),
    if (order.isNotEmpty) 'order': [for (final term in order) term.toJson()],
    'limit': ?limit,
    'offset': ?offset,
  };

  /// The join statement encoded in [json].
  static Result<Statement<Object?>, DbError> decode(
    Map<Object?, Object?> json,
  ) {
    final from = switch (json['from']) {
      final Map<Object?, Object?> map => map,
      _ => const <Object?, Object?>{},
    };

    if ((from['table'], from['as']) case (
      final String table,
      final String? alias,
    )) {
      return _decodeFrom(table, alias, json);
    }

    return Statement._invalid('join', json);
  }

  static Result<Statement<Object?>, DbError> _decodeFrom(
    String table,
    String? alias,
    Map<Object?, Object?> json,
  ) {
    final joins = <JoinClause>[];

    for (final join in switch (json['joins']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    }) {
      switch (JoinClause.decode(join)) {
        case Ok(:final data):
          joins.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return SelectStatement.decode(table, {
      'filter': json['filter'],
      'order': json['order'],
      'limit': json['limit'],
      'offset': json['offset'],
    }).flatMap(
      (query) => switch (query) {
        final SelectStatement select => Ok(
          JoinStatement(
            table,
            alias: alias,
            joins: joins,
            filter: select.filter,
            order: select.order,
            limit: select.limit,
            offset: select.offset,
          ),
        ),
        _ => Statement._invalid('join', json),
      },
    );
  }

  @override
  Result<List<Map<String, Object?>>, DbError> decodeOutput(Object? payload) =>
      Statement._field(payload, 'rows', Statement._rows);

  @override
  Map<String, Object?> encodeOutput(List<Map<String, Object?>> output) => {
    'rows': output,
  };
}
