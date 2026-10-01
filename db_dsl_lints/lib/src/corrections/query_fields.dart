/// Writing the typed fields of a table from its model.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';

import '../model/db_dsl_types.dart';
import '../model/stored_fields.dart';

/// The `extension <T>Fields on DbTable<T>` of a model: one getter per
/// stored field, with its Dart name and type, so queries read
/// `t.done.eq(false)`.
///
/// Why one place: the assist that adds the fields and the fix that
/// regenerates them after the model changed must write the same thing.
final class QueryFields {
  QueryFields._(this.model, this.fields, this.target);

  /// The model of the table.
  final InterfaceType model;

  /// What the model stores.
  final StoredFields fields;

  /// Where the extension goes: the range of the current one, or an empty
  /// range after the model (or at the end of the file).
  final SourceRange target;

  /// The fields for the table [node] belongs to (a `DbTable<T>(...)`
  /// creation or an extension on `DbTable<T>`), or `null` when [node] is not
  /// in one or the model cannot be read.
  static QueryFields? at(AstNode node, CompilationUnit unit, TypeSystem types) {
    final creation = node.thisOrAncestorOfType<InstanceCreationExpression>();
    final extension = node.thisOrAncestorOfType<ExtensionDeclaration>();
    final model = switch ((creation, extension)) {
      (final InstanceCreationExpression table, _)
          when DbDslTypes.modelOfCreation(table) != null =>
        DbDslTypes.modelOfCreation(table),
      (_, final ExtensionDeclaration declared) => DbDslTypes.modelOfTable(
        declared.onClause?.extendedType.type,
      ),
      _ => null,
    };

    final toJson = switch (creation) {
      final InstanceCreationExpression table => DbDslTypes.namedArgument(
        table.argumentList,
        'toJson',
      ),
      null => null,
    };

    final fields = switch ((model, toJson)) {
      (final InterfaceType type, final Expression function) =>
        StoredFields.ofFunction(function, type, types),
      (final InterfaceType type, null) => StoredFields.of(type, types),
      _ => null,
    };

    return switch ((model, fields)) {
      (final InterfaceType type, final StoredFields stored) => switch (_target(
        unit,
        type,
        node,
      )) {
        final SourceRange target => QueryFields._(type, stored, target),
        null => null,
      },
      _ => null,
    };
  }

  /// The name of the extension: `TaskFields` for `Task`.
  String get name => '${model.element.name}Fields';

  /// Writes the extension with [builder], replacing or inserting at
  /// [target].
  void write(DartFileEditBuilder builder) {
    void source(DartEditBuilder edit) {
      if (target.length == 0) {
        edit.write('\n\n');
      }

      edit
        ..write('/// The fields of `')
        ..write(model.element.name ?? '')
        ..write('` for queries, read from its `toJson`.\n')
        ..write('extension $name on DbTable<')
        ..writeType(model)
        ..write('> {\n');

      var first = true;

      for (final StoredField(:key, :member, :type, :dateForm)
          in fields.byKey.values) {
        if ((member, type) case (final String getter, final DartType value)) {
          // Documented, so the code passes `public_member_api_docs` in the
          // packages that enable it; a blank line between getters.
          edit
            ..write(first ? '' : '\n')
            ..write('  /// The stored `$key`.\n')
            ..write('  Field<')
            ..writeType(value)
            ..write("> get $getter => field('$key'")
            ..write(_codec(value, dateForm))
            ..write(');\n');
          first = false;
        }
      }

      edit.write('}');
    }

    builder.addReplacement(target, source);
  }

  /// The `encode` and `decode` of a `DateTime` stored as a number.
  static String _codec(DartType type, DateForm form) =>
      switch ((type.isDartCoreDateTime, form)) {
        (true, DateForm.epochMillis) =>
          ',\n    encode: (date) => date.millisecondsSinceEpoch,\n'
              '    decode: (stored) => '
              'DateTime.fromMillisecondsSinceEpoch(stored as int),\n  ',
        (true, DateForm.epochMicros) =>
          ',\n    encode: (date) => date.microsecondsSinceEpoch,\n'
              '    decode: (stored) => '
              'DateTime.fromMicrosecondsSinceEpoch(stored as int),\n  ',
        _ => '',
      };

  /// The current `<T>Fields` extension of [model] in [unit], or an empty
  /// range after the model class (or at the end of [unit]); `null` when the
  /// fields of [model] are written in another file, where a second
  /// extension here would make every getter ambiguous.
  static SourceRange? _target(
    CompilationUnit unit,
    InterfaceType model,
    AstNode node,
  ) {
    final name = '${model.element.name}Fields';
    final existing = [
      for (final declaration in unit.declarations)
        if (declaration is ExtensionDeclaration &&
            declaration.name?.lexeme == name)
          declaration,
    ].firstOrNull;
    final owner = [
      for (final declaration in unit.declarations)
        if (declaration is ClassDeclaration &&
            declaration.namePart.typeName.lexeme == model.element.name)
          declaration,
    ].firstOrNull;

    final elsewhere = DbDslTypes.extensionsOn(model, node).any(
      (extension) =>
          extension.firstFragment.libraryFragment != unit.declaredFragment,
    );

    return switch ((existing, owner, elsewhere)) {
      (final ExtensionDeclaration current, _, _) => SourceRange(
        current.offset,
        current.length,
      ),
      (null, _, true) => null,
      (null, final ClassDeclaration declaration, false) => SourceRange(
        declaration.end,
        0,
      ),
      _ => SourceRange(unit.end, 0),
    };
  }
}

/// What the writer needs to know of a type.
extension on DartType {
  bool get isDartCoreDateTime => switch (this) {
    InterfaceType(:final element) =>
      element.name == 'DateTime' &&
          element.library.uri.toString() == 'dart:core',
    _ => false,
  };
}
