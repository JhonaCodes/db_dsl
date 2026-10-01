/// Recognizing the types of db_dsl in analyzed code.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// The db_dsl types the plugin reasons about: `DbTable<T>` and `Field<V>`.
///
/// Why by library: an app may have its own `Field` or `DbTable`; only the
/// ones declared by `package:db_dsl` carry the meaning the rules check.
abstract final class DbDslTypes {
  /// Whether [element] is declared by `package:db_dsl`.
  static bool isFromDbDsl(Element? element) =>
      element?.library?.uri.toString().startsWith('package:db_dsl/') ?? false;

  /// The model `T` of a `DbTable<T>` type, or `null` for any other type.
  static InterfaceType? modelOfTable(DartType? type) => switch (type) {
    InterfaceType(
      element: final InterfaceElement element,
      typeArguments: [final InterfaceType model],
    )
        when element.name == 'DbTable' && isFromDbDsl(element) =>
      model,
    _ => null,
  };

  /// The value type `V` of a `Field<V>` type, or `null` for any other type.
  static DartType? valueOfField(DartType? type) => switch (type) {
    InterfaceType(
      element: final InterfaceElement element,
      typeArguments: [final DartType value],
    )
        when element.name == 'Field' && isFromDbDsl(element) =>
      value,
    _ => null,
  };

  /// The model of the table [node] (a `field(...)` call) reads from: its
  /// explicit target, or the table an enclosing
  /// `extension ... on DbTable<T>` extends.
  static InterfaceType? modelOfFieldCall(MethodInvocation node) {
    final element = node.methodName.element;

    if (node.methodName.name != 'field' ||
        !isFromDbDsl(element) ||
        element?.enclosingElement?.name != 'DbTable') {
      return null;
    }

    return modelOfTable(
      node.realTarget?.staticType ??
          node
              .thisOrAncestorOfType<ExtensionDeclaration>()
              ?.onClause
              ?.extendedType
              .type,
    );
  }

  /// The model of a `DbTable<T>(...)` creation, or `null` for any other
  /// creation.
  static InterfaceType? modelOfCreation(InstanceCreationExpression node) =>
      modelOfTable(node.staticType);

  /// The getter names of the extensions on `DbTable<model>` visible where
  /// [node] is: in its own file or imported.
  static Set<String> queryFieldsOf(InterfaceType model, AstNode node) => {
    for (final extension in extensionsOn(model, node))
      for (final getter in extension.getters) ?getter.name,
  };

  /// The extensions on `DbTable<model>` visible where [node] is.
  static Iterable<ExtensionElement> extensionsOn(
    InterfaceType model,
    AstNode node,
  ) => [
    if (node.root case CompilationUnit(:final declaredFragment?))
      for (final extension in declaredFragment.accessibleExtensions)
        if (modelOfTable(extension.extendedType)
            case final InterfaceType extended
            when extended.element == model.element)
          extension,
  ];

  /// The argument named [name] of [arguments], if any.
  static Expression? namedArgument(ArgumentList arguments, String name) => [
    for (final argument in arguments.arguments)
      if (argument case NamedArgument(
        name: Token(lexeme: final label),
        :final argumentExpression,
      ) when label == name)
        argumentExpression,
  ].firstOrNull;
}
