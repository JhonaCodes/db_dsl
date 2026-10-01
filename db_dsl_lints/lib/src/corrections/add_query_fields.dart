/// The assist and the fix that write the typed fields of a table.
library;

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer_plugin/utilities/assist/assist.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

import 'query_fields.dart';

/// Assist "Write the fields of T": on a `DbTable<T>(...)` or on its
/// `extension <T>Fields`, writes (or rewrites) one typed getter per field
/// the model stores, so queries read `t.done.eq(false)`.
///
/// Why an assist: the fields come from the model, so nobody should type
/// them; the IDE writes them once, and again when the model changes.
final class AddQueryFields extends ResolvedCorrectionProducer {
  /// An assist at the context's selection.
  AddQueryFields({required super.context});

  static const AssistKind _kind = AssistKind(
    'db_dsl.assist.writeQueryFields',
    30,
    'Write the query fields of the table',
  );

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  AssistKind get assistKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    if (QueryFields.at(node, unit, typeSystem) case final QueryFields fields) {
      await builder.addDartFileEdit(file, fields.write);
    }
  }
}

/// Fix for `unknown_field` inside a `<T>Fields` extension (a field of the
/// model was renamed or removed) and for `missing_query_fields` on a table
/// (no extension yet, or the model gained a field): the extension is
/// written again from the model.
final class RewriteQueryFields extends ResolvedCorrectionProducer {
  /// A fix for the diagnostic of the context.
  RewriteQueryFields({required super.context});

  static const FixKind _kind = FixKind(
    'db_dsl.fix.rewriteQueryFields',
    DartFixKindPriority.standard,
    'Write the query fields from the model',
  );

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    if (QueryFields.at(node, unit, typeSystem) case final QueryFields fields) {
      await builder.addDartFileEdit(file, fields.write);
    }
  }
}
