/// The conformance suite of the db_dsl protocol.
///
/// Every engine of the protocol must pass it: [MemoryEngine] in db_dsl, the
/// native engines of flutter_local_db and dart_db, and any third-party
/// translator. The suite does not depend on a test framework; wrap each
/// case in your framework's `test`:
///
/// ```dart
/// import 'package:db_dsl/conformance.dart';
/// import 'package:test/test.dart';
///
/// void main() {
///   final host = ConformanceHost(MyEngine(), () async => freshPath());
///
///   for (final ConformanceCase(:group, :name, :run) in Conformance.cases) {
///     test('$group: $name', () => run(host));
///   }
/// }
/// ```
library;

export 'src/conformance/conformance.dart' show Conformance, ConformanceCase;
export 'src/conformance/conformance_support.dart';
export 'src/conformance/protocol_examples.dart';
