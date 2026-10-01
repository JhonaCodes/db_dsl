part of '../conformance.dart';

/// Offline-first sync (`PROTOCOL.md`, "Sync"; RFC-001 §13.19): a write to a
/// synchronized table records its change in the same transaction, and the
/// sync operations settle it by mutation and revision.
abstract final class _SyncCases {
  static const String _remote = 'primary';

  static Future<(Database, JsonTable)> _notes(ConformanceHost host) async {
    final notes = JsonTable(
      'notes',
      indexes: [
        ['title'],
      ],
      syncWith: _remote,
    );
    return (await host.open([notes]), notes);
  }

  static Future<void> _insert(Database db, JsonTable notes, String id) async =>
      Check.ok(
        await notes
            .insert(
              JsonTable.rows([
                {'id': id, 'title': 'title of $id'},
              ]),
            )
            .execute(db),
        'insert $id',
      );

  static Future<void> _retitle(
    Database db,
    JsonTable notes,
    String id,
    String title,
  ) async => Check.ok(
    await notes
        .update()
        .filter(notes.field<String>('id').eq(id))
        .set(notes.field<String>('title'), title)
        .execute(db),
    'update $id',
  );

  static Future<ClaimedBatch> _claim(
    Database db, {
    Duration lease = const Duration(seconds: 30),
  }) async => Check.ok(
    await db.sync.claim(_remote, limits: ClaimLimits(lease: lease)),
    'claim',
  );

  static Future<void> _acknowledge(
    Database db,
    SyncEnvelope envelope,
    Object? version,
  ) async => Check.ok(
    await db.sync.applyPushResult(
      _remote,
      PushResult(acknowledged: [SyncAcknowledgement.of(envelope, version)]),
    ),
    'acknowledge ${envelope.mutationId}',
  );

  static Future<EntitySyncState> _state(
    Database db,
    JsonTable notes,
    String id,
  ) async => switch (Check.ok(await db.sync.stateOf(notes, id), 'state')) {
    final EntitySyncState state => state,
    null => throw ConformanceFailure('$id has no sync state'),
  };

  static Future<int> _pending(Database db) async =>
      Check.ok(await db.sync.status(_remote), 'status').pending;

  static RemotePage _page(
    Object? after,
    Object? next,
    List<RemoteChange> changes,
  ) => RemotePage(
    expectedCheckpoint: after,
    nextCheckpoint: next,
    changes: changes,
  );

