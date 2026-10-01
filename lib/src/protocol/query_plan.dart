/// The answer of `explain`: how an engine will visit the rows of a query.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';

/// How a plan reaches the rows.
enum PlanAccess {
  /// One lookup by primary key.
  primaryKeyLookup('primary_key_lookup'),

  /// A range of primary keys.
  primaryKeyRange('primary_key_range'),

  /// A range of a secondary index.
  indexScan('index_scan'),

  /// Every row of the table.
  fullScan('full_scan'),

  /// An access this version does not know (a newer engine).
  unknown('');

  const PlanAccess(this.wire);

  /// The `access` of the protocol.
  final String wire;

  /// The access named [wire], or [unknown].
  static PlanAccess fromWire(String wire) => values.firstWhere(
    (access) => access.wire == wire && access != unknown,
    orElse: () => unknown,
  );
}

/// How an engine will run a query, without running it.
///
/// Why it exists: an index that is never chosen is pure write cost;
/// `explain` shows the choice so a missing or useless index can be spotted.
final class QueryPlan {
  /// A plan over [table].
  const QueryPlan({
    required this.table,
    required this.access,
    this.index,
    this.descending = false,
    this.presorted = false,
    this.exact = false,
  });

  /// The queried table.
  final String table;

  /// How the rows are reached.
  final PlanAccess access;

  /// The index used by an [PlanAccess.indexScan].
  final String? index;

  /// Keys are visited in descending order.
  final bool descending;

  /// Rows come out already sorted as requested (no sort step).
  final bool presorted;

  /// The visited keys alone satisfy the filter: rows are not checked again,
  /// and a count reads no row.
  final bool exact;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'table': table,
    'access': access.wire,
    'index': index,
    'descending': descending,
    'presorted': presorted,
    'exact': exact,
  };

  /// The plan encoded in [json].
  static Result<QueryPlan, DbError> decode(Object? json) => switch (json) {
    {'table': final String table, 'access': final String access} => Ok(
      QueryPlan(
        table: table,
        access: PlanAccess.fromWire(access),
        index: json['index'] as String?,
        descending: json['descending'] == true,
        presorted: json['presorted'] == true,
        exact: json['exact'] == true,
      ),
    ),
    _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bad plan: $json')),
  };

  @override
  String toString() => 'QueryPlan(${toJson()})';
}
