/// Fixes for a single wrong field.
library;

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

import '../model/db_dsl_types.dart';
import '../model/stored_fields.dart';

/// Fix for `unknown_field` and `unknown_key`: replaces the name with the
/// stored field closest to it ("Did you mean 'done'?").
final class UseClosestField extends ResolvedCorrectionProducer {
  /// A fix for the diagnostic of the context.
  UseClosestField({required super.context});

  static const FixKind _kind = FixKind(
    'db_dsl.fix.useClosestField',
    DartFixKindPriority.standard,
    "Use '{0}'",
  );

  String _closest = '';

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  List<String> get fixArguments => [_closest];

  @override
  Future<void> compute(ChangeBuilder builder) async {
    final literal = node;
    final table = literal.thisOrAncestorOfType<InstanceCreationExpression>();
    final call = literal.thisOrAncestorOfType<MethodInvocation>();
    final model = switch ((call, table)) {
      (final MethodInvocation field, _)
          when DbDslTypes.modelOfFieldCall(field) != null =>
        DbDslTypes.modelOfFieldCall(field),
      (_, final InstanceCreationExpression creation) =>
        DbDslTypes.modelOfCreation(creation),
      _ => null,
    };

    final missing = switch ((literal, model)) {
      (final SimpleStringLiteral name, final model?) => StoredFields.of(
        model,
        typeSystem,
      )?.lookup(name.value, typeSystem),
      _ => null,
    };

    if ((literal, missing) case (
      final SimpleStringLiteral name,
      MissingPath(:final segment, closest: final String closest),
    )) {
      _closest = closest;
      final replaced = name.value.replaceFirst(segment, closest);

      await builder.addDartFileEdit(file, (edit) {
        edit.addSimpleReplacement(range.node(name), "'$replaced'");
      });
    }
  }
}

/// Fix for `field_type_mismatch`: writes the stored type into the field's
/// `Field<V>` (the getter's return type, or the explicit type argument).
final class UseStoredType extends ResolvedCorrectionProducer {
  /// A fix for the diagnostic of the context.
  UseStoredType({required super.context});

  static const FixKind _kind = FixKind(
    'db_dsl.fix.useStoredType',
    DartFixKindPriority.standard,
    'Use the type the model stores',
  );

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    final call = node.thisOrAncestorOfType<MethodInvocation>();
    final model = switch (call) {
      final MethodInvocation field => DbDslTypes.modelOfFieldCall(field),
      null => null,
    };
    final path = call?.argumentList.arguments.firstOrNull;

    final stored = switch ((model, path)) {
      (final model?, final SimpleStringLiteral name) => switch (StoredFields.of(
        model,
        typeSystem,
      )?.lookup(name.value, typeSystem)) {
        FoundPath(:final field) => field.type,
        _ => null,
      },
      _ => null,
    };

    final annotation = switch (call) {
      MethodInvocation(
        typeArguments: TypeArgumentList(arguments: [final explicit]),
      ) =>
        explicit,
      final MethodInvocation field => switch (field.parent) {
        ExpressionFunctionBody(
          parent: MethodDeclaration(
            returnType: NamedType(
              typeArguments: TypeArgumentList(arguments: [final returned]),
            ),
          ),
        ) =>
          returned,
        _ => null,
      },
      null => null,
    };

    if ((stored, annotation) case (final type?, final TypeAnnotation old)) {
      await builder.addDartFileEdit(file, (edit) {
        edit.addReplacement(range.node(old), (write) => write.writeType(type));
      });
    }
  }
}
