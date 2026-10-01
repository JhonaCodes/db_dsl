/// Sort keys of a query (`ORDER BY`).
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';

/// One sort key: a field and its direction.
///
/// Built with `column.asc()` or `column.desc()`. Values sort by the total
/// order of the protocol (`PROTOCOL.md`, "Values"): `null` first, then
/// booleans, numbers, strings, arrays and objects.
final class OrderingTerm {
  /// Sorts by [field], ascending unless [descending].
  const OrderingTerm(this.field, {this.descending = false, this.table});

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// This sort key with its field prefixed by its table, a path of a
  /// combined join row.
  OrderingTerm qualified() => switch (table) {
    null => this,
    final String owner => OrderingTerm('$owner.$field', descending: descending),
  };

  /// Largest values first.
  final bool descending;

  /// The protocol form (`{"field": ..., "desc": ...}`).
  Map<String, Object?> toJson() => {'field': field, 'desc': descending};

  /// The sort key encoded in [json] (`desc` defaults to `false`).
  static Result<OrderingTerm, DbError> decode(Object? json) => switch (json) {
    {'field': final String field, 'desc': final bool desc} => Ok(
      OrderingTerm(field, descending: desc),
    ),
    {'field': final String field} when !json.containsKey('desc') => Ok(
      OrderingTerm(field),
    ),
    _ => Err(
      DbError(DbErrorCode.invalidRequest, 'Not a valid sort key: $json'),
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is OrderingTerm &&
      other.field == field &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(field, descending);

  @override
  String toString() => '$field ${descending ? 'DESC' : 'ASC'}';
}
