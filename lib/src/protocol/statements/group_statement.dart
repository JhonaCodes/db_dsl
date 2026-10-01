part of '../statement.dart';

/// The functions of a [GroupAggregate].
enum GroupFunction {
  /// Rows of the group, or rows whose field is not `null`.
  count('count'),

  /// Sum of the numbers (integers stay integers unless they overflow).
  sum('sum'),

  /// Average of the numbers, as a double.
  avg('avg'),

  /// Smallest value in the total order.
  min('min'),

  /// Largest value in the total order.
  max('max');

  const GroupFunction(this.wire);

  /// The `function` of the protocol.
  final String wire;

  /// Functions by their `function`.
  static final Map<String, GroupFunction> byWire = {
    for (final function in values) function.wire: function,
  };
}

/// One aggregate of a [GroupStatement], stored in each group row as [alias].
final class GroupAggregate {
  /// [function] over [field] (every row for a `count` without field).
  const GroupAggregate(this.function, this.alias, {this.field});

  /// How the values combine.
  final GroupFunction function;

  /// The field path aggregated; `null` only for `count` (rows of the group).
  final String? field;

  /// The name of the result in the group row: non-empty, without `.`.
  final String alias;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'function': function.wire,
    'field': ?field,
    'as': alias,
  };

  /// The aggregate encoded in [json].
  static Result<GroupAggregate, DbError> decode(Object? json) => switch (json) {
    {'function': final String function, 'as': final String alias}
        when GroupFunction.byWire.containsKey(function) &&
            (json['field'] == null || json['field'] is String) =>
      Ok(
        GroupAggregate(
          GroupFunction.byWire[function]!,
          alias,
          field: json['field'] as String?,
        ),
      ),
    _ => Statement._invalid('aggregate', json),
  };
}

/// `SELECT by, aggregates FROM table WHERE filter GROUP BY by HAVING having
/// ORDER BY order LIMIT limit OFFSET offset`.
///
/// One output row per group: the [by] values at their paths plus one field
/// per aggregate. Without [by], one group over every matching row (it exists
/// even when no row matches). Without [order], groups come in ascending order
/// of their key encoding. Evaluation order: filter, group, having, order,
/// offset, limit.
final class GroupStatement extends ReadStatement<List<Map<String, Object?>>> {
  /// Groups the rows of [table] by [by].
  const GroupStatement(
    super.table, {
    this.filter,
    this.by = const [],
    this.aggregates = const [],
    this.having,
    this.order = const [],
    this.limit,
    this.offset,
  });

  /// The rows grouped; every row when `null`.
  final Expression? filter;

  /// The paths whose values form a group (a missing value is `null`, which
  /// forms its own group).
  final List<String> by;

  /// The aggregates computed per group.
  final List<GroupAggregate> aggregates;

  /// A condition on the group rows (their fields are [by] and the aliases).
  final Expression? having;

  /// Sort keys over the group rows.
  final List<OrderingTerm> order;

  /// At most this many groups.
  final int? limit;

  /// Groups skipped before the first one returned.
  final int? offset;

  @override
  Map<String, Object?> toJson() => {
    'op': 'group',
    'table': table,
    'filter': ?filter?.toJson(),
    'by': by,
    'aggregates': [for (final aggregate in aggregates) aggregate.toJson()],
    'having': ?having?.toJson(),
    if (order.isNotEmpty) 'order': [for (final term in order) term.toJson()],
    'limit': ?limit,
    'offset': ?offset,
  };

  /// The group statement encoded in [json] for [table].
  static Result<Statement<Object?>, DbError> decode(
    String table,
    Map<Object?, Object?> json,
  ) {
    final aggregates = <GroupAggregate>[];

    for (final aggregate in switch (json['aggregates']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    }) {
      switch (GroupAggregate.decode(aggregate)) {
        case Ok(:final data):
          aggregates.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    final by = switch (json['by'] ?? const <Object?>[]) {
      final List<Object?> paths when paths.every((path) => path is String) =>
        paths.cast<String>(),
      _ => null,
    };

    if (by == null) {
      return Statement._invalid('group', json);
    }

    final having = switch (json['having']) {
      null => null,
      final Object expression => Expression.decode(expression),
    };

    if (having case Err(:final DbError error)) {
      return Err(error);
    }

    return SelectStatement.decode(table, {
      'filter': json['filter'],
      'order': json['order'],
      'limit': json['limit'],
      'offset': json['offset'],
    }).flatMap(
      (query) => switch (query) {
        final SelectStatement select => Ok(
          GroupStatement(
            table,
            filter: select.filter,
            by: by,
            aggregates: aggregates,
            having: having?.when(
              ok: (condition) => condition,
              err: (_) => null,
            ),
            order: select.order,
            limit: select.limit,
            offset: select.offset,
          ),
        ),
        _ => Statement._invalid('group', json),
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
