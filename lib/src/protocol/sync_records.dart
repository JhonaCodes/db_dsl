/// The records of the sync operations (`PROTOCOL.md`, "Sync"): envelopes,
/// acknowledgements, remote pages, conflicts and states, in their protocol
/// form.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';

/// What a change does to its row.
enum SyncOperation {
  /// The row exists with the payload.
  upsert('upsert'),

  /// The row was deleted.
  delete('delete');

  const SyncOperation(this.wire);

  /// The name in the protocol.
  final String wire;

  /// Operations by their name.
  static final Map<String, SyncOperation> byWire = {
    for (final operation in values) operation.wire: operation,
  };
}

/// The delivery state of an open change.
enum DeliveryState {
  /// Waiting to be claimed.
  pending('pending'),

  /// Claimed under a lease that has not expired.
  leased('leased'),

  /// Rejected as not retryable; `DbSync.retry` sends it again.
  blocked('blocked');

  const DeliveryState(this.wire);

  /// The name in the protocol.
  final String wire;

  /// States by their name.
  static final Map<String, DeliveryState> byWire = {
    for (final state in values) state.wire: state,
  };
}

/// The sync state of a row (RFC-001 §13.3).
enum SyncStateKind {
  /// The table is not synchronized.
  localOnly('local_only'),

  /// The row exists, but nothing says what the server holds (written before
  /// the table was synchronized).
  unknown('unknown'),

  /// Local changes are not settled yet.
  pending('pending'),

  /// No pending change and no conflict, as far as the last server state
  /// observed.
  synced('synced'),

  /// A server change met a pending local change; it needs a resolution.
  conflict('conflict'),

  /// The next change was rejected and is not sent until retried.
  blocked('blocked');

  const SyncStateKind(this.wire);

  /// The name in the protocol.
  final String wire;

  /// States by their name.
  static final Map<String, SyncStateKind> byWire = {
    for (final kind in values) kind.wire: kind,
  };
}

/// Readers of protocol JSON for the sync records.
abstract final class SyncJson {
  /// [json] as an object, or `null`.
  static Map<String, Object?>? object(Object? json) => switch (json) {
    final Map<String, Object?> map => map,
    _ => null,
  };

