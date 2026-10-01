/// The committed data of a [MemoryEngine] database and its transactions.
library;

import 'dart:async';

import 'package:logger_rs/logger_rs.dart';
import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/request.dart';
import '../protocol/statement.dart';
import 'memory_executor.dart';
import 'memory_state.dart';

/// One database of a [MemoryEngine]: its committed state, its single
/// writer and its open transactions.
///
/// It follows offline_first_core (`engine/session.rs`): one write
/// transaction at a time, reads on snapshots, idle transactions rolled back,
/// and the same error for every misuse.
final class MemoryStore {
  /// An empty database.
  MemoryStore();

  /// The last committed state. It is never changed in place: writes build a
  /// copy and replace it, so a snapshot is just a reference.
  MemoryState committed = MemoryState();

  final _WriterLock _writer = _WriterLock();
  final Map<int, MemorySession> _sessions = {};
  final Map<int, Duration> _expired = {};
  int _lastId = 0;

  /// Root write transactions so far: each numbers the changes it records.
  int _roots = 0;

  /// Runs [write] on a copy of the committed state under the writer, and
  /// commits the copy when it answers `Ok`.
  Future<Result<O, DbError>> autocommit<O>(
    Result<O, DbError> Function(MemoryExecutor executor) write,
  ) async {
    final release = await _writer.acquire();

    try {
      final copy = committed.copy();
      final result = write(MemoryExecutor(copy, transaction: ++_roots));

      if (result.isOk) {
        committed = copy;
      }

      return result;
    } finally {
      release();
    }
  }

  /// Opens a transaction; write transactions wait for the writer.
  Future<int> begin(TransactionMode mode, Duration idleTimeout) async {
    final id = ++_lastId;

    final session = switch (mode) {
      TransactionMode.write => MemorySession._write(
        this,
        id,
        await _writer.acquire(),
        idleTimeout,
      ),
      TransactionMode.read => MemorySession._read(this, id, idleTimeout),
    };

    _sessions[id] = session;
    return id;
  }

  /// The open transaction [id], or why it cannot be used.
  Result<MemorySession, DbError> session(int id) => switch (_sessions[id]) {
    final MemorySession session => Ok(session),
    null when _expired.containsKey(id) => Err(
      DbError(
        DbErrorCode.transactionExpired,
        'Transaction $id was rolled back after ${_expired[id]} without '
        'activity',
      ),
    ),
    null when id > _lastId || id <= 0 => Err(
      DbError(DbErrorCode.unknownTransaction, 'Unknown transaction $id'),
    ),
    null => Err(
      DbError(DbErrorCode.transactionClosed, 'Transaction $id is closed'),
    ),
  };

  void _end(MemorySession session, {bool expired = false}) {
    _sessions.remove(session.id);

    if (expired) {
      _expired[session.id] = session.idleTimeout;
      Log.w(
        'Transaction ${session.id} rolled back after ${session.idleTimeout} '
        'without activity',
      );
    }
  }
}

/// One level of a write transaction: the transaction itself or a savepoint.
final class _Level {
  _Level(this.state);

  /// The data as this level sees it.
  MemoryState state;

  /// A write failed at this level: it can only be rolled back.
  bool rollbackOnly = false;
}

/// An open transaction of a [MemoryStore].
///
/// Why levels: a savepoint is a nested copy of its parent's state. Releasing
/// it replaces the parent's state; rolling it back drops it. Each level has
/// its own rollback-only flag, exactly like the nested LMDB transactions of
/// offline_first_core.
final class MemorySession {
  MemorySession._write(
    this._store,
    this.id,
    this._releaseWriter,
    this.idleTimeout,
  ) : mode = TransactionMode.write,
      _root = ++_store._roots,
      _levels = [_Level(_store.committed.copy())] {
    _touch();
  }

  MemorySession._read(this._store, this.id, this.idleTimeout)
    : mode = TransactionMode.read,
      _releaseWriter = null,
      _root = 0,
      _levels = [_Level(_store.committed)] {
    _touch();
  }

  final MemoryStore _store;

  /// The transaction id.
  final int id;

  /// Write or read.
  final TransactionMode mode;

  /// Idle time after which the transaction is rolled back.
  final Duration idleTimeout;

