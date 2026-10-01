/// The meaning of JSON values in the protocol: how they compare in filters,
/// how they sort, and how they become ordered keys.
///
/// Every engine of the protocol must follow these rules, so they are written
/// once here and mirrored by offline_first_core (`engine/value.rs` and
/// `engine/keys.rs`); [MemoryEngine] uses them directly.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The semantics of JSON values (`PROTOCOL.md`, "Values").
///
/// Why a class of static members: the rules are pure functions of their
/// arguments, shared by the DSL (expression equality) and by [MemoryEngine].
abstract final class JsonValues {
  /// Largest key the storage accepts, in bytes (LMDB's default).
  static const int maxKeySize = 511;

  /// The value at the dot-separated [path] of [row] (`'address.city'`), or
  /// `null` when a segment is missing or not inside an object.
  static Object? fieldAt(Object? row, String path) {
    Object? value = row;

    for (final segment in path.split('.')) {
      value = switch (value) {
        Map<String, Object?>() => value[segment],
        _ => null,
      };
    }

    return value;
  }

  /// Sets [value] at the dot-separated [path] of [row], creating objects on
  /// the way; `false` (and nothing set) when a segment on the way holds a
  /// value that is not an object.
  static bool setAt(Map<String, Object?> row, String path, Object? value) {
    final segments = path.split('.');
    var target = row;

    for (final segment in segments.take(segments.length - 1)) {
      switch (target.putIfAbsent(segment, () => <String, Object?>{})) {
        case final Map<String, Object?> nested:
          target = nested;
        default:
          return false;
      }
    }

    target[segments.last] = value;
    return true;
  }

  /// Structural equality of decoded JSON values (`1` and `1.0` differ here,
  /// unlike in [sqlCompare]).
  static bool equals(Object? a, Object? b) => switch ((a, b)) {
    (final Map<String, Object?> x, final Map<String, Object?> y) =>
      x.length == y.length &&
          x.entries.every(
            (entry) =>
                y.containsKey(entry.key) && equals(entry.value, y[entry.key]),
          ),
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          Iterable<int>.generate(x.length).every((i) => equals(x[i], y[i])),
    _ => a == b,
  };

  /// Comparison in filters (SQL semantics): only values of the same kind
  /// compare — numbers with numbers (by value, `-0.0` equals `0`), strings
  /// with strings (by Unicode code point), booleans with booleans. Arrays and
  /// objects are only equal or not comparable. `null` compares with nothing.
  ///
  /// Returns a negative number, zero or a positive number, or `null` when the
  /// values are not comparable (every comparison with them is then false).
  static int? sqlCompare(Object? a, Object? b) => switch ((a, b)) {
    (final num x, final num y) => _compareNumbers(x, y),
    (final String x, final String y) => _compareStrings(x, y),
    (final bool x, final bool y) => _compareBools(x, y),
    (List<Object?>(), List<Object?>()) ||
    (Map<String, Object?>(), Map<String, Object?>()) => equals(a, b) ? 0 : null,
    _ => null,
  };

  /// Total order used by `order` and by index keys:
  /// `null < false < true < numbers < strings < arrays < objects`; inside a
  /// kind, numbers by value, strings by code point, arrays and objects by
  /// their canonical JSON.
  static int totalCompare(Object? a, Object? b) {
    final byKind = kindRank(a).compareTo(kindRank(b));

    if (byKind != 0) {
      return byKind;
    }

    return switch ((a, b)) {
      (final num x, final num y) => _compareNumbers(x, y),
      (final String x, final String y) => _compareStrings(x, y),
      (List<Object?>(), List<Object?>()) ||
      (
        Map<String, Object?>(),
        Map<String, Object?>(),
      ) => _compareBytes(utf8.encode(canonical(a)), utf8.encode(canonical(b))),
      _ => 0,
    };
  }

  /// Rank of the kind of [value] in the total order; also the first byte of
  /// its key encoding.
  static int kindRank(Object? value) => switch (value) {
    null => 1,
    false => 2,
    true => 3,
    num() => 4,
    String() => 5,
    List<Object?>() => 6,
    _ => 7,
  };

