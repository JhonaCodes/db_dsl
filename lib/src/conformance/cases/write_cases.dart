part of '../conformance.dart';

/// Writes and the rules of the data: affected rows, keys, constraints.
abstract final class _WriteCases {
  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'writes',
      'insert, update and delete answer the affected rows',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 9);
        final city = people.field<String>('city');
        final age = people.field<int>('age');

        Check.equals(
          Check.ok(
            await people
                .update()
                .filter(city.eq('Lima'))
                .set(age, 99)
                .execute(db),
            'update',
          ),
          2,
          'updated rows',
        );
        Check.equals(
          Check.ok(await people.filter(age.eq(99)).count(db), 'count'),
          2,
          'rows with the new value',
        );
        Check.equals(
          Check.ok(
            await people.delete().filter(city.eq('Bogotá')).execute(db),
            'delete',
          ),
          3,
          'deleted rows',
        );
        Check.equals(
          Check.ok(await people.all().count(db), 'count'),
          6,
          'rows left',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'writes',
      'expectAffectedRows fails and writes nothing when it does not hold',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 8);
        final city = people.field<String>('city');
        final age = people.field<int>('age');

        Check.fails(
          await people
              .update()
              .filter(city.eq('Lima'))
              .set(age, 0)
              .expectAffectedRows(1)
              .execute(db),
          DbErrorCode.affectedRowsMismatch,
          'update expecting 1 of 2',
        );
        Check.fails(
          await people
              .delete()
              .filter(city.eq('Lima'))
              .expectAffectedRows(3)
              .execute(db),
          DbErrorCode.affectedRowsMismatch,
          'delete expecting 3 of 2',
        );
        Check.equals(
          Check.ok(await people.filter(age.eq(0)).count(db), 'count'),
          0,
          'no row was updated',
        );
        Check.equals(
          Check.ok(await people.all().count(db), 'count'),
          8,
          'no row was deleted',
        );
        Check.equals(
          Check.ok(
            await people
                .delete()
                .filter(city.eq('Lima'))
                .expectAffectedRows(2)
                .execute(db),
            'delete expecting 2',
          ),
          2,
          'deleted when it holds',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'writes',
      'set on a dotted path creates the objects on the way; setNull stores null',
      (host) async {
        final table = JsonTable('docs');
        final db = await host.open([table]);
        final city = table.field<String>('address.city');
        final title = table.field<String>('title');

        Check.ok(
          await table
              .insert([
                const JsonRow({'id': 'd1', 'title': 't'}),
              ])
              .execute(db),
          'insert',
        );
        Check.ok(
          await table.update().set(city, 'Lima').setNull(title).execute(db),
          'update',
        );
        Check.equals(
          Check.ok(await table.find('d1').first(db), 'find'),
          const JsonRow({
            'id': 'd1',
            'title': null,
            'address': {'city': 'Lima'},
          }),
          'updated document',
        );
        await db.close();
      },
    ),
    ConformanceCase('writes', 'the primary key cannot be updated', (
      host,
    ) async {
      final (db, people, _) = await _People.seeded(host, 2);

      Check.fails(
        await people
            .update()
            .set(people.field<String>('id'), 'other')
            .execute(db),
        DbErrorCode.invalidRequest,
        'update of the primary key',
      );
      await db.close();
    }),
    ConformanceCase(
      'writes',
      'auto-increment keys follow the largest key given so far',
      (host) async {
        final table = JsonTable('tasks', autoIncrementKey: true);
        final db = await host.open([table]);

        final first = Check.ok(
          await table
              .insert([
                const JsonRow({'id': null, 'title': 'a'}),
                const JsonRow({'title': 'b'}),
              ])
              .getResults(db),
          'insert without keys',
        );
        Check.equals(
          [for (final row in first) row.json['id']],
          [1, 2],
          'generated keys',
        );
        Check.ok(
          await table
              .insert([
                const JsonRow({'id': 10, 'title': 'c'}),
              ])
              .execute(db),
          'insert with key 10',
        );
        final next = Check.ok(
          await table
              .insert([
                const JsonRow({'title': 'd'}),
              ])
              .getResults(db),
          'insert after 10',
        );
        Check.equals(next.single.json['id'], 11, 'key after 10');
        await db.close();
      },
    ),
    ConformanceCase('writes', 'an insert is all rows or none', (host) async {
      final (db, people, _) = await _People.seeded(host, 3);

      Check.fails(
        await people
            .insert(
              JsonTable.rows([
                _People.row(10),
                _People.row(11),
                _People.row(1),
              ]),
            )
            .execute(db),
        DbErrorCode.duplicateKey,
        'third row repeats p001',
      );
      Check.equals(
        Check.ok(await people.all().count(db), 'count'),
        3,
        'the first two rows were not kept',
      );
      await db.close();
    }),
    ConformanceCase(
      'writes',
      'on conflict: error by default, ignore keeps, replace overwrites',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 2);
        final changed = JsonRow({...data[0], 'name': 'changed'});

        final error = Check.fails(
          await people.insert([changed]).execute(db),
          DbErrorCode.duplicateKey,
          'plain insert',
        );
        Check.isTrue(
          error is ConstraintError,
          'a duplicate key is a constraint',
        );
        Check.equals(
          Check.ok(
            await people.insert([changed]).onConflictDoNothing().execute(db),
            'ignore',
          ),
          0,
          'ignored rows are not counted',
        );
        Check.equals(
          Check.ok(await people.find('p000').first(db), 'find')?.json['name'],
          'name-0',
          'the row was kept',
        );
        Check.ok(
          await people.insert([changed]).onConflictReplace().execute(db),
          'replace',
        );
        Check.equals(
          Check.ok(await people.find('p000').first(db), 'find')?.json['name'],
          'changed',
          'the row was replaced',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'writes',
      'a unique index rejects duplicates and exempts nulls',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 3);
        final email = people.field<String>('email');

        Check.fails(
          await people
              .insert([
                JsonRow({..._People.row(20), 'email': data[0]['email']}),
              ])
              .execute(db),
          DbErrorCode.uniqueViolation,
          'insert of an existing email',
        );
        Check.fails(
          await people
              .update()
              .filter(people.field<String>('id').eq('p001'))
              .set(email, data[0]['email']! as String)
              .execute(db),
          DbErrorCode.uniqueViolation,
          'update to an existing email',
        );
        Check.ok(
          await people
              .insert([
                JsonRow({..._People.row(21), 'email': null}),
                JsonRow({..._People.row(22), 'email': null}),
              ])
              .execute(db),
          'two rows without email',
        );
        await db.close();
      },
    ),
    ConformanceCase('writes', 'a row without a primary key is rejected', (
      host,
    ) async {
      final table = JsonTable('things');
      final db = await host.open([table]);

      Check.fails(
        await table
            .insert([
              const JsonRow({'name': 'x'}),
            ])
            .execute(db),
        DbErrorCode.missingPrimaryKey,
        'insert without id',
      );
      await db.close();
    }),
    ConformanceCase(
      'writes',
      'an atomic batch commits every statement or none',
      (host) async {
        final (db, people, _) = await _People.seeded(host, 2);
        final id = people.field<String>('id');
        final age = people.field<int>('age');

        Check.fails(
          await db.atomicBatch([
            people.insert(JsonTable.rows([_People.row(5)])),
            people.update().filter(id.eq('p000')).set(age, 77),
            people.insert(JsonTable.rows([_People.row(1)])),
          ]),
          DbErrorCode.duplicateKey,
          'batch whose last insert fails',
        );
        Check.equals(
          Check.ok(await people.all().count(db), 'count'),
          2,
          'the first insert was undone',
        );
        Check.equals(
          Check.ok(await people.filter(age.eq(77)).count(db), 'count'),
          0,
          'the update was undone',
        );
        Check.equals(
          Check.ok(
            await db.atomicBatch([
              people.insert(JsonTable.rows([_People.row(5)])),
              people.update().filter(id.eq('p000')).set(age, 77),
            ]),
            'batch',
          ),
          [1, 1],
          'affected rows per statement',
        );
        await db.close();
      },
    ),
  ];
}
