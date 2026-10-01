/// The requests of the protocol (`PROTOCOL.md`, "Operations"): one class per
/// `op`, each with the shape of its `ok` payload.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../schema/table_schema.dart';
import 'engine_info.dart';
import 'query_plan.dart';
import 'statement.dart';
import 'sync_records.dart';

part 'sync_requests.dart';

/// A request of the protocol, answered with an output of type [O].
///
/// Why sealed and generic: the protocol has a fixed set of operations, and
/// each has one answer shape. Engines written in Dart `switch` over the
/// family exhaustively; the database decodes each answer without casts.
///
/// The family may gain members in a minor release, one per new operation
/// of the protocol (the sync operations arrived in 0.2.4): an engine
/// written in Dart adds the case, apps that never switch over requests are
/// not affected.
sealed class ProtocolRequest<O> {
  const ProtocolRequest();

  /// The protocol version these requests follow (`"v"`).
  static const int version = 1;

  /// The `op` of the request.
  String get op;

  /// The fields of the request besides `v` and `op`.
  Map<String, Object?> get fields;

  /// The protocol form: `{"v": 1, "op": ..., ...fields}`.
  Map<String, Object?> toJson() => {'v': version, 'op': op, ...fields};

  /// The output encoded in an `ok` payload of this request.
  Result<O, DbError> decodeOutput(Object? payload);

  /// The `ok` payload of [output], for engines written in Dart.
  Map<String, Object?> encodeOutput(O output);

  /// The request encoded in [json]: [DbErrorCode.unsupportedProtocol] for
  /// another version, [DbErrorCode.invalidRequest] for anything else that
  /// does not follow the protocol.
  static Result<ProtocolRequest<Object?>, DbError> decode(Object? json) {
    if (json case {'v': final int v} when v != version) {
      return Err(
        DbError(DbErrorCode.unsupportedProtocol, 'Protocol version $v'),
      );
    }

    return switch (json) {
      {'v': version, 'op': 'define_table', 'table': final Object? table} =>
        TableSchema.decode(table).map(DefineTableRequest.new),
      {'v': version, 'op': 'drop_table', 'name': final String name} => Ok(
        DropTableRequest(name),
      ),
      {'v': version, 'op': 'tables'} => Ok(const TablesRequest()),
      {'v': version, 'op': 'execute', 'statement': final Object? statement} =>
        Statement.decode(statement).map(ExecuteRequest.new),
      {
        'v': version,
        'op': 'batch',
        'statements': final List<Object?> statements,
      } =>
        _statements(statements).map(BatchRequest.new),
      {'v': version, 'op': 'explain', 'query': {'table': final String table}} =>
        SelectStatement.decode(table, json['query']! as Map).flatMap(
          (query) => switch (query) {
            final SelectStatement select => Ok(ExplainRequest(select)),
            _ => _invalid(json),
          },
        ),
      {
        'v': version,
        'op': 'explain',
        'query': {'from': Object()} && final Map<Object?, Object?> query,
      } =>
        JoinStatement.decode({...query, 'op': 'join'}).flatMap(
          (decoded) => switch (decoded) {
            final JoinStatement join => Ok(ExplainJoinRequest(join)),
            _ => _invalid(json),
          },
        ),
      {'v': version, 'op': 'begin'} => _begin(json),
      {
        'v': version,
        'op': 'tx_execute',
        'transaction': final int id,
        'statement': final Object? statement,
      } =>
        Statement.decode(
          statement,
        ).map((decoded) => TransactionExecuteRequest(id, decoded)),
      {'v': version, 'op': final String op, 'transaction': final int id}
          when TransactionControl.byWire.containsKey(op) =>
        Ok(TransactionControlRequest(id, TransactionControl.byWire[op]!)),
      {'v': version, 'op': 'info'} => Ok(const InfoRequest()),
      {'v': version, 'op': String()} when _SyncRequests.decode(json) != null =>
        _SyncRequests.decode(json)!,
      {'v': version} => _invalid(json),
      _ => Err(
        DbError(DbErrorCode.unsupportedProtocol, 'Protocol version missing'),
      ),
    };
  }

  static Result<ProtocolRequest<Object?>, DbError> _begin(
    Map<Object?, Object?> json,
  ) => switch ((json['mode'] ?? 'write', json['timeout_ms'])) {
    (final String mode, final int? ms)
        when TransactionMode.byWire.containsKey(mode) && (ms ?? 0) >= 0 =>
      Ok(
        BeginRequest(
          TransactionMode.byWire[mode]!,
          idleTimeout: ms == null
              ? BeginRequest.defaultIdleTimeout
              : Duration(milliseconds: ms),
        ),
      ),
    _ => _invalid(json),
  };

