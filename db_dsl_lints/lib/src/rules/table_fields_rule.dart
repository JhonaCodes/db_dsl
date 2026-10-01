/// The rule that checks every field of a db_dsl table against its model.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../model/db_dsl_types.dart';
import '../model/stored_fields.dart';

/// Checks the fields of `DbTable<T>` against the fields `T` stores:
///
/// - `unknown_field`: `field('dne')`, or `Index(['dne'])`, names a field the
///   model does not store;
/// - `field_type_mismatch`: `Field<int> get done => field('done')` when the
///   model stores `done` as a `bool`;
/// - `unknown_key`: the `key:` of a table is not a stored field;
/// - `missing_query_fields`: the model stores fields its table does not
///   expose as typed getters yet (no `<T>Fields` extension, or the model
///   gained a field); its fix writes them.
///
/// Why errors: a field name is a string the compiler cannot check, and a
/// wrong one silently matches no row. Reading the model's `toJson` gives the
/// compiler that check back, without reflection or generated code.
///
/// Why a warning for missing fields: the getters are written by the IDE,
/// not by hand, and plugin fixes cannot run on save or in `dart fix`; the
/// warning is what makes the IDE offer them the moment the model changes.
///
/// Why silence when unsure: a model whose `toJson` is built at run time
/// cannot be read; then nothing is reported, never a false positive.
final class TableFieldsRule extends MultiAnalysisRule {
  /// The rule.
  TableFieldsRule()
    : super(
        name: 'db_dsl_table_fields',
        description:
            'Checks the fields of db_dsl tables against the fields their '
            'models store.',
      );

  /// A field the model does not store.
  static const LintCode unknownField = LintCode(
    'unknown_field',
    "'{0}' is not a field that '{1}' stores.",
    correctionMessage: '{2}',
    severity: DiagnosticSeverity.ERROR,
  );

  /// A field read as another type than the model stores.
  static const LintCode fieldTypeMismatch = LintCode(
    'field_type_mismatch',
    "'{0}' is stored as a '{1}', not as a '{2}'.",
    correctionMessage: "Use Field<{1}>, or pass 'encode' and 'decode'.",
    severity: DiagnosticSeverity.ERROR,
  );

  /// A table key the model does not store.
  static const LintCode unknownKey = LintCode(
    'unknown_key',
    "The key '{0}' is not a field that '{1}' stores.",
    correctionMessage: '{2}',
    severity: DiagnosticSeverity.ERROR,
  );

  /// Fields the model stores that its table does not expose as getters.
  static const LintCode missingQueryFields = LintCode(
    'missing_query_fields',
    "'{0}' stores fields its table cannot query: {1}.",
    correctionMessage:
        "Use the quick fix 'Write the query fields from the "
        "model'.",
    severity: DiagnosticSeverity.WARNING,
  );

  @override
  List<DiagnosticCode> get diagnosticCodes => [
    unknownField,
    fieldTypeMismatch,
    unknownKey,
    missingQueryFields,
  ];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(this, context);
    registry
      ..addMethodInvocation(this, visitor)
      ..addInstanceCreationExpression(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.context);

  final TableFieldsRule rule;
  final RuleContext context;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final model = DbDslTypes.modelOfFieldCall(node);
    final path = node.argumentList.arguments.firstOrNull;

    if (model == null || path is! SimpleStringLiteral) {
      return;
    }

    final fields = StoredFields.of(model, context.typeSystem);

    switch (fields?.lookup(path.value, context.typeSystem)) {
      case final MissingPath missing:
        _reportMissing(TableFieldsRule.unknownField, path, model, missing);
      case FoundPath(:final field) when _checksType(node):
        _checkType(node, path.value, field);
      case _:
        break;
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final model = DbDslTypes.modelOfCreation(node);

    if (model == null) {
      return;
    }

    final arguments = node.argumentList;
    final fields = switch (DbDslTypes.namedArgument(arguments, 'toJson')) {
      final Expression toJson => StoredFields.ofFunction(
        toJson,
        model,
        context.typeSystem,
      ),
      null => StoredFields.of(model, context.typeSystem),
    };

    if (fields == null) {
      return;
    }

    _checkWritten(node, model, fields);

    if (DbDslTypes.namedArgument(arguments, 'key')
        case final SimpleStringLiteral key
        when fields.lookup(key.value, context.typeSystem) is MissingPath) {
      _reportMissing(
        TableFieldsRule.unknownKey,
        key,
        model,
        fields.lookup(key.value, context.typeSystem) as MissingPath,
      );
    }

    for (final name in _indexFields(
      DbDslTypes.namedArgument(arguments, 'indexes'),
    )) {
      if (fields.lookup(name.value, context.typeSystem)
          case final MissingPath missing) {
        _reportMissing(TableFieldsRule.unknownField, name, model, missing);
      }
    }
  }

  /// Reports the stored fields no extension on `DbTable<T>` visible here
  /// exposes, in the order the model stores them.
  void _checkWritten(
    InstanceCreationExpression node,
    InterfaceType model,
    StoredFields fields,
  ) {
    final written = DbDslTypes.queryFieldsOf(model, node);
    final missing = [
      for (final StoredField(:member, :type) in fields.byKey.values)
        if ((member, type) case (
          final String getter,
          _?,
        ) when !written.contains(getter))
          getter,
    ];

    if (missing.isNotEmpty) {
      rule.reportAtNode(
        node.constructorName,
        diagnosticCode: TableFieldsRule.missingQueryFields,
        arguments: [model.element.name ?? '', missing.join(', ')],
      );
    }
  }

  /// A `field<V>(...)` with its own `encode` or `decode` stores `V` its own
  /// way: its type is not the model's to check.
  static bool _checksType(MethodInvocation node) =>
      DbDslTypes.namedArgument(node.argumentList, 'encode') == null &&
      DbDslTypes.namedArgument(node.argumentList, 'decode') == null;

  void _checkType(MethodInvocation node, String path, StoredField field) {
    final stored = field.type;
    final read = DbDslTypes.valueOfField(node.staticType);
    final types = context.typeSystem;

    if (stored == null || read == null) {
      return;
    }

    final same =
        types.isSubtypeOf(stored, read) && types.isSubtypeOf(read, stored);

    if (!same) {
      rule.reportAtNode(
        node,
        diagnosticCode: TableFieldsRule.fieldTypeMismatch,
        arguments: [path, stored.getDisplayString(), read.getDisplayString()],
      );
    }
  }

  void _reportMissing(
    LintCode code,
    AstNode node,
    InterfaceType model,
    MissingPath missing,
  ) => rule.reportAtNode(
    node,
    diagnosticCode: code,
    arguments: [
      missing.segment,
      missing.model,
      switch (missing.closest) {
        final String closest => "Did you mean '$closest'?",
        null => 'Stored fields: ${missing.known.join(', ')}.',
      },
    ],
  );

  /// The field names written in `indexes: [Index([...]), ...]`.
  static Iterable<SimpleStringLiteral> _indexFields(Expression? indexes) => [
    if (indexes case ListLiteral(:final elements))
      for (final index in elements)
        if (index case InstanceCreationExpression(
          argumentList: ArgumentList(
            arguments: [ListLiteral(elements: final names), ...],
          ),
        ) when DbDslTypes.isFromDbDsl(index.constructorName.type.element))
          for (final name in names)
            if (name is SimpleStringLiteral) name,
  ];
}
