part of 'request.dart';

/// `sync_claim`: leases the next eligible changes of [remote] (one per row,
/// in commit order); answers the batch.
final class SyncClaimRequest extends ProtocolRequest<ClaimedBatch> {
  /// Claims changes of [remote] within [limits].
  const SyncClaimRequest(this.remote, [this.limits = const ClaimLimits()]);

  /// The remote.
  final String remote;

  /// How much to claim, and for how long.
  final ClaimLimits limits;

  @override
  String get op => 'sync_claim';

  @override
  Map<String, Object?> get fields => {'remote': remote, ...limits.toJson()};

  @override
  Result<ClaimedBatch, DbError> decodeOutput(Object? payload) =>
      ClaimedBatch.decode(payload);

  @override
  Map<String, Object?> encodeOutput(ClaimedBatch output) => output.toJson();
}

/// `sync_push_result`: records what the server answered to a push.
final class SyncPushResultRequest extends ProtocolRequest<PushOutcome> {
  /// Records [result] for [remote].
  const SyncPushResultRequest(this.remote, this.result);

  /// The remote.
  final String remote;

  /// The answer of the server.
  final PushResult result;

  @override
  String get op => 'sync_push_result';

  @override
  Map<String, Object?> get fields => {'remote': remote, ...result.toJson()};

  @override
  Result<PushOutcome, DbError> decodeOutput(Object? payload) =>
      PushOutcome.decode(payload);

  @override
  Map<String, Object?> encodeOutput(PushOutcome output) => output.toJson();
}

/// `sync_release`: makes the deliveries still held by [leaseId] pending
/// again; answers how many.
final class SyncReleaseRequest extends ProtocolRequest<int> {
  /// Releases [leaseId] of [remote], recording [reason].
  const SyncReleaseRequest(this.remote, this.leaseId, this.reason);

  /// The remote.
  final String remote;

  /// The lease.
  final int leaseId;

  /// Recorded as the last error of the released changes.
  final String reason;

  @override
  String get op => 'sync_release';

  @override
  Map<String, Object?> get fields => {
    'remote': remote,
    'lease_id': leaseId,
    'reason': reason,
  };

  @override
  Result<int, DbError> decodeOutput(Object? payload) =>
      _SyncRequests.count(payload, 'released');

  @override
  Map<String, Object?> encodeOutput(int output) => {'released': output};
}

/// `sync_retry`: makes blocked mutations pending again; answers how many
/// were blocked.
final class SyncRetryRequest extends ProtocolRequest<int> {
  /// Retries [mutationIds] of [remote].
  const SyncRetryRequest(this.remote, this.mutationIds);

  /// The remote.
  final String remote;

  /// The mutations.
  final List<String> mutationIds;

  @override
  String get op => 'sync_retry';

  @override
  Map<String, Object?> get fields => {
    'remote': remote,
    'mutation_ids': mutationIds,
  };

  @override
  Result<int, DbError> decodeOutput(Object? payload) =>
      _SyncRequests.count(payload, 'retried');

  @override
  Map<String, Object?> encodeOutput(int output) => {'retried': output};
}

/// `sync_apply_remote`: applies a page of server changes and its checkpoint
/// in one transaction.
final class SyncApplyRemoteRequest extends ProtocolRequest<ApplyOutcome> {
  /// Applies [page] from [remote].
  const SyncApplyRemoteRequest(this.remote, this.page);

  /// The remote.
  final String remote;

  /// The page.
  final RemotePage page;

  @override
  String get op => 'sync_apply_remote';

  @override
  Map<String, Object?> get fields => {'remote': remote, ...page.toJson()};

  @override
  Result<ApplyOutcome, DbError> decodeOutput(Object? payload) =>
      ApplyOutcome.decode(payload);

  @override
  Map<String, Object?> encodeOutput(ApplyOutcome output) => output.toJson();
}

/// `sync_resolve`: resolves the conflict [conflict] if the row version is
/// still [expectedRowVersion].
final class SyncResolveRequest extends ProtocolRequest<()> {
  /// Resolves [conflict] with [resolution].
  const SyncResolveRequest(
    this.conflict,
    this.expectedRowVersion,
    this.resolution,
  );

  /// The conflict id.
  final String conflict;

  /// The row version the resolution was decided on.
  final int expectedRowVersion;

  /// How it ends.
  final ConflictResolution resolution;

  @override
  String get op => 'sync_resolve';

  @override
  Map<String, Object?> get fields => {
    'conflict': conflict,
    'expected_row_version': expectedRowVersion,
    'resolution': resolution.toJson(),
  };

  @override
  Result<(), DbError> decodeOutput(Object? payload) => switch (payload) {
    Map<String, Object?>() => Ok(()),
    _ => Err(SyncJson.bad('resolve answer', payload)),
  };

  @override
  Map<String, Object?> encodeOutput(() output) => const {};
}

/// `sync_state`: the sync state of the row [key] of [table]; `null` when
/// the row does not exist and the engine holds no record of it.
final class SyncStateRequest extends ProtocolRequest<EntitySyncState?> {
  /// The state of [key] in [table].
  const SyncStateRequest(this.table, this.key);

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  @override
  String get op => 'sync_state';

  @override
  Map<String, Object?> get fields => {'table': table, 'key': key};

