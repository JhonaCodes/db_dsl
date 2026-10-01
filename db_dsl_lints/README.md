# db_dsl_lints

The analyzer plugin of [db_dsl](https://pub.dev/packages/db_dsl). It reads
each model's `toJson`, checks every table against it while you type, and
writes the typed fields of a table from its model, so that queries read
`t.done.eq(false)` with the name and type the model stores.

No code generation, no macros: the fields are plain code in your file,
written by a quick fix, and kept in step with the model by the diagnostics
below.

## Setup

Requires Dart 3.11 or later (the analyzer it builds on needs it). In the
`analysis_options.yaml` at the root of your package (not in
`pubspec.yaml`):

```yaml
plugins:
  db_dsl_lints: ^0.1.0
```

Restart the analysis server after changing the `plugins` section. The
diagnostics then appear in the IDE and in `dart analyze`, so CI checks them
too. In a Flutter project run `dart analyze` as well: `flutter analyze` does
not report plugin diagnostics yet (checked with Flutter 3.47).

## From a model to typed queries

The model carries its table:

```dart
class Task {
  const Task(this.id, this.done, this.updatedAt);

  factory Task.fromJson(Map<String, dynamic> json) => Task(
    json['id'] as String,
    json['done'] as bool,
    DateTime.parse(json['updated_at'] as String),
  );

  static final table = DbTable<Task>('tasks', key: 'id', fromJson: Task.fromJson);

  final String id;
  final bool done;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'done': done,
    'updated_at': updatedAt.toIso8601String(),
  };
}
```

`DbTable<Task>` gets the warning `missing_query_fields`: *'Task' stores
fields its table cannot query: id, done, updatedAt.* Its quick fix, *Write
the query fields from the model* (Ctrl+. or ⌘. in VS Code, Alt+Enter in
IntelliJ and Android Studio), writes this right after the model:

```dart
/// The fields of `Task` for queries, read from its `toJson`.
extension TaskFields on DbTable<Task> {
  /// The stored `id`.
  Field<String> get id => field('id');

  /// The stored `done`.
  Field<bool> get done => field('done');

  /// The stored `updated_at`.
  Field<DateTime> get updatedAt => field('updated_at');
}
```

and queries are checked by the compiler:

```dart
final t = Task.table;
await t.filter(t.done.eq(false).and(t.updatedAt.gt(since))).order(t.updatedAt.desc());

t.dne;         // does not compile
t.done.eq(1);  // does not compile: Field<bool>.eq(bool)
```

When the model changes, the plugin says so where it matters:

- **a field is added** → `missing_query_fields` on the table again; the
  same quick fix rewrites the extension;
- **a field is renamed or removed** → `unknown_field` on the getter that
  still names it, with *Write the query fields from the model*, and every
  query using that getter stops compiling once it is rewritten;
- **a type changes** → `field_type_mismatch`, with *Use Field<T>*.

The assist *Write the query fields of the table*, on `DbTable<Task>(...)`
or on its extension, does the same on demand.

## Diagnostics

| Code | Severity | When | Quick fixes |
|---|---|---|---|
| `missing_query_fields` | warning | the model stores fields its table does not expose as getters: no `<T>Fields` extension, or the model gained a field | *Write the query fields from the model* |
| `unknown_field` | error | `field('dne')`, or a name in `Index([...])`, is not a field the model stores; a nested path (`'address.cty'`) is checked in the nested model | *Use 'done'* (the closest name), *Write the query fields from the model* |
| `field_type_mismatch` | error | `Field<int> get done => field('done')` while the model stores a `bool`, or an untyped `field('done')` | *Use Field<bool>* |
| `unknown_key` | error | the `key:` of the table is not a stored field | *Use 'id'* |

## What it reads

- A `toJson` that returns a map literal: `=> {'id': id, ...}`, or a block
  whose only statement is `return {...}`; entries may be `'key': ?value`
  or `if (x case final v?) 'key': v`.
- json_serializable's generated `_$TaskToJson` in a part file, with the
  keys `@JsonKey(name: ...)` gave them.
- A `toJson:` passed to the table, which then decides what is stored.
- Nested models (`'address.city'`), each through its own `toJson`.
- A `DateTime` stored as `toIso8601String()`, or as
  `millisecondsSinceEpoch` / `microsecondsSinceEpoch`; for the epoch forms
  the written field gets its `encode` and `decode`.

A field with its own `encode` or `decode` stores its value its own way, so
its type is not checked.

## Limits

- **Never a false positive.** When a model's `toJson` is built at run time
  (`Map.of(values)`, a loop), the plugin cannot know what is stored and
  reports nothing for that model.
- Extensions are looked up wherever they are visible: fields written in
  another file count. The quick fix writes in the file where it is used
  (after the model when the model is there), and never adds a second
  extension when one already lives in another file.
- **Fixes run from the IDE only.** Dart's plugin system does not apply
  plugin fixes in bulk yet, so neither `dart fix` nor fix-all-on-save runs
  them; the diagnostics are what tells you, the moment the model changes.

## License

[Apache License 2.0](LICENSE). Redistributions must keep the [NOTICE](NOTICE)
file, which credits JhonaCodes as the author.
