/// The data of a [MemoryEngine] database: tables and indexes kept as maps
/// ordered by encoded keys, the way LMDB keeps its B+trees.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../protocol/json_values.dart';
import '../protocol/sync_records.dart';
import '../schema/table_schema.dart';

/// Keys compared byte by byte, like LMDB's default comparator.
typedef KeyMap<V> = SplayTreeMap<List<int>, V>;

/// One table: its definition, its rows by primary key, and its indexes.
///
/// Why keys are bytes: the order of rows and index entries, the equality of
/// keys (integers beyond 2^53 collide, `-0.0` equals `0`) and the key size
/// limit then follow `JsonValues.encodeKey` exactly as in the native engine.
final class MemoryTable {
  /// An empty table defined by [schema].
  MemoryTable(this.schema)
    : rows = KeyMap<Map<String, Object?>>(JsonValues.compareKeys),
      indexes = {
        for (final index in schema.indexes)
          index.name: KeyMap<List<int>>(JsonValues.compareKeys),
      };

  MemoryTable._(this.schema, this.rows, this.indexes);

  /// The definition.
  final TableSchema schema;

  /// Rows by encoded primary key.
  final KeyMap<Map<String, Object?>> rows;

  /// Index entries (encoded key → encoded primary key), by index name.
  final Map<String, KeyMap<List<int>>> indexes;

  /// An independent copy (rows are replaced, never mutated in place, so they
  /// are shared).
  MemoryTable copy() => MemoryTable._(
    schema,
    KeyMap<Map<String, Object?>>.of(rows, JsonValues.compareKeys),
    {
      for (final MapEntry(:key, :value) in indexes.entries)
        key: KeyMap<List<int>>.of(value, JsonValues.compareKeys),
    },
  );
}

/// Every table and sequence of a database at one point in time.
///
/// Why copies: a transaction works on its own copy and replaces the
/// committed state only on commit; a statement works on a copy of its
/// transaction's state and replaces it only when it succeeds. That is how
/// LMDB's copy-on-write gives atomic statements and savepoints.
final class MemoryState {
  /// An empty database.
  MemoryState() : tables = {}, sequences = {}, sync = MemorySync();

  MemoryState._(this.tables, this.sequences, this.sync);

  /// Tables by name.
  final Map<String, MemoryTable> tables;

  /// Last generated key of each auto-increment table.
  final Map<String, int> sequences;

  /// The sync records of the synchronized tables.
  final MemorySync sync;

  /// An independent copy.
  MemoryState copy() => MemoryState._(
    {for (final MapEntry(:key, :value) in tables.entries) key: value.copy()},
    {...sequences},
    sync.copy(),
  );

  /// A deep copy of a stored JSON value, so no caller aliases stored data.
  static Object? detached(Object? value) => jsonDecode(jsonEncode(value));
}

/// The sync records of a database (offline_first_core keeps them in its
/// `__sync` database): per row, the open changes, the receipts of settled
/// mutations, the conflicts and the remotes.
///
/// Why a deep [copy]: the records follow the state they belong to, so a
/// statement, a savepoint or a transaction that fails takes its changes
/// with it; copying every record lets the operations change them in place.
final class MemorySync {
  /// Empty records, with a new replica identity.
  MemorySync()
    : replica = _newReplica(),
      entities = KeyMap<MemoryEntitySync>(JsonValues.compareKeys),
      changes = SplayTreeMap<int, MemoryChange>(),
      mutations = {},
      remotes = {},
      conflicts = SplayTreeMap<String, MemoryConflict>();

  MemorySync._(
    this.replica,
    this.entities,
    this.changes,
    this.mutations,
    this.remotes,
    this.conflicts,
  );

  /// Identity of this database among replicas, in mutation ids.
  final String replica;

  /// A synchronized table was defined at least once.
  bool enabled = false;

  /// Last change sequence.
  int sequence = 0;

  /// Last lease number.
  int leases = 0;

  /// Last conflict number.
  int conflictCount = 0;

  /// Records of each row, by `encodeKey([table, key])`.
  final KeyMap<MemoryEntitySync> entities;

  /// Open changes, by sequence (commit order).
  final SplayTreeMap<int, MemoryChange> changes;

  /// Open and settled mutations, by id.
  final Map<String, MemoryMutation> mutations;

  /// Checkpoint and counters of each remote.
  final Map<String, MemoryRemote> remotes;

  /// Open conflicts, by id.
  final SplayTreeMap<String, MemoryConflict> conflicts;

  /// An independent copy.
  MemorySync copy() =>
      MemorySync._(
          replica,
          KeyMap<MemoryEntitySync>.from(
            entities.map((key, value) => MapEntry(key, value.copy())),
            JsonValues.compareKeys,
          ),
          SplayTreeMap<int, MemoryChange>.from(
            changes.map((key, value) => MapEntry(key, value.copy())),
          ),
          {...mutations},
          {
            for (final MapEntry(:key, :value) in remotes.entries)
              key: value.copy(),
          },
          SplayTreeMap<String, MemoryConflict>.from(conflicts),
        )
        ..enabled = enabled
        ..sequence = sequence
        ..leases = leases
        ..conflictCount = conflictCount;

  /// The checkpoint and counters of [remote].
  MemoryRemote remote(String remote) =>
      remotes.putIfAbsent(remote, MemoryRemote.new);

  static String _newReplica() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

/// The sync records of one row.
final class MemoryEntitySync {
  /// The records of a row never changed locally.
  MemoryEntitySync(this.table, this.key);

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// Incarnation of the key.
  int generation = 1;

  /// Revision of the latest local change.
  int localRevision = 0;

