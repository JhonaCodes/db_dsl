/// The conformance suite of the protocol: the behavior every engine must
/// show, written once and run against [MemoryEngine] and every native
/// engine.
library;

import 'dart:async';

import 'package:result_controller/result_controller.dart';

import '../database/database.dart';
import '../errors/db_error.dart';
import '../query/expression.dart';
import '../query/ordering.dart';
import '../query/queries.dart';
import '../schema/field.dart';
import '../protocol/request.dart';
import '../protocol/sync_records.dart';
import 'conformance_support.dart';
import 'protocol_examples.dart';

part 'cases/query_cases.dart';
part 'cases/value_cases.dart';
part 'cases/write_cases.dart';
part 'cases/transaction_cases.dart';
part 'cases/schema_cases.dart';
part 'cases/relational_cases.dart';
part 'cases/protocol_cases.dart';
part 'cases/sync_cases.dart';

/// One behavior an engine must show.
final class ConformanceCase {
  /// A case named [name] in [group].
  const ConformanceCase(this.group, this.name, this.run);

  /// The area it covers (`queries`, `values`, `writes`, ...).
  final String group;

  /// What it checks, as a sentence.
  final String name;

  /// Runs the case on databases opened by the host; throws
  /// [ConformanceFailure] when the engine misbehaves.
  final Future<void> Function(ConformanceHost host) run;

  @override
  String toString() => '$group: $name';
}

/// Every case of the suite.
///
/// ```dart
/// // In the tests of an engine:
/// final host = ConformanceHost(MyEngine(), () async => freshTempPath());
///
/// for (final ConformanceCase(:group, :name, :run) in Conformance.cases) {
///   test('$group: $name', () => run(host));
/// }
/// ```
///
/// Why it is part of the package: it is the executable form of
/// `PROTOCOL.md`. flutter_local_db and dart_db run it against their native
/// engines, db_dsl against [MemoryEngine], and a third-party translator can
/// run it to prove it speaks the protocol.
abstract final class Conformance {
  /// All cases, grouped by area.
  static List<ConformanceCase> get cases => [
    ..._QueryCases.cases,
    ..._ValueCases.cases,
    ..._WriteCases.cases,
    ..._TransactionCases.cases,
    ..._SchemaCases.cases,
    ..._RelationalCases.cases,
    ..._SyncCases.cases,
    ..._ProtocolCases.cases,
  ];
}

/// The people table and data most cases use.
abstract final class _People {
  static const List<String> cities = ['Bogotá', 'Auckland', 'Lima', 'Madrid'];

  static JsonTable table() => JsonTable(
    'people',
    indexes: [
      ['city', 'age'],
    ],
    uniqueIndexes: [
      ['email'],
    ],
  );

  /// Row [i]: every tenth has no `nickname`, every seventh has a `null` one.
  static Map<String, Object?> row(int i) => {
    'id': 'p${i.toString().padLeft(3, '0')}',
    'name': 'name-$i',
    'email': 'p$i@example.com',
    'city': cities[i % 4],
    'age': 18 + i % 50,
    'score': i / 4,
    'active': i.isEven,
    'meta': {'stars': i % 7},
    if (i % 10 != 0) 'nickname': i % 7 == 0 ? null : 'nick-$i',
  };

  static List<Map<String, Object?>> rows(int count) => [
    for (var i = 0; i < count; i++) row(i),
  ];

  /// A database with [count] people.
  static Future<(Database, JsonTable, List<Map<String, Object?>>)> seeded(
    ConformanceHost host,
    int count,
  ) async {
    final people = table();
    final db = await host.open([people]);
    final data = rows(count);
    Check.ok(
      await people.insert(JsonTable.rows(data)).execute(db),
      'seed $count people',
    );

    return (db, people, data);
  }

  static List<String> ids(Iterable<Map<String, Object?>> rows) => [
    for (final row in rows) row['id']! as String,
  ];

  static List<String> loadedIds(List<JsonRow> rows) => [
    for (final row in rows) row.json['id']! as String,
  ];
}
