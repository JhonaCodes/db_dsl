part of '../conformance.dart';

/// Transactions: commit and rollback, rollback-only, savepoints, snapshots,
/// the single writer, idle expiry.
abstract final class _TransactionCases {
  static Future<int> _count(QueryExecutor executor, JsonTable table) async =>
      Check.ok(await table.all().count(executor), 'count');

  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'transactions',
      'Ok commits, Err rolls back, and reads see the transaction\'s writes',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);

        final committed = await db.transaction<int>((tx) async {
          Check.ok(
            await table.insert(JsonTable.rows([_People.row(1)])).execute(tx),
            'insert in tx',
          );
          return Ok(await _count(tx, table));
        });
        Check.equals(Check.ok(committed, 'commit'), 1, 'read your writes');

        final rolledBack = await db.transaction<int>((tx) async {
          Check.ok(
            await table.insert(JsonTable.rows([_People.row(2)])).execute(tx),
            'insert in tx',
          );
          return Err(
            DbError(DbErrorCode.invalidRequest, 'the caller gives up'),
          );
        });
        Check.fails(rolledBack, DbErrorCode.invalidRequest, 'body error');
        Check.equals(
          await _count(db, table),
          1,
          'the second insert was undone',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'other connections do not see uncommitted writes',
      (host) async {
        final table = _People.table();
        final path = await host.freshPath();
        final db = await host.reopen(path, [table]);
        final other = await host.reopen(path, [table]);

        Check.ok(
          await db.transaction<()>((tx) async {
            Check.ok(
              await table.insert(JsonTable.rows([_People.row(1)])).execute(tx),
              'insert in tx',
            );
            Check.equals(
              await _count(other, table),
              0,
              'uncommitted row is invisible',
            );
            return Ok(());
          }),
          'commit',
        );
        Check.equals(await _count(other, table), 1, 'visible after commit');
        await other.close();
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'a failed write makes the transaction rollback-only',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 1);

        final result = await db.transaction<()>((tx) async {
          Check.ok(
            await people.insert(JsonTable.rows([_People.row(5)])).execute(tx),
            'first insert',
          );
          Check.fails(
            await people.insert(JsonTable.rows([_People.row(0)])).execute(tx),
            DbErrorCode.duplicateKey,
            'duplicate insert',
          );
          Check.fails(
            await people.all().count(tx),
            DbErrorCode.transactionAborted,
            'any statement after the failure',
          );
          // The failure is ignored on purpose: the commit must still refuse.
          return Ok(());
        });

        Check.fails(result, DbErrorCode.transactionAborted, 'commit');
        Check.equals(await _count(db, people), 1, 'nothing was committed');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'a savepoint rolls back only its own writes',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);
        final id = table.field<String>('id');

        Check.ok(
          await db.transaction<()>((tx) async {
            Check.ok(
              await table.insert(JsonTable.rows([_People.row(1)])).execute(tx),
              'outer insert',
            );
            Check.fails(
              await tx.savepoint<()>((sp) async {
                Check.ok(
                  await table
                      .insert(JsonTable.rows([_People.row(2)]))
                      .execute(sp),
                  'inner insert',
                );
                return Err(DbError(DbErrorCode.invalidRequest, 'undo'));
              }),
              DbErrorCode.invalidRequest,
              'savepoint answering Err',
            );
            Check.ok(
              await tx.savepoint(
                (sp) =>
                    table.insert(JsonTable.rows([_People.row(3)])).execute(sp),
              ),
              'savepoint answering Ok',
            );
            return Ok(());
          }),
          'commit',
        );

        Check.equals(
          _People.loadedIds(
            Check.ok(await table.all().order(id.asc()).load(db), 'load'),
          ),
          ['p001', 'p003'],
          'rows kept',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'a failure ignored inside a savepoint fails the savepoint, not the '
          'transaction',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 1);

        Check.ok(
          await db.transaction<()>((tx) async {
            Check.fails(
              await tx.savepoint<()>((sp) async {
                Check.ok(
                  await people
                      .insert(JsonTable.rows([_People.row(7)]))
                      .execute(sp),
                  'insert',
                );
                Check.fails(
                  await people
                      .insert(JsonTable.rows([_People.row(0)]))
                      .execute(sp),
                  DbErrorCode.duplicateKey,
                  'duplicate',
                );
                return Ok(());
              }),
              DbErrorCode.transactionAborted,
              'savepoint with an ignored failure',
            );
            Check.ok(
              await people.insert(JsonTable.rows([_People.row(8)])).execute(tx),
              'the transaction goes on',
            );
            return Ok(());
          }),
          'commit',
        );

        Check.equals(await _count(db, people), 2, 'p000 and p008 only');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'using the database inside its own transaction is rejected',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);

        final result = await db.transaction<DbError>(
          (tx) async => Ok(
            Check.fails(
              await table.all().count(db),
              DbErrorCode.transactionReentrancy,
              'the database inside its transaction',
            ),
          ),
        );

        Check.ok(result, 'the transaction itself is fine');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'an exception in the body rolls back and propagates',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);
        Object? caught;

        try {
          await db.transaction<()>((tx) async {
            await table.insert(JsonTable.rows([_People.row(1)])).execute(tx);
            throw StateError('bug');
          });
        } on StateError catch (error) {
          caught = error;
        }

        Check.isTrue(caught is StateError, 'the exception propagates');
        Check.equals(await _count(db, table), 0, 'the insert was undone');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'writes from outside wait for the running transaction',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);
        final events = <String>[];
        final release = Completer<void>();

        final transaction = db.transaction<()>((tx) async {
          Check.ok(
            await table.insert(JsonTable.rows([_People.row(1)])).execute(tx),
            'insert in tx',
          );
          events.add('tx wrote');
          await release.future;
          events.add('tx ends');
          return Ok(());
        });

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final outside = table
            .insert(JsonTable.rows([_People.row(2)]))
            .execute(db)
            .then((result) {
              Check.ok(result, 'outside insert');
              events.add('outside wrote');
            });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        release.complete();
        await Future.wait([transaction, outside]);

        Check.equals(events, [
          'tx wrote',
          'tx ends',
          'outside wrote',
        ], 'order of events');
        Check.equals(await _count(db, table), 2, 'both rows');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'a read transaction is a snapshot and refuses writes',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 2);

        final result = await db.readTransaction<()>((snapshot) async {
          Check.ok(
            await people.insert(JsonTable.rows([_People.row(9)])).execute(db),
            'insert outside the snapshot',
          );
          Check.equals(
            await _count(snapshot, people),
            2,
            'the snapshot does not see it',
          );
          Check.fails(
            await people
                .insert(JsonTable.rows([_People.row(10)]))
                .execute(snapshot),
            DbErrorCode.readOnlyTransaction,
            'write in a read transaction',
          );
          return Ok(());
        });

        Check.ok(result, 'read transaction');
        Check.equals(await _count(db, people), 3, 'the outside insert stays');
        await db.close();
      },
    ),
    ConformanceCase(
      'transactions',
      'an idle transaction expires and frees the writer',
      (host) async {
        final table = _People.table();
        final db = await host.open([table]);
        Transaction? leaked;

        final result = await db.transaction<int>((tx) async {
          leaked = tx;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return table.all().count(tx);
        }, idleTimeout: const Duration(milliseconds: 100));

        Check.fails(result, DbErrorCode.transactionExpired, 'expired');
        Check.ok(
          await table.insert(JsonTable.rows([_People.row(1)])).execute(db),
          'the writer is free again',
        );
        Check.fails(
          await table.all().count(leaked!),
          DbErrorCode.transactionClosed,
          'the ended transaction',
        );
        await db.close();
      },
    ),
  ];
}
