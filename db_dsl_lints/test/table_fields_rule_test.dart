// test_reflective_loader runs the methods named test_*.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:db_dsl_lints/src/rules/table_fields_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support/db_dsl_package.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(TableFieldsRuleTest);
  });
}

/// A model as an app writes it: a map literal in `toJson`, a nested model,
/// a date and a counter.
const String _model = r'''
import 'package:db_dsl/db_dsl.dart';

class Address {
  const Address(this.city, this.zip);
  final String city;
  final String zip;
  Map<String, dynamic> toJson() => {'city': city, 'zip': zip};
}

class Task {
  const Task(this.id, this.done, this.updatedAt, this.address, this.views);
  factory Task.fromJson(Map<String, dynamic> json) => throw 0;

  final String id;
  final bool done;
  final DateTime updatedAt;
  final Address address;
  final int? views;

  Map<String, dynamic> toJson() => {
    'id': id,
    'done': done,
    'updatedAt': updatedAt.toString(),
    'address': address,
    'views': views,
  };
}
''';

@reflectiveTest
class TableFieldsRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = TableFieldsRule();
    // Before `super.setUp()`, which writes the package configuration.
    DbDslPackage.addTo(this);
    super.setUp();
  }

  Future<void> test_fields_the_model_stores_are_accepted() async {
    await assertNoDiagnostics('''
$_model
extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
  Field<bool> get done => field('done');
  Field<DateTime> get updatedAt => field('updatedAt');
  Field<Address> get address => field('address');
  Field<String> get city => field('address.city');
  Field<int> get views => field('views');
}
''');
  }

  Future<void> test_a_typo_names_the_closest_field() async {
    const code =
        '''
$_model
extension TaskFields on DbTable<Task> {
  Field<bool> get done => field('dne');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("'dne'"),
        5,
        name: 'unknown_field',
        messageContainsAll: ["'dne' is not a field that 'Task' stores"],
        correctionContains: "Did you mean 'done'?",
      ),
    ]);
  }

  Future<void> test_a_name_far_from_any_field_lists_the_fields() async {
    const code =
        '''
$_model
extension TaskFields on DbTable<Task> {
  Field<String> get owner => field('owner');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("'owner'"),
        7,
        name: 'unknown_field',
        correctionContains:
            'Stored fields: id, done, updatedAt, address, views.',
      ),
    ]);
  }

  Future<void> test_a_nested_path_is_checked_in_the_nested_model() async {
    const code =
        '''
$_model
extension TaskFields on DbTable<Task> {
  Field<String> get zip => field('address.zp');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("'address.zp'"),
        12,
        name: 'unknown_field',
        messageContainsAll: ["'zp' is not a field that 'Address' stores"],
        correctionContains: "Did you mean 'zip'?",
      ),
    ]);
  }

  Future<void> test_another_type_than_the_stored_one_is_an_error() async {
    const code =
        '''
$_model
extension TaskFields on DbTable<Task> {
  Field<int> get done => field('done');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("field('done')"),
        13,
        name: 'field_type_mismatch',
        messageContainsAll: ["'done' is stored as a 'bool', not as a 'int'"],
      ),
    ]);
  }

  Future<void> test_an_untyped_field_is_an_error() async {
    const code =
        '''
$_model
void f(DbTable<Task> tasks) {
  tasks.field('done');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("tasks.field('done')"),
        19,
        name: 'field_type_mismatch',
        messageContainsAll: ["'done' is stored as a 'bool', not as a 'Object'"],
      ),
    ]);
  }

  Future<void> test_a_custom_codec_is_not_type_checked() async {
    await assertNoDiagnostics('''
$_model
extension TaskFields on DbTable<Task> {
  Field<int> get updatedAt => field(
    'updatedAt',
    encode: (value) => value,
    decode: (stored) => stored as int,
  );
}
''');
  }

  Future<void> test_an_explicit_table_is_checked_too() async {
    const code =
        '''
$_model
void f(DbTable<Task> tasks) {
  tasks.field<bool>('dne');
}
''';
    await assertDiagnostics(code, [
      lint(const Source(code).offsetOf("'dne'"), 5, name: 'unknown_field'),
    ]);
  }

  Future<void> test_the_key_and_the_indexes_of_a_table_are_checked() async {
    const code =
        '''
$_model
final tasks = DbTable<Task>(
  'tasks',
  key: 'idd',
  fromJson: Task.fromJson,
  indexes: [Index(['done', 'updatedAt']), Index.unique(['dne'])],
);
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf('DbTable<Task>('),
        13,
        name: 'missing_query_fields',
      ),
      lint(
        const Source(code).offsetOf("'idd'"),
        5,
        name: 'unknown_key',
        correctionContains: "Did you mean 'id'?",
      ),
      lint(const Source(code).offsetOf("'dne'"), 5, name: 'unknown_field'),
    ]);
  }

  Future<void> test_a_toJson_of_the_table_decides_what_is_stored() async {
    const code =
        '''
$_model
final tasks = DbTable<Task>(
  'tasks',
  key: 'id',
  fromJson: Task.fromJson,
  toJson: (task) => {'id': task.id},
  indexes: [Index(['done'])],
);
''';
    await assertDiagnostics(code, [
      // Only `id` is stored, so only `id` is missing.
      lint(
        const Source(code).offsetOf('DbTable<Task>('),
        13,
        name: 'missing_query_fields',
        messageContainsAll: [
          "'Task' stores fields its table cannot query: id.",
        ],
      ),
      // The `'done'` of the index, not the one of the model's `toJson`.
      lint(
        const Source(code).offsetOf("['done']") + 1,
        6,
        name: 'unknown_field',
      ),
    ]);
  }

  Future<void>
  test_json_serializable_keys_are_read_from_the_generated_part() async {
    newFile('$testPackageLibPath/note.g.dart', r'''
part of 'test.dart';

Map<String, dynamic> _$NoteToJson(Note instance) => <String, dynamic>{
  'id': instance.id,
  'updated_at': instance.updatedAt.toString(),
  if (instance.title case final value?) 'title': value,
};
''');
    const code = r'''
import 'package:db_dsl/db_dsl.dart';

part 'note.g.dart';

class Note {
  const Note(this.id, this.updatedAt, this.title);
  final String id;
  final DateTime updatedAt;
  final String? title;
  Map<String, dynamic> toJson() => _$NoteToJson(this);
}

extension NoteFields on DbTable<Note> {
  Field<String> get id => field('id');
  Field<String> get title => field('title');
  Field<DateTime> get updatedAt => field('updatedAt');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("'updatedAt'"),
        11,
        name: 'unknown_field',
        correctionContains: "Did you mean 'updated_at'?",
      ),
    ]);
  }

  Future<void> test_a_table_without_its_fields_is_reported() async {
    const code =
        '''
$_model
final tasks = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf('DbTable<Task>('),
        13,
        name: 'missing_query_fields',
        messageContainsAll: [
          "'Task' stores fields its table cannot query: "
              'id, done, updatedAt, address, views.',
        ],
        correctionContains: 'Write the query fields from the model',
      ),
    ]);
  }

  Future<void> test_a_field_added_to_the_model_is_reported() async {
    const code =
        '''
$_model
final tasks = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);

extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
  Field<bool> get done => field('done');
  Field<DateTime> get updatedAt => field('updatedAt');
  Field<Address> get address => field('address');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf('DbTable<Task>('),
        13,
        name: 'missing_query_fields',
        messageContainsAll: [
          "'Task' stores fields its table cannot query: views.",
        ],
      ),
    ]);
  }

  Future<void>
  test_a_table_with_all_its_fields_written_is_not_reported() async {
    await assertNoDiagnostics('''
$_model
final tasks = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);

extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
  Field<bool> get done => field('done');
  Field<DateTime> get updatedAt => field('updatedAt');
  Field<Address> get address => field('address');
  Field<int> get views => field('views');
}
''');
  }

  Future<void> test_fields_written_in_another_library_count() async {
    newFile('$testPackageLibPath/task.dart', _model);
    newFile('$testPackageLibPath/task_fields.dart', r'''
import 'package:db_dsl/db_dsl.dart';

import 'task.dart';

extension TaskFields on DbTable<Task> {
  Field<String> get id => field('id');
  Field<bool> get done => field('done');
  Field<DateTime> get updatedAt => field('updatedAt');
  Field<Address> get address => field('address');
  Field<int> get views => field('views');
}
''');
    await assertNoDiagnostics(r'''
import 'package:db_dsl/db_dsl.dart';

import 'task.dart';
import 'task_fields.dart';

final tasks = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);

Object pending() => tasks.done.eq(false);
''');
  }

  Future<void> test_a_table_of_an_unreadable_model_is_not_reported() async {
    await assertNoDiagnostics(r'''
import 'package:db_dsl/db_dsl.dart';

class Bag {
  const Bag(this.values);
  factory Bag.fromJson(Map<String, dynamic> json) => Bag(json);
  final Map<String, Object?> values;
  Map<String, dynamic> toJson() => Map.of(values);
}

final bags = DbTable<Bag>('bags', key: 'id', fromJson: Bag.fromJson);
''');
  }

  Future<void> test_a_toJson_with_a_block_body_is_read() async {
    const code = r'''
import 'package:db_dsl/db_dsl.dart';

class Note {
  const Note(this.id);
  final String id;
  Map<String, dynamic> toJson() {
    return {'id': id};
  }
}

extension NoteFields on DbTable<Note> {
  Field<String> get id => field('idd');
}
''';
    await assertDiagnostics(code, [
      lint(
        const Source(code).offsetOf("'idd'"),
        5,
        name: 'unknown_field',
        correctionContains: "Did you mean 'id'?",
      ),
    ]);
  }

  Future<void> test_a_toJson_built_at_run_time_reports_nothing() async {
    await assertNoDiagnostics(r'''
import 'package:db_dsl/db_dsl.dart';

class Bag {
  const Bag(this.values);
  final Map<String, Object?> values;
  Map<String, dynamic> toJson() => Map.of(values);
}

extension BagFields on DbTable<Bag> {
  Field<String> get anything => field('anything');
}
''');
  }

  Future<void> test_a_field_method_of_another_library_is_ignored() async {
    await assertNoDiagnostics(r'''
class Form {
  Object field(String name) => name;
}

void f(Form form) => form.field('dne');
''');
  }
}