  /// [json] as a list of records decoded by [decode], or the first error.
  static Result<List<T>, DbError> list<T>(
    Object? json,
    Result<T, DbError> Function(Object? json) decode,
  ) {
    if (json is! List<Object?>) {
      return Err(bad('list', json));
    }

    final decoded = <T>[];

    for (final item in json) {
      switch (decode(item)) {
        case Ok(:final data):
          decoded.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(decoded);
  }

  /// The error for [json], which is not a valid [what].
  static DbError bad(String what, Object? json) =>
      DbError(DbErrorCode.unsupportedProtocol, 'Not a valid $what: $json');

  /// The error for a request field [json], which is not a valid [what].
  static DbError invalid(String what, Object? json) =>
      DbError(DbErrorCode.invalidRequest, 'Not a valid $what: $json');
}

/// Limits of `DbSync.claim`.
final class ClaimLimits {
  /// At most [maxChanges] envelopes, [maxBytes] bytes of envelope JSON (an
  /// envelope larger than that alone is still sent, alone), leased for
  /// [lease].
  const ClaimLimits({
    this.maxChanges = 100,
    this.maxBytes,
    this.lease = const Duration(seconds: 30),
  });

  /// Most envelopes in the batch.
  final int maxChanges;

  /// Most bytes of envelopes in the batch.
  final int? maxBytes;

  /// How long the lease lasts; after it, the envelopes can be claimed again
  /// (the same bytes).
  final Duration lease;

  /// The protocol fields.
  Map<String, Object?> toJson() => {
    'max_changes': maxChanges,
    'max_bytes': maxBytes,
    'lease_ms': lease.inMilliseconds,
  };

  /// The limits in a request.
  static Result<ClaimLimits, DbError> decode(Map<Object?, Object?> json) =>
      switch ((json['max_changes'], json['max_bytes'], json['lease_ms'])) {
        (final int? changes, final int? bytes, final int? ms)
            when (changes ?? 0) >= 0 && (ms ?? 0) >= 0 =>
          Ok(
            ClaimLimits(
              maxChanges: changes ?? 100,
              maxBytes: bytes,
              lease: Duration(milliseconds: ms ?? 30000),
            ),
          ),
        _ => Err(SyncJson.invalid('claim', json)),
      };
}

/// One change to send, with everything the server needs to apply it once.
final class SyncEnvelope {
  /// An envelope.
  const SyncEnvelope({
    required this.mutationId,
    required this.table,
    required this.key,
    required this.generation,
    required this.localRevision,
    required this.localTransactionId,
    required this.operation,
    required this.row,
    required this.baseVersion,
    required this.predecessor,
    required this.attempt,
  });

  /// Stable identity of the mutation, the same on every retry: servers
  /// deduplicate by it.
  final String mutationId;

  /// The table.
  final String table;

  /// The primary key of the row.
  final Object key;

  /// Incarnation of the key: grows when a deleted key is created again.
  final int generation;

  /// Local revision of the row this change produced.
  final int localRevision;

  /// Changes committed together share it (no remote atomicity implied).
  final String localTransactionId;

  /// Upsert or delete.
  final SyncOperation operation;

  /// The row as written, or `null` for a delete.
  final Map<String, Object?>? row;

  /// The server version this change builds on (`null` when the server never
  /// confirmed the row), fixed at the first claim.
  final Object? baseVersion;

  /// The previous mutation of the row, if any.
  final String? predecessor;

  /// How many times the change was claimed, this one included.
  final int attempt;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'mutation_id': mutationId,
    'table': table,
    'key': key,
    'generation': generation,
    'local_revision': localRevision,
    'local_transaction_id': localTransactionId,
    'operation': operation.wire,
    'row': row,
    'base_version': baseVersion,
    'predecessor': predecessor,
    'attempt': attempt,
  };

  /// The envelope encoded in [json].
  static Result<SyncEnvelope, DbError> decode(Object? json) => switch (json) {
    {
      'mutation_id': final String mutationId,
      'table': final String table,
      'key': final Object key,
      'generation': final int generation,
      'local_revision': final int localRevision,
      'local_transaction_id': final String localTransactionId,
      'operation': final String operation,
      'attempt': final int attempt,
    }
        when SyncOperation.byWire.containsKey(operation) =>
      Ok(
        SyncEnvelope(
          mutationId: mutationId,
          table: table,
          key: key,
          generation: generation,
          localRevision: localRevision,
          localTransactionId: localTransactionId,
          operation: SyncOperation.byWire[operation]!,
          row: SyncJson.object(json['row']),
          baseVersion: json['base_version'],
          predecessor: json['predecessor'] as String?,
          attempt: attempt,
        ),
      ),
    _ => Err(SyncJson.bad('envelope', json)),
  };

  @override
  String toString() => 'SyncEnvelope($mutationId, $table $key r$localRevision)';
}

/// A leased batch of envelopes.
final class ClaimedBatch {
  /// A batch.
  const ClaimedBatch({required this.leaseId, required this.envelopes});

  /// The lease, or `null` when nothing was eligible.
  final int? leaseId;

  /// The envelopes, in commit order.
  final List<SyncEnvelope> envelopes;

  /// Whether nothing was claimed.
  bool get isEmpty => envelopes.isEmpty;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'lease_id': leaseId,
    'envelopes': [for (final envelope in envelopes) envelope.toJson()],
  };

  /// The batch encoded in [json].
  static Result<ClaimedBatch, DbError> decode(Object? json) => switch (json) {
    {'lease_id': final int? leaseId, 'envelopes': final Object? envelopes} =>
      SyncJson.list(
        envelopes,
        SyncEnvelope.decode,
      ).map((list) => ClaimedBatch(leaseId: leaseId, envelopes: list)),
    _ => Err(SyncJson.bad('claimed batch', json)),
  };
}