  static Result<List<Statement<Object?>>, DbError> _statements(
    List<Object?> json,
  ) {
    final statements = <Statement<Object?>>[];

    for (final statement in json) {
      switch (Statement.decode(statement)) {
        case Ok(:final data):
          statements.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(statements);
  }

  static Err<T, DbError> _invalid<T>(Object? json) =>
      Err(DbError(DbErrorCode.invalidRequest, 'Not a valid request: $json'));

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

  static Result<bool, DbError> _bool(Object? value) => switch (value) {
    final bool flag => Ok(flag),
    _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bool expected: $value')),
  };

  @override
  String toString() => '$runtimeType(${toJson()})';
}

/// `define_table`: creates [schema], or adds and removes indexes of an
/// existing table (new indexes are built over its rows). Answers whether
/// anything changed.
final class DefineTableRequest extends ProtocolRequest<bool> {
  /// Defines [schema].
  const DefineTableRequest(this.schema);

  /// The definition.
  final TableSchema schema;

  @override
  String get op => 'define_table';

  @override
  Map<String, Object?> get fields => {'table': schema.toJson()};

  @override
  Result<bool, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'changed', ProtocolRequest._bool);

  @override
  Map<String, Object?> encodeOutput(bool output) => {'changed': output};
}

/// `drop_table`: deletes the table [name] with its rows and indexes. Answers
/// whether it existed.
final class DropTableRequest extends ProtocolRequest<bool> {
  /// Drops [name].
  const DropTableRequest(this.name);

  /// The table.
  final String name;

  @override
  String get op => 'drop_table';

  @override
  Map<String, Object?> get fields => {'name': name};

  @override
  Result<bool, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'dropped', ProtocolRequest._bool);

  @override
  Map<String, Object?> encodeOutput(bool output) => {'dropped': output};
}

/// `tables`: the definitions of every table.
final class TablesRequest extends ProtocolRequest<List<TableSchema>> {
  /// Lists the tables.
  const TablesRequest();

  @override
  String get op => 'tables';

  @override
  Map<String, Object?> get fields => const {};

  @override
  Result<List<TableSchema>, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'tables', (value) {
        final schemas = <TableSchema>[];

        for (final table in switch (value) {
          final List<Object?> list => list,
          _ => const <Object?>[],
        }) {
          switch (TableSchema.decode(table)) {
            case Ok(:final data):
              schemas.add(data);
            case Err(:final error):
              return Err(error);
          }
        }

        return Ok(schemas);
      });

  @override
  Map<String, Object?> encodeOutput(List<TableSchema> output) => {
    'tables': [for (final schema in output) schema.toJson()],
  };
}

/// `execute`: runs [statement] in its own transaction.
final class ExecuteRequest<O> extends ProtocolRequest<O> {
  /// Runs [statement].
  const ExecuteRequest(this.statement);

  /// The statement.
  final Statement<O> statement;

  @override
  String get op => 'execute';

  @override
  Map<String, Object?> get fields => {'statement': statement.toJson()};

  @override
  Result<O, DbError> decodeOutput(Object? payload) =>
      statement.decodeOutput(payload);

  @override
  Map<String, Object?> encodeOutput(O output) => statement.encodeOutput(output);
}

/// `batch`: runs [statements] in order in one transaction; all commit or
/// none does. Answers one output per statement.
final class BatchRequest<O> extends ProtocolRequest<List<O>> {
  /// Runs [statements] atomically.
  const BatchRequest(this.statements);

  /// The statements, in order.
  final List<Statement<O>> statements;

  @override
  String get op => 'batch';

  @override
  Map<String, Object?> get fields => {
    'statements': [for (final statement in statements) statement.toJson()],
  };

  @override
  Result<List<O>, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'results', (value) {
        if (value case final List<Object?> results
            when results.length == statements.length) {
          final outputs = <O>[];

          for (final (index, result) in results.indexed) {
            switch (statements[index].decodeOutput(result)) {
              case Ok(:final data):
                outputs.add(data);
              case Err(:final error):
                return Err(error);
            }
          }

          return Ok(outputs);
        }

        return Err(
          DbError(DbErrorCode.unsupportedProtocol, 'Bad batch results: $value'),
        );
      });

  @override
  Map<String, Object?> encodeOutput(List<O> output) => {
    'results': [
      for (final (index, result) in output.indexed)
        statements[index].encodeOutput(result),
    ],
  };
}

/// `explain`: the plan the engine chooses for [query], without running it.
final class ExplainRequest extends ProtocolRequest<QueryPlan> {
  /// Explains [query].
  const ExplainRequest(this.query);

  /// The query.
  final SelectStatement query;

  @override
  String get op => 'explain';

  @override
  Map<String, Object?> get fields => {'query': query.toQueryJson()};

  @override
  Result<QueryPlan, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'plan', QueryPlan.decode);

  @override
  Map<String, Object?> encodeOutput(QueryPlan output) => {
    'plan': output.toJson(),
  };
}

/// `explain` of a join: how the engine would combine the tables of
/// [query], without running it.
final class ExplainJoinRequest extends ProtocolRequest<JoinPlan> {
  /// Explains [query].
  const ExplainJoinRequest(this.query);

