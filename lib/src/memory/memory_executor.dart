/// How [MemoryEngine] runs statements and table definitions on a
/// [MemoryState], with the rules of offline_first_core (`engine/exec.rs`,
/// `engine/store.rs`).
library;

import 'dart:convert';
import 'dart:math';

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/json_values.dart';
import '../protocol/query_plan.dart';
import '../protocol/statement.dart';
import '../protocol/sync_records.dart';
import '../query/expression.dart';
import '../schema/table_schema.dart';
import 'expression_evaluator.dart';
import 'memory_relational.dart';
import 'memory_state.dart';

part 'memory_sync.dart';

/// Runs statements and definitions on one [MemoryState].
///
/// Writes change [state] in place; callers give it a copy and keep the copy
/// only when the result is `Ok`, which makes every statement atomic.
final class MemoryExecutor {
  /// An executor over [state], inside the root transaction numbered
  /// [transaction] (the changes it records carry it).
  MemoryExecutor(this.state, {this.transaction = 0});

  /// The state read and written.
  final MemoryState state;

  /// The number of the root transaction this executor writes in.
  final int transaction;

  /// The sync operations on [state].
  late final MemorySyncOperations sync = MemorySyncOperations(this);

  /// Runs [statement]; answers its output.
  Result<Object?, DbError> execute(Statement<Object?> statement) =>
      _table(statement.table).flatMap(
        (table) => switch (statement) {
          SelectStatement() => _select(table, statement),
          GroupStatement(:final filter) => MemoryGrouping.group([
            for (final (_, row) in _matching(table, filter)) row,
          ], statement).map(MemoryRows.detached),
          JoinStatement() => _join(table, statement),
          CountStatement(:final filter) => Ok(_matching(table, filter).length),
          AggregateStatement() => Ok(_aggregate(table, statement)),
          FindStatement(:final key) => Ok(
            _detachedRow(table.rows[JsonValues.encodeKey([key])]),
          ),
          InsertStatement() => _insert(table, statement),
          UpdateStatement() => _update(table, statement),
          DeleteStatement() => _delete(table, statement),
        },
      );

  /// Defines [schema] (see `DefineTableRequest`); answers whether anything
  /// changed.
  Result<bool, DbError> defineTable(TableSchema schema) {
    if (_validate(schema) case final DbError error) {
      return Err(error);
    }

    final existing = state.tables[schema.name];

    switch (existing) {
      case final MemoryTable table when table.schema == schema:
        return Ok(false);
      case final MemoryTable table
          when table.schema.primaryKey != schema.primaryKey ||
              table.schema.autoIncrement != schema.autoIncrement:
        return Err(
          DbError(
            DbErrorCode.schemaMismatch,
            '`${schema.name}`: the primary key and auto_increment cannot '
            'change',
          ),
        );
      case MemoryTable(schema: TableSchema(sync: final String remote))
          when remote != schema.sync:
        return Err(
          DbError(
            DbErrorCode.schemaMismatch,
            '`${schema.name}`: a synchronized table keeps its remote',
          ),
        );
      default:
        break;
    }

    final table = MemoryTable(schema);

    if (existing != null) {
      table.rows.addAll(existing.rows);
    }

    for (final index in schema.indexes) {
      final kept = existing?.schema.indexes.contains(index) ?? false;

      if (kept) {
        table.indexes[index.name] = existing!.indexes[index.name]!;
        continue;
      }

      for (final MapEntry(key: pk, value: row) in table.rows.entries) {
        if (_addIndexEntry(table, index, row, pk) case final DbError error) {
          return Err(error);
        }
      }
    }

    state.tables[schema.name] = table;

    if (schema.sync != null) {
      state.sync.enabled = true;
    }

    return Ok(true);
  }

  /// Drops the table [name] (with its sync records); answers whether it
  /// existed.
  bool dropTable(String name) {
    state.sequences.remove(name);

    if (state.tables[name]?.schema.sync != null) {
      sync.purgeTable(name);
    }

    return state.tables.remove(name) != null;
  }

  /// The definitions of every table, by name.
  List<TableSchema> tables() => [
    for (final name in state.tables.keys.toList()..sort())
      state.tables[name]!.schema,
  ];

