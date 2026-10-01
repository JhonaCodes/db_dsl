part of '../conformance.dart';

/// Reads: lookups, filters, order, pagination, counts and aggregates.
abstract final class _QueryCases {
  static List<ConformanceCase> get cases => [
    ConformanceCase('queries', 'find answers the row by primary key, or null', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 5);

      Check.equals(
        Check.ok(await people.find('p003').first(db), 'find p003'),
        JsonRow(data[3]),
        'find p003',
      );
      Check.equals(
        Check.ok(await people.find('missing').first(db), 'find missing'),
        null,
        'find missing',
      );
      await db.close();
    }),
    ConformanceCase('queries', 'filter, order and limit select and sort rows', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 40);
      final city = people.field<String>('city');
      final active = people.field<bool>('active');
      final age = people.field<int>('age');
      final id = people.field<String>('id');

      final expected =
          data
              .where((row) => row['city'] == 'Lima' && row['active'] == true)
              .toList()
            ..sort(
              (a, b) =>
                  switch ((b['age']! as int).compareTo(a['age']! as int)) {
                    0 => (a['id']! as String).compareTo(b['id']! as String),
                    final order => order,
                  },
            );

      final loaded = Check.ok(
        await people
            .filter(city.eq('Lima').and(active.eq(true)))
            .order(age.desc())
            .thenOrderBy(id.asc())
            .limit(3)
            .load(db),
        'load',
      );

      Check.equals(
        _People.loadedIds(loaded),
        _People.ids(expected.take(3)),
        'top 3',
      );
      await db.close();
    }),
    ConformanceCase('queries', 'every operator matches its definition', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 60);
      final age = people.field<int>('age');
      final city = people.field<String>('city');
      final name = people.field<String>('name');
      final nickname = people.field<String>('nickname');
      final active = people.field<bool>('active');

      int ageOf(Map<String, Object?> row) => row['age']! as int;

      final cases = <String, (Expression, bool Function(Map<String, Object?>))>{
        'eq': (age.eq(30), (row) => ageOf(row) == 30),
        'ne': (age.ne(30), (row) => ageOf(row) != 30),
        'gt': (age.gt(40), (row) => ageOf(row) > 40),
        'ge': (age.ge(40), (row) => ageOf(row) >= 40),
        'lt': (age.lt(25), (row) => ageOf(row) < 25),
        'le': (age.le(25), (row) => ageOf(row) <= 25),
        'between': (
          age.between(20, 30),
          (row) => ageOf(row) >= 20 && ageOf(row) <= 30,
        ),
        'notBetween': (
          age.notBetween(20, 30),
          (row) => ageOf(row) < 20 || ageOf(row) > 30,
        ),
        'eqAny': (
          city.eqAny(['Lima', 'Madrid']),
          (row) => row['city'] == 'Lima' || row['city'] == 'Madrid',
        ),
        'eqAny empty': (city.eqAny(const []), (_) => false),
        'neAll': (
          city.neAll(['Lima', 'Madrid']),
          (row) => row['city'] != 'Lima' && row['city'] != 'Madrid',
        ),
        'isNull (null or missing)': (
          nickname.isNull(),
          (row) => row['nickname'] == null,
        ),
        'isNotNull': (nickname.isNotNull(), (row) => row['nickname'] != null),
        'like': (
          name.like('name-1%'),
          (row) => (row['name']! as String).startsWith('name-1'),
        ),
        'ilike': (
          name.ilike('NAME-2_'),
          (row) => RegExp(r'^name-2.$').hasMatch(row['name']! as String),
        ),
        'and': (
          city.eq('Lima').and(age.gt(30)),
          (row) => row['city'] == 'Lima' && ageOf(row) > 30,
        ),
        'or': (
          city.eq('Lima').or(age.gt(60)),
          (row) => row['city'] == 'Lima' || ageOf(row) > 60,
        ),
        'not': (active.eq(true).not(), (row) => row['active'] != true),
        'comparison on a null field': (
          nickname.eq('nick-3'),
          (row) => row['nickname'] == 'nick-3',
        ),
      };

      for (final MapEntry(key: operator, value: (expression, keep))
          in cases.entries) {
        final loaded = Check.ok(
          await people.filter(expression).load(db),
          operator,
        );
        final expected = _People.ids(data.where(keep))..sort();

        Check.equals(
          _People.loadedIds(loaded)..sort(),
          expected,
          'rows of $operator',
        );
        Check.equals(
          Check.ok(await people.filter(expression).count(db), operator),
          expected.length,
          'count of $operator',
        );
      }

      await db.close();
    }),
    ConformanceCase('queries', 'offset and limit page an ordered query', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 23);
      final id = people.field<String>('id');
      final pages = <String>[];

      for (var page = 0; page < 5; page++) {
        final rows = Check.ok(
          await people.all().order(id.asc()).limit(5).offset(page * 5).load(db),
          'page $page',
        );
        pages.addAll(_People.loadedIds(rows));
      }

      Check.equals(pages, _People.ids(data), 'every row once, in order');
      await db.close();
    }),
    ConformanceCase('queries', 'count ignores limit and offset', (host) async {
      final (db, people, _) = await _People.seeded(host, 12);

      Check.equals(
        Check.ok(await people.all().limit(2).offset(3).count(db), 'count'),
        12,
        'count',
      );
      await db.close();
    }),
    ConformanceCase('queries', 'aggregates follow their definition', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 30);
      final age = people.field<int>('age');
      final score = people.field<double>('score');
      final city = people.field<String>('city');
      final ages = [for (final row in data) row['age']! as int];
      final scores = [for (final row in data) row['score']! as double];

      Check.equals(
        Check.ok(await people.all().sum(age, db), 'sum'),
        ages.reduce((a, b) => a + b),
        'sum of ages',
      );
      Check.equals(
        Check.ok(await people.all().avg(score, db), 'avg'),
        scores.reduce((a, b) => a + b) / scores.length,
        'average score',
      );
      Check.equals(
        Check.ok(await people.all().min(age, db), 'min'),
        ages.reduce((a, b) => a < b ? a : b),
        'min age',
      );
      Check.equals(
        Check.ok(await people.all().max(city, db), 'max'),
        'Madrid',
        'max city',
      );
      Check.equals(
        Check.ok(await people.filter(age.gt(1000)).sum(age, db), 'empty sum'),
        null,
        'sum of no rows',
      );
      Check.equals(
        Check.ok(await people.filter(age.gt(1000)).max(age, db), 'empty max'),
        null,
        'max of no rows',
      );
      await db.close();
    }),
    ConformanceCase('queries', 'dotted paths reach nested fields', (
      host,
    ) async {
      final (db, people, data) = await _People.seeded(host, 21);
      final stars = people.field<int>('meta.stars');

      final loaded = Check.ok(
        await people.filter(stars.eq(3)).load(db),
        'nested filter',
      );

      Check.equals(
        _People.loadedIds(loaded)..sort(),
        _People.ids(data.where((row) => (row['meta']! as Map)['stars'] == 3))
          ..sort(),
        'rows with meta.stars = 3',
      );
      await db.close();
    }),
  ];
}
