/// How [MemoryEngine] projects, deduplicates, groups and joins rows, with
/// the rules of the protocol (`PROTOCOL.md`, "Statements").
library;

import 'dart:collection';

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/json_values.dart';
import '../protocol/statement.dart';
import '../query/ordering.dart';
import 'expression_evaluator.dart';
import 'memory_state.dart';

/// Row operations shared by selects, groups and joins.
abstract final class MemoryRows {
  /// [rows] sorted by [order]; rows that tie keep their order (Dart's own
  /// sort is not stable).
  static List<Map<String, Object?>> sorted(
    List<Map<String, Object?>> rows,
    List<OrderingTerm> order,
  ) {
    if (order.isEmpty) {
      return rows;
    }

    final indexed = [for (final (index, row) in rows.indexed) (index, row)]
      ..sort((a, b) {
        for (final term in order) {
          final byTerm = JsonValues.totalCompare(
            JsonValues.fieldAt(a.$2, term.field),
            JsonValues.fieldAt(b.$2, term.field),
          );

          if (byTerm != 0) {
            return term.descending ? -byTerm : byTerm;
          }
        }

        return a.$1.compareTo(b.$1);
      });

    return [for (final (_, row) in indexed) row];
  }

  /// The rows from [offset], at most [limit].
  static List<Map<String, Object?>> page(
    List<Map<String, Object?>> rows,
    int? offset,
    int? limit,
  ) => rows.skip(offset ?? 0).take(limit ?? rows.length).toList();

  /// [row] reduced to [fields], each at its path; a missing value is `null`.
  static Map<String, Object?> project(
    Map<String, Object?> row,
    List<String> fields,
  ) {
    final projected = <String, Object?>{};

    for (final field in fields) {
      JsonValues.setAt(projected, field, JsonValues.fieldAt(row, field));
    }

    return projected;
  }

  /// [rows] without repeats, keeping the first; two rows repeat when the key
  /// encodings of their [fields] values (of the whole row without fields)
  /// are equal.
  static List<Map<String, Object?>> distinct(
    List<Map<String, Object?>> rows,
    List<String> fields,
  ) {
    final seen = SplayTreeSet<List<int>>(JsonValues.compareKeys);

    return [
      for (final row in rows)
        if (seen.add(
          JsonValues.encodeKey(switch (fields) {
            [] => [row],
            _ => [for (final field in fields) JsonValues.fieldAt(row, field)],
          }),
        ))
          row,
    ];
  }

  /// An error when [paths] are empty, repeated, or one is a prefix of
  /// another (`a` and `a.b` would land on the same place).
  static DbError? checkPaths(List<String> paths, String what) {
    for (final (i, path) in paths.indexed) {
      if (path.isEmpty) {
        return DbError(DbErrorCode.invalidRequest, 'An empty path in $what');
      }

      for (final other in paths.skip(i + 1)) {
        if (other == path ||
            other.startsWith('$path.') ||
            path.startsWith('$other.')) {
          return DbError(
            DbErrorCode.invalidRequest,
            'The paths `$path` and `$other` of $what overlap',
          );
        }
      }
    }

    return null;
  }

  /// The detached copies of [rows], so no caller aliases stored data.
  static List<Map<String, Object?>> detached(
    List<Map<String, Object?>> rows,
  ) => [
    for (final row in rows) MemoryState.detached(row)! as Map<String, Object?>,
  ];
}

/// The reduction of aggregates, shared by `aggregate` and `group`.
abstract final class MemoryAggregates {
  /// [function] over the non-null [values] of a field; `null` when there is
  /// none (`count` answers 0).
  static Object? reduce(GroupFunction function, List<Object> values) {
    final numbers = values.whereType<num>().toList();

    return switch (function) {
      GroupFunction.count => values.length,
      GroupFunction.min when values.isNotEmpty => MemoryState.detached(
        values.reduce((a, b) => JsonValues.totalCompare(a, b) <= 0 ? a : b),
      ),
      GroupFunction.max when values.isNotEmpty => MemoryState.detached(
        values.reduce((a, b) => JsonValues.totalCompare(a, b) >= 0 ? a : b),
      ),
      GroupFunction.sum when numbers.isNotEmpty => _sum(numbers),
      GroupFunction.avg when numbers.isNotEmpty =>
        numbers.fold<double>(0, (sum, n) => sum + n.toDouble()) /
            numbers.length,
      _ => null,
    };
  }

  /// Integers stay integers unless the sum overflows 64 bits; then, like any
  /// sum with a double, the result is a double.
  static num _sum(List<num> numbers) {
    if (numbers.every((n) => n is int)) {
      var total = 0;

      for (final n in numbers.cast<int>()) {
        final next = total + n;

        if ((n > 0 && next < total) || (n < 0 && next > total)) {
          return numbers.fold<double>(0, (sum, n) => sum + n.toDouble());
        }

        total = next;
      }

      return total;
    }

    return numbers.fold<double>(0, (sum, n) => sum + n.toDouble());
  }
}

