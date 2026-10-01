part of '../statement.dart';

/// `SELECT COUNT(*) FROM table WHERE filter`.
final class CountStatement extends ReadStatement<int> {
  /// Counts the rows of [table] matching [filter].
  const CountStatement(super.table, {this.filter});

  /// The rows to count; every row when `null`.
  final Expression? filter;

  @override
  Map<String, Object?> toJson() => {
    'op': 'count',
    'table': table,
    'filter': ?filter?.toJson(),
  };

  @override
  Result<int, DbError> decodeOutput(Object? payload) => Statement._field(
    payload,
    'count',
    (count) => switch (count) {
      final int value => Ok(value),
      _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bad count: $count')),
    },
  );

  @override
  Map<String, Object?> encodeOutput(int output) => {'count': output};
}

/// The aggregate functions, named as in Diesel.
enum AggregateFunction {
  /// Sum of the numbers (integers stay integers unless they overflow).
  sum('sum'),

  /// Average of the numbers, as a double.
  avg('avg'),

  /// Smallest value in the total order.
  min('min'),

  /// Largest value in the total order.
  max('max');

  const AggregateFunction(this.wire);

  /// The `function` of the protocol.
  final String wire;

  /// Functions by their `function`.
  static final Map<String, AggregateFunction> byWire = {
    for (final function in values) function.wire: function,
  };
}

/// `SELECT function(field) FROM table WHERE filter`; `null` when no row has a
/// value (for `sum` and `avg`, a number).
final class AggregateStatement extends ReadStatement<Object?> {
  /// Aggregates [field] of [table] with [function].
  const AggregateStatement(
    super.table,
    this.function,
    this.field, {
    this.filter,
  });

  /// How the values combine.
  final AggregateFunction function;

  /// Field path aggregated.
  final String field;

  /// The rows aggregated; every row when `null`.
  final Expression? filter;

  @override
  Map<String, Object?> toJson() => {
    'op': 'aggregate',
    'table': table,
    'filter': ?filter?.toJson(),
    'function': function.wire,
    'field': field,
  };

  @override
  Result<Object?, DbError> decodeOutput(Object? payload) =>
      Statement._field(payload, 'value', Ok.new);

  @override
  Map<String, Object?> encodeOutput(Object? output) => {'value': output};
}

/// The row whose primary key is [key], or `null`.
final class FindStatement extends ReadStatement<Map<String, Object?>?> {
  /// Looks up [key] in [table].
  const FindStatement(super.table, this.key);

  /// The stored form of the primary key.
  final Object? key;

  @override
  Map<String, Object?> toJson() => {'op': 'find', 'table': table, 'key': key};

  @override
  Result<Map<String, Object?>?, DbError> decodeOutput(Object? payload) =>
      Statement._field(
        payload,
        'row',
        (row) => switch (row) {
          null => Ok(null),
          final Map<String, Object?> value => Ok(value),
          _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bad row: $row')),
        },
      );

  @override
  Map<String, Object?> encodeOutput(Map<String, Object?>? output) => {
    'row': output,
  };
}
