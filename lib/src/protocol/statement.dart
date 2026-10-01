/// The statements of the protocol (`PROTOCOL.md`, "Statements"): what the
/// DSL sends to an engine inside `execute`, `batch` and `tx_execute`, and the
/// shape of each answer.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../query/expression.dart';
import '../query/ordering.dart';

part 'statements/select_statement.dart';
part 'statements/read_statements.dart';
part 'statements/write_statements.dart';
part 'statements/group_statement.dart';
part 'statements/join_statement.dart';

/// A statement on one table, answered with an output of type [O].
///
/// Why sealed and generic: every statement has exactly one output shape
/// (rows, one row, a count, a value, affected rows). Typing the output here
/// lets an executor return `Result<O, DbError>` without casts, and a closed
/// family lets engines handle every statement exhaustively.
sealed class Statement<O> {
  const Statement(this.table);

  /// The table the statement reads or writes.
  final String table;

  /// The protocol form (`{"op": ..., "table": ..., ...}`).
  Map<String, Object?> toJson();

  /// The output encoded in an `ok` payload of this statement.
  Result<O, DbError> decodeOutput(Object? payload);

  /// The `ok` payload of [output]; engines written in Dart use it so the
  /// answer shape stays defined in one place.
  Map<String, Object?> encodeOutput(O output);

  /// The statement encoded in [json].
  static Result<Statement<Object?>, DbError> decode(
    Object? json,
  ) => switch (json) {
    {'op': 'select', 'table': final String table} => SelectStatement.decode(
      table,
      json,
    ),
    {'op': 'group', 'table': final String table} => GroupStatement.decode(
      table,
      json,
    ),
    {'op': 'join'} => JoinStatement.decode(json),
    {'op': 'count', 'table': final String table} => _filterOf(
      json,
    ).map((filter) => CountStatement(table, filter: filter)),
    {
      'op': 'aggregate',
      'table': final String table,
      'function': final String function,
      'field': final String field,
    }
        when AggregateFunction.byWire.containsKey(function) =>
      _filterOf(json).map(
        (filter) => AggregateStatement(
          table,
          AggregateFunction.byWire[function]!,
          field,
          filter: filter,
        ),
      ),
    {'op': 'find', 'table': final String table, 'key': final Object? key} => Ok(
      FindStatement(table, key),
    ),
    {
      'op': 'insert',
      'table': final String table,
      'rows': final List<Object?> rows,
    }
        when rows.every((row) => row is Map<String, Object?>) =>
      switch (OnConflict.byWire[json['on_conflict'] ?? 'error']) {
        final OnConflict onConflict => Ok(
          InsertStatement(
            table,
            rows.cast<Map<String, Object?>>(),
            onConflict: onConflict,
          ),
        ),
        null => _invalid('on_conflict', json),
      },
    {'op': 'update', 'table': final String table} => switch ((
      json['set'] ?? const <String, Object?>{},
      json['increment'] ?? const <String, Object?>{},
    )) {
      (final Map<String, Object?> set, final Map<String, Object?> increment)
          when increment.values.every((delta) => delta is num) =>
        _writeFilterOf(json).map(
          (parts) => UpdateStatement(
            table,
            set,
            filter: parts.$1,
            expectedRows: parts.$2,
            increment: increment.cast<String, num>(),
          ),
        ),
      _ => _invalid('update', json),
    },
    {'op': 'delete', 'table': final String table} => _writeFilterOf(json).map(
      (parts) =>
          DeleteStatement(table, filter: parts.$1, expectedRows: parts.$2),
    ),
    _ => _invalid('statement', json),
  };

  static Result<Expression?, DbError> _filterOf(Map<Object?, Object?> json) =>
      switch (json['filter']) {
        null => Ok(null),
        final Object filter => Expression.decode(filter),
      };

  static Result<(Expression?, int?), DbError> _writeFilterOf(
    Map<Object?, Object?> json,
  ) => switch (json['expect']) {
    null => _filterOf(json).map((filter) => (filter, null)),
    final int expect when expect >= 0 => _filterOf(
      json,
    ).map((filter) => (filter, expect)),
    _ => _invalid('expect', json),
  };

  static Err<T, DbError> _invalid<T>(String what, Object? json) =>
      Err(DbError(DbErrorCode.invalidRequest, 'Not a valid $what: $json'));

  static Result<T, DbError> _field<T>(
    Object? payload,
    String name,
    Result<T, DbError> Function(Object? value) read,
  ) => switch (payload) {
    Map<String, Object?>() when payload.containsKey(name) => read(
      payload[name],
    ),
    _ => Err(
      DbError(
        DbErrorCode.unsupportedProtocol,
        'The engine answered without `$name`: $payload',
      ),
    ),
  };

  static Result<List<Map<String, Object?>>, DbError> _rows(Object? value) =>
      switch (value) {
        final List<Object?> rows
            when rows.every((row) => row is Map<String, Object?>) =>
          Ok(rows.cast<Map<String, Object?>>()),
        _ => Err(
          DbError(DbErrorCode.unsupportedProtocol, 'Rows expected: $value'),
        ),
      };

  @override
  String toString() => '$runtimeType(${toJson()})';
}

/// A statement that only reads.
sealed class ReadStatement<O> extends Statement<O> {
  const ReadStatement(super.table);
}

/// A statement that writes, answered with the affected rows.
sealed class WriteStatement extends Statement<WriteOutput> {
  const WriteStatement(super.table, {this.filter, this.expectedRows});

  /// Rows to write; every row when `null` (not used by inserts).
  final Expression? filter;

  /// The statement fails, writing nothing, unless exactly this many rows are
  /// affected (`expectAffectedRows`).
  final int? expectedRows;

  @override
  Result<WriteOutput, DbError> decodeOutput(Object? payload) =>
      Statement._field(
        payload,
        'affected',
        (affected) => switch ((affected, (payload! as Map)['rows'])) {
          (final int count, null) => Ok(WriteOutput(count)),
          (final int count, final Object rows) => Statement._rows(
            rows,
          ).map((decoded) => WriteOutput(count, rows: decoded)),
          _ => Err(
            DbError(
              DbErrorCode.unsupportedProtocol,
              'Bad write output: $payload',
            ),
          ),
        },
      );

  @override
  Map<String, Object?> encodeOutput(WriteOutput output) => {
    'affected': output.affected,
    'rows': output.rows,
  };
}

/// What a write did: how many rows it affected and, for inserts, the rows as
/// stored (with generated keys).
final class WriteOutput {
  /// [affected] rows, and the inserted [rows].
  const WriteOutput(this.affected, {this.rows = const []});

  /// Rows inserted, updated or deleted.
  final int affected;

  /// The inserted rows as stored; empty for updates and deletes.
  final List<Map<String, Object?>> rows;
}
