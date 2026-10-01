/// Conditions on rows (`WHERE`), built with the columns of a table and sent
/// to the engine as data.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/json_values.dart';

/// A condition on the rows of a table.
///
/// Expressions are data: the DSL builds them, the engine evaluates them
/// (`PROTOCOL.md`, "Expressions"). Combine them as in Diesel:
/// `a.and(b)`, `a.or(b)` and `a.not()`.
///
/// Why sealed: the engine understands exactly these forms. A closed family
/// lets [toJson], [Expression.decode] and every evaluator handle each form
/// exhaustively, and makes a new form a change the compiler points out
/// everywhere.
sealed class Expression {
  const Expression();

  /// Rows matching this condition and [other] (`AND`, Diesel's `.and()`);
  /// nested `AND`s are flattened.
  Expression and(Expression other) => And([..._conjuncts, ...other._conjuncts]);

  /// Rows matching this condition or [other] (`OR`, Diesel's `.or()`);
  /// nested `OR`s are flattened.
  Expression or(Expression other) => Or([..._disjuncts, ...other._disjuncts]);

  /// This condition as a list of `AND` operands.
  List<Expression> get _conjuncts => [this];

  /// This condition as a list of `OR` operands.
  List<Expression> get _disjuncts => [this];

  /// Rows not matching this condition (`NOT`, Diesel's `not()`).
  ///
  /// Two-valued, as in offline_first_core: `column.eq(x).not()` also matches
  /// rows where the column is missing or `null`.
  Expression not() => Not(this);

  /// The protocol form (`{"op": ..., ...}`).
  Map<String, Object?> toJson();

  /// This condition with every field built from a table column prefixed by
  /// its table (`'name'` becomes `'users.name'`), the paths of a combined
  /// join row. Fields without a known table stay as they are.
  Expression qualified() => switch (this) {
    Comparison(:final field, :final operator, :final value, :final table) =>
      Comparison(_qualify(table, field), operator, value),
    Membership(:final field, :final values, :final negated, :final table) =>
      Membership(_qualify(table, field), values, negated: negated),
    NullCheck(:final field, :final isNull, :final table) => NullCheck(
      _qualify(table, field),
      isNull: isNull,
    ),
    Range(
      :final field,
      :final low,
      :final high,
      :final negated,
      :final table,
    ) =>
      Range(_qualify(table, field), low, high, negated: negated),
    LikePattern(
      :final field,
      :final pattern,
      :final caseInsensitive,
      :final table,
    ) =>
      LikePattern(
        _qualify(table, field),
        pattern,
        caseInsensitive: caseInsensitive,
      ),
    And(:final operands) => And([
      for (final operand in operands) operand.qualified(),
    ]),
    Or(:final operands) => Or([
      for (final operand in operands) operand.qualified(),
    ]),
    Not(:final operand) => Not(operand.qualified()),
  };

  static String _qualify(String? table, String field) => switch (table) {
    null => field,
    final String owner => '$owner.$field',
  };

  /// The expression encoded in [json], or an [DbErrorCode.invalidRequest]
  /// error naming what does not follow the protocol.
  static Result<Expression, DbError> decode(Object? json) => switch (json) {
    {
      'op': final String op,
      'field': final String field,
      'value': final Object? value,
    }
        when ComparisonOperator.byWire.containsKey(op) =>
      Ok(Comparison(field, ComparisonOperator.byWire[op]!, value)),
    {
      'op': 'eq_any',
      'field': final String field,
      'values': final List<Object?> values,
    } =>
      Ok(Membership(field, [...values], negated: false)),
    {
      'op': 'ne_all',
      'field': final String field,
      'values': final List<Object?> values,
    } =>
      Ok(Membership(field, [...values], negated: true)),
    {'op': 'is_null', 'field': final String field} => Ok(
      NullCheck(field, isNull: true),
    ),
    {'op': 'is_not_null', 'field': final String field} => Ok(
      NullCheck(field, isNull: false),
    ),
    {
      'op': 'between',
      'field': final String field,
      'low': final Object? low,
      'high': final Object? high,
    } =>
      Ok(Range(field, low, high, negated: false)),
    {
      'op': 'not_between',
      'field': final String field,
      'low': final Object? low,
      'high': final Object? high,
    } =>
      Ok(Range(field, low, high, negated: true)),
    {
      'op': 'like',
      'field': final String field,
      'pattern': final String pattern,
    } =>
      Ok(LikePattern(field, pattern, caseInsensitive: false)),
    {
      'op': 'ilike',
      'field': final String field,
      'pattern': final String pattern,
    } =>
      Ok(LikePattern(field, pattern, caseInsensitive: true)),
    {'op': 'and', 'args': final List<Object?> args} => _decodeAll(
      args,
    ).map(And.new),
    {'op': 'or', 'args': final List<Object?> args} => _decodeAll(
      args,
    ).map(Or.new),
    {'op': 'not', 'arg': final Object? arg} => decode(arg).map(Not.new),
    _ => Err(
      DbError(DbErrorCode.invalidRequest, 'Not a valid expression: $json'),
    ),
  };

  static Result<List<Expression>, DbError> _decodeAll(List<Object?> args) {
    final decoded = <Expression>[];

    for (final arg in args) {
      switch (decode(arg)) {
        case Ok(:final data):
          decoded.add(data);
        case Err(:final error):
          return Err(error);
      }
    }

    return Ok(decoded);
  }

