import 'package:db_dsl/conformance.dart';
import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// Every operation and statement the DSL can send has a replayed example in
/// `PROTOCOL.md`.
///
/// Why the switches: they are exhaustive over the sealed request and
/// statement families, so a new kind does not compile until it is named
/// here, and then this test asks for its example.
void main() {
  test('every operation has an example in PROTOCOL.md', () {
    final shown = _ExampleOps.of(ProtocolExamples.scenario);

    for (final op in _Kinds.operations) {
      expect(shown.operations, contains(op), reason: 'no example of `$op`');
    }
  });

  test('every statement has an example in PROTOCOL.md', () {
    final shown = _ExampleOps.of(ProtocolExamples.scenario);

    for (final op in _Kinds.statements) {
      expect(shown.statements, contains(op), reason: 'no example of `$op`');
    }
  });
}

/// The wire names of every request and statement kind.
abstract final class _Kinds {
  /// Every `op` of a request, transaction controls included.
  static final List<String> operations = [
    'define_table',
    'drop_table',
    'tables',
    'execute',
    'batch',
    'explain',
    'begin',
    'tx_execute',
    for (final control in TransactionControl.values) control.wire,
    'info',
    'sync_claim',
    'sync_push_result',
    'sync_release',
    'sync_retry',
    'sync_apply_remote',
    'sync_resolve',
    'sync_state',
    'sync_pending',
    'sync_conflicts',
    'sync_status',
  ];

  /// Every `op` of a statement.
  static const List<String> statements = [
    'select',
    'count',
    'aggregate',
    'find',
    'group',
    'join',
    'insert',
    'update',
    'delete',
  ];

  /// Compile-time guard: adding a request kind breaks this switch until it
  /// is added to [operations].
  // ignore: unused_element
  static String _operation(ProtocolRequest<Object?> request) =>
      switch (request) {
        DefineTableRequest() => 'define_table',
        DropTableRequest() => 'drop_table',
        TablesRequest() => 'tables',
        ExecuteRequest() => 'execute',
        BatchRequest() => 'batch',
        ExplainRequest() => 'explain',
        BeginRequest() => 'begin',
        TransactionExecuteRequest() => 'tx_execute',
        TransactionControlRequest(:final control) => control.wire,
        InfoRequest() => 'info',
        SyncClaimRequest() => 'sync_claim',
        SyncPushResultRequest() => 'sync_push_result',
        SyncReleaseRequest() => 'sync_release',
        SyncRetryRequest() => 'sync_retry',
        SyncApplyRemoteRequest() => 'sync_apply_remote',
        SyncResolveRequest() => 'sync_resolve',
        SyncStateRequest() => 'sync_state',
        SyncPendingRequest() => 'sync_pending',
        SyncConflictsRequest() => 'sync_conflicts',
        SyncStatusRequest() => 'sync_status',
      };

  /// Compile-time guard: adding a statement kind breaks this switch until
  /// it is added to [statements].
  // ignore: unused_element
  static String _statement(Statement<Object?> statement) => switch (statement) {
    SelectStatement() => 'select',
    CountStatement() => 'count',
    AggregateStatement() => 'aggregate',
    FindStatement() => 'find',
    GroupStatement() => 'group',
    JoinStatement() => 'join',
    InsertStatement() => 'insert',
    UpdateStatement() => 'update',
    DeleteStatement() => 'delete',
  };
}

/// The operations and statements the examples send.
final class _ExampleOps {
  _ExampleOps._(this.operations, this.statements);

  /// The ops found in [examples]' requests.
  factory _ExampleOps.of(List<ProtocolExample> examples) {
    final operations = <String>{};
    final statements = <String>{};

    for (final ProtocolExample(:request) in examples) {
      if (request['op'] case final String op) {
        operations.add(op);
      }
      for (final statement in [
        request['statement'],
        ...?(request['statements'] as List<Object?>?),
      ]) {
        if (statement case {'op': final String op}) {
          statements.add(op);
        }
      }
      // `explain` carries a select without its `op`.
      if (request['query'] case Map<String, Object?>()) {
        statements.add('select');
      }
    }

    return _ExampleOps._(operations, statements);
  }

  /// Request ops.
  final Set<String> operations;

  /// Statement ops.
  final Set<String> statements;
}
