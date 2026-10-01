part of 'database.dart';

/// A write transaction (see [Database.transaction]).
///
/// Statements run on it see its own writes; nothing is visible to others
/// until the commit.
final class Transaction extends QueryExecutor {
  Transaction._(this._database, this._id);

  final Database _database;
  final int _id;

  /// Tables written so far, notified to watchers after the commit.
  final Set<String> _touched = {};
  bool _closed = false;

  @override
  Future<Result<O, DbError>> run<O>(Statement<O> statement) async {
    if (_closed) {
      return Err(
        DbError(DbErrorCode.transactionClosed, 'The transaction is closed'),
      );
    }

    final output = await _database._send(
      TransactionExecuteRequest(_id, statement),
    );

    if (statement is WriteStatement && output.isOk) {
      _touched.add(statement.table);
    }

    return output;
  }

  /// Runs [body] in a savepoint: when it answers `Err` (or throws), only its
  /// writes are rolled back and the transaction goes on; when it answers
  /// `Ok`, its writes stay.
  ///
  /// A write that failed inside the savepoint and was ignored makes the
  /// savepoint fail with [DbErrorCode.transactionAborted] instead of keeping
  /// partial work.
  Future<Result<R, DbError>> savepoint<R>(
    Future<Result<R, DbError>> Function(Transaction tx) body,
  ) async {
    if (_closed) {
      return Err(
        DbError(DbErrorCode.transactionClosed, 'The transaction is closed'),
      );
    }

    if (await _control(TransactionControl.savepoint) case Err(:final error)) {
      return Err(error);
    }

    final touchedBefore = {..._touched};
    final Result<R, DbError> result;

    try {
      result = await body(this);
    } on Object {
      await _undoSavepoint(touchedBefore);
      rethrow;
    }

    if (result.isErr) {
      await _undoSavepoint(touchedBefore);
      return result;
    }

    final released = await _control(TransactionControl.release);

    if (released.isErr) {
      _restoreTouched(touchedBefore);
    }

    return released.flatMap((_) => result);
  }

  /// Runs [body] in this transaction and ends it: commit on `Ok`, rollback
  /// on `Err` or exception.
  Future<Result<R, DbError>> _complete<R>(
    Future<Result<R, DbError>> Function(Transaction tx) body,
  ) async {
    final Result<R, DbError> result;

    try {
      // Awaited inside the zone: a body that returns a query without
      // awaiting it (`(tx) => users.insert(rows)`) runs it here, on this
      // transaction, instead of on the database (which waits for us).
      result = await runZoned(
        () async => await body(this),
        zoneValues: {Database._scopeZone: this},
      );
    } on Object catch (error) {
      _closed = true;
      Log.w('Transaction $_id rolled back after an exception: $error');
      await _control(TransactionControl.rollback);
      rethrow;
    }

    _closed = true;

    if (result.isErr) {
      await _control(TransactionControl.rollback);
      return result;
    }

    final committed = await _control(TransactionControl.commit);

    if (committed.isOk) {
      _database._notify(_touched);
    }

    return committed.flatMap((_) => result);
  }

  Future<Result<(), DbError>> _control(TransactionControl control) =>
      _database._send(TransactionControlRequest(_id, control));

  Future<void> _undoSavepoint(Set<String> touchedBefore) async {
    _restoreTouched(touchedBefore);
    // When this fails the transaction itself ended; the caller's result
    // already explains why.
    await _control(TransactionControl.rollbackTo);
  }

  void _restoreTouched(Set<String> touchedBefore) => _touched
    ..clear()
    ..addAll(touchedBefore);
}

/// A read-only snapshot (see [Database.readTransaction]).
///
/// Every statement sees the database as it was when the snapshot began;
/// writes sent to it fail with [DbErrorCode.readOnlyTransaction].
final class ReadTransaction extends QueryExecutor {
  ReadTransaction._(this._database, this._id);

  final Database _database;
  final int _id;
  bool _closed = false;

  @override
  Future<Result<O, DbError>> run<O>(Statement<O> statement) async {
    if (_closed) {
      return Err(
        DbError(DbErrorCode.transactionClosed, 'The transaction is closed'),
      );
    }

    return _database._send(TransactionExecuteRequest(_id, statement));
  }

  /// Runs [body] on the snapshot, then releases it whatever the outcome.
  Future<Result<R, DbError>> _complete<R>(
    Future<Result<R, DbError>> Function(ReadTransaction tx) body,
  ) async {
    try {
      // Awaited inside the zone, like a write transaction's body.
      return await runZoned(
        () async => await body(this),
        zoneValues: {Database._scopeZone: this},
      );
    } finally {
      _closed = true;
      await _database._send(
        TransactionControlRequest(_id, TransactionControl.rollback),
      );
    }
  }
}