  @override
  Result<EntitySyncState?, DbError> decodeOutput(Object? payload) =>
      switch (payload) {
        {'state': null} => Ok(null),
        {'state': final Object state} => EntitySyncState.decode(state),
        _ => Err(SyncJson.bad('state answer', payload)),
      };

  @override
  Map<String, Object?> encodeOutput(EntitySyncState? output) => {
    'state': output?.toJson(),
  };
}

/// `sync_pending`: the open changes of [remote], in commit order.
final class SyncPendingRequest extends ProtocolRequest<PendingChanges> {
  /// Lists open changes of [remote], of [table] only when given, at most
  /// [limit].
  const SyncPendingRequest(this.remote, {this.table, this.limit});

  /// The remote.
  final String remote;

  /// Only this table, when given.
  final String? table;

  /// At most this many, when given.
  final int? limit;

  @override
  String get op => 'sync_pending';

  @override
  Map<String, Object?> get fields => {
    'remote': remote,
    'table': table,
    'limit': limit,
  };

  @override
  Result<PendingChanges, DbError> decodeOutput(Object? payload) =>
      PendingChanges.decode(payload);

  @override
  Map<String, Object?> encodeOutput(PendingChanges output) => output.toJson();
}

/// `sync_conflicts`: the open conflicts of [remote].
final class SyncConflictsRequest extends ProtocolRequest<List<SyncConflict>> {
  /// Lists the conflicts of [remote].
  const SyncConflictsRequest(this.remote);

  /// The remote.
  final String remote;

  @override
  String get op => 'sync_conflicts';

  @override
  Map<String, Object?> get fields => {'remote': remote};

  @override
  Result<List<SyncConflict>, DbError> decodeOutput(Object? payload) =>
      switch (payload) {
        {'conflicts': final Object? conflicts} => SyncJson.list(
          conflicts,
          SyncConflict.decode,
        ),
        _ => Err(SyncJson.bad('conflicts answer', payload)),
      };

  @override
  Map<String, Object?> encodeOutput(List<SyncConflict> output) => {
    'conflicts': [for (final conflict in output) conflict.toJson()],
  };
}

/// `sync_status`: the checkpoint and counters of [remote].
final class SyncStatusRequest extends ProtocolRequest<RemoteSyncStatus> {
  /// The status of [remote].
  const SyncStatusRequest(this.remote);

  /// The remote.
  final String remote;

  @override
  String get op => 'sync_status';

  @override
  Map<String, Object?> get fields => {'remote': remote};

  @override
  Result<RemoteSyncStatus, DbError> decodeOutput(Object? payload) =>
      RemoteSyncStatus.decode(payload);

  @override
  Map<String, Object?> encodeOutput(RemoteSyncStatus output) => output.toJson();
}

/// Decoding of the sync requests.
abstract final class _SyncRequests {
  /// The sync request encoded in [json], or `null` when its `op` is not a
  /// sync operation.
  static Result<ProtocolRequest<Object?>, DbError>? decode(
    Map<Object?, Object?> json,
  ) => switch (json) {
    {'op': 'sync_claim', 'remote': final String remote} => ClaimLimits.decode(
      json,
    ).map((limits) => SyncClaimRequest(remote, limits)),
    {'op': 'sync_push_result', 'remote': final String remote} =>
      PushResult.decode(
        json,
      ).map((result) => SyncPushResultRequest(remote, result)),
    {
      'op': 'sync_release',
      'remote': final String remote,
      'lease_id': final int lease,
    } =>
      Ok(
        SyncReleaseRequest(
          remote,
          lease,
          json['reason'] as String? ?? 'released',
        ),
      ),
    {
      'op': 'sync_retry',
      'remote': final String remote,
      'mutation_ids': final List<Object?> ids,
    }
        when ids.every((id) => id is String) =>
      Ok(SyncRetryRequest(remote, ids.cast<String>())),
    {'op': 'sync_apply_remote', 'remote': final String remote} =>
      RemotePage.decode(
        json,
      ).map((page) => SyncApplyRemoteRequest(remote, page)),
    {
      'op': 'sync_resolve',
      'conflict': final String conflict,
      'expected_row_version': final int version,
    } =>
      ConflictResolution.decode(
        json['resolution'],
      ).map((resolution) => SyncResolveRequest(conflict, version, resolution)),
    {
      'op': 'sync_state',
      'table': final String table,
      'key': final Object key,
    } =>
      Ok(SyncStateRequest(table, key)),
    {'op': 'sync_pending', 'remote': final String remote} => switch ((
      json['table'],
      json['limit'],
    )) {
      (final String? table, final int? limit) => Ok(
        SyncPendingRequest(remote, table: table, limit: limit),
      ),
      _ => Err(SyncJson.invalid('pending request', json)),
    },
    {'op': 'sync_conflicts', 'remote': final String remote} => Ok(
      SyncConflictsRequest(remote),
    ),
    {'op': 'sync_status', 'remote': final String remote} => Ok(
      SyncStatusRequest(remote),
    ),
    {'op': final String op} when op.startsWith('sync_') => Err(
      SyncJson.invalid('sync request', json),
    ),
    _ => null,
  };

  /// The count at [name] of [payload].
  static Result<int, DbError> count(Object? payload, String name) =>
      switch (payload) {
        final Map<String, Object?> map when map[name] is int => Ok(
          map[name]! as int,
        ),
        _ => Err(SyncJson.bad('$name answer', payload)),
      };
}
