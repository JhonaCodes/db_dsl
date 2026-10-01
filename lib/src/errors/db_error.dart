/// What went wrong in a database operation: [DbErrorCode] names the exact
/// cause, and the sealed [DbError] family groups causes by how a caller
/// reacts to them.
library;

/// The exact cause of a [DbError].
///
/// The codes are part of the protocol (`PROTOCOL.md`, "Errors"): an engine
/// answers with their [wire] name, and a code never changes its meaning
/// between versions. Codes marked *Dart side* are produced by db_dsl itself,
/// never by an engine.
enum DbErrorCode {
  /// A statement names a table that is not defined.
  tableNotFound('TableNotFound'),

  /// A table definition is invalid (empty name, bad index, ...).
  invalidSchema('InvalidSchema'),

  /// A table is already defined with another primary key.
  schemaMismatch('SchemaMismatch'),

  /// An insert used a primary key that already exists.
  duplicateKey('DuplicateKey'),

  /// A write would duplicate a value of a unique index.
  uniqueViolation('UniqueViolation'),

  /// A row has no primary key and the table does not generate one.
  missingPrimaryKey('MissingPrimaryKey'),

  /// The request does not follow the protocol.
  invalidRequest('InvalidRequest'),

  /// A write did not affect the number of rows it expected.
  affectedRowsMismatch('AffectedRowsMismatch'),

  /// A stored row cannot be decoded by the engine.
  corruptRecord('CorruptRecord'),

  /// A key or an indexed value is too large for the storage.
  keyTooLarge('KeyTooLarge'),

  /// The database reached its maximum size (`DbOptions.maxSize`).
  mapFull('MapFull'),

  /// The files were written by LMDB 0.9 (flutter_local_db 1.x, dart_db 0.2),
  /// which LMDB 1.0 cannot read. The files are left untouched.
  legacyFormat('LegacyFormat'),

  /// The storage reported an error.
  storage('StorageError'),

  /// A file system operation failed.
  io('IoError'),

  /// The transaction was already committed, rolled back or expired.
  transactionClosed('TransactionClosed'),

  /// A write failed in this transaction, which can now only be rolled back.
  transactionAborted('TransactionAborted'),

  /// The transaction was rolled back after staying idle too long.
  transactionExpired('TransactionExpired'),

  /// A write was sent to a read-only transaction.
  readOnlyTransaction('ReadOnlyTransaction'),

  /// A savepoint was released or rolled back while none was open.
  noSavepoint('NoSavepoint'),

  /// The transaction was committed while a savepoint was open.
  savepointOpen('SavepointOpen'),

  /// The database was used directly inside one of its own transactions; the
  /// statement must run on the transaction instead.
  transactionReentrancy('TransactionReentrancy'),

  /// The transaction id does not belong to this database.
  unknownTransaction('UnknownTransaction'),

  /// The files are already open by another engine instance of this process.
  alreadyOpen('AlreadyOpen'),

  /// The database is closed.
  closed('Closed'),

  /// *Dart side*: a query was awaited without naming a database, and its
  /// table is open in none.
  notOpen('NotOpen'),

  /// *Dart side*: a table was used for the first time inside a transaction.
  /// Defining it needs the database to itself, which the transaction holds,
  /// so it is refused instead of waiting forever.
  tableNotReady('TableNotReady'),

  /// The engine speaks another protocol version.
  unsupportedProtocol('UnsupportedProtocol'),

  /// The engine failed internally (a contained panic of the native engine).
  internalPanic('InternalPanic'),

  /// *Dart side*: this platform has no engine for the operation (the native
  /// engine on the web).
  unsupportedPlatform('UnsupportedPlatform'),

  /// *Dart side*: the native library could not be loaded or called.
  nativeLibrary('NativeLibrary'),

  /// *Dart side*: `DbTable.fromJson` failed on a stored row, so the row does not
  /// match the table's model.
  rowMapping('RowMapping'),

  /// A code this version does not know (an engine newer than db_dsl).
  unknown('');

  const DbErrorCode(this.wire);

  /// The name of the code in the protocol.
  final String wire;

  /// The code named [wire], or [unknown] for a name this version lacks.
  static DbErrorCode fromWire(String wire) => values.firstWhere(
    (code) => code.wire == wire && code != unknown,
    orElse: () => unknown,
  );
}