  @override
  bool operator ==(Object other) =>
      other is Expression && JsonValues.equals(toJson(), other.toJson());

  @override
  int get hashCode => JsonValues.canonical(toJson()).hashCode;

  @override
  String toString() => 'Expression(${toJson()})';
}

/// The operators of a [Comparison], named as in Diesel.
enum ComparisonOperator {
  /// `=`.
  eq('eq'),

  /// `<>`.
  ne('ne'),

  /// `>`.
  gt('gt'),

  /// `>=`.
  ge('ge'),

  /// `<`.
  lt('lt'),

  /// `<=`.
  le('le');

  const ComparisonOperator(this.wire);

  /// The `op` of the protocol.
  final String wire;

  /// Operators by their `op`.
  static final Map<String, ComparisonOperator> byWire = {
    for (final operator in values) operator.wire: operator,
  };
}

/// `field <operator> value`, with SQL semantics: a missing or `null` field,
/// or a value of another kind, never matches.
final class Comparison extends Expression {
  /// Compares [field] with the stored form of a value.
  const Comparison(this.field, this.operator, this.value, {this.table});

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// How the field compares with [value].
  final ComparisonOperator operator;

  /// The value, as stored (the column already encoded it).
  final Object? value;

  @override
  Map<String, Object?> toJson() => {
    'op': operator.wire,
    'field': field,
    'value': value,
  };
}

/// `field IN (values)` (`eq_any`), or `field NOT IN (values)` (`ne_all`) when
/// [negated]. A missing or `null` field matches neither.
final class Membership extends Expression {
  /// Matches [field] against [values].
  const Membership(
    this.field,
    this.values, {
    required this.negated,
    this.table,
  });

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// Candidate values, as stored.
  final List<Object?> values;

  /// `NOT IN` instead of `IN`.
  final bool negated;

  @override
  Map<String, Object?> toJson() => {
    'op': negated ? 'ne_all' : 'eq_any',
    'field': field,
    'values': values,
  };
}

/// `field IS NULL`, or `IS NOT NULL` when not [isNull]; a missing field is
/// `NULL`.
final class NullCheck extends Expression {
  /// Checks whether [field] is `null` or missing.
  const NullCheck(this.field, {required this.isNull, this.table});

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// Matches `null` or missing values (`true`) or present ones (`false`).
  final bool isNull;

  @override
  Map<String, Object?> toJson() => {
    'op': isNull ? 'is_null' : 'is_not_null',
    'field': field,
  };
}

/// `field BETWEEN low AND high` (both included), or `NOT BETWEEN` when
/// [negated]. The field must compare with both bounds to match either form.
final class Range extends Expression {
  /// Matches [field] against the bounds.
  const Range(
    this.field,
    this.low,
    this.high, {
    required this.negated,
    this.table,
  });

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// Lower bound, included, as stored.
  final Object? low;

  /// Upper bound, included, as stored.
  final Object? high;

  /// `NOT BETWEEN` instead of `BETWEEN`.
  final bool negated;

  @override
  Map<String, Object?> toJson() => {
    'op': negated ? 'not_between' : 'between',
    'field': field,
    'low': low,
    'high': high,
  };
}

/// `field LIKE pattern`, or `ILIKE` (ASCII case-insensitive) when
/// [caseInsensitive]. Only strings match.
final class LikePattern extends Expression {
  /// Matches the text of [field] against [pattern].
  const LikePattern(
    this.field,
    this.pattern, {
    required this.caseInsensitive,
    this.table,
  });

  /// Field path in the row.
  final String field;

  /// The table of the column that built it, if any; not sent to the engine
  /// (see [qualified]).
  final String? table;

  /// `%` matches any sequence, `_` exactly one character.
  final String pattern;

  /// Ignore the case of ASCII letters.
  final bool caseInsensitive;

  @override
  Map<String, Object?> toJson() => {
    'op': caseInsensitive ? 'ilike' : 'like',
    'field': field,
    'pattern': pattern,
  };
}

/// Every operand matches (`AND`); with no operand, every row matches.
final class And extends Expression {
  /// The conjunction of [operands].
  const And(this.operands);

  /// The conditions, all of which must match.
  final List<Expression> operands;

  @override
  List<Expression> get _conjuncts => operands;

  @override
  Map<String, Object?> toJson() => {
    'op': 'and',
    'args': [for (final operand in operands) operand.toJson()],
  };
}

/// At least one operand matches (`OR`); with no operand, no row matches.
final class Or extends Expression {
  /// The disjunction of [operands].
  const Or(this.operands);

  /// The alternatives, one of which must match.
  final List<Expression> operands;

  @override
  List<Expression> get _disjuncts => operands;

  @override
  Map<String, Object?> toJson() => {
    'op': 'or',
    'args': [for (final operand in operands) operand.toJson()],
  };
}

/// The operand does not match (`NOT`, two-valued: rows the operand does not
/// match, including those where its field is missing or `null`).
final class Not extends Expression {
  /// The negation of [operand].
  const Not(this.operand);

  /// The negated condition.
  final Expression operand;

  @override
  Map<String, Object?> toJson() => {'op': 'not', 'arg': operand.toJson()};
}
