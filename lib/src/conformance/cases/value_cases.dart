part of '../conformance.dart';

/// The meaning of values: SQL comparisons, the total order, keys.
abstract final class _ValueCases {
  static JsonTable _values() => JsonTable(
    'values',
    indexes: [
      ['v'],
    ],
  );

  static Future<(Database, JsonTable)> _seed(
    ConformanceHost host,
    Map<String, Object?> valuesById,
  ) async {
    final table = _values();
    final db = await host.open([table]);
    Check.ok(
      await table
          .insert([
            for (final MapEntry(:key, :value) in valuesById.entries)
              JsonRow({'id': key, 'v': value}),
          ])
          .execute(db),
      'seed values',
    );

    return (db, table);
  }

  static Future<List<String>> _ids(
    Database db,
    JsonTable table,
    Expression filter,
  ) async => _People.loadedIds(
    Check.ok(await table.filter(filter).load(db), 'load $filter'),
  )..sort();

  static List<ConformanceCase> get cases => [
    ConformanceCase('values', 'order follows the total order of kinds', (
      host,
    ) async {
      final (db, table) = await _seed(host, {
        'a-object': {'k': 1},
        'b-null': null,
        'c-string': 'text',
        'd-false': false,
        'e-number': -1.5,
        'f-array': [1, 2],
        'g-true': true,
        'h-big-number': 7,
      });

      final ordered = Check.ok(
        await table.all().order(const OrderingTerm('v')).load(db),
        'ordered',
      );

      Check.equals(_People.loadedIds(ordered), [
        'b-null',
        'd-false',
        'g-true',
        'e-number',
        'h-big-number',
        'c-string',
        'f-array',
        'a-object',
      ], 'null < false < true < numbers < strings < arrays < objects');
      await db.close();
    }),
    ConformanceCase('values', 'strings sort by Unicode code point', (
      host,
    ) async {
      final (db, table) = await _seed(host, {
        '1': '😀',
        '2': 'Z',
        '3': '\u{FFFD}',
        '4': 'a',
        '5': 'é',
      });

      final ordered = Check.ok(
        await table
            .all()
            .order(const OrderingTerm('v', descending: true))
            .load(db),
        'ordered',
      );

      // UTF-16 order would put the emoji (a surrogate pair) before U+FFFD.
      Check.equals(
        [for (final row in ordered) row.json['v']],
        ['😀', '\u{FFFD}', 'é', 'a', 'Z'],
        'descending code point order',
      );
      await db.close();
    }),
    ConformanceCase(
      'values',
      'comparisons only match values of the same kind',
      (host) async {
        final (db, table) = await _seed(host, {
          'n0': 0,
          'n2': 2,
          'n3': 3.5,
          's2': '2',
          's9': '9',
          'b': true,
          'nil': null,
        });

        Check.equals(
          await _ids(
            db,
            table,
            const Comparison('v', ComparisonOperator.gt, 1),
          ),
          ['n2', 'n3'],
          'v > 1 (numbers only)',
        );
        Check.equals(
          await _ids(
            db,
            table,
            const Comparison('v', ComparisonOperator.gt, '1'),
          ),
          ['s2', 's9'],
          'v > "1" (strings only)',
        );
        Check.equals(
          await _ids(
            db,
            table,
            const Comparison('v', ComparisonOperator.eq, 2),
          ),
          ['n2'],
          'v = 2 does not match "2"',
        );
        Check.equals(
          await _ids(
            db,
            table,
            const Comparison('v', ComparisonOperator.ne, 2),
          ),
          ['n0', 'n3'],
          'v <> 2 skips other kinds and null',
        );
        await db.close();
      },
    ),
    ConformanceCase(
      'values',
      'not is two-valued: it matches null and missing fields',
      (host) async {
        final (db, table) = await _seed(host, {
          'one': 1,
          'two': 2,
          'nil': null,
          'text': 'x',
        });

        Check.equals(
          await _ids(
            db,
            table,
            const Comparison('v', ComparisonOperator.eq, 1).not(),
          ),
          ['nil', 'text', 'two'],
          'not (v = 1)',
        );
        await db.close();
      },
    ),
    ConformanceCase('values', 'integers and doubles compare by value', (
      host,
    ) async {
      final (db, table) = await _seed(host, {
        'int': 1,
        'double': 1.0,
        'negative-zero': -0.0,
        'zero': 0,
      });

      Check.equals(
        await _ids(db, table, const Comparison('v', ComparisonOperator.eq, 1)),
        ['double', 'int'],
        '1 = 1.0',
      );
      Check.equals(
        await _ids(db, table, const Comparison('v', ComparisonOperator.eq, 0)),
        ['negative-zero', 'zero'],
        '-0.0 = 0',
      );
      Check.equals(
        await _ids(db, table, const Comparison('v', ComparisonOperator.lt, 0)),
        <String>[],
        'nothing is below 0',
      );
      await db.close();
    }),
    ConformanceCase('values', 'like matches whole characters', (host) async {
      final (db, table) = await _seed(host, {
        'accent': 'año',
        'plain': 'ano',
        'long': 'anno',
        'upper': 'AÑO',
      });

      Check.equals(
        await _ids(
          db,
          table,
          const LikePattern('v', 'a_o', caseInsensitive: false),
        ),
        ['accent', 'plain'],
        '_ is one character, ñ included',
      );
      Check.equals(
        await _ids(
          db,
          table,
          const LikePattern('v', 'a%o', caseInsensitive: false),
        ),
        ['accent', 'long', 'plain'],
        '% is any sequence',
      );
      Check.equals(
        await _ids(
          db,
          table,
          const LikePattern('v', 'a_o', caseInsensitive: true),
        ),
        ['accent', 'plain', 'upper'],
        'ilike folds A and O; _ matches Ñ',
      );
      Check.equals(
        await _ids(
          db,
          table,
          const LikePattern('v', 'añ_', caseInsensitive: true),
        ),
        ['accent'],
        'ilike folds ASCII only: Ñ does not match ñ',
      );
      await db.close();
    }),
    ConformanceCase('values', 'integers beyond 2^53 share their key', (
      host,
    ) async {
      const big = 9007199254740992;
      final table = JsonTable('big', key: 'n');
      final db = await host.open([table]);

      Check.ok(
        await table
            .insert([
              const JsonRow({'n': big}),
            ])
            .execute(db),
        'insert 2^53',
      );
      Check.fails(
        await table
            .insert([
              const JsonRow({'n': big + 1}),
            ])
            .execute(db),
        DbErrorCode.duplicateKey,
        '2^53 + 1 rounds to the same f64 key',
      );
      await db.close();
    }),
    ConformanceCase('values', 'keys longer than 511 bytes are rejected', (
      host,
    ) async {
      final table = JsonTable(
        'keys',
        indexes: [
          ['label'],
        ],
      );
      final db = await host.open([table]);
      final long = 'x' * 600;

      Check.fails(
        await table
            .insert([
              JsonRow({'id': long}),
            ])
            .execute(db),
        DbErrorCode.keyTooLarge,
        'primary key of 600 bytes',
      );
      Check.fails(
        await table
            .insert([
              JsonRow({'id': 'ok', 'label': long}),
            ])
            .execute(db),
        DbErrorCode.keyTooLarge,
        'indexed value of 600 bytes',
      );
      Check.equals(
        Check.ok(await table.all().count(db), 'count'),
        0,
        'nothing was written',
      );
      await db.close();
    }),
  ];
}
