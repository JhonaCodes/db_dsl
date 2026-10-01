import 'package:db_dsl/conformance.dart';
import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// The whole conformance suite against [MemoryEngine]: the reference
/// behavior every native engine is checked against too.
void main() {
  var next = 0;
  final host = ConformanceHost(MemoryEngine(), () async => 'db-${next++}');

  for (final ConformanceCase(:group, :name, :run) in Conformance.cases) {
    test('$group: $name', () => run(host));
  }
}