/// The server stored one mutation.
final class SyncAcknowledgement {
  /// An acknowledgement of [mutationId], checked against its [table],
  /// [key] and [localRevision].
  const SyncAcknowledgement({
    required this.mutationId,
    required this.table,
    required this.key,
    required this.localRevision,
    required this.serverVersion,
  });

  /// The acknowledgement of [envelope], which the server stored as
  /// [serverVersion].
  SyncAcknowledgement.of(SyncEnvelope envelope, this.serverVersion)
    : mutationId = envelope.mutationId,
      table = envelope.table,
      key = envelope.key,
      localRevision = envelope.localRevision;

  /// The mutation.
  final String mutationId;

  /// Its table.
  final String table;

  /// Its key.
  final Object key;

  /// Its local revision.
  final int localRevision;

  /// The version the server stored (opaque).
  final Object? serverVersion;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'mutation_id': mutationId,
    'table': table,
    'key': key,
    'local_revision': localRevision,
    'server_version': serverVersion,
  };

  /// The acknowledgement encoded in [json].
  static Result<SyncAcknowledgement, DbError> decode(Object? json) =>
      switch (json) {
        {
          'mutation_id': final String mutationId,
          'table': final String table,
          'key': final Object key,
          'local_revision': final int localRevision,
        } =>
          Ok(
            SyncAcknowledgement(
              mutationId: mutationId,
              table: table,
              key: key,
              localRevision: localRevision,
              serverVersion: json['server_version'],
            ),
          ),
        _ => Err(SyncJson.invalid('acknowledgement', json)),
      };
}

/// The server refused one mutation.
final class SyncRejection {
  /// A rejection of [mutationId]; [retryable] sends it again later,
  /// otherwise it is blocked until retried.
  const SyncRejection({
    required this.mutationId,
    required this.reason,
    required this.retryable,
  });

  /// The rejection of [envelope].
  SyncRejection.of(
    SyncEnvelope envelope,
    this.reason, {
    required this.retryable,
  }) : mutationId = envelope.mutationId;

  /// The mutation.
  final String mutationId;

  /// Why, for diagnostics.
  final String reason;

  /// Whether to send it again later.
  final bool retryable;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'mutation_id': mutationId,
    'reason': reason,
    'retryable': retryable,
  };

  /// The rejection encoded in [json].
  static Result<SyncRejection, DbError> decode(Object? json) => switch (json) {
    {
      'mutation_id': final String mutationId,
      'reason': final String reason,
      'retryable': final bool retryable,
    } =>
      Ok(
        SyncRejection(
          mutationId: mutationId,
          reason: reason,
          retryable: retryable,
        ),
      ),
    _ => Err(SyncJson.invalid('rejection', json)),
  };
}

/// What the server answered to a push.
final class PushResult {
  /// The answer for the batch [leaseId]: with it, envelopes of the lease left
  /// out of [acknowledged] and [rejected] are released (pending again).
  const PushResult({
    this.leaseId,
    this.acknowledged = const [],
    this.rejected = const [],
  });

  /// The lease of the batch.
  final int? leaseId;

  /// Mutations the server stored; valid even after their lease expired.
  final List<SyncAcknowledgement> acknowledged;

  /// Mutations the server refused; applied only while the lease holds them.
  final List<SyncRejection> rejected;

  /// The protocol fields.
  Map<String, Object?> toJson() => {
    'lease_id': leaseId,
    'acknowledged': [for (final ack in acknowledged) ack.toJson()],
    'rejected': [for (final rejection in rejected) rejection.toJson()],
  };

  /// The result in a request.
  static Result<PushResult, DbError> decode(Map<Object?, Object?> json) =>
      switch (json['lease_id']) {
        final int? leaseId =>
          SyncJson.list(
            json['acknowledged'] ?? const <Object?>[],
            SyncAcknowledgement.decode,
          ).flatMap(
            (acknowledged) =>
                SyncJson.list(
                  json['rejected'] ?? const <Object?>[],
                  SyncRejection.decode,
                ).map(
                  (rejected) => PushResult(
                    leaseId: leaseId,
                    acknowledged: acknowledged,
                    rejected: rejected,
                  ),
                ),
          ),
        _ => Err(SyncJson.invalid('push result', json)),
      };
}

