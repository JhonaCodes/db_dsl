/// The fields a model stores, read from its source code.
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';

/// How a model stores a `DateTime`.
enum DateForm {
  /// `toIso8601String()`: db_dsl's default for a `Field<DateTime>`.
  iso8601,

  /// `millisecondsSinceEpoch`.
  epochMillis,

  /// `microsecondsSinceEpoch`.
  epochMicros,
}

/// One field of the documents a model stores.
final class StoredField {
  /// The field stored under [key].
  const StoredField({
    required this.key,
    this.member,
    this.type,
    this.dateForm = DateForm.iso8601,
  });

  /// The key in the stored JSON (`'updated_at'`).
  final String key;

  /// The Dart member the value comes from (`updatedAt`); `null` when the
  /// value is computed.
  final String? member;

  /// The non-nullable Dart type of [member]; `null` when unknown.
  final DartType? type;

  /// How a `DateTime` value is stored.
  final DateForm dateForm;
}

/// What a field path (`'address.city'`) is in a model.
///
/// Why sealed: a rule must tell a field that does not exist (an error to
/// report) from one it cannot determine (silence: no false positives).
sealed class PathLookup {
  const PathLookup();
}

/// The path names [field].
final class FoundPath extends PathLookup {
  /// The path ends at [field].
  const FoundPath(this.field);

  /// The last field of the path.
  final StoredField field;
}

/// The path names a field its model does not store.
final class MissingPath extends PathLookup {
  /// [segment] is not stored by [model]; [closest] is the most similar
  /// stored key.
  const MissingPath(this.segment, this.model, this.closest, this.known);

  /// The segment of the path that is not stored.
  final String segment;

  /// The model that does not store it: the table's, or a nested one.
  final String model;

  /// The stored key most similar to [segment], if any is close.
  final String? closest;

  /// Every key stored at that level, for the message.
  final List<String> known;
}

/// The model's storage cannot be read (a `toJson` built at run time).
final class UnknownPath extends PathLookup {
  /// Nothing can be said.
  const UnknownPath();
}

/// The fields a model stores, read from the map its `toJson` returns: a map
/// literal in the method, or in the function json_serializable generates
/// (`_$TaskToJson`), with keys from `@JsonKey(name:)` already applied.
///
/// Why from the source: there is no reflection in Flutter and no code
/// generation here, and `toJson` is where the model decides each stored
/// key; the analyzer can read it without running anything.
final class StoredFields {
  StoredFields._(this.model, this.byKey);

  /// The name of the model.
  final String model;

  /// Stored fields by key, in the order `toJson` writes them.
  final Map<String, StoredField> byKey;

  /// The fields [model] stores, or `null` when its `toJson` cannot be read.
  static StoredFields? of(InterfaceType model, TypeSystem typeSystem) {
    final element = model.element;
    final library = element.library;
    final name = element.name;

    if (name == null) {
      return null;
    }

    try {
      return switch (library.session.getParsedLibraryByElement(library)) {
        final ParsedLibraryResult parsed => _read(
          [for (final unit in parsed.units) unit.unit],
          name,
          model,
          typeSystem,
        ),
        _ => null,
      };
    } on Object {
      // The library changed while it was read; the next analysis retries.
      return null;
    }
  }

  /// The fields a `toJson:` function of a table writes, or `null` when it
  /// is not a map literal.
  static StoredFields? ofFunction(
    Expression toJson,
    InterfaceType model,
    TypeSystem typeSystem,
  ) => switch (toJson) {
    FunctionExpression(
      :final body,
      parameters: FormalParameterList(parameters: [final parameter]),
    ) =>
      switch (_returned(body)) {
        final SetOrMapLiteral map => _entries(
          map,
          parameter.name?.lexeme,
          model,
          typeSystem,
        ),
        _ => null,
      },
    _ => null,
  };

  /// What [path] names in these fields, following nested models.
  PathLookup lookup(String path, TypeSystem typeSystem) {
    final [first, ...rest] = path.split('.');

    return switch ((byKey[first], rest)) {
      (null, _) => MissingPath(first, model, _closest(first), [...byKey.keys]),
      (final StoredField field, []) => FoundPath(field),
      (StoredField(type: final InterfaceType nested), _) =>
        switch (StoredFields.of(nested, typeSystem)) {
          final StoredFields inner => inner.lookup(rest.join('.'), typeSystem),
          null => const UnknownPath(),
        },
      _ => const UnknownPath(),
    };
  }

  /// The stored key closest to [key], when it is a likely typo.
  String? _closest(String key) {
    final ranked = [
      for (final candidate in byKey.keys)
        (
          candidate,
          _Distance.between(key.toLowerCase(), candidate.toLowerCase()),
        ),
    ]..sort((a, b) => a.$2.compareTo(b.$2));

    // A third of the name, at least one edit: `dne` → `done`, `zp` → `zip`,
    // `updatedAt` → `updated_at`, but not `owner` → `done`.
    final tolerance = key.length ~/ 3 < 1 ? 1 : key.length ~/ 3;

    return switch (ranked) {
      [(final candidate, final distance), ...] when distance <= tolerance =>
        candidate,
      _ => null,
    };
  }

