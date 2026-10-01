part of '../statement.dart';

/// What an insert does when a primary key already exists.
enum OnConflict {
  /// Fail with [DbErrorCode.duplicateKey] (default).
  error('error'),

  /// Replace the existing row.
  replace('replace'),

  /// Keep the existing row and skip the new one.
  ignore('ignore');

  const OnConflict(this.wire);

  /// The `on_conflict` of the protocol.
  final String wire;

  /// Policies by their `on_conflict`.
  static final Map<String, OnConflict> byWire = {
    for (final policy in values) policy.wire: policy,
  };
}

/// `INSERT INTO table VALUES rows`, all or none.
final class InsertStatement extends WriteStatement {
  /// Inserts [rows] into [table].
  const InsertStatement(
    super.table,
    this.rows, {
    this.onConflict = OnConflict.error,
  });

  /// The rows, as stored; an auto-increment table generates a missing key.
  final List<Map<String, Object?>> rows;

  /// What happens when a primary key already exists.
  final OnConflict onConflict;

  @override
  Map<String, Object?> toJson() => {
    'op': 'insert',
    'table': table,
    'on_conflict': onConflict.wire,
    'rows': rows,
  };
}

/// `UPDATE table SET set, field = field + delta WHERE filter`; the primary
/// key cannot change.
final class UpdateStatement extends WriteStatement {
  /// Sets the fields of [set] and adds the deltas of [increment] on the rows
  /// of [table] matching the filter.
  const UpdateStatement(
    super.table,
    this.set, {
    super.filter,
    super.expectedRows,
    this.increment = const {},
  });

  /// New values by field path (`'address.city'` creates the objects on the
  /// way); `null` stores `null`.
  final Map<String, Object?> set;

  /// Numbers added to the current values by field path (a counter,
  /// `UPDATE ... SET views = views + 1`); a missing or `null` value counts as
  /// `0`. A path cannot be in both [set] and [increment].
  final Map<String, num> increment;

  @override
  Map<String, Object?> toJson() => {
    'op': 'update',
    'table': table,
    'filter': ?filter?.toJson(),
    'set': set,
    if (increment.isNotEmpty) 'increment': increment,
    'expect': ?expectedRows,
  };
}

/// `DELETE FROM table WHERE filter`.
final class DeleteStatement extends WriteStatement {
  /// Deletes the rows of [table] matching the filter.
  const DeleteStatement(super.table, {super.filter, super.expectedRows});

  @override
  Map<String, Object?> toJson() => {
    'op': 'delete',
    'table': table,
    'filter': ?filter?.toJson(),
    'expect': ?expectedRows,
  };
}
