/// Writes the examples section of `PROTOCOL.md` from
/// `ProtocolExamples.scenario`, the same data the conformance suite replays.
///
/// ```sh
/// dart run tool/protocol_examples.dart
/// ```
library;

import 'dart:io';

import 'package:db_dsl/conformance.dart';

Future<void> main() async {
  final document = File('PROTOCOL.md');
  final text = await document.readAsString();
  final start = text.indexOf(ExamplesSection.start);
  final end = text.indexOf(ExamplesSection.end);

  if (start < 0 || end < start) {
    stderr.writeln('PROTOCOL.md has no examples markers');
    exitCode = 1;
    return;
  }

  await document.writeAsString(
    text.replaceRange(
      start,
      end + ExamplesSection.end.length,
      ExamplesSection.render(),
    ),
  );
  stdout.writeln('PROTOCOL.md: ${ProtocolExamples.scenario.length} examples');
}

/// The generated part of `PROTOCOL.md`.
abstract final class ExamplesSection {
  /// Where the section starts.
  static const String start = '<!-- examples:start -->';

  /// Where the section ends.
  static const String end = '<!-- examples:end -->';

  /// The section, markers included.
  static String render() => [
    start,
    '',
    for (final example in ProtocolExamples.scenario) example.markdown,
    end,
  ].join('\n');
}