/// What `DbSync.applyPushResult` did.
final class PushOutcome {
  /// An outcome.
  const PushOutcome({
    required this.acknowledged,
    required this.rejected,
    required this.released,
    required this.ignored,
  });

  /// Mutations settled by an acknowledgement (duplicates not counted).
  final int acknowledged;

  /// Rejections applied.
  final int rejected;

  /// Deliveries of the lease released because the result left them out.
  final int released;

  /// Rejections ignored: the delivery is settled or held by another lease.
  final List<String> ignored;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'acknowledged': acknowledged,
    'rejected': rejected,
    'released': released,
    'ignored': ignored,
  };

  /// The outcome encoded in [json].
  static Result<PushOutcome, DbError> decode(Object? json) => switch (json) {
    {
      'acknowledged': final int acknowledged,
      'rejected': final int rejected,
      'released': final int released,
      'ignored': final List<Object?> ignored,
    }
        when ignored.every((id) => id is String) =>
      Ok(
        PushOutcome(
          acknowledged: acknowledged,
          rejected: rejected,
          released: released,
          ignored: ignored.cast<String>(),
        ),
      ),
    _ => Err(SyncJson.bad('push outcome', json)),
  };
}

/// One change of the server.
final class RemoteChange {
  /// The server holds [row] (keyed [key]) of [table] at [serverVersion].
  /// [mutationId] names the local mutation it echoes, when the server knows
  /// it: the change then acknowledges that mutation.
  const RemoteChange.upsert(
    this.table, {
    required this.key,
    required Map<String, Object?> this.row,
    required this.serverVersion,
    this.mutationId,
  }) : operation = SyncOperation.upsert;

  /// The server deleted the row [key] of [table] at [serverVersion].
  const RemoteChange.delete(
    this.table, {
    required this.key,
    required this.serverVersion,
    this.mutationId,
  }) : operation = SyncOperation.delete,
       row = null;

  const RemoteChange._(
    this.table,
    this.key,
    this.operation,
    this.row,
    this.serverVersion,
    this.mutationId,
  );

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// Upsert or delete.
  final SyncOperation operation;

  /// The row of an upsert; its primary key is [key].
  final Map<String, Object?>? row;

  /// The version the server holds after the change (opaque).
  final Object? serverVersion;

  /// The local mutation this change is the echo of.
  final String? mutationId;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'table': table,
    'key': key,
    'operation': operation.wire,
    'row': row,
    'server_version': serverVersion,
    'mutation_id': mutationId,
  };

  /// The change encoded in [json].
  static Result<RemoteChange, DbError> decode(Object? json) => switch (json) {
    {
      'table': final String table,
      'key': final Object key,
      'operation': final String operation,
    }
        when SyncOperation.byWire.containsKey(operation) =>
      Ok(
        RemoteChange._(
          table,
          key,
          SyncOperation.byWire[operation]!,
          SyncJson.object(json['row']),
          json['server_version'],
          json['mutation_id'] as String?,
        ),
      ),
    _ => Err(SyncJson.invalid('remote change', json)),
  };
}

/// A page of server changes.
final class RemotePage {
  /// [changes] read after [expectedCheckpoint] (the current checkpoint),
  /// stored with [nextCheckpoint].
  const RemotePage({
    required this.expectedCheckpoint,
    required this.nextCheckpoint,
    required this.changes,
  });

  /// The checkpoint the page was read after (`null` before the first page).
  final Object? expectedCheckpoint;

  /// The checkpoint stored with the page.
  final Object? nextCheckpoint;

  /// The changes, in feed order.
  final List<RemoteChange> changes;