  static RemoteChange _remoteRow(String id, String title, String version) =>
      RemoteChange.upsert(
        'notes',
        key: id,
        row: {'id': id, 'title': title},
        serverVersion: version,
      );

  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'sync',
      'a write records its change in its commit; a rollback or a rolled '
          'back savepoint records nothing',
      (host) async {
        final (db, notes) = await _notes(host);

        await _insert(db, notes, 'kept');
        Check.equals(await _pending(db), 1, 'one change per write');

        final undone = await db.transaction<()>((tx) async {
          Check.ok(
            await notes
                .insert(
                  JsonTable.rows([
                    {'id': 'never', 'title': 'x'},
                  ]),
                )
                .execute(tx),
            'insert in tx',
          );
          return Err(DbError(DbErrorCode.invalidRequest, 'undo'));
        });
        Check.fails(undone, DbErrorCode.invalidRequest, 'rolled back');

        Check.ok(
          await db.transaction<()>((tx) async {
            final inner = await tx.savepoint<()>((sp) async {
              Check.ok(
                await notes
                    .insert(
                      JsonTable.rows([
                        {'id': 'undone', 'title': 'x'},
                      ]),
                    )
                    .execute(sp),
                'insert in savepoint',
              );
              return Err(DbError(DbErrorCode.invalidRequest, 'undo it'));
            });
            Check.fails(inner, DbErrorCode.invalidRequest, 'savepoint');
            return Ok(());
          }),
          'transaction',
        );

        final batch = await _claim(db);
        Check.equals(
          [for (final envelope in batch.envelopes) envelope.key],
          ['kept'],
          'only the committed change',
        );
        Check.equals(
          Check.ok(await db.sync.stateOf(notes, 'never'), 'state'),
          null,
          'a rolled back row has no records',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'sync',
      'the acknowledgement of one revision leaves the next one pending',
      (host) async {
        final (db, notes) = await _notes(host);
        await _insert(db, notes, 'a');
        final sent = (await _claim(db, lease: Duration.zero)).envelopes.single;

        await _retitle(db, notes, 'a', 'eight');
        final resent = (await _claim(db)).envelopes.single;
        Check.equals(resent.mutationId, sent.mutationId, 'same identity');
        Check.equals(resent.row, sent.row, 'same bytes');
        Check.equals(resent.attempt, 2, 'second attempt');

        await _acknowledge(db, sent, 'v7');
        final state = await _state(db, notes, 'a');
        Check.equals(state.state, SyncStateKind.pending, 'revision 2 pending');
        Check.equals(state.acknowledgedLocalRevision, 1, 'acknowledged');
        Check.equals(state.settledLocalRevision, 1, 'settled');

        final next = (await _claim(db)).envelopes.single;
        Check.equals(next.localRevision, 2, 'the next revision');
        Check.equals(next.baseVersion, 'v7', 'on the acknowledged version');
        Check.equals(next.predecessor, sent.mutationId, 'chained');
        await db.close();
      },
    ),
    ConformanceCase(
      'sync',
      'one change per row is in flight, and acknowledgements are checked',
      (host) async {
        final (db, notes) = await _notes(host);
        await _insert(db, notes, 'a');
        await _retitle(db, notes, 'a', 'twice');
        await _insert(db, notes, 'b');

        final batch = await _claim(db);
        Check.equals(
          [for (final e in batch.envelopes) (e.key, e.localRevision)],
          [('a', 1), ('b', 1)],
          'the first change of each row',
        );
        Check.isTrue((await _claim(db)).isEmpty, 'revision 2 waits');

        final wrong = SyncAcknowledgement(
          mutationId: batch.envelopes.first.mutationId,
          table: 'notes',
          key: 'a',
          localRevision: 2,
          serverVersion: 'v1',
        );
        Check.fails(
          await db.sync.applyPushResult(
            _remote,
            PushResult(acknowledged: [wrong]),
          ),
          DbErrorCode.acknowledgementMismatch,
          'another revision',
        );

        await _acknowledge(db, batch.envelopes.first, 'v1');
        final again = Check.ok(
          await db.sync.applyPushResult(
            _remote,
            PushResult(
              acknowledged: [
                SyncAcknowledgement.of(batch.envelopes.first, 'v1'),
              ],
            ),
          ),
          'duplicate',
        );
        Check.equals(again.acknowledged, 0, 'a duplicate settles nothing');
        await db.close();
      },
    ),
    ConformanceCase(
      'sync',
      'a deletion keeps a tombstone until acknowledged, then the key comes '
          'back as a new generation',
      (host) async {
        final (db, notes) = await _notes(host);
        await _insert(db, notes, 'a');
        await _acknowledge(db, (await _claim(db)).envelopes.single, 'v1');
        Check.ok(
          await notes
              .delete()
              .filter(notes.field<String>('id').eq('a'))
              .execute(db),
          'delete',
        );

        Check.fails(
          await notes
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'title': 'again'},
                ]),
              )
              .execute(db),
          DbErrorCode.tombstonePending,
          'recreate before the deletion is settled',
        );
        final deletion = (await _claim(db)).envelopes.single;
        Check.equals(deletion.operation, SyncOperation.delete, 'delete');
        Check.equals(deletion.row, null, 'no payload');
        Check.equals(deletion.baseVersion, 'v1', 'on the server version');

        await _acknowledge(db, deletion, null);
        await _insert(db, notes, 'a');
        final reborn = (await _claim(db)).envelopes.single;
        Check.equals(reborn.generation, 2, 'a new incarnation');
        await db.close();
      },
    ),
    ConformanceCase(
      'sync',
      'remote changes apply without an echo, and the checkpoint moves '
          'with its page',
      (host) async {
        final (db, notes) = await _notes(host);

        final applied = Check.ok(
          await db.sync.applyRemote(
            _remote,
            _page(null, 'c1', [_remoteRow('r', 'from server', 'v3')]),
          ),
          'apply',
        );
        Check.equals(applied.applied, 1, 'applied');
        Check.equals(Check.ok(await notes.find('r').first(db), 'find')?.json, {
          'id': 'r',
          'title': 'from server',
        }, 'the row');
        Check.equals(await _pending(db), 0, 'no echo');
        Check.equals(
          (await _state(db, notes, 'r')).state,
          SyncStateKind.synced,
          'synced',
        );

        Check.fails(
          await db.sync.applyRemote(
            _remote,
            _page(null, 'c2', [_remoteRow('s', 's', 'v4')]),
          ),
          DbErrorCode.staleCheckpoint,
          'read after an old checkpoint',
        );
        Check.fails(
          await db.sync.applyRemote(
            _remote,
            _page('c1', 'c2', [
              _remoteRow('s', 's', 'v4'),
              RemoteChange.upsert(
                'notes',
                key: 't',
                row: {'id': 'other', 'title': 't'},
                serverVersion: 'v5',
              ),
            ]),
          ),
          DbErrorCode.invalidRequest,
          'a broken page',
        );
        Check.equals(
          Check.ok(await notes.find('s').first(db), 'find'),
          null,
          'nothing of a broken page is kept',
        );
        Check.equals(
          Check.ok(await db.sync.status(_remote), 'status').checkpoint,
          'c1',
          'the checkpoint did not move',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'sync',
      'a remote change over a pending change is a conflict, resolved with '
          'the row version as precondition',
      (host) async {
        final (db, notes) = await _notes(host);
        await _insert(db, notes, 'a');
        final sending = await _claim(db);
        Check.ok(
          await db.sync.applyRemote(
            _remote,
            _page(null, 'c1', [_remoteRow('a', 'remote', 'v9')]),
          ),
          'pull',
        );

        Check.equals(
          Check.ok(await notes.find('a').first(db), 'find')?.json['title'],
          'title of a',
          'the local row stays',
        );
        final conflict = Check.ok(
          await db.sync.conflicts(_remote),
          'conflicts',
        ).single;
        Check.equals(conflict.remoteRow, {
          'id': 'a',
          'title': 'remote',
        }, 'the remote variant is kept');

        Check.fails(
          await db.sync.resolveConflict(
            conflict,
            const ConflictResolution.acceptRemote(),
          ),
          DbErrorCode.mutationInFlight,
          'a change is being sent',
        );
        Check.ok(
          await db.sync.release(_remote, sending.leaseId!, reason: 'network'),
          'release',
        );

        await _retitle(db, notes, 'a', 'edited after');
        Check.fails(
          await db.sync.resolveConflict(
            conflict,
            const ConflictResolution.acceptRemote(),
          ),
          DbErrorCode.rowVersionMismatch,
          'the row changed since',
        );

        final fresh = Check.ok(
          await db.sync.conflicts(_remote),
          'conflicts',
        ).single;
        Check.ok(
          await db.sync.resolveConflict(
            fresh,
            const ConflictResolution.merged({'id': 'a', 'title': 'merged'}),
          ),
          'merge',
        );
        final merged = (await _claim(db)).envelopes.single;
        Check.equals(merged.row, {'id': 'a', 'title': 'merged'}, 'merged');
        Check.equals(merged.baseVersion, 'v9', 'on the remote version');
        await db.close();
      },
    ),
  ];
}