  final void Function()? _releaseWriter;
  final int _root;
  final List<_Level> _levels;
  Timer? _idle;
  bool _finished = false;

  /// Runs [statement] at the innermost level.
  Result<Object?, DbError> execute(Statement<Object?> statement) {
    _touch();
    final level = _levels.last;

    return switch ((mode, statement)) {
      (TransactionMode.read, WriteStatement()) => Err(
        DbError(
          DbErrorCode.readOnlyTransaction,
          'Transaction $id is read-only',
        ),
      ),
      (TransactionMode.write, _) when level.rollbackOnly => _aborted(),
      (_, ReadStatement()) => MemoryExecutor(level.state).execute(statement),
      (TransactionMode.write, WriteStatement()) => _write(level, statement),
    };
  }

  /// Applies [control]: savepoint, release, rollback to, commit, rollback.
  Result<(), DbError> control(TransactionControl control) {
    _touch();

    return switch ((mode, control)) {
      (TransactionMode.read, TransactionControl.commit) ||
      (TransactionMode.read, TransactionControl.rollback) ||
      (TransactionMode.write, TransactionControl.rollback) => _finish(),
      (TransactionMode.read, _) => Err(
        DbError(
          DbErrorCode.readOnlyTransaction,
          'Transaction $id is read-only',
        ),
      ),
      (TransactionMode.write, TransactionControl.savepoint) => _savepoint(),
      (TransactionMode.write, TransactionControl.release) =>
        _releaseSavepoint(),
      (TransactionMode.write, TransactionControl.rollbackTo) => _rollbackTo(),
      (TransactionMode.write, TransactionControl.commit) => _commit(),
    };
  }

  Result<Object?, DbError> _write(_Level level, Statement<Object?> statement) {
    final copy = level.state.copy();
    final result = MemoryExecutor(copy, transaction: _root).execute(statement);

    if (result.isOk) {
      level.state = copy;
    } else {
      level.rollbackOnly = true;
    }

    return result;
  }

  Result<(), DbError> _savepoint() {
    final level = _levels.last;

    if (level.rollbackOnly) {
      return _aborted();
    }

    _levels.add(_Level(level.state.copy()));
    return Ok(());
  }

  Result<(), DbError> _releaseSavepoint() {
    if (_levels.length == 1) {
      return _noSavepoint();
    }

    final child = _levels.removeLast();

    if (child.rollbackOnly) {
      return _aborted();
    }

    _levels.last.state = child.state;
    return Ok(());
  }

  Result<(), DbError> _rollbackTo() {
    if (_levels.length == 1) {
      return _noSavepoint();
    }

    _levels.removeLast();
    return Ok(());
  }

  Result<(), DbError> _commit() {
    if (_levels.length > 1) {
      return Err(
        DbError(
          DbErrorCode.savepointOpen,
          'Transaction $id has an open savepoint',
        ),
      );
    }

    final top = _levels.single;

    if (top.rollbackOnly) {
      _finish();
      return _aborted();
    }

    _store.committed = top.state;
    return _finish();
  }

  /// Ends the transaction once: stops the timer, frees the writer and
  /// forgets the session.
  Result<(), DbError> _finish({bool expired = false}) {
    if (!_finished) {
      _finished = true;
      _idle?.cancel();
      _releaseWriter?.call();
      _store._end(this, expired: expired);
    }

    return Ok(());
  }

  /// Restarts the idle timer: the transaction expires when nothing arrives
  /// for [idleTimeout].
  void _touch() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () => _finish(expired: true));
  }

  Err<T, DbError> _aborted<T>() => Err(
    DbError(
      DbErrorCode.transactionAborted,
      'A write failed in transaction $id; it can only be rolled back',
    ),
  );

  Err<T, DbError> _noSavepoint<T>() => Err(
    DbError(DbErrorCode.noSavepoint, 'Transaction $id has no open savepoint'),
  );
}

/// The single writer of a [MemoryStore].
///
/// Why a queue: LMDB lets one write transaction run at a time and makes the
/// others wait; waiters here get the writer in arrival order.
final class _WriterLock {
  Future<void> _tail = Future<void>.value();

  /// Waits for the writer; call the answered function to release it.
  Future<void Function()> acquire() async {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    await previous;

    return released.complete;
  }
}