  /// The protocol fields.
  Map<String, Object?> toJson() => {
    'expected_checkpoint': expectedCheckpoint,
    'next_checkpoint': nextCheckpoint,
    'changes': [for (final change in changes) change.toJson()],
  };

  /// The page in a request.
  static Result<RemotePage, DbError> decode(Map<Object?, Object?> json) =>
      SyncJson.list(json['changes'], RemoteChange.decode).map(
        (changes) => RemotePage(
          expectedCheckpoint: json['expected_checkpoint'],
          nextCheckpoint: json['next_checkpoint'],
          changes: changes,
        ),
      );
}

/// What `DbSync.applyRemote` did.
final class ApplyOutcome {
  /// An outcome.
  const ApplyOutcome({
    required this.applied,
    required this.conflicts,
    required this.acknowledged,
    required this.skipped,
  });

  /// Changes written to their rows.
  final int applied;

  /// Changes kept as conflicts (a local change was pending).
  final int conflicts;

  /// Echoes that acknowledged a local mutation.
  final int acknowledged;

  /// Changes already applied, or echoes of settled mutations.
  final int skipped;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'applied': applied,
    'conflicts': conflicts,
    'acknowledged': acknowledged,
    'skipped': skipped,
  };

  /// The outcome encoded in [json].
  static Result<ApplyOutcome, DbError> decode(Object? json) => switch (json) {
    {
      'applied': final int applied,
      'conflicts': final int conflicts,
      'acknowledged': final int acknowledged,
      'skipped': final int skipped,
    } =>
      Ok(
        ApplyOutcome(
          applied: applied,
          conflicts: conflicts,
          acknowledged: acknowledged,
          skipped: skipped,
        ),
      ),
    _ => Err(SyncJson.bad('apply outcome', json)),
  };
}

/// How a conflict ends.
///
/// Why sealed: a resolution is one of these three, and the engine applies
/// each differently.
sealed class ConflictResolution {
  const ConflictResolution();

  /// The server variant wins: the row takes it, and the local changes are
  /// settled as resolved (never as acknowledged).
  const factory ConflictResolution.acceptRemote() = AcceptRemote;

  /// The local row wins: it is sent again, on the server version.
  const factory ConflictResolution.keepLocal() = KeepLocal;

  /// [row] replaces both and is sent on the server version.
  const factory ConflictResolution.merged(Map<String, Object?> row) = Merged;

  /// The protocol form.
  Map<String, Object?> toJson();

  /// The resolution encoded in [json].
  static Result<ConflictResolution, DbError> decode(Object? json) =>
      switch (json) {
        {'kind': 'accept_remote'} => Ok(const AcceptRemote()),
        {'kind': 'keep_local'} => Ok(const KeepLocal()),
        {'kind': 'merged', 'row': final Map<String, Object?> row} => Ok(
          Merged(row),
        ),
        _ => Err(SyncJson.invalid('resolution', json)),
      };
}

/// See [ConflictResolution.acceptRemote].
final class AcceptRemote extends ConflictResolution {
  /// Accepts the server variant.
  const AcceptRemote();

  @override
  Map<String, Object?> toJson() => const {'kind': 'accept_remote'};
}

/// See [ConflictResolution.keepLocal].
final class KeepLocal extends ConflictResolution {
  /// Keeps the local row.
  const KeepLocal();

  @override
  Map<String, Object?> toJson() => const {'kind': 'keep_local'};
}

/// See [ConflictResolution.merged].
final class Merged extends ConflictResolution {
  /// Replaces both variants with [row].
  const Merged(this.row);

  /// The merged row; its primary key is the conflict's key.
  final Map<String, Object?> row;

  @override
  Map<String, Object?> toJson() => {'kind': 'merged', 'row': row};
}

/// The sync state of one row.
final class EntitySyncState {
  /// A state.
  const EntitySyncState({
    required this.state,
    required this.deleted,
    required this.sending,
    required this.attempts,
    required this.lastError,
    required this.pending,
    required this.localRevision,
    required this.acknowledgedLocalRevision,
    required this.settledLocalRevision,
    required this.rowVersion,
    required this.serverVersion,
    required this.conflict,
  });