  /// The join.
  final JoinStatement query;

  @override
  String get op => 'explain';

  @override
  Map<String, Object?> get fields => {
    'query': {...query.toJson()}..remove('op'),
  };

  @override
  Result<JoinPlan, DbError> decodeOutput(Object? payload) =>
      ProtocolRequest._field(payload, 'plan', JoinPlan.decode);

  @override
  Map<String, Object?> encodeOutput(JoinPlan output) => {
    'plan': output.toJson(),
  };
}

/// What a transaction may do.
enum TransactionMode {
  /// Reads and writes; one write transaction at a time per database.
  write('write'),

  /// A consistent snapshot for reads, running next to writes.
  read('read');

  const TransactionMode(this.wire);

  /// The `mode` of `begin`.
  final String wire;

  /// Modes by their `mode`.
  static final Map<String, TransactionMode> byWire = {
    for (final mode in values) mode.wire: mode,
  };
}

/// `begin`: opens an interactive transaction; answers its id.
///
/// A transaction that receives nothing for [idleTimeout] is rolled back, so
/// a forgotten one cannot hold the writer forever.
final class BeginRequest extends ProtocolRequest<int> {
  /// Begins a [mode] transaction.
  const BeginRequest(this.mode, {this.idleTimeout = defaultIdleTimeout});

  /// The idle timeout when the request does not set `timeout_ms`.
  static const Duration defaultIdleTimeout = Duration(seconds: 30);

  /// Write or read.
  final TransactionMode mode;

  /// Idle time after which the engine rolls the transaction back.
  final Duration idleTimeout;

  @override
  String get op => 'begin';

  @override
  Map<String, Object?> get fields => {
    'mode': mode.wire,
    'timeout_ms': idleTimeout.inMilliseconds,
  };

  @override
  Result<int, DbError> decodeOutput(Object? payload) => ProtocolRequest._field(
    payload,
    'transaction',
    (id) => switch (id) {
      final int value => Ok(value),
      _ => Err(
        DbError(DbErrorCode.unsupportedProtocol, 'Bad transaction id: $id'),
      ),
    },
  );

  @override
  Map<String, Object?> encodeOutput(int output) => {'transaction': output};
}

/// `tx_execute`: runs [statement] inside the open transaction
/// [transaction].
final class TransactionExecuteRequest<O> extends ProtocolRequest<O> {
  /// Runs [statement] in [transaction].
  const TransactionExecuteRequest(this.transaction, this.statement);

  /// The transaction id from `begin`.
  final int transaction;

  /// The statement.
  final Statement<O> statement;

  @override
  String get op => 'tx_execute';

  @override
  Map<String, Object?> get fields => {
    'transaction': transaction,
    'statement': statement.toJson(),
  };

  @override
  Result<O, DbError> decodeOutput(Object? payload) =>
      statement.decodeOutput(payload);

  @override
  Map<String, Object?> encodeOutput(O output) => statement.encodeOutput(output);
}

/// The operations that steer an open transaction.
enum TransactionControl {
  /// Opens a savepoint (a nested level).
  savepoint('savepoint'),

  /// Keeps the writes of the innermost savepoint and closes it.
  release('release'),

  /// Undoes the writes of the innermost savepoint and closes it.
  rollbackTo('rollback_to'),

  /// Commits the transaction.
  commit('commit'),

  /// Rolls the transaction back.
  rollback('rollback');

  const TransactionControl(this.wire);

  /// The `op` of the protocol.
  final String wire;

  /// Controls by their `op`.
  static final Map<String, TransactionControl> byWire = {
    for (final control in values) control.wire: control,
  };
}

/// `savepoint`, `release`, `rollback_to`, `commit` or `rollback` on
/// [transaction]; answers an empty payload.
///
/// One class for the five operations: they share their fields and answer,
/// and differ only in what the engine does.
final class TransactionControlRequest extends ProtocolRequest<()> {
  /// Applies [control] to [transaction].
  const TransactionControlRequest(this.transaction, this.control);

  /// The transaction id from `begin`.
  final int transaction;

  /// What to do.
  final TransactionControl control;

  @override
  String get op => control.wire;

  @override
  Map<String, Object?> get fields => {'transaction': transaction};

  @override
  Result<(), DbError> decodeOutput(Object? payload) => switch (payload) {
    Map<String, Object?>() => Ok(()),
    _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bad answer: $payload')),
  };

  @override
  Map<String, Object?> encodeOutput(() output) => const {};
}

/// `info`: facts about the database and its engine.
final class InfoRequest extends ProtocolRequest<EngineInfo> {
  /// Asks for the info.
  const InfoRequest();

  @override
  String get op => 'info';

  @override
  Map<String, Object?> get fields => const {};

  @override
  Result<EngineInfo, DbError> decodeOutput(Object? payload) =>
      EngineInfo.decode(payload);

  @override
  Map<String, Object?> encodeOutput(EngineInfo output) => output.toJson();
}
