part of '../statement.dart';

/// `SELECT fields FROM table WHERE filter ORDER BY order LIMIT limit OFFSET
/// offset`, optionally `DISTINCT`.
///
/// Evaluation order: filter, order (over the stored rows, so sort keys need
/// not be projected), projection, distinct, offset, limit. Without [order]
/// the order of the rows is unspecified; with it, rows that tie on every key
/// come in an unspecified order.
final class SelectStatement extends ReadStatement<List<Map<String, Object?>>> {
  /// A query over [table].
  const SelectStatement(
    super.table, {
    this.filter,
    this.order = const [],
    this.limit,
    this.offset,
    this.fields = const [],
    this.distinct = false,
  });

  /// The rows to return; every row when `null`.
  final Expression? filter;

  /// Sort keys, most significant first.
  final List<OrderingTerm> order;

  /// At most this many rows.
  final int? limit;

  /// Rows skipped before the first one returned.
  final int? offset;

  /// The paths each output row keeps (`SELECT a, b.c`); whole rows when
  /// empty. A missing value is `null` in the output.
  final List<String> fields;

  /// Equal output rows are returned once (`SELECT DISTINCT`); equality is
  /// the key encoding of the projected values, so `1` equals `1.0`.
  final bool distinct;

  /// The query part of a `select` (also the `query` of `explain`).
  Map<String, Object?> toQueryJson() => {
    'table': table,
    'filter': ?filter?.toJson(),
    if (order.isNotEmpty) 'order': [for (final term in order) term.toJson()],
    'limit': ?limit,
    'offset': ?offset,
    if (fields.isNotEmpty) 'fields': fields,
    if (distinct) 'distinct': true,
  };

  @override
  Map<String, Object?> toJson() => {'op': 'select', ...toQueryJson()};

  /// The query encoded in [json] (a `select` statement or an `explain`
  /// query) for [table].
  static Result<Statement<Object?>, DbError> decode(
    String table,
    Map<Object?, Object?> json,
  ) {
    final order = <OrderingTerm>[];

    for (final term in switch (json['order']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    }) {
      switch (OrderingTerm.decode(term)) {
        case Ok(:final data):
          order.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return switch ((
      json['limit'],
      json['offset'],
      json['fields'] ?? const <Object?>[],
      json['distinct'] ?? false,
    )) {
      (
        final int? limit,
        final int? offset,
        final List<Object?> fields,
        final bool distinct,
      )
          when (limit ?? 0) >= 0 &&
              (offset ?? 0) >= 0 &&
              fields.every((field) => field is String) =>
        Statement._filterOf(json).map(
          (filter) => SelectStatement(
            table,
            filter: filter,
            order: order,
            limit: limit,
            offset: offset,
            fields: fields.cast<String>(),
            distinct: distinct,
          ),
        ),
      _ => Statement._invalid('select', json),
    };
  }

  @override
  Result<List<Map<String, Object?>>, DbError> decodeOutput(Object? payload) =>
      Statement._field(payload, 'rows', Statement._rows);

  @override
  Map<String, Object?> encodeOutput(List<Map<String, Object?>> output) => {
    'rows': output,
  };
}
