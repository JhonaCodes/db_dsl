part of '../conformance.dart';

/// Tables and the database itself: definitions, indexes, persistence,
/// change notifications, info, closing.
abstract final class _SchemaCases {
  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'schema',
      'defining a table again changes nothing; indexes can be added and removed',
      (host) async {
        final path = await host.freshPath();
        final plain = JsonTable('items');
        final db = await host.reopen(path, [plain]);

        Check.equals(
          Check.ok(await db.defineTable(plain), 'define again'),
          false,
          'the same definition changes nothing',
        );
        Check.ok(
          await plain
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'code': 'x'},
                  {'id': 'b', 'code': 'y'},
                ]),
              )
              .execute(db),
          'insert',
        );

        final indexed = JsonTable(
          'items',
          uniqueIndexes: [
            ['code'],
          ],
        );
        Check.equals(
          Check.ok(await db.defineTable(indexed), 'add an index'),
          true,
          'adding an index is a change',
        );
        Check.fails(
          await indexed
              .insert(
                JsonTable.rows([
                  {'id': 'c', 'code': 'x'},
                ]),
              )
              .execute(db),
          DbErrorCode.uniqueViolation,
          'the new index covers the existing rows',
        );
        Check.equals(
          [
            for (final schema in Check.ok(await db.tables(), 'tables'))
              if (schema.name == 'items') schema.indexes.length,
          ],
          [1],
          'the index is listed',
        );
        Check.equals(
          Check.ok(await db.defineTable(plain), 'remove the index'),
          true,
          'removing an index is a change',
        );
        Check.ok(
          await plain
              .insert(
                JsonTable.rows([
                  {'id': 'c', 'code': 'x'},
                ]),
              )
              .execute(db),
          'duplicates allowed again',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'schema',
      'a unique index cannot be added over duplicated rows',
      (host) async {
        final plain = JsonTable('items');
        final db = await host.open([plain]);

        Check.ok(
          await plain
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'code': 'x'},
                  {'id': 'b', 'code': 'x'},
                ]),
              )
              .execute(db),
          'insert duplicates',
        );
        Check.fails(
          await db.defineTable(
            JsonTable(
              'items',
              uniqueIndexes: [
                ['code'],
              ],
            ),
          ),
          DbErrorCode.uniqueViolation,
          'unique index over duplicates',
        );
        await db.close();
      },
    ),
    ConformanceCase('schema', 'the primary key of a table cannot change', (
      host,
    ) async {
      final db = await host.open([JsonTable('items')]);

      Check.fails(
        await db.defineTable(JsonTable('items', key: 'code')),
        DbErrorCode.schemaMismatch,
        'another primary key',
      );
      await db.close();
    }),
    ConformanceCase('schema', 'invalid definitions are rejected', (host) async {
      final db = await host.open(const []);

      for (final (what, table) in [
        ('a name starting with __', JsonTable('__items')),
        ('a name with :', JsonTable('a:b')),
        ('an empty primary key', JsonTable('items', key: '')),
        (
          'an index defined twice',
          JsonTable(
            'items',
            indexes: [
              ['code'],
              ['code'],
            ],
          ),
        ),
      ]) {
        Check.fails(
          await db.defineTable(table),
          DbErrorCode.invalidSchema,
          what,
        );
      }

      await db.close();
    }),
    ConformanceCase('schema', 'dropping a table removes it and its rows', (
      host,
    ) async {
      final (db, people, _) = await _People.seeded(host, 3);

      Check.equals(
        Check.ok(await db.dropTable('people'), 'drop'),
        true,
        'the table existed',
      );
      Check.fails(
        await people.all().count(db),
        DbErrorCode.tableNotFound,
        'statement on the dropped table',
      );
      Check.equals(
        Check.ok(await db.dropTable('people'), 'drop again'),
        false,
        'dropping a missing table',
      );
      await db.close();
    }),
    ConformanceCase('schema', 'data survives closing and reopening', (
      host,
    ) async {
      final path = await host.freshPath();
      final people = _People.table();
      final first = await host.reopen(path, [people]);

      Check.ok(
        await people.insert(JsonTable.rows(_People.rows(4))).execute(first),
        'insert',
      );
      Check.ok(await first.close(), 'close');
      Check.fails(
        await people.all().count(first),
        DbErrorCode.closed,
        'a closed database',
      );

      final second = await host.reopen(path, [people]);
      Check.equals(
        Check.ok(await people.all().count(second), 'count'),
        4,
        'rows after reopening',
      );
      await second.close();
    }),
    ConformanceCase(
      'reactivity',
      'watch emits the rows now and after each commit to its table',
      (host) async {
        final people = _People.table();
        final other = JsonTable('other');
        final db = await host.open([people, other]);
        final id = people.field<String>('id');
        final updates = <List<String>>[];

        final subscription = people
            .all()
            .order(id.asc())
            .watch(db)
            .listen(
              (rows) => updates.add(_People.loadedIds(Check.ok(rows, 'rows'))),
            );
        Future<void> settle() =>
            Future<void>.delayed(const Duration(milliseconds: 100));

        await settle();
        Check.ok(
          await people.insert(JsonTable.rows([_People.row(1)])).execute(db),
          'insert',
        );
        await settle();
        Check.ok(
          await other
              .insert(
                JsonTable.rows([
                  {'id': 'x'},
                ]),
              )
              .execute(db),
          'write to another table',
        );
        await settle();
        Check.ok(
          await db.transaction<int>(
            (tx) => people.insert(JsonTable.rows([_People.row(2)])).execute(tx),
          ),
          'transaction',
        );
        await settle();
        await subscription.cancel();

        Check.equals(updates, [
          <String>[],
          ['p001'],
          ['p001', 'p002'],
        ], 'emissions');
        await db.close();
      },
    ),
    ConformanceCase('info', 'info reports the protocol and the tables', (
      host,
    ) async {
      final db = await host.open([_People.table(), JsonTable('other')]);
      final info = Check.ok(await db.info(), 'info');

      Check.equals(info.protocol, 1, 'protocol version');
      Check.equals(info.tables, 2, 'tables');
      Check.isTrue(info.storage.isNotEmpty, 'the storage names itself');
      await db.close();
    }),
    ConformanceCase('schema', 'statements on an undefined table fail', (
      host,
    ) async {
      final db = await host.open(const []);

      Check.fails(
        await JsonTable('ghost').all().load(db),
        DbErrorCode.tableNotFound,
        'select',
      );
      Check.fails(
        await JsonTable('ghost')
            .insert([
              const JsonRow({'id': 'a'}),
            ])
            .execute(db),
        DbErrorCode.tableNotFound,
        'insert',
      );
      await db.close();
    }),
  ];
}
