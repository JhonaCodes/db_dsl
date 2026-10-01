part of '../conformance.dart';

/// Diesel's relational powers: projections, distinct, group by, joins,
/// associations and counters.
abstract final class _RelationalCases {
  /// Authors, posts and comments with some rows on purpose: an author
  /// without posts, a post without comments, a post whose author is missing,
  /// and a post without author.
  static Future<(Database, JsonTable, JsonTable, JsonTable)> _blog(
    ConformanceHost host, {
    bool indexed = true,
  }) async {
    final authors = JsonTable('authors');
    final posts = JsonTable(
      'posts',
      indexes: [
        if (indexed) ['author_id'],
      ],
    );
    final comments = JsonTable('comments');
    final db = await host.open([authors, posts, comments]);

    Check.ok(
      await authors
          .insert(
            JsonTable.rows([
              {'id': 'a1', 'name': 'Ada', 'city': 'Lima'},
              {'id': 'a2', 'name': 'Grace', 'city': 'Bogotá'},
              {'id': 'a3', 'name': 'Linus', 'city': 'Lima'},
            ]),
          )
          .execute(db),
      'authors',
    );
    Check.ok(
      await posts
          .insert(
            JsonTable.rows([
              {'id': 'p1', 'author_id': 'a1', 'title': 'Types', 'likes': 5},
              {'id': 'p2', 'author_id': 'a1', 'title': 'Joins', 'likes': 9},
              {'id': 'p3', 'author_id': 'a2', 'title': 'COBOL', 'likes': 7},
              {'id': 'p4', 'author_id': 'ghost', 'title': 'Orphan', 'likes': 1},
              {'id': 'p5', 'title': 'Anonymous', 'likes': 2},
            ]),
          )
          .execute(db),
      'posts',
    );
    Check.ok(
      await comments
          .insert(
            JsonTable.rows([
              {'id': 'c1', 'post_id': 'p1', 'text': 'nice'},
              {'id': 'c2', 'post_id': 'p1', 'text': 'more'},
              {'id': 'c3', 'post_id': 'p3', 'text': 'classic'},
            ]),
          )
          .execute(db),
      'comments',
    );

    return (db, authors, posts, comments);
  }