  /// `LIKE` matching: `%` matches any sequence, `_` exactly one character;
  /// with [caseInsensitive], ASCII letters match regardless of case (`ILIKE`).
  static bool like(
    String text,
    String pattern, {
    bool caseInsensitive = false,
  }) {
    List<int> normalize(String value) => [
      for (final rune in value.runes)
        caseInsensitive && rune >= 0x41 && rune <= 0x5A ? rune + 32 : rune,
    ];

    final chars = normalize(text);
    final wildcards = normalize(pattern);
    var t = 0;
    var p = 0;
    int? starPattern;
    var starText = 0;

    // Iterative wildcard matching with backtracking to the last `%`.
    while (t < chars.length) {
      final current = p < wildcards.length ? wildcards[p] : null;

      switch (current) {
        case 0x25:
          starPattern = p;
          starText = t;
          p++;
        case 0x5F:
          t++;
          p++;
        case final int rune when rune == chars[t]:
          t++;
          p++;
        default:
          if (starPattern == null) {
            return false;
          }
          p = starPattern + 1;
          starText++;
          t = starText;
      }
    }

    return wildcards.skip(p).every((rune) => rune == 0x25);
  }

  /// Canonical JSON of [value]: compact, with object keys sorted.
  static String canonical(Object? value) => jsonEncode(_sorted(value));

  /// The order-preserving key of [value]: byte order of keys is the
  /// [totalCompare] order of values, and every key is self-delimiting, so a
  /// composite key is the concatenation of its parts.
  ///
  /// | Value | Encoding |
  /// |---|---|
  /// | `null` | `0x01` |
  /// | `false` / `true` | `0x02` / `0x03` |
  /// | number | `0x04` + the `f64` value in 8 order-preserving bytes |
  /// | string | `0x05` + UTF-8, `0x00` escaped as `0x00 0xFF`, then `0x00 0x00` |
  /// | array / object | `0x06` / `0x07` + canonical JSON escaped like a string |
  ///
  /// Numbers go through `f64`, so integers beyond ±2^53 that round to the
  /// same `f64` share a key.
  static Uint8List encodeKey(Iterable<Object?> values) {
    final out = BytesBuilder(copy: false);

    for (final value in values) {
      out.addByte(kindRank(value));

      switch (value) {
        case final num number:
          out.add(_orderedFloat(number.toDouble()));
        case final String text:
          _addEscaped(out, utf8.encode(text));
        case List<Object?>() || Map<String, Object?>():
          _addEscaped(out, utf8.encode(canonical(value)));
        default:
          break;
      }
    }

    return out.takeBytes();
  }

  /// Compares two keys byte by byte, like LMDB's default comparator.
  static int compareKeys(List<int> a, List<int> b) => _compareBytes(a, b);

  /// `<` and `>` are exact between two integers and compare as doubles
  /// otherwise, like the Rust engine. `compareTo` is not used: it orders
  /// `-0.0` before `0`, and on the web `-0.0` is an `int`.
  static int _compareNumbers(final num x, final num y) => switch (x) {
    _ when x < y => -1,
    _ when x > y => 1,
    _ => 0,
  };

  static int _compareBools(final bool x, final bool y) => switch ((x, y)) {
    (false, true) => -1,
    (true, false) => 1,
    _ => 0,
  };

  /// Code point order, which is the byte order of UTF-8 (and of the Rust
  /// engine); Dart's own `compareTo` orders UTF-16 code units instead.
  static int _compareStrings(final String x, final String y) =>
      _compareBytes(x.runes.toList(), y.runes.toList());

  static int _compareBytes(List<int> a, List<int> b) {
    final shared = a.length < b.length ? a.length : b.length;

    for (var i = 0; i < shared; i++) {
      final order = a[i].compareTo(b[i]);

      if (order != 0) {
        return order;
      }
    }

    return a.length.compareTo(b.length);
  }

  static Object? _sorted(Object? value) => switch (value) {
    Map<String, Object?>() => {
      for (final key in value.keys.toList()..sort(_compareStrings))
        key: _sorted(value[key]),
    },
    List<Object?>() => [for (final item in value) _sorted(item)],
    _ => value,
  };

  /// The 8 bytes whose unsigned order is the numeric order of [value]:
  /// negative numbers have every bit flipped, the others only the sign bit.
  /// Split in 32-bit halves so it also runs where 64-bit integers do not
  /// (the web).
  static Uint8List _orderedFloat(double value) {
    final bytes = ByteData(8)..setFloat64(0, value == 0 ? 0.0 : value);
    final negative = bytes.getUint8(0) & 0x80 != 0;

    for (var i = 0; i < 8; i++) {
      final byte = bytes.getUint8(i);
      bytes.setUint8(i, switch ((negative, i)) {
        (true, _) => ~byte & 0xFF,
        (false, 0) => byte | 0x80,
        (false, _) => byte,
      });
    }

    return bytes.buffer.asUint8List();
  }

  static void _addEscaped(BytesBuilder out, List<int> bytes) {
    for (final byte in bytes) {
      out.addByte(byte);

      if (byte == 0) {
        out.addByte(0xFF);
      }
    }

    out
      ..addByte(0)
      ..addByte(0);
  }
}