  /// The plan of [query]: [MemoryEngine] always scans the whole table.
  Result<QueryPlan, DbError> explain(SelectStatement query) =>
      _table(query.table).map(
        (_) => QueryPlan(
          table: query.table,
          access: PlanAccess.fullScan,
          presorted: query.order.isEmpty,
          exact: query.filter == null,
        ),
      );

  /// The plan of the join [query], without running it: [MemoryEngine]
  /// reads every table in full, hashes each joined one by its join field,
  /// and filters the combined rows, like offline_first_core.
  Result<JoinPlan, DbError> explainJoin(JoinStatement query) {
    final tables = <JoinPlanTable>[];

    for (final (name, alias) in [
      (query.table, query.alias),
      for (final join in query.joins) (join.table, join.alias),
    ]) {
      if (_table(name) case Err(:final error)) {
        return Err(error);
      }

      tables.add(
        JoinPlanTable(table: name, alias: alias, access: PlanAccess.fullScan),
      );
    }

    if (MemoryJoin.check(query) case final DbError error) {
      return Err(error);
    }

    return Ok(
      JoinPlan(
        strategy: 'hash_join',
        tables: tables,
        filter: query.filter == null ? 'none' : 'after_join',
      ),
    );
  }

  Result<MemoryTable, DbError> _table(String name) =>
      switch (state.tables[name]) {
        final MemoryTable table => Ok(table),
        null => Err(
          DbError(DbErrorCode.tableNotFound, 'Table `$name` is not defined'),
        ),
      };

  /// Rows matching [filter], in primary key order: `(key, row)`.
  List<(List<int>, Map<String, Object?>)> _matching(
    MemoryTable table,
    Expression? filter,
  ) => [
    for (final MapEntry(:key, :value) in table.rows.entries)
      if (filter == null || ExpressionEvaluator.matches(filter, value))
        (key, value),
  ];

  Result<List<Map<String, Object?>>, DbError> _select(
    MemoryTable table,
    SelectStatement query,
  ) {
    if (MemoryRows.checkPaths(query.fields, 'fields') case final DbError e) {
      return Err(e);
    }

    final sorted = MemoryRows.sorted([
      for (final (_, row) in _matching(table, query.filter)) row,
    ], query.order);
    final projected = switch (query.fields) {
      [] => sorted,
      final fields => [
        for (final row in sorted) MemoryRows.project(row, fields),
      ],
    };
    final unique = query.distinct
        ? MemoryRows.distinct(projected, query.fields)
        : projected;

    return Ok(
      MemoryRows.detached(MemoryRows.page(unique, query.offset, query.limit)),
    );
  }

  Result<List<Map<String, Object?>>, DbError> _join(
    MemoryTable from,
    JoinStatement join,
  ) {
    final joined = <List<Map<String, Object?>>>[];

    for (final clause in join.joins) {
      switch (_table(clause.table)) {
        case Ok(data: final table):
          joined.add(table.rows.values.toList());
        case Err(:final error):
          return Err(error);
      }
    }

    return MemoryJoin.combine(join, from.rows.values.toList(), joined).map(
      (combined) => MemoryRows.detached(
        MemoryRows.page(
          MemoryRows.sorted([
            for (final row in combined)
              if (join.filter == null ||
                  ExpressionEvaluator.matches(join.filter!, row))
                row,
          ], join.order),
          join.offset,
          join.limit,
        ),
      ),
    );
  }

  Object? _aggregate(MemoryTable table, AggregateStatement statement) =>
      MemoryAggregates.reduce(GroupFunction.byWire[statement.function.wire]!, [
        for (final (_, row) in _matching(table, statement.filter))
          if (JsonValues.fieldAt(row, statement.field) case final Object value)
            value,
      ]);

