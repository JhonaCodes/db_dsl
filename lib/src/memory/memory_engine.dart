/// An engine of the protocol that keeps its databases in memory.
library;

import 'dart:convert';

import 'package:result_controller/result_controller.dart';

import '../engine/db_options.dart';
import '../engine/engine.dart';
import '../errors/db_error.dart';
import '../protocol/engine_info.dart';
import '../protocol/request.dart';
import '../protocol/statement.dart';
import 'memory_executor.dart';
import 'memory_state.dart';
import 'memory_store.dart';

/// Answers the protocol in memory, with the observable behavior of
/// offline_first_core: the same results, errors, transactions, savepoints,
/// key order and key limits.
///
/// Why it exists: the DSL must be testable without a native library — by
/// db_dsl itself, by the libraries built on it, and by apps testing their
/// repositories. The conformance suite (`package:db_dsl/conformance.dart`)
/// runs against it and against every native engine, so both stay the same.
///
/// Databases live as long as the engine: closing and reopening a path finds
/// its data again, like files. It does not emulate the planner (`explain`
/// always answers a full scan), durability or map growth.
final class MemoryEngine implements Engine {
  /// An engine with no database yet.
  MemoryEngine();

  final Map<String, MemoryStore> _stores = {};

  @override
  Future<Result<EngineConnection, DbError>> open(
    String path,
    DbOptions options,
  ) async => Ok(MemoryConnection._(_stores.putIfAbsent(path, MemoryStore.new)));
}

/// An open database of a [MemoryEngine].
final class MemoryConnection implements EngineConnection {
  MemoryConnection._(this._store);

  final MemoryStore _store;
  bool _closed = false;

  @override
  Future<Result<Map<String, Object?>, DbError>> send(
    ProtocolRequest<Object?> request,
  ) async {
    if (_closed) {
      return Err(DbError(DbErrorCode.closed, 'The database is closed'));
    }

    // Through JSON, like the wire: the engine never aliases the caller's
    // objects, and a request that is not JSON fails the same way it would
    // with a native engine.
    final Object? wire;

    try {
      wire = jsonDecode(jsonEncode(request.toJson()));
    } on JsonUnsupportedObjectError catch (error) {
      return Err(
        DbError(
          DbErrorCode.invalidRequest,
          'The request is not JSON: ${error.unsupportedObject}',
        ),
      );
    }

    return ProtocolRequest.decode(wire).when(
      ok: (decoded) async => (await _answer(decoded)).map(
        (output) =>
            MemoryState.detached(decoded.encodeOutput(output))!
                as Map<String, Object?>,
      ),
      err: (error) async => Err(error),
    );
  }

  @override
  Future<Result<(), DbError>> close() async {
    _closed = true;
    return Ok(());
  }

  /// The output of [request].
  Future<Result<Object?, DbError>> _answer(
    ProtocolRequest<Object?> request,
  ) async => switch (request) {
    DefineTableRequest(:final schema) => _store.autocommit(
      (executor) => executor.defineTable(schema),
    ),
    DropTableRequest(:final name) => _store.autocommit(
      (executor) => Ok(executor.dropTable(name)),
    ),
    TablesRequest() => Ok(MemoryExecutor(_store.committed).tables()),
    ExecuteRequest(:final statement) => switch (statement) {
      WriteStatement() => _store.autocommit(
        (executor) => executor.execute(statement),
      ),
      ReadStatement() => MemoryExecutor(_store.committed).execute(statement),
    },
    BatchRequest(:final statements) => _store.autocommit(
      (executor) => _batch(executor, statements),
    ),
    ExplainRequest(:final query) => MemoryExecutor(
      _store.committed,
    ).explain(query),
    ExplainJoinRequest(:final query) => MemoryExecutor(
      _store.committed,
    ).explainJoin(query),
    BeginRequest(:final mode, :final idleTimeout) => Ok(
      await _store.begin(mode, idleTimeout),
    ),
    TransactionExecuteRequest(:final transaction, :final statement) =>
      _store
          .session(transaction)
          .flatMap((session) => session.execute(statement)),
    TransactionControlRequest(:final transaction, :final control) =>
      _store
          .session(transaction)
          .flatMap((session) => session.control(control)),
    SyncClaimRequest(:final remote, :final limits) => _store.autocommit(
      (executor) => executor.sync.claim(remote, limits),
    ),
    SyncPushResultRequest(:final remote, :final result) => _store.autocommit(
      (executor) => executor.sync.applyPushResult(remote, result),
    ),
    SyncReleaseRequest(:final remote, :final leaseId, :final reason) =>
      _store.autocommit(
        (executor) => executor.sync.release(remote, leaseId, reason),
      ),
    SyncRetryRequest(:final remote, :final mutationIds) => _store.autocommit(
      (executor) => executor.sync.retry(remote, mutationIds),
    ),
    SyncApplyRemoteRequest(:final remote, :final page) => _store.autocommit(
      (executor) => executor.sync.applyRemote(remote, page),
    ),
    SyncResolveRequest(
      :final conflict,
      :final expectedRowVersion,
      :final resolution,
    ) =>
      _store.autocommit(
        (executor) => executor.sync.resolveConflict(
          conflict,
          expectedRowVersion,
          resolution,
        ),
      ),
    SyncStateRequest(:final table, :final key) => MemoryExecutor(
      _store.committed,
    ).sync.stateOf(table, key),
    SyncPendingRequest(:final remote, :final table, :final limit) =>
      MemoryExecutor(_store.committed).sync.pending(remote, table, limit),
    SyncConflictsRequest(:final remote) => MemoryExecutor(
      _store.committed,
    ).sync.conflicts(remote),
    SyncStatusRequest(:final remote) => MemoryExecutor(
      _store.committed,
    ).sync.status(remote),
    InfoRequest() => Ok(
      EngineInfo(
        protocol: ProtocolRequest.version,
        tables: _store.committed.tables.length,
        storage: 'memory',
        mapSize: 0,
      ),
    ),
  };

  /// Every statement in order on one state, stopping at the first error
  /// (the caller then drops the state, so nothing commits).
  static Result<List<Object?>, DbError> _batch(
    MemoryExecutor executor,
    List<Statement<Object?>> statements,
  ) {
    final outputs = <Object?>[];

    for (final statement in statements) {
      switch (executor.execute(statement)) {
        case Ok(:final data):
          outputs.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(outputs);
  }
}