  /// The summary.
  final SyncStateKind state;

  /// The row is deleted (a tombstone, pending or settled).
  final bool deleted;

  /// The next change is leased right now.
  final bool sending;

  /// Times the next change was claimed.
  final int attempts;

  /// The last error recorded for the next change.
  final String? lastError;

  /// Changes not settled yet.
  final int pending;

  /// Revision of the latest local change.
  final int localRevision;

  /// Highest revision the server acknowledged.
  final int acknowledgedLocalRevision;

  /// Every revision up to this one is acknowledged or resolved.
  final int settledLocalRevision;

  /// Changes whenever the local row changes: the precondition of a
  /// resolution.
  final int rowVersion;

  /// The last server version known for the row (opaque).
  final Object? serverVersion;

  /// The open conflict, if any.
  final String? conflict;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'state': state.wire,
    'deleted': deleted,
    'sending': sending,
    'attempts': attempts,
    'last_error': lastError,
    'pending': pending,
    'local_revision': localRevision,
    'acknowledged_local_revision': acknowledgedLocalRevision,
    'settled_local_revision': settledLocalRevision,
    'row_version': rowVersion,
    'server_version': serverVersion,
    'conflict': conflict,
  };

  /// The state encoded in [json].
  static Result<EntitySyncState, DbError> decode(Object? json) =>
      switch (json) {
        {
          'state': final String state,
          'deleted': final bool deleted,
          'sending': final bool sending,
          'attempts': final int attempts,
          'pending': final int pending,
          'local_revision': final int localRevision,
          'acknowledged_local_revision': final int acknowledged,
          'settled_local_revision': final int settled,
          'row_version': final int rowVersion,
        }
            when SyncStateKind.byWire.containsKey(state) =>
          Ok(
            EntitySyncState(
              state: SyncStateKind.byWire[state]!,
              deleted: deleted,
              sending: sending,
              attempts: attempts,
              lastError: json['last_error'] as String?,
              pending: pending,
              localRevision: localRevision,
              acknowledgedLocalRevision: acknowledged,
              settledLocalRevision: settled,
              rowVersion: rowVersion,
              serverVersion: json['server_version'],
              conflict: json['conflict'] as String?,
            ),
          ),
        _ => Err(SyncJson.bad('sync state', json)),
      };
}

/// One open change, as `DbSync.pending` lists it.
final class PendingChange {
  /// A pending change.
  const PendingChange({
    required this.mutationId,
    required this.table,
    required this.key,
    required this.localRevision,
    required this.operation,
    required this.state,
    required this.attempts,
    required this.lastError,
  });

  /// The mutation.
  final String mutationId;

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// Its local revision.
  final int localRevision;

  /// Upsert or delete.
  final SyncOperation operation;

  /// Pending, leased or blocked.
  final DeliveryState state;

  /// Times claimed.
  final int attempts;

  /// The last error recorded.
  final String? lastError;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'mutation_id': mutationId,
    'table': table,
    'key': key,
    'local_revision': localRevision,
    'operation': operation.wire,
    'state': state.wire,
    'attempts': attempts,
    'last_error': lastError,
  };

  /// The change encoded in [json].
  static Result<PendingChange, DbError> decode(Object? json) => switch (json) {
    {
      'mutation_id': final String mutationId,
      'table': final String table,
      'key': final Object key,
      'local_revision': final int localRevision,
      'operation': final String operation,
      'state': final String state,
      'attempts': final int attempts,
    }
        when SyncOperation.byWire.containsKey(operation) &&
            DeliveryState.byWire.containsKey(state) =>
      Ok(
        PendingChange(
          mutationId: mutationId,
          table: table,
          key: key,
          localRevision: localRevision,
          operation: SyncOperation.byWire[operation]!,
          state: DeliveryState.byWire[state]!,
          attempts: attempts,
          lastError: json['last_error'] as String?,
        ),
      ),
    _ => Err(SyncJson.bad('pending change', json)),
  };
}

