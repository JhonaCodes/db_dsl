part of 'memory_executor.dart';

/// The sync operations of [MemoryEngine] on one [MemoryState], with the
/// rules of offline_first_core (`engine/sync.rs`): the same answers, errors
/// and invariants (RFC-001 §13.19).
///
/// Why part of the executor: recording a change belongs to the same write
/// as the row (insert, update, delete), and applying remote changes keeps
/// the indexes in step the way the executor does.
final class MemorySyncOperations {
  /// The operations on the state of [_executor].
  MemorySyncOperations(this._executor);

  final MemoryExecutor _executor;

  MemorySync get _sync => _executor.state.sync;

  /// Milliseconds since the epoch: lease expiry only, never ordering.
  static int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Records the change of the row [pk] of [table] from [before] to
  /// [after]; nothing for a local table or an unchanged row.
  DbError? track(
    MemoryTable table,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
  ) {
    final remote = table.schema.sync;

    if (remote == null ||
        (before != null && JsonValues.equals(before, after))) {
      return null;
    }

    final key = JsonValues.fieldAt(after ?? before, table.schema.primaryKey)!;
    final entity = _entity(table.schema.name, key);

    if (before == null && entity.deleted) {
      if (entity.open.isNotEmpty) {
        return DbError(
          DbErrorCode.tombstonePending,
          'Row ${JsonValues.canonical(key)} of `${table.schema.name}` has a '
          'deletion that is not settled yet',
        );
      }

      entity.generation += 1;
    }

    entity.rowVersion += 1;
    _record(
      remote,
      entity,
      after == null ? SyncOperation.delete : SyncOperation.upsert,
      after,
    );
    return null;
  }

  /// Leases the next eligible changes of [remote].
  Result<ClaimedBatch, DbError> claim(String remote, ClaimLimits limits) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    final now = _now;
    final seen = <String>{};
    final envelopes = <SyncEnvelope>[];
    var bytes = 0;
    int? lease;

    for (final MapEntry(key: sequence, value: change)
        in _sync.changes.entries.toList()) {
      if (change.remote != remote) {
        continue;
      }

      if (envelopes.length >= limits.maxChanges) {
        break;
      }

      final entity = _entity(change.table, change.key);

      if (!seen.add(
        String.fromCharCodes(_entityKey(change.table, change.key)),
      )) {
        continue;
      }

      final eligible =
          entity.open.first == sequence &&
          entity.conflict == null &&
          change.delivery(now) == DeliveryState.pending;

      if (!eligible) {
        continue;
      }

      final next = change.copy();

      if (!next.prepared) {
        next
          ..prepared = true
          ..baseVersion = entity.serverVersion;
      }

      next.attempts += 1;
      final envelope = next.envelope;
      final size = utf8.encode(jsonEncode(envelope.toJson())).length;

      if (limits.maxBytes case final int max
          when envelopes.isNotEmpty && bytes + size > max) {
        break;
      }

      lease ??= ++_sync.leases;
      _sync.changes[sequence] = next
        ..state = DeliveryState.leased
        ..leaseId = lease
        ..leaseExpiresAt = now + limits.lease.inMilliseconds;
      envelopes.add(envelope);
      bytes += size;
    }