  static List<String?> _ids(List<JoinRow> rows, String table) => [
    for (final row in rows)
      switch (row.json[table]) {
        final Map<String, Object?> stored => stored['id'] as String?,
        _ => null,
      },
  ];

  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'relational',
      'pluck and project keep only the chosen columns, null when missing',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 12);
        final id = people.field<String>('id');
        final city = people.field<String>('city');
        final stars = people.field<int>('meta.stars');
        final nickname = people.field<String>('nickname');

        final cities = Check.ok(
          await people.all().order(id.asc()).pluck(city).load(db),
          'pluck',
        );
        Check.equals(cities, [
          for (final row in data) row['city'],
        ], 'one city per row, in order');

        final projected = Check.ok(
          await people
              .all()
              .order(id.asc())
              .project([id, stars, nickname])
              .load(db),
          'project',
        );
        Check.equals(
          [for (final row in projected) row.json],
          [
            for (final row in data)
              {
                'id': row['id'],
                'meta': {'stars': (row['meta']! as Map)['stars']},
                'nickname': row['nickname'],
              },
          ],
          'projected rows',
        );
        Check.equals(
          Check.ok(projected.first.get(stars), 'typed read'),
          0,
          'a projected value read through its column',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'order applies to the stored rows before projection and distinct',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 16);
        final city = people.field<String>('city');
        final age = people.field<int>('age');

        final byAge = Check.ok(
          await people.all().order(age.desc()).pluck(city).load(db),
          'pluck ordered by a column not projected',
        );
        final sorted = [...data]
          ..sort((a, b) => (b['age']! as int).compareTo(a['age']! as int));
        Check.equals(byAge, [for (final row in sorted) row['city']], 'cities');

        final distinct = Check.ok(
          await people.all().order(age.desc()).pluck(city).distinct().load(db),
          'distinct',
        );
        final expected = <Object?>[];
        for (final row in sorted) {
          if (!expected.contains(row['city'])) {
            expected.add(row['city']);
          }
        }
        Check.equals(distinct, expected, 'first occurrence of each city');
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'distinct compares values like keys: 1 equals 1.0',
      (host) async {
        final table = JsonTable('numbers');
        final db = await host.open([table]);
        final v = table.field<double>('v');

        Check.ok(
          await table
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'v': 1},
                  {'id': 'b', 'v': 1.0},
                  {'id': 'c', 'v': 2.5},
                ]),
              )
              .execute(db),
          'insert',
        );
        final values = Check.ok(
          await table
              .all()
              .order(table.field<String>('id').asc())
              .pluck(v)
              .distinct()
              .load(db),
          'distinct',
        );
        Check.equals(values, [1.0, 2.5], 'one 1');
        await db.close();
      },
    ),
    ConformanceCase('relational', 'overlapping projected paths are rejected', (
      host,
    ) async {
      final (db, people, _) = await _People.seeded(host, 2);

      Check.fails(
        await people
            .all()
            .project([
              people.field<String>('meta'),
              people.field<int>('meta.stars'),
            ])
            .load(db),
        DbErrorCode.invalidRequest,
        'meta and meta.stars',
      );
      await db.close();
    }),
    ConformanceCase(
      'relational',
      'group by computes every aggregate per group, in key order',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 30);
        final city = people.field<String>('city');
        final age = people.field<int>('age');
        final score = people.field<double>('score');
        final nickname = people.field<String>('nickname');

        final groups = Check.ok(
          await people
              .groupBy([city])
              .count('people')
              .countOf(nickname, 'nicknamed')
              .sum(age, 'total_age')
              .avg(score, 'avg_score')
              .min(age, 'youngest')
              .max(age, 'oldest')
              .load(db),
          'group',
        );

        final cities = {for (final row in data) row['city']! as String}.toList()
          ..sort();
        Check.equals(
          [for (final group in groups) group.json],
          [
            for (final name in cities)
              () {
                final members = data.where((row) => row['city'] == name);
                final ages = [for (final row in members) row['age']! as int];
                final scores = [
                  for (final row in members) row['score']! as double,
                ];
                return {
                  'city': name,
                  'people': members.length,
                  'nicknamed': members
                      .where((row) => row['nickname'] != null)
                      .length,
                  'total_age': ages.reduce((a, b) => a + b),
                  'avg_score': scores.reduce((a, b) => a + b) / scores.length,
                  'youngest': ages.reduce((a, b) => a < b ? a : b),
                  'oldest': ages.reduce((a, b) => a > b ? a : b),
                };
              }(),
          ],
          'group rows',
        );
        Check.equals(
          Check.ok(groups.first.key(city), 'key'),
          cities.first,
          'typed key',
        );
        Check.equals(
          Check.ok(groups.first.count('people'), 'count'),
          data.where((row) => row['city'] == cities.first).length,
          'typed count',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'having, order and limit apply to the group rows',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 23);
        final city = people.field<String>('city');
        const people_ = Field<int>('people');

        final counts = <String, int>{};
        for (final row in data) {
          counts.update(
            row['city']! as String,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
        }
        final expected =
            counts.entries.where((entry) => entry.value >= 6).toList()..sort(
              (a, b) => switch (b.value.compareTo(a.value)) {
                0 => a.key.compareTo(b.key),
                final order => order,
              },
            );
        Check.isTrue(
          expected.length < counts.length,
          'the data leaves a group out',
        );

        final query = people
            .groupBy([city])
            .count('people')
            .having(people_.ge(6))
            .order(people_.desc())
            .thenOrderBy(city.asc());
        final all = Check.ok(await query.load(db), 'having and order');
        Check.equals(
          [for (final group in all) group.json],
          [
            for (final entry in expected)
              {'city': entry.key, 'people': entry.value},
          ],
          'groups kept by having, sorted',
        );

        final page = Check.ok(
          await query.offset(1).limit(1).load(db),
          'offset and limit',
        );
        Check.equals(
          [for (final group in page) group.json],
          [
            {'city': expected[1].key, 'people': expected[1].value},
          ],
          'the second group only',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'null is a group, and no key gives one group even without rows',
      (host) async {
        final (db, people, data) = await _People.seeded(host, 20);
        final nickname = people.field<String>('nickname');
        final age = people.field<int>('age');

        final byNickname = Check.ok(
          await people.groupBy([nickname]).count('n').load(db),
          'group by a nullable column',
        );
        Check.equals([for (final group in byNickname) group.json].first, {
          'nickname': null,
          'n': data.where((r) => r['nickname'] == null).length,
        }, 'the null group sorts first');

        final none = Check.ok(
          await people
              .filter(age.gt(1000))
              .groupBy(const [])
              .count('n')
              .sum(age, 'total')
              .load(db),
          'no key, no rows',
        );
        Check.equals(
          [for (final group in none) group.json],
          [
            {'n': 0, 'total': null},
          ],
          'one empty group',
        );
        Check.equals(
          Check.ok(
            await people
                .filter(age.gt(1000))
                .groupBy([nickname])
                .count('n')
                .load(db),
            'key, no rows',
          ).length,
          0,
          'no groups',
        );
        await db.close();
      },
    ),
    ConformanceCase('relational', 'invalid aggregates are rejected', (
      host,
    ) async {
      final (db, people, _) = await _People.seeded(host, 2);
      final city = people.field<String>('city');

      for (final (what, query) in [
        ('a repeated alias', people.groupBy([city]).count('n').count('n')),
        ('an alias with a dot', people.groupBy([city]).count('a.b')),
        ('an alias equal to a key', people.groupBy([city]).count('city')),
      ]) {
        Check.fails(await query.load(db), DbErrorCode.invalidRequest, what);
      }

      await db.close();
    }),
    ConformanceCase(
      'relational',
      'inner join keeps one row per match; left join keeps rows without one',
      (host) async {
        for (final indexed in [true, false]) {
          final (db, authors, posts, _) = await _blog(host, indexed: indexed);
          final id = authors.field<String>('id');
          final authorId = posts.field<String>('author_id');
          final postId = posts.field<String>('id');
          final label = indexed ? 'indexed' : 'not indexed';

          final inner = Check.ok(
            await authors
                .innerJoin(posts, on: id, equals: authorId)
                .order(postId.asc())
                .load(db),
            'inner $label',
          );
          Check.equals(_ids(inner, 'authors'), ['a1', 'a1', 'a2'], 'authors');
          Check.equals(_ids(inner, 'posts'), ['p1', 'p2', 'p3'], 'posts');

          final left = Check.ok(
            await authors.leftJoin(posts, on: id, equals: authorId).load(db),
            'left $label',
          );
          Check.equals(_ids(left, 'authors'), [
            'a1',
            'a1',
            'a2',
            'a3',
          ], 'every author, in key order');
          Check.equals(_ids(left, 'posts'), [
            'p1',
            'p2',
            'p3',
            null,
          ], 'no post for a3');
          Check.equals(
            Check.ok(left.last.maybe(posts), 'maybe'),
            null,
            'left join without match reads as null',
          );
          await db.close();
        }
      },
    ),
    ConformanceCase('relational', 'a missing or null key never matches', (
      host,
    ) async {
      final (db, authors, posts, _) = await _blog(host);

      final fromPosts = Check.ok(
        await posts
            .leftJoin(
              authors,
              on: posts.field<String>('author_id'),
              equals: authors.field<String>('id'),
            )
            .order(posts.field<String>('id').asc())
            .load(db),
        'posts to authors',
      );
      Check.equals(_ids(fromPosts, 'authors'), [
        'a1',
        'a1',
        'a2',
        null,
        null,
      ], 'ghost and missing author do not match');
      await db.close();
    }),
    ConformanceCase(
      'relational',
      'joins chain, and filter and order use any joined table',
      (host) async {
        final (db, authors, posts, comments) = await _blog(host);

        final rows = Check.ok(
          await authors
              .innerJoin(
                posts,
                on: authors.field<String>('id'),
                equals: posts.field<String>('author_id'),
              )
              .leftJoin(
                comments,
                on: posts.field<String>('id'),
                equals: comments.field<String>('post_id'),
              )
              .filter(
                authors
                    .field<String>('city')
                    .eq('Lima')
                    .and(posts.field<int>('likes').ge(5)),
              )
              .order(posts.field<int>('likes').desc())
              .thenOrderBy(comments.field<String>('id').asc())
              .load(db),
          'three tables',
        );

        Check.equals(_ids(rows, 'posts'), ['p2', 'p1', 'p1'], 'posts');
        Check.equals(_ids(rows, 'comments'), [null, 'c1', 'c2'], 'comments');
        Check.equals(
          Check.ok(rows[1].of(authors), 'of').json['name'],
          'Ada',
          'typed author',
        );
        await db.close();
      },
    ),
    ConformanceCase('relational', 'joining an undefined table fails', (
      host,
    ) async {
      final (db, authors, _, _) = await _blog(host);
      final ghost = JsonTable('ghost');

      Check.fails(
        await authors
            .innerJoin(
              ghost,
              on: authors.field<String>('id'),
              equals: ghost.field<String>('id'),
            )
            .load(db),
        DbErrorCode.tableNotFound,
        'join with ghost',
      );
      await db.close();
    }),
    ConformanceCase(
      'relational',
      'belongingTo loads the children of some parents; groupedBy attaches them',
      (host) async {
        final (db, authors, posts, _) = await _blog(host);
        final lima = Check.ok(
          await authors
              .filter(authors.field<String>('city').eq('Lima'))
              .order(authors.field<String>('id').asc())
              .load(db),
          'parents',
        );
        final children = Check.ok(
          await posts
              .belongingTo([
                for (final author in lima) author.json['id']! as String,
              ], posts.field<String>('author_id'))
              .order(posts.field<String>('id').asc())
              .load(db),
          'children',
        );

        final grouped = Associations.groupedBy(
          lima,
          children,
          parentKey: (author) => author.json['id']! as String,
          childKey: (post) => post.json['author_id'] as String?,
        );
        Check.equals(
          [
            for (final (author, owned) in grouped)
              [author.json['id'], for (final post in owned) post.json['id']],
          ],
          [
            ['a1', 'p1', 'p2'],
            ['a3'],
          ],
          'posts under their authors',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'increment counts from zero and keeps integers',
      (host) async {
        final table = JsonTable('pages');
        final db = await host.open([table]);
        final id = table.field<String>('id');
        final views = table.field<int>('views');
        final score = table.field<double>('score');

        Check.ok(
          await table
              .insert(
                JsonTable.rows([
                  {'id': 'home'},
                  {'id': 'about', 'views': 10, 'score': 1.5},
                ]),
              )
              .execute(db),
          'insert',
        );
        for (var i = 0; i < 3; i++) {
          Check.ok(
            await table.update().increment(views, 1).execute(db),
            'increment $i',
          );
        }
        Check.ok(
          await table
              .update()
              .filter(id.eq('about'))
              .increment(score, 0.25)
              .execute(db),
          'increment a double',
        );

        final pages = Check.ok(
          await table.all().order(id.asc()).load(db),
          'load',
        );
        Check.equals(
          [for (final page in pages) page.json],
          [
            {'id': 'about', 'views': 13, 'score': 1.75},
            {'id': 'home', 'views': 3},
          ],
          'counters',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'increment refuses non-numbers, the key and set on the same field',
      (host) async {
        final table = JsonTable('pages');
        final db = await host.open([table]);
        final views = table.field<int>('views');

        Check.ok(
          await table
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'views': 1},
                  {'id': 'b', 'views': 'many'},
                ]),
              )
              .execute(db),
          'insert',
        );

        Check.fails(
          await table.update().increment(views, 1).execute(db),
          DbErrorCode.invalidRequest,
          'a text counter',
        );
        Check.fails(
          await table.update().set(views, 0).increment(views, 1).execute(db),
          DbErrorCode.invalidRequest,
          'set and increment on one field',
        );
        Check.fails(
          await table.update().increment(table.field<int>('id'), 1).execute(db),
          DbErrorCode.invalidRequest,
          'the primary key',
        );
        Check.equals(
          Check.ok(await table.find('a').first(db), 'find')?.json['views'],
          1,
          'nothing was written',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'increment past the largest 64-bit integer fails',
      (host) async {
        // On the web `int` is a JavaScript number: there is no 64-bit
        // overflow to detect.
        if (!ConformancePlatform.hasInt64) {
          return;
        }

        final table = JsonTable('pages');
        final db = await host.open([table]);
        final views = table.field<int>('views');
        final largest = ConformancePlatform.maxInt64;

        Check.ok(
          await table
              .insert(
                JsonTable.rows([
                  {'id': 'c', 'views': largest},
                ]),
              )
              .execute(db),
          'insert',
        );
        Check.fails(
          await table.update().increment(views, 1).execute(db),
          DbErrorCode.invalidRequest,
          'past the largest integer',
        );
        Check.equals(
          Check.ok(await table.find('c').first(db), 'find')?.json['views'],
          largest,
          'nothing was written',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'relational',
      'increment to a number JSON cannot hold fails',
      (host) async {
        final table = JsonTable('pages');
        final db = await host.open([table]);
        final score = table.field<double>('score');

        Check.ok(
          await table
              .insert(
                JsonTable.rows([
                  {'id': 'a', 'score': 1e308},
                ]),
              )
              .execute(db),
          'insert',
        );
        Check.fails(
          await table.update().increment(score, 1e308).execute(db),
          DbErrorCode.invalidRequest,
          'past the largest double',
        );
        Check.equals(
          Check.ok(await table.find('a').first(db), 'find')?.json['score'],
          1e308,
          'nothing was written',
        );
        await db.close();
      },
    ),
    ConformanceCase('relational', 'exists tells whether any row matches', (
      host,
    ) async {
      final (db, people, _) = await _People.seeded(host, 3);
      final age = people.field<int>('age');

      Check.equals(
        Check.ok(await people.filter(age.eq(19)).exists(db), 'exists'),
        true,
        'a match',
      );
      Check.equals(
        Check.ok(await people.filter(age.eq(99)).exists(db), 'exists'),
        false,
        'no match',
      );
      await db.close();
    }),
  ];
}