/// Open changes of a remote.
final class PendingChanges {
  /// The open changes.
  const PendingChanges({required this.count, required this.changes});

  /// How many changes of the remote are open (every table).
  final int count;

  /// The changes listed, in commit order.
  final List<PendingChange> changes;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'count': count,
    'changes': [for (final change in changes) change.toJson()],
  };

  /// The changes encoded in [json].
  static Result<PendingChanges, DbError> decode(Object? json) => switch (json) {
    {'count': final int count, 'changes': final Object? changes} =>
      SyncJson.list(
        changes,
        PendingChange.decode,
      ).map((list) => PendingChanges(count: count, changes: list)),
    _ => Err(SyncJson.bad('pending changes', json)),
  };
}

/// A server change that met pending local changes (RFC-001 §13.15).
final class SyncConflict {
  /// A conflict.
  const SyncConflict({
    required this.id,
    required this.table,
    required this.key,
    required this.localRowVersion,
    required this.localRow,
    required this.outstanding,
    required this.remoteVersion,
    required this.remoteOperation,
    required this.remoteRow,
    required this.baseVersion,
  });

  /// Identity, for `DbSync.resolveConflict`.
  final String id;

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// The current row version: the precondition to resolve it.
  final int localRowVersion;

  /// The local row now (`null` if deleted locally).
  final Map<String, Object?>? localRow;

  /// Open local mutations of the row.
  final List<String> outstanding;

  /// The server version of the remote variant.
  final Object? remoteVersion;

  /// What the server did.
  final SyncOperation remoteOperation;

  /// The server row (`null` for a delete).
  final Map<String, Object?>? remoteRow;

  /// The server version the local changes were based on.
  final Object? baseVersion;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'id': id,
    'table': table,
    'key': key,
    'local_row_version': localRowVersion,
    'local_row': localRow,
    'outstanding': outstanding,
    'remote_version': remoteVersion,
    'remote_operation': remoteOperation.wire,
    'remote_row': remoteRow,
    'base_version': baseVersion,
  };

  /// The conflict encoded in [json].
  static Result<SyncConflict, DbError> decode(Object? json) => switch (json) {
    {
      'id': final String id,
      'table': final String table,
      'key': final Object key,
      'local_row_version': final int localRowVersion,
      'outstanding': final List<Object?> outstanding,
      'remote_operation': final String operation,
    }
        when SyncOperation.byWire.containsKey(operation) &&
            outstanding.every((mutation) => mutation is String) =>
      Ok(
        SyncConflict(
          id: id,
          table: table,
          key: key,
          localRowVersion: localRowVersion,
          localRow: SyncJson.object(json['local_row']),
          outstanding: outstanding.cast<String>(),
          remoteVersion: json['remote_version'],
          remoteOperation: SyncOperation.byWire[operation]!,
          remoteRow: SyncJson.object(json['remote_row']),
          baseVersion: json['base_version'],
        ),
      ),
    _ => Err(SyncJson.bad('conflict', json)),
  };
}

/// The checkpoint and counters of a remote.
final class RemoteSyncStatus {
  /// A status.
  const RemoteSyncStatus({
    required this.checkpoint,
    required this.pending,
    required this.conflicts,
  });

  /// The checkpoint of the last applied page (`null` before the first).
  final Object? checkpoint;

  /// Open changes.
  final int pending;

  /// Open conflicts.
  final int conflicts;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'checkpoint': checkpoint,
    'pending': pending,
    'conflicts': conflicts,
  };

  /// The status encoded in [json].
  static Result<RemoteSyncStatus, DbError> decode(Object? json) =>
      switch (json) {
        {'pending': final int pending, 'conflicts': final int conflicts} => Ok(
          RemoteSyncStatus(
            checkpoint: json['checkpoint'],
            pending: pending,
            conflicts: conflicts,
          ),
        ),
        _ => Err(SyncJson.bad('remote status', json)),
      };
}