    return Ok(ClaimedBatch(leaseId: lease, envelopes: envelopes));
  }

  /// Records what the server answered to a push.
  Result<PushOutcome, DbError> applyPushResult(
    String remote,
    PushResult result,
  ) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    if (!_sync.enabled) {
      return switch (result.acknowledged.firstOrNull) {
        final SyncAcknowledgement ack => Err(_unknown(ack.mutationId)),
        null => Ok(
          const PushOutcome(
            acknowledged: 0,
            rejected: 0,
            released: 0,
            ignored: [],
          ),
        ),
      };
    }

    final now = _now;
    var acknowledged = 0;
    var rejected = 0;
    final ignored = <String>[];

    for (final ack in result.acknowledged) {
      switch (_acknowledge(remote, ack, now)) {
        case Ok(data: true):
          acknowledged += 1;
        case Ok():
          break;
        case Err(:final error):
          return Err(error);
      }
    }

    for (final rejection in result.rejected) {
      switch (_sync.mutations[rejection.mutationId]) {
        case null:
          return Err(_unknown(rejection.mutationId));
        case MemorySettledMutation():
          ignored.add(rejection.mutationId);
        case MemoryOpenMutation(:final sequence):
          final change = _sync.changes[sequence]!;
          final held =
              change.state == DeliveryState.leased &&
              result.leaseId != null &&
              change.leaseId == result.leaseId;

          if (change.remote != remote || !held) {
            ignored.add(rejection.mutationId);
            continue;
          }

          change
            ..state = rejection.retryable
                ? DeliveryState.pending
                : DeliveryState.blocked
            ..leaseId = null
            ..leaseExpiresAt = null
            ..lastError = rejection.reason;
          rejected += 1;
      }
    }

    final released = switch (result.leaseId) {
      final int lease => _releaseLease(remote, lease, null),
      null => 0,
    };

    return Ok(
      PushOutcome(
        acknowledged: acknowledged,
        rejected: rejected,
        released: released,
        ignored: ignored,
      ),
    );
  }

  /// Makes the deliveries held by [lease] pending again.
  Result<int, DbError> release(String remote, int lease, String reason) =>
      switch (_validRemote(remote)) {
        final DbError error => Err(error),
        null => Ok(_sync.enabled ? _releaseLease(remote, lease, reason) : 0),
      };

  /// Makes the blocked mutations of [ids] pending again.
  Result<int, DbError> retry(String remote, List<String> ids) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    var retried = 0;

    for (final id in ids) {
      if (_sync.mutations[id] case MemoryOpenMutation(:final sequence)) {
        final change = _sync.changes[sequence]!;

        if (change.remote == remote && change.state == DeliveryState.blocked) {
          change.state = DeliveryState.pending;
          retried += 1;
        }
      }
    }

    return Ok(retried);
  }

  /// Applies [page] and stores its checkpoint.
  Result<ApplyOutcome, DbError> applyRemote(String remote, RemotePage page) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    if (!_sync.enabled) {
      return Err(_notTracked(remote));
    }

    final record = _sync.remote(remote);

    if (!JsonValues.equals(record.checkpoint, page.expectedCheckpoint)) {
      return Err(
        DbError(
          DbErrorCode.staleCheckpoint,
          'The checkpoint is ${JsonValues.canonical(record.checkpoint)}, the '
          'page expected ${JsonValues.canonical(page.expectedCheckpoint)}',
        ),
      );
    }

    final now = _now;
    final outcome = _Applied();

    for (final change in page.changes) {
      if (_applyChange(remote, change, now, outcome) case final DbError e) {
        return Err(e);
      }
    }

    _sync.remote(remote).checkpoint = MemoryState.detached(page.nextCheckpoint);
    return Ok(
      ApplyOutcome(
        applied: outcome.applied,
        conflicts: outcome.conflicts,
        acknowledged: outcome.acknowledged,
        skipped: outcome.skipped,
      ),
    );
  }

  /// Resolves the conflict [id] with [resolution].
  Result<(), DbError> resolveConflict(
    String id,
    int expectedRowVersion,
    ConflictResolution resolution,
  ) {
    final conflict = _sync.conflicts[id];

    if (!_sync.enabled || conflict == null) {
      return Err(
        DbError(DbErrorCode.conflictNotFound, 'Unknown conflict `$id`'),
      );
    }

    final table = _executor.state.tables[conflict.table];

    if (table == null) {
      return Err(_tableNotFound(conflict.table));
    }

    final pk = JsonValues.encodeKey([conflict.key]);
    var entity = _entity(conflict.table, conflict.key);

    if (entity.rowVersion != expectedRowVersion) {
      return Err(
        DbError(
          DbErrorCode.rowVersionMismatch,
          'The row version is ${entity.rowVersion}, the resolution expected '
          '$expectedRowVersion',
        ),
      );
    }

    final now = _now;

    for (final sequence in entity.open) {
      final change = _sync.changes[sequence]!;

      if (change.leaseAlive(now)) {
        return Err(
          DbError(
            DbErrorCode.mutationInFlight,
            'Mutation `${change.mutationId}` is being sent; acknowledge or '
            'release it first',
          ),
        );
      }
    }

    final merged = switch (resolution) {
      Merged(:final row) => row,
      AcceptRemote() || KeepLocal() => null,
    };

    if (merged != null && !_holdsKey(table, merged, pk)) {
      return Err(
        DbError(
          DbErrorCode.invalidRequest,
          'The merged row of ${JsonValues.canonical(conflict.key)} in '
          '`${conflict.table}` must be an object with that primary key',
        ),
      );
    }

    final reason = switch (resolution) {
      AcceptRemote() => 'accept_remote',
      KeepLocal() => 'keep_local',
      Merged() => 'merged',
    };

    for (final sequence in [...entity.open]) {
      _settle(sequence, null, now, reason);
    }

    _sync.conflicts.remove(id);
    _sync.remote(conflict.remote).conflicts -= 1;
    entity = _entity(conflict.table, conflict.key)
      ..serverVersion = conflict.remoteVersion
      ..initialized = true
      ..conflict = null;
    final current = table.rows[pk];

    final (SyncOperation, Map<String, Object?>?)? resend;

    switch (resolution) {
      case AcceptRemote():
        if (_writeRow(table, pk, current, conflict.remoteRow) case final e?) {
          return Err(e);
        }

        entity
          ..deleted = conflict.remoteRow == null
          ..rowVersion += 1;
        resend = null;
      case KeepLocal():
        resend = switch ((current, conflict.remoteOperation)) {
          (null, SyncOperation.delete) => null,
          (final Map<String, Object?> row, _) => (SyncOperation.upsert, row),
          (null, SyncOperation.upsert) => (SyncOperation.delete, null),
        };
      case Merged():
        final row = MemoryState.detached(merged)! as Map<String, Object?>;

        if (_writeRow(table, pk, current, row) case final e?) {
          return Err(e);
        }

        entity.rowVersion += 1;
        resend = (SyncOperation.upsert, row);
    }

    if (resend case (final operation, final row)) {
      _record(conflict.remote, entity, operation, row);
    }

    return Ok(());
  }

  /// The sync state of the row [key] of the table [name].
  Result<EntitySyncState?, DbError> stateOf(String name, Object key) {
    final table = _executor.state.tables[name];

    if (table == null) {
      return Err(_tableNotFound(name));
    }

    if (table.schema.sync == null) {
      return Ok(_withoutRecords(SyncStateKind.localOnly));
    }

    final entity = _sync.entities[_entityKey(name, key)];

    if (entity == null) {
      return Ok(
        table.rows.containsKey(JsonValues.encodeKey([key]))
            ? _withoutRecords(SyncStateKind.unknown)
            : null,
      );
    }

    final now = _now;
    final next = entity.open.isEmpty ? null : _sync.changes[entity.open.first];
    final state = switch (next) {
      _ when entity.conflict != null => SyncStateKind.conflict,
      MemoryChange(state: DeliveryState.blocked) => SyncStateKind.blocked,
      MemoryChange() => SyncStateKind.pending,
      null when entity.initialized => SyncStateKind.synced,
      null => SyncStateKind.unknown,
    };

    return Ok(
      EntitySyncState(
        state: state,
        deleted: entity.deleted,
        sending: next?.leaseAlive(now) ?? false,
        attempts: next?.attempts ?? 0,
        lastError: next?.lastError,
        pending: entity.open.length,
        localRevision: entity.localRevision,
        acknowledgedLocalRevision: entity.acknowledgedLocalRevision,
        settledLocalRevision: entity.settledLocalRevision,
        rowVersion: entity.rowVersion,
        serverVersion: entity.serverVersion,
        conflict: entity.conflict,
      ),
    );
  }

  /// The open changes of [remote], of [table] when given, at most [limit].
  Result<PendingChanges, DbError> pending(
    String remote,
    String? table,
    int? limit,
  ) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    final now = _now;
    final changes = <PendingChange>[];

    for (final change in _sync.changes.values) {
      if (change.remote != remote) {
        continue;
      }

      if (limit != null && changes.length >= limit) {
        break;
      }

      if (table == null || table == change.table) {
        changes.add(
          PendingChange(
            mutationId: change.mutationId,
            table: change.table,
            key: change.key,
            localRevision: change.localRevision,
            operation: change.operation,
            state: change.delivery(now),
            attempts: change.attempts,
            lastError: change.lastError,
          ),
        );
      }
    }

    return Ok(
      PendingChanges(
        count: _sync.remotes[remote]?.pending ?? 0,
        changes: changes,
      ),
    );
  }

  /// The open conflicts of [remote].
  Result<List<SyncConflict>, DbError> conflicts(String remote) {
    if (_validRemote(remote) case final DbError error) {
      return Err(error);
    }

    return Ok([
      for (final conflict in _sync.conflicts.values)
        if (conflict.remote == remote) _conflict(conflict),
    ]);
  }

  /// The checkpoint and counters of [remote].
  Result<RemoteSyncStatus, DbError> status(String remote) =>
      switch (_validRemote(remote)) {
        final DbError error => Err(error),
        null => Ok(
          RemoteSyncStatus(
            checkpoint: _sync.remotes[remote]?.checkpoint,
            pending: _sync.remotes[remote]?.pending ?? 0,
            conflicts: _sync.remotes[remote]?.conflicts ?? 0,
          ),
        ),
      };

  /// Drops the sync records of [table] (its pending changes go with it).
  void purgeTable(String table) {
    for (final MapEntry(:key, value: entity)
        in _sync.entities.entries.toList()) {
      if (entity.table != table) {
        continue;
      }

      for (final sequence in entity.open) {
        final change = _sync.changes.remove(sequence)!;
        _sync.mutations.remove(change.mutationId);
        _sync.remote(change.remote).pending -= 1;
      }

      if (entity.conflict case final String id) {
        if (_sync.conflicts.remove(id) case final MemoryConflict conflict) {
          _sync.remote(conflict.remote).conflicts -= 1;
        }
      }

      _sync.entities.remove(key);
    }
  }

  // --- Records ------------------------------------------------------------

  static List<int> _entityKey(String table, Object key) =>
      JsonValues.encodeKey([table, key]);

  /// The records of [key] in [table], created when missing.
  MemoryEntitySync _entity(String table, Object key) => _sync.entities
      .putIfAbsent(_entityKey(table, key), () => MemoryEntitySync(table, key));

  /// Appends a change of [entity].
  void _record(
    String remote,
    MemoryEntitySync entity,
    SyncOperation operation,
    Map<String, Object?>? row,
  ) {
    final sequence = ++_sync.sequence;
    final mutationId = '${_sync.replica}-$sequence';
    final predecessor = entity.lastMutation;
    entity
      ..localRevision += 1
      ..deleted = operation == SyncOperation.delete
      ..open.add(sequence)
      ..lastMutation = mutationId;
    _sync.changes[sequence] = MemoryChange(
      mutationId: mutationId,
      remote: remote,
      table: entity.table,
      key: entity.key,
      generation: entity.generation,
      localRevision: entity.localRevision,
      localTransactionId: '${_sync.replica}:${_executor.transaction}',
      operation: operation,
      row: MemoryState.detached(row) as Map<String, Object?>?,
      predecessor: predecessor,
    );
    _sync.mutations[mutationId] = MemoryOpenMutation(sequence);
    _sync.remote(remote).pending += 1;
  }

  /// Closes the change [sequence]: acknowledged at [serverVersion] when
  /// [reason] is `null`, resolved otherwise.
  void _settle(int sequence, Object? serverVersion, int now, [String? reason]) {
    final change = _sync.changes.remove(sequence)!;
    final entity = _entity(change.table, change.key)..open.remove(sequence);

    if (reason == null) {
      entity
        ..acknowledgedLocalRevision = max(
          entity.acknowledgedLocalRevision,
          change.localRevision,
        )
        ..serverVersion = serverVersion
        ..initialized = true;
    }

    entity.settledLocalRevision = entity.open.isEmpty
        ? entity.localRevision
        : _sync.changes[entity.open.first]!.localRevision - 1;
    _sync.mutations[change.mutationId] = MemorySettledMutation(
      change.table,
      change.key,
      change.localRevision,
    );
    _sync.remote(change.remote).pending -= 1;
  }

  /// Settles the mutation [ack] names; `false` for a duplicate.
  Result<bool, DbError> _acknowledge(
    String remote,
    SyncAcknowledgement ack,
    int now,
  ) {
    DbError mismatch(String detail) => DbError(
      DbErrorCode.acknowledgementMismatch,
      'The acknowledgement of `${ack.mutationId}` does not match it: $detail',
    );

    bool same(String table, Object key, int localRevision) =>
        table == ack.table &&
        JsonValues.compareKeys(
              JsonValues.encodeKey([key]),
              JsonValues.encodeKey([ack.key]),
            ) ==
            0 &&
        localRevision == ack.localRevision;

    switch (_sync.mutations[ack.mutationId]) {
      case null:
        return Err(_unknown(ack.mutationId));
      case MemorySettledMutation(
        :final table,
        :final key,
        :final localRevision,
      ):
        return same(table, key, localRevision)
            ? Ok(false)
            : Err(mismatch('another entity or revision'));
      case MemoryOpenMutation(:final sequence):
        final change = _sync.changes[sequence]!;

        if (change.remote != remote) {
          return Err(mismatch('the mutation belongs to another remote'));
        }

        if (!same(change.table, change.key, change.localRevision)) {
          return Err(mismatch('another entity or revision'));
        }

        if (change.attempts == 0) {
          return Err(mismatch('the mutation was never claimed'));
        }

        _settle(sequence, MemoryState.detached(ack.serverVersion), now);
        return Ok(true);
    }
  }

  int _releaseLease(String remote, int lease, String? reason) {
    var released = 0;

    for (final change in _sync.changes.values) {
      if (change.remote == remote &&
          change.state == DeliveryState.leased &&
          change.leaseId == lease) {
        change
          ..state = DeliveryState.pending
          ..leaseId = null
          ..leaseExpiresAt = null;

        if (reason != null) {
          change.lastError = reason;
        }

        released += 1;
      }
    }

    return released;
  }

  DbError? _applyChange(
    String remote,
    RemoteChange change,
    int now,
    _Applied outcome,
  ) {
    final table = _executor.state.tables[change.table];

    if (table == null) {
      return _tableNotFound(change.table);
    }

    if (table.schema.sync != remote) {
      return _notTracked(change.table);
    }

    final pk = JsonValues.encodeKey([change.key]);
    final row = switch (change.operation) {
      SyncOperation.upsert => change.row,
      SyncOperation.delete => null,
    };

    if (change.operation == SyncOperation.upsert) {
      if (row == null) {
        return DbError(
          DbErrorCode.invalidRequest,
          'The upsert of ${JsonValues.canonical(change.key)} in '
          '`${change.table}` needs a row object',
        );
      }

      if (!_holdsKey(table, row, pk)) {
        return DbError(
          DbErrorCode.invalidRequest,
          'The row of ${JsonValues.canonical(change.key)} in '
          '`${change.table}` holds another primary key',
        );
      }
    }

    if (change.mutationId case final String id) {
      switch (_sync.mutations[id]) {
        case MemoryOpenMutation(:final sequence):
          final local = _sync.changes[sequence]!;
          final sameRow =
              local.table == change.table &&
              JsonValues.compareKeys(JsonValues.encodeKey([local.key]), pk) ==
                  0;

          if (sameRow && local.attempts > 0) {
            _settle(sequence, MemoryState.detached(change.serverVersion), now);
            outcome.acknowledged += 1;
            return null;
          }
        case MemorySettledMutation():
          outcome.skipped += 1;
          return null;
        case null:
          break;
      }
    }

    final entity = _entity(change.table, change.key);
    final quiet = entity.open.isEmpty && entity.conflict == null;

    if (quiet &&
        entity.initialized &&
        JsonValues.equals(entity.serverVersion, change.serverVersion)) {
      outcome.skipped += 1;
      return null;
    }

    if (!quiet) {
      if (entity.conflict case final String open
          when JsonValues.equals(
            _sync.conflicts[open]?.remoteVersion,
            change.serverVersion,
          )) {
        outcome.skipped += 1;
        return null;
      }

      final id = entity.conflict ?? 'conflict-${++_sync.conflictCount}';

      if (entity.conflict == null) {
        _sync.remote(remote).conflicts += 1;
      }

      _sync.conflicts[id] = MemoryConflict(
        id: id,
        remote: remote,
        table: change.table,
        key: change.key,
        remoteVersion: MemoryState.detached(change.serverVersion),
        remoteOperation: change.operation,
        remoteRow: MemoryState.detached(row) as Map<String, Object?>?,
        baseVersion: entity.serverVersion,
      );
      entity.conflict = id;
      outcome.conflicts += 1;
      return null;
    }

    final stored = MemoryState.detached(row) as Map<String, Object?>?;

    if (_writeRow(table, pk, table.rows[pk], stored) case final DbError e) {
      return e;
    }

    if (stored != null && entity.deleted) {
      entity.generation += 1;
    }

    entity
      ..serverVersion = MemoryState.detached(change.serverVersion)
      ..initialized = true
      ..deleted = stored == null
      ..rowVersion += 1;
    outcome.applied += 1;
    return null;
  }

  /// Writes [after] as the row [pk] of [table] (or deletes it), keeping the
  /// indexes in step, without recording a change.
  DbError? _writeRow(
    MemoryTable table,
    List<int> pk,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
  ) {
    if (before != null) {
      MemoryExecutor._removeIndexEntries(table, before, pk);
    }

    if (after == null) {
      table.rows.remove(pk);
      return null;
    }

    for (final index in table.schema.indexes) {
      if (_executor._addIndexEntry(table, index, after, pk)
          case final DbError error) {
        return error;
      }
    }

    table.rows[pk] = after;
    return null;
  }

  static bool _holdsKey(
    MemoryTable table,
    Map<String, Object?> row,
    List<int> pk,
  ) => switch (JsonValues.fieldAt(row, table.schema.primaryKey)) {
    null => false,
    final Object key =>
      JsonValues.compareKeys(JsonValues.encodeKey([key]), pk) == 0,
  };

  SyncConflict _conflict(MemoryConflict conflict) {
    final entity = _sync.entities[_entityKey(conflict.table, conflict.key)]!;
    final row = _executor
        .state
        .tables[conflict.table]
        ?.rows[JsonValues.encodeKey([conflict.key])];

    return SyncConflict(
      id: conflict.id,
      table: conflict.table,
      key: conflict.key,
      localRowVersion: entity.rowVersion,
      localRow: MemoryState.detached(row) as Map<String, Object?>?,
      outstanding: [
        for (final sequence in entity.open) _sync.changes[sequence]!.mutationId,
      ],
      remoteVersion: conflict.remoteVersion,
      remoteOperation: conflict.remoteOperation,
      remoteRow: conflict.remoteRow,
      baseVersion: conflict.baseVersion,
    );
  }

  static EntitySyncState _withoutRecords(SyncStateKind state) =>
      EntitySyncState(
        state: state,
        deleted: false,
        sending: false,
        attempts: 0,
        lastError: null,
        pending: 0,
        localRevision: 0,
        acknowledgedLocalRevision: 0,
        settledLocalRevision: 0,
        rowVersion: 0,
        serverVersion: null,
        conflict: null,
      );

  static DbError? _validRemote(String remote) => remote.isEmpty
      ? DbError(DbErrorCode.invalidRequest, 'The remote must not be empty')
      : null;

  static DbError _unknown(String id) =>
      DbError(DbErrorCode.unknownMutation, 'Unknown mutation `$id`');

  static DbError _notTracked(String name) =>
      DbError(DbErrorCode.syncNotTracked, '`$name` is not synchronized');

  static DbError _tableNotFound(String name) =>
      DbError(DbErrorCode.tableNotFound, 'Table `$name` is not defined');
}

/// Counts of an `applyRemote`.
final class _Applied {
  int applied = 0;
  int conflicts = 0;
  int acknowledged = 0;
  int skipped = 0;
}
