@TestOn('vm')
library;

import 'dart:io';

import 'package:db_dsl/conformance.dart';
import 'package:test/test.dart';

/// `PROTOCOL.md` shows exactly the examples the conformance suite replays,
/// so the document cannot drift from what engines do.
void main() {
  test('PROTOCOL.md contains every replayed example verbatim', () {
    final document = File('PROTOCOL.md').readAsStringSync();

    for (final example in ProtocolExamples.scenario) {
      expect(
        document.contains(example.markdown),
        isTrue,
        reason:
            'Missing or outdated: ${example.title}. '
            'Run `dart run tool/protocol_examples.dart`.',
      );
    }
  });
}
