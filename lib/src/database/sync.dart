part of 'database.dart';

/// The offline-first sync of a [Database] (`PROTOCOL.md`, "Sync"): its
/// tables declared with `syncWith` record every write as a change in the
/// same transaction, and these operations move the changes to a server
/// and the server's changes back. The network is yours: the engine only
/// knows what is pending, what is being sent and what the server confirmed.
///
/// ```dart
/// // Push: lease a batch, send it, record exactly what the server stored.
/// if (await db.sync.claim('primary') case Ok(data: final batch) when !batch.isEmpty) {
///   final versions = await api.push(batch.envelopes);   // your HTTP: a version per envelope
///   await db.sync.applyPushResult('primary', PushResult(
///     leaseId: batch.leaseId,
///     acknowledged: [
///       for (final (i, envelope) in batch.envelopes.indexed)
///         SyncAcknowledgement.of(envelope, versions[i]),
///     ],
///   ));
/// }
///
/// // Pull: a page and its checkpoint are stored together, or not at all.
/// if (await db.sync.status('primary') case Ok(data: final status)) {
///   final page = await api.pull(after: status.checkpoint);   // a RemotePage
///   await db.sync.applyRemote('primary', page);
/// }
///
/// // A server change over a pending local change is a conflict.
/// if (await db.sync.conflicts('primary') case Ok(data: final conflicts)) {
///   for (final conflict in conflicts) {
///     await db.sync.resolveConflict(conflict, const ConflictResolution.acceptRemote());
///   }
/// }
/// ```
///
/// Every operation is a short transaction of its own, never open while
/// your code talks to the server; inside one of this database's
/// transactions they fail with [DbErrorCode.transactionReentrancy].
final class DbSync {
  DbSync._(this._database);

  final Database _database;

  /// Leases the next eligible changes of [remote]: at most one per row, in
  /// commit order, skipping rows with a conflict or a blocked change. An
  /// envelope keeps its bytes and its `mutationId` on every claim, so a
  /// server can deduplicate retries.
  Future<Result<ClaimedBatch, DbError>> claim(
    String remote, {
    ClaimLimits limits = const ClaimLimits(),
  }) => _write(SyncClaimRequest(remote, limits));

  /// Records what the server answered to a push: each acknowledgement
  /// settles exactly one mutation and revision (checked against its
  /// change; one that does not match fails the call and changes nothing),
  /// and with `leaseId` the envelopes the result leaves out are released.
  Future<Result<PushOutcome, DbError>> applyPushResult(
    String remote,
    PushResult result,
  ) => _write(SyncPushResultRequest(remote, result));

  /// Releases the deliveries still held by [leaseId] (a push that failed);
  /// answers how many. A lease that moved on releases nothing.
  Future<Result<int, DbError>> release(
    String remote,
    int leaseId, {
    String reason = 'released',
  }) => _write(SyncReleaseRequest(remote, leaseId, reason));

  /// Makes blocked mutations pending again; answers how many were blocked.
  Future<Result<int, DbError>> retry(String remote, List<String> mutationIds) =>
      _write(SyncRetryRequest(remote, mutationIds));

  /// Applies a page of server changes and stores its checkpoint in one
  /// transaction. Remote changes never come back as local changes; one
  /// over a pending local change becomes a conflict. The page must have
  /// been read after the current checkpoint ([DbErrorCode.staleCheckpoint]
  /// otherwise), and its tables must be defined in this database.
  Future<Result<ApplyOutcome, DbError>> applyRemote(
    String remote,
    RemotePage page,
  ) async {
    final applied = await _write(SyncApplyRemoteRequest(remote, page));

    if (applied case Ok(:final data) when data.applied > 0) {
      _database._notify({for (final change in page.changes) change.table});
    }

    return applied;
  }

  /// Resolves [conflict] with [resolution], if its row did not change since
  /// the conflict was read ([DbErrorCode.rowVersionMismatch] otherwise: read
  /// the conflicts again). Refused while a change of the row is being sent
  /// ([DbErrorCode.mutationInFlight]).
  Future<Result<(), DbError>> resolveConflict(
    SyncConflict conflict,
    ConflictResolution resolution,
  ) async {
    final resolved = await _write(
      SyncResolveRequest(conflict.id, conflict.localRowVersion, resolution),
    );

    if (resolved.isOk) {
      _database._notify({conflict.table});
    }

    return resolved;
  }

  /// The sync state of the row [key] of [table]; `null` when the row does
  /// not exist and the engine holds no record of it.
  Future<Result<EntitySyncState?, DbError>> stateOf(
    DbTable<Object?> table,
    Object key,
  ) => _defined(table, () => _read(SyncStateRequest(table.tableName, key)));

  /// The open changes of [remote], in commit order: of [table] only when
  /// given, at most [limit].
  Future<Result<PendingChanges, DbError>> pending(
    String remote, {
    DbTable<Object?>? table,
    int? limit,
  }) =>
      _read(SyncPendingRequest(remote, table: table?.tableName, limit: limit));

  /// The open conflicts of [remote].
  Future<Result<List<SyncConflict>, DbError>> conflicts(String remote) =>
      _read(SyncConflictsRequest(remote));

  /// The checkpoint of the last applied page and the counters of [remote].
  Future<Result<RemoteSyncStatus, DbError>> status(String remote) =>
      _read(SyncStatusRequest(remote));

  Future<Result<O, DbError>> _write<O>(ProtocolRequest<O> request) => _database
      ._guarded(() => _database._writes.run(() => _database._send(request)));

  Future<Result<O, DbError>> _read<O>(ProtocolRequest<O> request) =>
      _database._guarded(() => _database._send(request));

  /// Runs [action] once [table] is defined in this database (a table no
  /// database holds yet defines itself here).
  Future<Result<O, DbError>> _defined<O>(
    DbTable<Object?> table,
    Future<Result<O, DbError>> Function() action,
  ) async {
    if (Database._homes[table] == null) {
      if (await _database._defineOnce(table) case Err(:final error)) {
        return Err(error);
      }
    }

    return action();
  }
}