  Result<Object?, DbError> _insert(MemoryTable table, InsertStatement insert) {
    final schema = table.schema;
    final written = <Map<String, Object?>>[];

    for (final original in insert.rows) {
      final row = MemoryState.detached(original)! as Map<String, Object?>;
      final keyValue = JsonValues.fieldAt(row, schema.primaryKey);

      switch ((keyValue, schema.autoIncrement)) {
        case (final int given, true):
          _bumpSequence(schema.name, given);
        case (null, true) when !schema.primaryKey.contains('.'):
          row[schema.primaryKey] = _nextSequence(schema.name);
        case (null, _):
          return Err(
            DbError(
              DbErrorCode.missingPrimaryKey,
              '`${schema.name}` rows need `${schema.primaryKey}`',
            ),
          );
        default:
          break;
      }

      final pk = JsonValues.encodeKey([
        JsonValues.fieldAt(row, schema.primaryKey),
      ]);

      if (_checkKey(pk) case final DbError error) {
        return Err(error);
      }

      final previous = table.rows[pk];

      if (previous != null) {
        switch (insert.onConflict) {
          case OnConflict.error:
            return Err(
              DbError(
                DbErrorCode.duplicateKey,
                '`${schema.name}` already has the key '
                '${JsonValues.canonical(JsonValues.fieldAt(row, schema.primaryKey))}',
              ),
            );
          case OnConflict.ignore:
            continue;
          case OnConflict.replace:
            _removeIndexEntries(table, previous, pk);
        }
      }

      for (final index in schema.indexes) {
        if (_addIndexEntry(table, index, row, pk) case final DbError error) {
          return Err(error);
        }
      }

      table.rows[pk] = row;

      if (sync.track(table, previous, row) case final DbError error) {
        return Err(error);
      }

      written.add(row);
    }

    return Ok(
      WriteOutput(
        written.length,
        rows: [for (final row in written) _detachedRow(row)!],
      ),
    );
  }

  Result<Object?, DbError> _update(MemoryTable table, UpdateStatement update) {
    final pk = table.schema.primaryKey;

    bool touchesKey(String path) => path == pk || path.startsWith('$pk.');

    if (update.set.keys.any(touchesKey) ||
        update.increment.keys.any(touchesKey)) {
      return Err(
        DbError(
          DbErrorCode.invalidRequest,
          'The primary key `$pk` of `${table.schema.name}` cannot be updated',
        ),
      );
    }

    if (update.increment.keys.where(update.set.containsKey).firstOrNull
        case final String both) {
      return Err(
        DbError(
          DbErrorCode.invalidRequest,
          '`$both` is both set and incremented',
        ),
      );
    }

    final rows = _matching(table, update.filter);

    if (_checkExpected(update.expectedRows, rows.length) case final DbError e) {
      return Err(e);
    }

    for (final (key, old) in rows) {
      final updated = MemoryState.detached(old)! as Map<String, Object?>;

      for (final MapEntry(key: path, :value) in update.set.entries) {
        if (!JsonValues.setAt(updated, path, MemoryState.detached(value))) {
          return Err(_notAnObject(path));
        }
      }

      for (final MapEntry(key: path, value: delta)
          in update.increment.entries) {
        final next = switch (JsonValues.fieldAt(updated, path)) {
          null => delta,
          final int current when delta is int => _checkedAdd(current, delta),
          final num current => _finiteAdd(current, delta),
          final Object other => _notANumber(path, other),
        };

        if (next case final DbError error) {
          return Err(error);
        }

        if (!JsonValues.setAt(updated, path, next)) {
          return Err(_notAnObject(path));
        }
      }

      _removeIndexEntries(table, old, key);

      for (final index in table.schema.indexes) {
        if (_addIndexEntry(table, index, updated, key) case final DbError e) {
          return Err(e);
        }
      }

      table.rows[key] = updated;

      if (sync.track(table, old, updated) case final DbError error) {
        return Err(error);
      }
    }

    return Ok(WriteOutput(rows.length));
  }

  Result<Object?, DbError> _delete(MemoryTable table, DeleteStatement delete) {
    final rows = _matching(table, delete.filter);

    if (_checkExpected(delete.expectedRows, rows.length) case final DbError e) {
      return Err(e);
    }

    for (final (key, old) in rows) {
      _removeIndexEntries(table, old, key);
      table.rows.remove(key);

      if (sync.track(table, old, null) case final DbError error) {
        return Err(error);
      }
    }

    return Ok(WriteOutput(rows.length));
  }

  /// The key of [row] in [index]: the indexed values, then the primary key
  /// unless the index is unique and every value is present (like SQL, rows
  /// with a `NULL` are exempt from uniqueness).
  static (List<int>, bool) _indexKey(
    IndexSchema index,
    Map<String, Object?> row,
    List<int> pk,
  ) {
    final values = [
      for (final field in index.fields) JsonValues.fieldAt(row, field),
    ];
    final enforced = index.unique && values.every((value) => value != null);

    return ([...JsonValues.encodeKey(values), if (!enforced) ...pk], enforced);
  }

