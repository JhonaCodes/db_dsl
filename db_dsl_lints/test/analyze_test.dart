@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

/// The plugin end to end: a real package on the real db_dsl, the plugin
/// enabled in its `analysis_options.yaml`, and `dart analyze` from the SDK.
///
/// Why it exists: the rule tests run on a mock SDK and a mock db_dsl; this
/// one proves the plugin loads in the analysis server, reads a real model,
/// and that the fields the assist writes compile with the real SDK.
void main() {
  late Directory app;
  late ProcessResult analysis;

  setUpAll(() async {
    final lints = Directory.current.absolute.path;
    final dsl = Directory(lints).parent.path;
    app = await Directory.systemTemp.createTemp('db_dsl_lints_app');

    File('${app.path}/pubspec.yaml').writeAsStringSync('''
name: lints_app
environment:
  sdk: ^3.11.0
dependencies:
  db_dsl:
    path: $dsl
''');
    File('${app.path}/analysis_options.yaml').writeAsStringSync('''
plugins:
  db_dsl_lints:
    path: $lints
''');
    Directory('${app.path}/lib').createSync();
    File('${app.path}/lib/task.dart').writeAsStringSync(_task);
    File('${app.path}/lib/wrong.dart').writeAsStringSync(_wrong);
    File('${app.path}/lib/note.dart').writeAsStringSync(_note);
    File('$dsl/example/example.dart').copySync('${app.path}/lib/blog.dart');

    final get = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
    ], workingDirectory: app.path);
    expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');

    analysis = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--format=machine',
    ], workingDirectory: app.path);
  });

  tearDownAll(() => app.delete(recursive: true));

  List<String> diagnosticsOf(String file) => [
    for (final line in '${analysis.stdout}${analysis.stderr}'.split('\n'))
      if (line.contains('/lib/$file|')) line,
  ];

  test('the fields the assist writes compile and pass the rule', () {
    expect(diagnosticsOf('task.dart'), isEmpty);
  });

  test('the fields of the db_dsl example pass the rule', () {
    // The example is what the README points to: its fields must be exactly
    // what the plugin accepts.
    expect(diagnosticsOf('blog.dart'), isEmpty);
  });

  test('a table whose fields are not written yet is a warning', () {
    expect(diagnosticsOf('note.dart'), [
      allOf(
        startsWith('WARNING|'),
        contains('MISSING_QUERY_FIELDS'),
        contains("'Note' stores fields its table cannot query: id, text."),
      ),
    ]);
  });

  test('a wrong field name and a wrong type are errors', () {
    final wrong = diagnosticsOf('wrong.dart');

    expect(
      wrong,
      contains(
        allOf(
          startsWith('ERROR|'),
          contains('UNKNOWN_FIELD'),
          contains("'dne' is not a field that 'Task' stores"),
        ),
      ),
    );
    expect(
      wrong,
      contains(allOf(startsWith('ERROR|'), contains('FIELD_TYPE_MISMATCH'))),
    );
    expect(wrong, hasLength(2), reason: wrong.join('\n'));
  });
}

/// A model, its table, and the fields exactly as the assist writes them.
const String _task = r'''
import 'package:db_dsl/db_dsl.dart';

class Task {
  const Task(this.id, this.done, this.updatedAt, this.createdAt);

  factory Task.fromJson(Map<String, dynamic> json) => Task(
    json['id'] as String,
    json['done'] as bool,
    DateTime.parse(json['updated_at'] as String),
    DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int),
  );

  static final table = DbTable<Task>(
    'tasks',
    key: 'id',
    fromJson: Task.fromJson,
    indexes: [Index(['done', 'updated_at'])],
  );

  final String id;
  final bool done;
  final DateTime updatedAt;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'done': done,
    'updated_at': updatedAt.toIso8601String(),
    'created_at': createdAt.millisecondsSinceEpoch,
  };
}

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
}

Future<Object> pending() =>
    Task.table.filter(Task.table.done.eq(false).and(Task.table.updatedAt.gt(DateTime.utc(2026))));
''';

/// Two mistakes the plugin must catch.
const String _wrong = r'''
import 'package:db_dsl/db_dsl.dart';

import 'task.dart';

extension MoreTaskFields on DbTable<Task> {
  Field<bool> get finished => field('dne');
  Field<int> get doneCount => field('done');
}
''';

/// A model with its table and no fields written yet.
const String _note = r'''
import 'package:db_dsl/db_dsl.dart';

class Note {
  const Note(this.id, this.text);

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(json['id'] as String, json['text'] as String);

  static final table = DbTable<Note>('notes', key: 'id', fromJson: Note.fromJson);

  final String id;
  final String text;

  Map<String, dynamic> toJson() => {'id': id, 'text': text};
}
''';