  /// Highest revision the server acknowledged.
  int acknowledgedLocalRevision = 0;

  /// Every revision up to this one is settled.
  int settledLocalRevision = 0;

  /// Changes whenever the local row changes.
  int rowVersion = 0;

  /// The last server version known.
  Object? serverVersion;

  /// The server state is known (an acknowledgement or a remote change).
  bool initialized = false;

  /// The row is deleted (a tombstone).
  bool deleted = false;

  /// Sequences of the open changes, in order.
  List<int> open = [];

  /// The latest mutation of the row.
  String? lastMutation;

  /// The open conflict.
  String? conflict;

  /// An independent copy.
  MemoryEntitySync copy() => MemoryEntitySync(table, key)
    ..generation = generation
    ..localRevision = localRevision
    ..acknowledgedLocalRevision = acknowledgedLocalRevision
    ..settledLocalRevision = settledLocalRevision
    ..rowVersion = rowVersion
    ..serverVersion = serverVersion
    ..initialized = initialized
    ..deleted = deleted
    ..open = [...open]
    ..lastMutation = lastMutation
    ..conflict = conflict;
}

/// An open change: the immutable mutation and its delivery state.
final class MemoryChange {
  /// A pending change.
  MemoryChange({
    required this.mutationId,
    required this.remote,
    required this.table,
    required this.key,
    required this.generation,
    required this.localRevision,
    required this.localTransactionId,
    required this.operation,
    required this.row,
    required this.predecessor,
  });

  /// Stable identity of the mutation.
  final String mutationId;

  /// The remote it is delivered to.
  final String remote;

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// Incarnation of the key.
  final int generation;

  /// Local revision this change produced.
  final int localRevision;

  /// Shared by the changes of one root transaction.
  final String localTransactionId;

  /// Upsert or delete.
  final SyncOperation operation;

  /// The row as written (immutable), or `null` for a delete.
  final Map<String, Object?>? row;

  /// The previous mutation of the row.
  final String? predecessor;

  /// Pending, leased or blocked.
  DeliveryState state = DeliveryState.pending;

  /// Times claimed.
  int attempts = 0;

  /// The lease holding it.
  int? leaseId;

  /// When the lease expires, in milliseconds since the epoch.
  int? leaseExpiresAt;

  /// Whether [baseVersion] is fixed (from the first claim on).
  bool prepared = false;

  /// The server version the change builds on.
  Object? baseVersion;

  /// The last error recorded.
  String? lastError;

  /// An independent copy.
  MemoryChange copy() =>
      MemoryChange(
          mutationId: mutationId,
          remote: remote,
          table: table,
          key: key,
          generation: generation,
          localRevision: localRevision,
          localTransactionId: localTransactionId,
          operation: operation,
          row: row,
          predecessor: predecessor,
        )
        ..state = state
        ..attempts = attempts
        ..leaseId = leaseId
        ..leaseExpiresAt = leaseExpiresAt
        ..prepared = prepared
        ..baseVersion = baseVersion
        ..lastError = lastError;

  /// Whether a lease that has not expired at [now] holds it.
  bool leaseAlive(int now) =>
      state == DeliveryState.leased && (leaseExpiresAt ?? 0) > now;

  /// The delivery state at [now]: an expired lease reads as pending.
  DeliveryState delivery(int now) =>
      state == DeliveryState.leased && !leaseAlive(now)
      ? DeliveryState.pending
      : state;

  /// The envelope sent for this change.
  SyncEnvelope get envelope => SyncEnvelope(
    mutationId: mutationId,
    table: table,
    key: key,
    generation: generation,
    localRevision: localRevision,
    localTransactionId: localTransactionId,
    operation: operation,
    row: row,
    baseVersion: baseVersion,
    predecessor: predecessor,
    attempt: attempts,
  );
}

/// Where a mutation is: open, or settled with a receipt.
sealed class MemoryMutation {
  const MemoryMutation();
}

/// An open mutation: its change is at [sequence].
final class MemoryOpenMutation extends MemoryMutation {
  /// The mutation of the change [sequence].
  const MemoryOpenMutation(this.sequence);

  /// The sequence of its change.
  final int sequence;
}

/// A settled mutation: acknowledged by the server, or resolved locally.
final class MemorySettledMutation extends MemoryMutation {
  /// The receipt of the mutation of [key] in [table] at [localRevision].
  const MemorySettledMutation(this.table, this.key, this.localRevision);

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// The local revision of the mutation.
  final int localRevision;
}

/// The checkpoint and counters of a remote.
final class MemoryRemote {
  /// A remote with nothing applied or pending.
  MemoryRemote();

  /// The checkpoint of the last applied page.
  Object? checkpoint;

  /// Open changes.
  int pending = 0;

  /// Open conflicts.
  int conflicts = 0;

  /// An independent copy.
  MemoryRemote copy() => MemoryRemote()
    ..checkpoint = checkpoint
    ..pending = pending
    ..conflicts = conflicts;
}

/// The remote variant of a conflict.
final class MemoryConflict {
  /// A conflict.
  const MemoryConflict({
    required this.id,
    required this.remote,
    required this.table,
    required this.key,
    required this.remoteVersion,
    required this.remoteOperation,
    required this.remoteRow,
    required this.baseVersion,
  });

  /// Identity.
  final String id;

  /// The remote.
  final String remote;

  /// The table.
  final String table;

  /// The primary key.
  final Object key;

  /// The server version of the remote variant.
  final Object? remoteVersion;

  /// What the server did.
  final SyncOperation remoteOperation;

  /// The server row, or `null` for a delete.
  final Map<String, Object?>? remoteRow;

  /// The server version the local changes were based on.
  final Object? baseVersion;
}