  DbError? _addIndexEntry(
    MemoryTable table,
    IndexSchema index,
    Map<String, Object?> row,
    List<int> pk,
  ) {
    final (key, enforced) = _indexKey(index, row, pk);
    final entries = table.indexes[index.name]!;

    if (_checkKey(key) case final DbError error) {
      return error;
    }

    if (entries[key] case final List<int> owner
        when enforced && JsonValues.compareKeys(owner, pk) != 0) {
      return DbError(
        DbErrorCode.uniqueViolation,
        '`${table.schema.name}` index `${index.name}` already holds '
        '${JsonValues.canonical([for (final field in index.fields) JsonValues.fieldAt(row, field)])}',
      );
    }

    entries[key] = pk;
    return null;
  }

  static void _removeIndexEntries(
    MemoryTable table,
    Map<String, Object?> row,
    List<int> pk,
  ) {
    for (final index in table.schema.indexes) {
      table.indexes[index.name]!.remove(_indexKey(index, row, pk).$1);
    }
  }

  static DbError? _checkKey(List<int> key) =>
      key.isEmpty || key.length > JsonValues.maxKeySize
      ? DbError(
          DbErrorCode.keyTooLarge,
          'A key of ${key.length} bytes exceeds ${JsonValues.maxKeySize}',
        )
      : null;

  static DbError? _checkExpected(int? expected, int actual) =>
      switch (expected) {
        final int count when count != actual => DbError(
          DbErrorCode.affectedRowsMismatch,
          'Expected $count affected rows, found $actual',
        ),
        _ => null,
      };

  static DbError _notAnObject(String path) => DbError(
    DbErrorCode.invalidRequest,
    'Cannot set `$path`: a value on the way is not an object',
  );

  static DbError _notANumber(String path, Object value) => DbError(
    DbErrorCode.invalidRequest,
    'Cannot increment `$path`: it holds $value, not a number',
  );

  /// [a] + [b], or an error when the sum does not fit 64 bits. On the web
  /// an `int` is a double, so a sum past the largest double is caught too.
  static Object _checkedAdd(int a, int b) {
    final sum = a + b;
    final overflowed =
        (b > 0 && sum < a) || (b < 0 && sum > a) || !sum.isFinite;

    return overflowed
        ? DbError(DbErrorCode.invalidRequest, 'The increment overflows')
        : sum;
  }

  /// [a] + [b], or an error when the sum is not a finite number: JSON has
  /// no infinity, so the row could not be stored or answered.
  static Object _finiteAdd(num a, num b) {
    final sum = a + b;

    return sum.isFinite
        ? sum
        : DbError(DbErrorCode.invalidRequest, 'The increment is not finite');
  }

  int _nextSequence(String table) =>
      state.sequences[table] = (state.sequences[table] ?? 0) + 1;

  void _bumpSequence(String table, int value) {
    if (value > (state.sequences[table] ?? 0)) {
      state.sequences[table] = value;
    }
  }

  static DbError? _validate(TableSchema schema) {
    DbError invalid(String message) =>
        DbError(DbErrorCode.invalidSchema, message);

    bool validName(String name) =>
        name.isNotEmpty && !name.contains(':') && !name.startsWith('__');

    if (!validName(schema.name)) {
      return invalid(
        'Table name `${schema.name}` must be non-empty, without `:`, and not '
        'start with `__`',
      );
    }

    if (schema.primaryKey.isEmpty) {
      return invalid('Table `${schema.name}` has an empty primary key');
    }

    if (schema.sync == '') {
      return invalid(
        'Table `${schema.name}` synchronizes with an empty remote',
      );
    }

    final names = <String>{};

    for (final index in schema.indexes) {
      final problem = switch (index) {
        _ when !validName(index.name) =>
          'Index name `${index.name}` is invalid',
        _ when !names.add(index.name) =>
          'Index `${index.name}` is defined twice on `${schema.name}`',
        _ when index.fields.isEmpty || index.fields.any((f) => f.isEmpty) =>
          'Index `${index.name}` of `${schema.name}` needs non-empty fields',
        _ => null,
      };

      if (problem != null) {
        return invalid(problem);
      }
    }

    return null;
  }

  static Map<String, Object?>? _detachedRow(Map<String, Object?>? row) =>
      MemoryState.detached(row) as Map<String, Object?>?;
}
