/// How [MemoryEngine] decides whether a row matches an [Expression].
library;

import '../protocol/json_values.dart';
import '../query/expression.dart';

/// Evaluates expressions on rows with the rules of the protocol
/// (`PROTOCOL.md`, "Expressions"), which offline_first_core implements in
/// `engine/stmt.rs`.
///
/// Why a class: evaluation is the one place where the semantics of every
/// expression form meet; the exhaustive `switch` over the sealed family
/// fails to compile when a form is added without its rule.
abstract final class ExpressionEvaluator {
  /// Whether [row] matches [expression].
  ///
  /// Comparisons see a missing or `null` field as absent: it matches no
  /// comparison, only `is_null`. `not` is two-valued.
  static bool matches(Expression expression, Map<String, Object?> row) {
    Object? present(String field) => JsonValues.fieldAt(row, field);

    return switch (expression) {
      Comparison(:final field, :final operator, :final value) =>
        switch (present(field)) {
          null => false,
          final Object stored => _compares(stored, operator, value),
        },
      Membership(:final field, :final values, negated: false) =>
        switch (present(field)) {
          null => false,
          final Object stored => values.any(
            (candidate) => JsonValues.sqlCompare(stored, candidate) == 0,
          ),
        },
      Membership(:final field, :final values, negated: true) => switch (present(
        field,
      )) {
        null => false,
        final Object stored => values.every(
          (excluded) => switch (JsonValues.sqlCompare(stored, excluded)) {
            null || 0 => false,
            _ => true,
          },
        ),
      },
      NullCheck(:final field, :final isNull) =>
        (present(field) == null) == isNull,
      Range(:final field, :final low, :final high, negated: false) =>
        switch (present(field)) {
          null => false,
          final Object stored => _between(stored, low, high),
        },
      Range(:final field, :final low, :final high, negated: true) =>
        switch (present(field)) {
          null => false,
          final Object stored =>
            JsonValues.sqlCompare(stored, low) != null &&
                JsonValues.sqlCompare(stored, high) != null &&
                !_between(stored, low, high),
        },
      LikePattern(:final field, :final pattern, :final caseInsensitive) =>
        switch (present(field)) {
          final String text => JsonValues.like(
            text,
            pattern,
            caseInsensitive: caseInsensitive,
          ),
          _ => false,
        },
      And(:final operands) => operands.every(
        (operand) => matches(operand, row),
      ),
      Or(:final operands) => operands.any((operand) => matches(operand, row)),
      Not(:final operand) => !matches(operand, row),
    };
  }

  static bool _compares(
    Object stored,
    ComparisonOperator operator,
    Object? value,
  ) => switch ((JsonValues.sqlCompare(stored, value), operator)) {
    (null, _) => false,
    (final int order, ComparisonOperator.eq) => order == 0,
    (final int order, ComparisonOperator.ne) => order != 0,
    (final int order, ComparisonOperator.gt) => order > 0,
    (final int order, ComparisonOperator.ge) => order >= 0,
    (final int order, ComparisonOperator.lt) => order < 0,
    (final int order, ComparisonOperator.le) => order <= 0,
  };

  static bool _between(Object stored, Object? low, Object? high) => switch ((
    JsonValues.sqlCompare(stored, low),
    JsonValues.sqlCompare(stored, high),
  )) {
    (final int fromLow, final int toHigh) => fromLow >= 0 && toHigh <= 0,
    _ => false,
  };
}
