import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';

/// The API of `package:db_dsl` the plugin reads, with its real signatures,
/// for the analyzed test code to import.
abstract final class DbDslPackage {
  /// Adds `package:db_dsl` to the test's package configuration.
  static void addTo(AnalysisRuleTest test) =>
      test.newPackage('db_dsl').addFile('lib/db_dsl.dart', _source);

  /// Gives the mock SDK's `DateTime` the epoch members of the real one,
  /// which the fields of a date stored as a number use. Call it after
  /// `super.setUp()`, which writes the mock SDK.
  ///
  /// Why: without them the code the plugin writes has an error that only
  /// the mock SDK has, and the tests could not expect no diagnostic at all.
  static void completeSdk(AnalysisRuleTest test) {
    final core = test.sdkRoot
        .getFolder('lib')
        .getFolder('core')
        .getFile('core.dart');
    const anchor = '  external int get millisecondsSinceEpoch;\n';
    final source = core.readAsStringSync();

    if (!source.contains(anchor)) {
      throw StateError('The mock SDK changed: its DateTime has no $anchor');
    }

    core.writeAsStringSync(
      source.replaceFirst(
        anchor,
        '$anchor'
        '  external int get microsecondsSinceEpoch;\n'
        '  external DateTime.fromMillisecondsSinceEpoch(int ms, {bool isUtc = false});\n'
        '  external DateTime.fromMicrosecondsSinceEpoch(int us, {bool isUtc = false});\n',
      ),
    );
  }

  static const String _source = r'''
final class Field<V extends Object> {
  const Field(
    this.name, {
    this.table,
    Object? Function(V value)? encode,
    V? Function(Object stored)? decode,
  });

  final String name;
  final String? table;

  Object eq(V value) => this;
}

final class Index {
  const Index(this.fields, {String? name});
  const Index.unique(this.fields, {String? name});

  final List<String> fields;
}

final class DbTable<T> {
  DbTable(
    this.tableName, {
    required String key,
    required T Function(Map<String, Object?> json) fromJson,
    Map<String, Object?> Function(T row)? toJson,
    bool autoIncrement = false,
    List<Index> indexes = const [],
  });

  final String tableName;

  Field<V> field<V extends Object>(
    String name, {
    Object? Function(V value)? encode,
    V? Function(Object stored)? decode,
  }) => Field<V>(name, table: tableName, encode: encode, decode: decode);
}
''';
}

/// The offset and length of [snippet] in [code], for expected diagnostics.
extension type const Source(String code) {
  /// Where [snippet] starts (its first occurrence, or the [nth]).
  int offsetOf(String snippet, [int nth = 0]) {
    var offset = -1;

    for (var i = 0; i <= nth; i++) {
      offset = code.indexOf(snippet, offset + 1);
    }

    if (offset < 0) {
      throw ArgumentError('`$snippet` is not in the test code');
    }

    return offset;
  }
}
