/// Typed fields of the rows of a table: the building blocks of filters, sort
/// keys and typed reads.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../query/expression.dart';
import '../query/ordering.dart';
import 'json_convention.dart';

/// A field of the rows of a table, compared and read as values of [V].
///
/// ```dart
/// final city = users.field<String>('city');
/// final joined = users.field<DateTime>('joined');
/// final price = products.field<Money>(
///   'price',
///   encode: (money) => money.cents,
///   decode: (stored) => Money(stored as int),
/// );
///
/// await users.filter(city.eq('Lima').and(joined.gt(DateTime.utc(2024))));
/// ```
///
/// Its operators follow Diesel: [eq], [ne], [gt], [ge], [lt], [le], [eqAny],
/// [neAll], [isNull], [isNotNull], [between], [notBetween]; text fields add
/// `like` and `ilike`.
///
/// Why one class for every type: the model decides how each value is
/// stored (its `toJson`), so a field only has to write a value of [V] the
/// same way. By default it follows Dart's JSON convention, as the model
/// does: strings, numbers and booleans as they are, a `DateTime` as ISO
/// 8601 (`toIso8601String`), an enum by its `name`, any other object
/// through its `toJson()`. [encode] and [decode] cover a model that stores
/// a value another way.
final class Field<V extends Object> {
  /// The field at [name] (a path: `'address.city'` reaches a nested value)
  /// of the rows of [table].
  const Field(
    this.name, {
    this.table,
    Object? Function(V value)? encode,
    V? Function(Object stored)? decode,
  }) : _encoder = encode,
       _decoder = decode;

  /// Field path in the row.
  final String name;

  /// The table of the field (set by `DbTable.field`); joins use it to
  /// qualify paths (`'users.name'`).
  final String? table;

  final Object? Function(V value)? _encoder;
  final V? Function(Object stored)? _decoder;

  /// The path of the field inside a combined join row.
  String get qualifiedName => switch (table) {
    null => name,
    final String owner => '$owner.$name',
  };

  /// The stored (JSON) form of [value]: what the model writes for it.
  Object? encode(V value) => switch (_encoder) {
    final Object? Function(V value) encoder => encoder(value),
    null => JsonConvention.value(value),
  };

  /// The stored form of a primary key given as [key]; a key of another Dart
  /// type is sent in its JSON form, and then simply matches no row.
  Object? encodeKey(Object key) => switch (key) {
    final V value => encode(value),
    _ => JsonConvention.value(key),
  };

  /// The value of [V] a [stored] one holds, or [DbErrorCode.rowMapping]
  /// when it holds none (another type, or a type that needs [decode]).
  Result<V, DbError> decode(Object? stored) => switch (_read(stored)) {
    final V value => Ok(value),
    null => Err(
      DbError(
        DbErrorCode.rowMapping,
        'Field `$name` cannot read the stored value $stored as $V'
        '${_decoder == null ? '; pass `decode:` to read it' : ''}',
      ),
    ),
  };

  V? _read(Object? stored) {
    if (stored == null) {
      return null;
    }

    try {
      return switch (_decoder) {
        final V? Function(Object stored) decoder => decoder(stored),
        null => _Stored.read<V>(stored),
      };
    } on Object {
      return null;
    }
  }

  /// `this = value`.
  Expression eq(V value) =>
      Comparison(name, ComparisonOperator.eq, encode(value), table: table);

  /// `this <> value`.
  Expression ne(V value) =>
      Comparison(name, ComparisonOperator.ne, encode(value), table: table);

  /// `this > value`.
  Expression gt(V value) =>
      Comparison(name, ComparisonOperator.gt, encode(value), table: table);

  /// `this >= value`.
  Expression ge(V value) =>
      Comparison(name, ComparisonOperator.ge, encode(value), table: table);

  /// `this < value`.
  Expression lt(V value) =>
      Comparison(name, ComparisonOperator.lt, encode(value), table: table);

  /// `this <= value`.
  Expression le(V value) =>
      Comparison(name, ComparisonOperator.le, encode(value), table: table);

  /// `this IN (values)`; an empty list matches no row.
  Expression eqAny(Iterable<V> values) => Membership(
    name,
    [for (final value in values) encode(value)],
    negated: false,
    table: table,
  );

  /// `this NOT IN (values)`; an empty list matches every row with a value.
  Expression neAll(Iterable<V> values) => Membership(
    name,
    [for (final value in values) encode(value)],
    negated: true,
    table: table,
  );

  /// `this IS NULL`: the field is `null` or missing.
  Expression isNull() => NullCheck(name, isNull: true, table: table);

  /// `this IS NOT NULL`.
  Expression isNotNull() => NullCheck(name, isNull: false, table: table);

  /// `this BETWEEN low AND high`, both included.
  Expression between(V low, V high) =>
      Range(name, encode(low), encode(high), negated: false, table: table);

  /// `this NOT BETWEEN low AND high`.
  Expression notBetween(V low, V high) =>
      Range(name, encode(low), encode(high), negated: true, table: table);

  /// Ascending sort key.
  OrderingTerm asc() => OrderingTerm(name, table: table);

  /// Descending sort key.
  OrderingTerm desc() => OrderingTerm(name, descending: true, table: table);

  @override
  String toString() => 'Field<$V>($qualifiedName)';
}

/// Pattern matching, for text fields.
extension TextFieldPatterns on Field<String> {
  /// `this LIKE pattern`: `%` matches any sequence, `_` exactly one character.
  Expression like(String pattern) =>
      LikePattern(name, pattern, caseInsensitive: false, table: table);

  /// `this ILIKE pattern`: like [like], ignoring the case of ASCII letters.
  Expression ilike(String pattern) =>
      LikePattern(name, pattern, caseInsensitive: true, table: table);
}

/// Reading stored values back as Dart values, by the same convention.
abstract final class _Stored {
  /// The value of [V] in [stored]: the value itself, an integer for a
  /// `double`, or an ISO 8601 text for a `DateTime`; `null` otherwise.
  static V? read<V extends Object>(Object stored) => switch (stored) {
    final V value => value,
    final int number when V == double => number.toDouble() as V,
    final String text when V == DateTime => DateTime.tryParse(text) as V?,
    _ => null,
  };
}
