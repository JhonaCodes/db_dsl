part of '../conformance.dart';

/// The examples of `PROTOCOL.md`, replayed request by request.
abstract final class _ProtocolCases {
  static List<ConformanceCase> get cases => [
    ConformanceCase(
      'protocol',
      'every example of PROTOCOL.md gets the documented answer',
      (host) async {
        final connection = Check.ok(
          await host.engine.open(await host.freshPath(), host.options),
          'open',
        );
        final captured = <String, Object?>{};

        for (final example in ProtocolExamples.scenario) {
          final wire = _substitute(example.request, captured);
          final answer = await ProtocolRequest.decode(wire).when(
            ok: connection.send,
            err: (error) async => Err<Map<String, Object?>, DbError>(error),
          );

          switch ((example.ok, example.errorCode)) {
            case (final Map<String, Object?> expected, _):
              final payload = Check.ok(answer, example.title);
              Check.isTrue(
                _matches(payload, expected, captured),
                '${example.title}: expected $expected, got $payload',
              );
            case (_, final String code):
              Check.fails(answer, DbErrorCode.fromWire(code), example.title);
            default:
              throw ConformanceFailure('${example.title} has no answer');
          }
        }

        await connection.close();
      },
    ),
  ];

  /// [json] with the captured values in place of their placeholders.
  static Object? _substitute(Object? json, Map<String, Object?> captured) =>
      switch (json) {
        final String placeholder
            when ProtocolExamples.placeholders.contains(placeholder) =>
          captured[placeholder],
        final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            key: _substitute(value, captured),
        },
        final List<Object?> list => [
          for (final item in list) _substitute(item, captured),
        ],
        _ => json,
      };

  /// Structural equality where [ProtocolExamples.any] matches any value,
  /// and a placeholder matches the value it captured, or captures it.
  static bool _matches(
    Object? actual,
    Object? expected,
    Map<String, Object?> captured,
  ) => switch ((actual, expected)) {
    (_, ProtocolExamples.any) => true,
    (_, final String placeholder)
        when ProtocolExamples.placeholders.contains(placeholder) =>
      _capture(captured, placeholder, actual),
    (final Map<String, Object?> a, final Map<String, Object?> e) =>
      a.length == e.length &&
          e.entries.every(
            (entry) =>
                a.containsKey(entry.key) &&
                _matches(a[entry.key], entry.value, captured),
          ),
    (final List<Object?> a, final List<Object?> e) =>
      a.length == e.length &&
          Iterable<int>.generate(
            a.length,
          ).every((i) => _matches(a[i], e[i], captured)),
    _ => actual == expected,
  };

  /// Captures [value] for [placeholder]. A `begin` answers a new
  /// transaction every time, so it always captures; other placeholders
  /// must keep the value they captured first.
  static bool _capture(
    Map<String, Object?> captured,
    String placeholder,
    Object? value,
  ) {
    if (placeholder == ProtocolExamples.transaction ||
        !captured.containsKey(placeholder)) {
      captured[placeholder] = value;
      return true;
    }

    return captured[placeholder] == value;
  }
}
