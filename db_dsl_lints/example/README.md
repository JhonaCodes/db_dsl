# db_dsl_lints example

## 1. Enable the plugin

`analysis_options.yaml`, at the root of the package:

```yaml
plugins:
  db_dsl_lints: ^0.1.0
```

Restart the analysis server.

## 2. Give a model its table

```dart
import 'package:db_dsl/db_dsl.dart';

class Note {
  const Note(this.id, this.text, this.pinned);

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(json['id'] as String, json['text'] as String, json['pinned'] as bool);

  static final table = DbTable<Note>('notes', key: 'id', fromJson: Note.fromJson);

  final String id;
  final String text;
  final bool pinned;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'pinned': pinned};
}
```

The table is underlined:

```
warning: 'Note' stores fields its table cannot query: id, text, pinned.
         (missing_query_fields)
```

## 3. Apply the quick fix

*Write the query fields from the model* adds, after the model:

```dart
/// The fields of `Note` for queries, read from its `toJson`.
extension NoteFields on DbTable<Note> {
  /// The stored `id`.
  Field<String> get id => field('id');

  /// The stored `text`.
  Field<String> get text => field('text');

  /// The stored `pinned`.
  Field<bool> get pinned => field('pinned');
}
```

## 4. Query with typed fields

```dart
final t = Note.table;
final pinned = await t.filter(t.pinned.eq(true)).order(t.text.asc());
```

## 5. Change the model

Rename the field `pinned` to `starred` (and its key in `toJson`), and the
plugin answers at once:

```
error:   'pinned' is not a field that 'Note' stores.
         Stored fields: id, text, starred.  (unknown_field, on NoteFields)
warning: 'Note' stores fields its table cannot query: starred.
         (missing_query_fields, on the table)
```

*Write the query fields from the model* rewrites `NoteFields`; every query
that still says `t.pinned` then stops compiling, so none of them can
silently match no row.
