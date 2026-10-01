/// The data of a [MemoryEngine] database: tables and indexes kept as maps
/// ordered by encoded keys, the way LMDB keeps its B+trees.
library;

import 'dart:collection';
import 'dart:convert';

import '../protocol/json_values.dart';
import '../schema/table_schema.dart';

/// Keys compared byte by byte, like LMDB's default comparator.
typedef KeyMap<V> = SplayTreeMap<List<int>, V>;

/// One table: its definition, its rows by primary key, and its indexes.
///
/// Why keys are bytes: the order of rows and index entries, the equality of
/// keys (integers beyond 2^53 collide, `-0.0` equals `0`) and the key size
/// limit then follow `JsonValues.encodeKey` exactly as in the native engine.
final class MemoryTable {
  /// An empty table defined by [schema].
  MemoryTable(this.schema)
    : rows = KeyMap<Map<String, Object?>>(JsonValues.compareKeys),
      indexes = {
        for (final index in schema.indexes)
          index.name: KeyMap<List<int>>(JsonValues.compareKeys),
      };

  MemoryTable._(this.schema, this.rows, this.indexes);

  /// The definition.
  final TableSchema schema;

  /// Rows by encoded primary key.
  final KeyMap<Map<String, Object?>> rows;

  /// Index entries (encoded key → encoded primary key), by index name.
  final Map<String, KeyMap<List<int>>> indexes;

  /// An independent copy (rows are replaced, never mutated in place, so they
  /// are shared).
  MemoryTable copy() => MemoryTable._(
    schema,
    KeyMap<Map<String, Object?>>.of(rows, JsonValues.compareKeys),
    {
      for (final MapEntry(:key, :value) in indexes.entries)
        key: KeyMap<List<int>>.of(value, JsonValues.compareKeys),
    },
  );
}

/// Every table and sequence of a database at one point in time.
///
/// Why copies: a transaction works on its own copy and replaces the
/// committed state only on commit; a statement works on a copy of its
/// transaction's state and replaces it only when it succeeds. That is how
/// LMDB's copy-on-write gives atomic statements and savepoints.
final class MemoryState {
  /// An empty database.
  MemoryState() : tables = {}, sequences = {};

  MemoryState._(this.tables, this.sequences);

  /// Tables by name.
  final Map<String, MemoryTable> tables;

  /// Last generated key of each auto-increment table.
  final Map<String, int> sequences;

  /// An independent copy.
  MemoryState copy() => MemoryState._(
    {for (final MapEntry(:key, :value) in tables.entries) key: value.copy()},
    {...sequences},
  );

  /// A deep copy of a stored JSON value, so no caller aliases stored data.
  static Object? detached(Object? value) => jsonDecode(jsonEncode(value));
}
