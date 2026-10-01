/// How the models of an app become JSON: Dart's own convention.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';

/// Dart's JSON convention, the one `jsonEncode` and the models of an app
/// follow: primitives as they are, lists and maps element by element, any
/// other object through its `toJson()`. A `DateTime` becomes ISO 8601 and an
/// enum its `name`, as json_serializable writes them (`jsonEncode` alone
/// refuses both).
///
/// Why db_dsl follows it instead of its own format: a table stores the model
/// the app already has, so a row is stored exactly as the model writes
/// itself, and a filter value is encoded exactly as the model would write it.
abstract final class JsonConvention {
  /// [value] in its JSON form.
  ///
  /// Throws [ArgumentError] when [value] has no JSON form: filter values
  /// are code, so that is a bug to fix, not an outcome.
  static Object? value(Object? value) => switch (value) {
    null || String() || bool() => value,
    final double number when !number.isFinite => throw ArgumentError.value(
      number,
      'value',
      'JSON has no infinity nor NaN',
    ),
    num() => value,
    final List<Object?> list => [
      for (final item in list) JsonConvention.value(item),
    ],
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, value: item) in map.entries)
        _key(key): JsonConvention.value(item),
    },
    final DateTime date => date.toIso8601String(),
    final Enum item => item.name,
    final Object object => JsonConvention.value(_toJson(object)),
  };

  /// The `toJson()` of [object], the method `jsonEncode` calls: Dart's
  /// convention for any class, which needs no interface of db_dsl.
  static Object? _toJson(Object object) {
    try {
      // The convention is by name, as in `jsonEncode`: there is no type to
      // check it against.
      // ignore: avoid_dynamic_calls
      return (object as dynamic).toJson();
    } on NoSuchMethodError {
      throw ArgumentError.value(
        object,
        'value',
        'has no JSON form (no toJson())',
      );
    }
  }

  /// The JSON object [row] produces, or [DbErrorCode.rowMapping] when it
  /// has no JSON form: a row is data, so it answers an error, never throws.
  static Result<Map<String, Object?>, DbError> object(
    Object? Function() row,
    String table,
  ) {
    try {
      return switch (value(row())) {
        final Map<String, Object?> json => Ok(json),
        final other => Err(
          DbError(
            DbErrorCode.rowMapping,
            '`$table` stores JSON objects, and a row became $other',
          ),
        ),
      };
    } on Object catch (error) {
      return Err(
        DbError(
          DbErrorCode.rowMapping,
          '`$table` cannot store a row ($error): give the model a toJson(), '
          'or pass `toJson:` to its DbTable',
        ),
      );
    }
  }

  static String _key(Object? key) => switch (key) {
    final String text => text,
    _ => throw ArgumentError.value(key, 'key', 'JSON keys are strings'),
  };
}