/// `group`: rows grouped by the key encoding of their `by` values.
abstract final class MemoryGrouping {
  /// The group rows of [rows] (already filtered) for [statement].
  static Result<List<Map<String, Object?>>, DbError> group(
    List<Map<String, Object?>> rows,
    GroupStatement statement,
  ) {
    if (_check(statement) case final DbError error) {
      return Err(error);
    }

    final groups = KeyMap<List<Map<String, Object?>>>(JsonValues.compareKeys);

    if (statement.by.isEmpty) {
      groups[const []] = rows;
    } else {
      for (final row in rows) {
        final key = JsonValues.encodeKey([
          for (final path in statement.by) JsonValues.fieldAt(row, path),
        ]);
        (groups[key] ??= []).add(row);
      }
    }

    final output =
        [for (final members in groups.values) _row(statement, members)]
            .where(
              (row) => switch (statement.having) {
                null => true,
                final condition => ExpressionEvaluator.matches(condition, row),
              },
            )
            .toList();

    return Ok(
      MemoryRows.page(
        MemoryRows.sorted(output, statement.order),
        statement.offset,
        statement.limit,
      ),
    );
  }

  static Map<String, Object?> _row(
    GroupStatement statement,
    List<Map<String, Object?>> members,
  ) {
    final row = switch (members) {
      [final first, ...] => MemoryRows.project(first, statement.by),
      [] => <String, Object?>{},
    };

    for (final GroupAggregate(:function, :field, :alias)
        in statement.aggregates) {
      row[alias] = switch (field) {
        null => members.length,
        final String path => MemoryAggregates.reduce(function, [
          for (final member in members)
            if (JsonValues.fieldAt(member, path) case final Object value) value,
        ]),
      };
    }

    return row;
  }

  static DbError? _check(GroupStatement statement) {
    DbError invalid(String message) =>
        DbError(DbErrorCode.invalidRequest, message);

    if (statement.by.any((path) => path.isEmpty)) {
      return invalid('An empty path in `by`');
    }

    final roots = {for (final path in statement.by) path.split('.').first};
    final aliases = <String>{};

    for (final GroupAggregate(:function, :field, :alias)
        in statement.aggregates) {
      final problem = switch (alias) {
        '' => 'An aggregate without alias',
        _ when alias.contains('.') => 'The alias `$alias` contains `.`',
        _ when !aliases.add(alias) => 'The alias `$alias` is repeated',
        _ when roots.contains(alias) =>
          'The alias `$alias` collides with a `by` path',
        _ when field == '' => 'An empty field in `$alias`',
        _ when field == null && function != GroupFunction.count =>
          '`${function.wire}` needs a field',
        _ => null,
      };

      if (problem != null) {
        return invalid(problem);
      }
    }

    return null;
  }
}

/// `join`: combined rows built table after table, by equality.
abstract final class MemoryJoin {
  /// The combined rows of [statement] (unfiltered), from the rows of each
  /// table in primary key order.
  static Result<List<Map<String, Object?>>, DbError> combine(
    JoinStatement statement,
    List<Map<String, Object?>> from,
    List<List<Map<String, Object?>>> joined,
  ) {
    if (check(statement) case final DbError error) {
      return Err(error);
    }

    var combined = [
      for (final row in from) <String, Object?>{statement.alias: row},
    ];

    for (final (index, clause) in statement.joins.indexed) {
      final byKey = KeyMap<List<Map<String, Object?>>>(JsonValues.compareKeys);

      for (final row in joined[index]) {
        if (JsonValues.fieldAt(row, clause.right) case final Object value) {
          (byKey[JsonValues.encodeKey([value])] ??= []).add(row);
        }
      }

      combined = [for (final row in combined) ..._extend(row, clause, byKey)];
    }

    return Ok(combined);
  }

  /// [row] once per match of [clause] (re-checked with SQL equality, since
  /// keys of integers beyond 2^53 collide), or once with `null` for a left
  /// join without match.
  static List<Map<String, Object?>> _extend(
    Map<String, Object?> row,
    JoinClause clause,
    KeyMap<List<Map<String, Object?>>> byKey,
  ) {
    final value = JsonValues.fieldAt(row, clause.left);
    final matches = switch (value) {
      null => const <Map<String, Object?>>[],
      final Object key => [
        for (final candidate in byKey[JsonValues.encodeKey([key])] ?? const [])
          if (JsonValues.sqlCompare(
                JsonValues.fieldAt(candidate, clause.right),
                key,
              ) ==
              0)
            candidate,
      ],
    };

    return switch ((matches, clause.kind)) {
      ([], JoinKind.inner) => const [],
      ([], JoinKind.left) => [
        {...row, clause.alias: null},
      ],
      _ => [
        for (final match in matches) {...row, clause.alias: match},
      ],
    };
  }

  /// Why the aliases of [statement] are invalid, or `null`: empty,
  /// containing `.`, or repeated.
  static DbError? check(JoinStatement statement) {
    final aliases = [
      statement.alias,
      for (final join in statement.joins) join.alias,
    ];

    for (final (i, alias) in aliases.indexed) {
      final problem = switch (alias) {
        '' => 'An empty alias',
        _ when alias.contains('.') => 'The alias `$alias` contains `.`',
        _ when aliases.skip(i + 1).contains(alias) =>
          'The alias `$alias` is repeated',
        _ => null,
      };

      if (problem != null) {
        return DbError(DbErrorCode.invalidRequest, problem);
      }
    }

    return null;
  }
}
