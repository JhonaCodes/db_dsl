// test_reflective_loader runs the methods named test_*.
// ignore_for_file: non_constant_identifier_names

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:db_dsl_lints/src/corrections/add_query_fields.dart';
import 'package:db_dsl_lints/src/corrections/field_fixes.dart';
import 'package:db_dsl_lints/src/rules/table_fields_rule.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support/db_dsl_package.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CorrectionsTest);
  });
}

const String _model = r'''
import 'package:db_dsl/db_dsl.dart';

class Address {
  const Address(this.city);
  final String city;
  Map<String, dynamic> toJson() => {'city': city};
}

class Task {
  const Task(this.id, this.done, this.updatedAt, this.createdAt, this.address);
  factory Task.fromJson(Map<String, dynamic> json) => throw 0;

  static final table = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);

  final String id;
  final bool done;
  final DateTime updatedAt;
  final DateTime createdAt;
  final Address? address;

  Map<String, dynamic> toJson() => {
    'id': id,
    'done': done,
    'updated_at': updatedAt.toString(),
    'created_at': createdAt.millisecondsSinceEpoch,
    'address': address,
  };
}''';

/// The extension the assist writes for [_model].
const String _fields = r'''


/// The fields of `Task` for queries, read from its `toJson`.
extension TaskFields on DbTable<Task> {
  /// The stored `id`.
  Field<String> get id => field('id');

  /// The stored `done`.
  Field<bool> get done => field('done');

  /// The stored `updated_at`.
  Field<DateTime> get updatedAt => field('updated_at');

  /// The stored `created_at`.
  Field<DateTime> get createdAt => field('created_at',
    encode: (date) => date.millisecondsSinceEpoch,
    decode: (stored) => DateTime.fromMillisecondsSinceEpoch(stored as int),
  );

  /// The stored `address`.
  Field<Address> get address => field('address');
}''';