/// A failed database operation, returned as the `Err` of a `Result`.
///
/// Why sealed: callers react to a family of causes — retry a
/// [TransactionError], report a [ConstraintError] to the user, alert on a
/// [StorageError] — and an exhaustive `switch` over the families keeps that
/// handling complete:
///
/// ```dart
/// final message = switch (error) {
///   ConstraintError() => 'That value already exists',
///   TransactionError() => 'Try again',
///   SchemaError() || StorageError() || EngineError() => 'Unexpected: $error',
/// };
/// ```
sealed class DbError {
  const DbError._(this.code, this.message, this.wireCode);

  /// The error for [code], in the family the code belongs to.
  ///
  /// The `switch` is exhaustive over [DbErrorCode]: a new code does not
  /// compile until it is given a family.
  factory DbError(DbErrorCode code, String message, {String? wireCode}) {
    final wire = wireCode ?? code.wire;

    return switch (code) {
      DbErrorCode.duplicateKey ||
      DbErrorCode.uniqueViolation ||
      DbErrorCode.missingPrimaryKey ||
      DbErrorCode.affectedRowsMismatch => ConstraintError._(
        code,
        message,
        wire,
      ),
      DbErrorCode.tableNotFound ||
      DbErrorCode.invalidSchema ||
      DbErrorCode.schemaMismatch ||
      DbErrorCode.invalidRequest ||
      DbErrorCode.keyTooLarge ||
      DbErrorCode.rowMapping ||
      DbErrorCode.tableNotReady => SchemaError._(code, message, wire),
      DbErrorCode.transactionClosed ||
      DbErrorCode.transactionAborted ||
      DbErrorCode.transactionExpired ||
      DbErrorCode.readOnlyTransaction ||
      DbErrorCode.noSavepoint ||
      DbErrorCode.savepointOpen ||
      DbErrorCode.transactionReentrancy ||
      DbErrorCode.unknownTransaction => TransactionError._(code, message, wire),
      DbErrorCode.corruptRecord ||
      DbErrorCode.mapFull ||
      DbErrorCode.legacyFormat ||
      DbErrorCode.storage ||
      DbErrorCode.io ||
      DbErrorCode.alreadyOpen ||
      DbErrorCode.closed ||
      DbErrorCode.notOpen => StorageError._(code, message, wire),
      DbErrorCode.unsupportedProtocol ||
      DbErrorCode.internalPanic ||
      DbErrorCode.unsupportedPlatform ||
      DbErrorCode.nativeLibrary ||
      DbErrorCode.unknown => EngineError._(code, message, wire),
    };
  }

  /// The error of a protocol error payload (`{"code": ..., "message": ...}`).
  factory DbError.fromWire(String wireCode, String message) =>
      DbError(DbErrorCode.fromWire(wireCode), message, wireCode: wireCode);

  /// The exact cause.
  final DbErrorCode code;

  /// A description for humans; it may change between versions, so code
  /// reacts to [code], never to the message.
  final String message;

  /// The code as the engine sent it: the only trace of an
  /// [DbErrorCode.unknown] code.
  final String wireCode;

  @override
  bool operator ==(Object other) =>
      other is DbError &&
      other.runtimeType == runtimeType &&
      other.code == code &&
      other.message == message &&
      other.wireCode == wireCode;

  @override
  int get hashCode => Object.hash(runtimeType, code, message, wireCode);

  @override
  String toString() => '$runtimeType(${code.name}): $message';
}

/// A write broke a rule of the data: a duplicate primary key, a unique index,
/// a missing key, or an `expectAffectedRows` that did not hold. Nothing was
/// written by the failed statement.
final class ConstraintError extends DbError {
  const ConstraintError._(super.code, super.message, super.wireCode)
    : super._();
}

/// The statement does not fit the schema or the protocol: an unknown table,
/// an invalid definition, a malformed request, a key too large, or a stored
/// row that the table's model cannot read.
final class SchemaError extends DbError {
  const SchemaError._(super.code, super.message, super.wireCode) : super._();
}

/// The transaction cannot go on: it is closed, expired, rollback-only or used
/// the wrong way. Running the unit of work again is usually the fix.
final class TransactionError extends DbError {
  const TransactionError._(super.code, super.message, super.wireCode)
    : super._();
}

/// The storage failed or cannot be used: full, corrupt, closed, already open,
/// written by an older format, or an I/O error.
final class StorageError extends DbError {
  const StorageError._(super.code, super.message, super.wireCode) : super._();
}

/// The engine itself is missing, incompatible or failed internally.
final class EngineError extends DbError {
  const EngineError._(super.code, super.message, super.wireCode) : super._();
}