  static StoredFields? _read(
    List<CompilationUnit> units,
    String className,
    InterfaceType model,
    TypeSystem typeSystem,
  ) {
    final toJson = [
      for (final unit in units)
        for (final declaration in unit.declarations)
          if (declaration is ClassDeclaration &&
              declaration.namePart.typeName.lexeme == className)
            for (final member in declaration.body.members)
              if (member is MethodDeclaration && member.name.lexeme == 'toJson')
                member,
    ].firstOrNull;

    return switch (toJson == null ? null : _returned(toJson.body)) {
      final SetOrMapLiteral map => _entries(map, null, model, typeSystem),
      // `toJson() => _$TaskToJson(this)`, generated by json_serializable.
      MethodInvocation(target: null, :final methodName) => _generated(
        units,
        methodName.name,
        model,
        typeSystem,
      ),
      _ => null,
    };
  }

  static StoredFields? _generated(
    List<CompilationUnit> units,
    String function,
    InterfaceType model,
    TypeSystem typeSystem,
  ) {
    final declaration = [
      for (final unit in units)
        for (final member in unit.declarations)
          if (member is FunctionDeclaration && member.name.lexeme == function)
            member,
    ].firstOrNull;

    return switch (declaration?.functionExpression) {
      FunctionExpression(
        :final body,
        parameters: FormalParameterList(parameters: [final parameter, ...]),
      ) =>
        switch (_returned(body)) {
          final SetOrMapLiteral map => _entries(
            map,
            parameter.name?.lexeme,
            model,
            typeSystem,
          ),
          _ => null,
        },
      _ => null,
    };
  }

  /// The single expression a body returns, or `null`.
  static Expression? _returned(FunctionBody body) => switch (body) {
    ExpressionFunctionBody(:final expression) => expression,
    BlockFunctionBody(
      block: Block(statements: [ReturnStatement(:final expression)]),
    ) =>
      expression,
    _ => null,
  };

  /// The fields of a map literal; `null` when an element is not a plain
  /// `'key': value` entry (a spread, a loop: the keys are not all known).
  ///
  /// The entries are what tells a map from a set: `isMap` is only known
  /// after resolution, and the model may come from a parsed library.
  static StoredFields? _entries(
    SetOrMapLiteral map,
    String? instance,
    InterfaceType model,
    TypeSystem typeSystem,
  ) {
    final fields = <String, StoredField>{};

    for (final element in map.elements) {
      final (entry, access) = switch (element) {
        final MapLiteralEntry entry => (
          entry,
          _Access.of(entry.value, instance),
        ),
        // `if (instance.x case final value?) 'x': value` (includeIfNull: false).
        IfElement(
          :final expression,
          thenElement: final MapLiteralEntry entry,
          elseElement: null,
        ) =>
          (entry, _Access.of(expression, instance)),
        _ => (null, null),
      };

      if (entry == null ||
          access == null ||
          entry.key is! SimpleStringLiteral) {
        return null;
      }

      final key = (entry.key as SimpleStringLiteral).value;
      final member = access.member;
      final type = switch (member) {
        final String name => model.getGetter(name)?.returnType,
        null => null,
      };

      fields[key] = StoredField(
        key: key,
        member: member,
        type: type == null ? null : typeSystem.promoteToNonNull(type),
        dateForm: access.dateForm,
      );
    }

    return StoredFields._(model.element.name ?? '', fields);
  }
}

/// Which member of the model a stored value comes from, and how it is
/// transformed (`updatedAt.toIso8601String()`, `instance.id`).
final class _Access {
  const _Access(this.member, this.chain);

  /// The member of the model, or `null` for a computed value.
  final String? member;

  /// The properties and methods applied after the member.
  final List<String> chain;

  DateForm get dateForm => switch (chain) {
    [..., 'millisecondsSinceEpoch'] ||
    ['millisecondsSinceEpoch', ...] => DateForm.epochMillis,
    [..., 'microsecondsSinceEpoch'] ||
    ['microsecondsSinceEpoch', ...] => DateForm.epochMicros,
    _ => DateForm.iso8601,
  };

  /// The access of [value]; [instance] is the parameter name of a generated
  /// `_$TToJson(T instance)` (members are read through it).
  static _Access of(Expression value, String? instance) => switch (value) {
    SimpleIdentifier(:final name) when name != instance => _Access(
      name,
      const [],
    ),
    PrefixedIdentifier(:final prefix, :final identifier)
        when prefix.name == instance =>
      _Access(identifier.name, const []),
    PrefixedIdentifier(:final prefix, :final identifier) => _Access(
      prefix.name,
      [identifier.name],
    ),
    PropertyAccess(target: ThisExpression(), :final propertyName) => _Access(
      propertyName.name,
      const [],
    ),
    PropertyAccess(:final Expression target, :final propertyName) => of(
      target,
      instance,
    )._then(propertyName.name),
    MethodInvocation(:final Expression target, :final methodName) => of(
      target,
      instance,
    )._then(methodName.name),
    ParenthesizedExpression(:final expression) ||
    AsExpression(:final expression) => of(expression, instance),
    PostfixExpression(:final operand) => of(operand, instance),
    _ => const _Access(null, []),
  };

  _Access _then(String step) => _Access(member, [...chain, step]);
}

/// Edit distance between two keys, for "did you mean".
abstract final class _Distance {
  static int between(String a, String b) {
    var previous = [for (var i = 0; i <= b.length; i++) i];

    for (var i = 1; i <= a.length; i++) {
      final current = [i, for (var j = 1; j <= b.length; j++) 0];

      for (var j = 1; j <= b.length; j++) {
        final substitution = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + substitution,
        ].reduce((x, y) => x < y ? x : y);
      }

      previous = current;
    }

    return previous[b.length];
  }
}
