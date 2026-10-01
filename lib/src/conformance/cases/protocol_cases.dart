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
        Object? transaction;

        for (final example in ProtocolExamples.scenario) {
          final wire = _substitute(example.request, transaction);
          final answer = await ProtocolRequest.decode(wire).when(
            ok: connection.send,
            err: (error) async => Err<Map<String, Object?>, DbError>(error),
          );

          switch ((example.ok, example.errorCode)) {
            case (final Map<String, Object?> expected, _):
              final payload = Check.ok(answer, example.title);
              if (expected['transaction'] == ProtocolExamples.transaction) {
                transaction = payload['transaction'];
              }
              Check.isTrue(
                _matches(payload, expected),
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

  /// [json] with the captured transaction id in place of its placeholder.
  static Object? _substitute(Object? json, Object? transaction) =>
      switch (json) {
        ProtocolExamples.transaction => transaction,
        final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            key: _substitute(value, transaction),
        },
        final List<Object?> list => [
          for (final item in list) _substitute(item, transaction),
        ],
        _ => json,
      };

  /// Structural equality where [ProtocolExamples.any] and
  /// [ProtocolExamples.transaction] match any value.
  static bool _matches(Object? actual, Object? expected) => switch ((
    actual,
    expected,
  )) {
    (_, ProtocolExamples.any || ProtocolExamples.transaction) => true,
    (final Map<String, Object?> a, final Map<String, Object?> e) =>
      a.length == e.length &&
          e.entries.every(
            (entry) =>
                a.containsKey(entry.key) && _matches(a[entry.key], entry.value),
          ),
    (final List<Object?> a, final List<Object?> e) =>
      a.length == e.length &&
          Iterable<int>.generate(a.length).every((i) => _matches(a[i], e[i])),
    _ => actual == expected,
  };
}