/// The assist and the fixes, applied to resolved code: the oracle is the
/// code they produce, which must then pass the rule with no diagnostic.
@reflectiveTest
class CorrectionsTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = TableFieldsRule();
    DbDslPackage.addTo(this);
    super.setUp();
    DbDslPackage.completeSdk(this);
  }

  /// [code] after applying the correction [create] makes at [offset].
  Future<String> _apply(
    String code,
    int offset,
    ResolvedCorrectionProducer Function({
      required CorrectionProducerContext context,
    })
    create,
  ) async {
    // A file of its own: the test file stays fresh for the final check of
    // the code the correction produced (the analyzer caches each file).
    final subject = newFile('$testPackageLibPath/subject.dart', code).path;
    final unit = await resolveFile(subject);
    final library =
        await unit.session.getResolvedLibrary(subject) as ResolvedLibraryResult;
    final producer = create(
      context: CorrectionProducerContext.createResolved(
        libraryResult: library,
        unitResult: unit,
        selectionOffset: offset,
      ),
    );
    final builder = ChangeBuilder(session: unit.session);
    await producer.compute(builder);

    return switch (builder.sourceChange.edits) {
      [final SourceFileEdit file] => SourceEdit.applySequence(code, file.edits),
      [] => code,
      final edits => fail('Edits in several files: $edits'),
    };
  }

  Future<void> test_the_assist_writes_the_fields_after_the_model() async {
    final code = '$_model\n';
    final written = await _apply(
      code,
      const Source('$_model\n').offsetOf("DbTable<Task>('tasks'"),
      AddQueryFields.new,
    );

    expect(written, '$_model$_fields\n');
    await assertNoDiagnostics(written);
  }

  Future<void> test_the_assist_rewrites_fields_the_model_no_longer_has() async {
    final code =
        '''
$_model

/// Old fields.
extension TaskFields on DbTable<Task> {
  Field<String> get title => field('title');
}
''';
    final written = await _apply(
      code,
      Source(code).offsetOf("field('title')"),
      RewriteQueryFields.new,
    );

    expect(written, '$_model$_fields\n');
    await assertNoDiagnostics(written);
  }

  Future<void> test_a_date_in_microseconds_gets_its_codec() async {
    const code = r'''
import 'package:db_dsl/db_dsl.dart';

class Tick {
  const Tick(this.at);
  factory Tick.fromJson(Map<String, dynamic> json) => throw 0;

  static final table = DbTable<Tick>('ticks', key: 'at', fromJson: Tick.fromJson);

  final DateTime at;

  Map<String, dynamic> toJson() => {'at': at.microsecondsSinceEpoch};
}''';
    const fields = r'''


/// The fields of `Tick` for queries, read from its `toJson`.
extension TickFields on DbTable<Tick> {
  /// The stored `at`.
  Field<DateTime> get at => field('at',
    encode: (date) => date.microsecondsSinceEpoch,
    decode: (stored) => DateTime.fromMicrosecondsSinceEpoch(stored as int),
  );
}''';

    final written = await _apply(
      '$code\n',
      const Source(code).offsetOf("DbTable<Tick>('ticks'"),
      AddQueryFields.new,
    );

    expect(written, '$code$fields\n');
    await assertNoDiagnostics(written);
  }

  Future<void> test_nothing_is_offered_when_the_model_cannot_be_read() async {
    const code = r'''
import 'package:db_dsl/db_dsl.dart';

class Bag {
  const Bag(this.values);
  factory Bag.fromJson(Map<String, dynamic> json) => Bag(json);
  final Map<String, Object?> values;
  Map<String, dynamic> toJson() => Map.of(values);
}

final bags = DbTable<Bag>('bags', key: 'id', fromJson: Bag.fromJson);
''';

    expect(
      await _apply(
        code,
        Source(code).offsetOf("DbTable<Bag>('bags'"),
        AddQueryFields.new,
      ),
      code,
    );
  }

  Future<void> test_a_typo_is_replaced_by_the_closest_field() async {
    final code =
        '''
$_model

extension TaskFields on DbTable<Task> {
  Field<bool> get done => field('dne');
}
''';

    expect(
      await _apply(code, Source(code).offsetOf("'dne'"), UseClosestField.new),
      code.replaceFirst("'dne'", "'done'"),
    );
  }

  Future<void> test_a_nested_typo_keeps_the_rest_of_the_path() async {
    final code =
        '''
$_model

extension TaskFields on DbTable<Task> {
  Field<String> get city => field('address.cty');
}
''';

    expect(
      await _apply(
        code,
        Source(code).offsetOf("'address.cty'"),
        UseClosestField.new,
      ),
      code.replaceFirst("'address.cty'", "'address.city'"),
    );
  }

  Future<void> test_a_wrong_type_becomes_the_stored_one() async {
    final code =
        '$_model${_fields.replaceFirst('Field<bool> get done', 'Field<int> get done')}\n';

    final written = await _apply(
      code,
      Source(code).offsetOf("field('done')"),
      UseStoredType.new,
    );

    expect(written, '$_model$_fields\n');
    await assertNoDiagnostics(written);
  }

  Future<void> test_the_table_fix_adds_the_fields_the_model_gained() async {
    // The model gained `address`; the warning sits on the table.
    final code =
        '''
$_model

/// The fields of `Task` for queries, read from its `toJson`.
extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
  Field<bool> get done => field('done');
}
''';

    final written = await _apply(
      code,
      Source(code).offsetOf("DbTable<Task>('tasks'"),
      RewriteQueryFields.new,
    );

    expect(written, '$_model$_fields\n');
    await assertNoDiagnostics(written);
  }

  Future<void>
  test_the_table_fix_never_duplicates_fields_of_another_file() async {
    newFile('$testPackageLibPath/task_fields.dart', r'''
import 'package:db_dsl/db_dsl.dart';

import 'subject.dart';

extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
}
''');
    final code =
        '''
$_model

Object pending() => Task.table.id;
'''
            .replaceFirst(
              "import 'package:db_dsl/db_dsl.dart';",
              "import 'package:db_dsl/db_dsl.dart';\n\nimport 'task_fields.dart';",
            );

    expect(
      await _apply(
        code,
        Source(code).offsetOf("DbTable<Task>('tasks'"),
        RewriteQueryFields.new,
      ),
      code,
    );
  }
}
