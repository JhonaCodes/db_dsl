/// The protocol form of a table definition (`PROTOCOL.md`, "Tables").
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/json_values.dart';

/// How a table is stored: its name, primary key, key generation and
/// secondary indexes.
///
/// This is what travels in `define_table` and comes back from `tables`; the
/// DSL builds it from a [DbTable].
final class TableSchema {
  /// A table named [name] whose rows are identified by the field
  /// [primaryKey].
  const TableSchema({
    required this.name,
    required this.primaryKey,
    this.autoIncrement = false,
    this.indexes = const [],
    this.sync,
  });

  /// Table name: non-empty, without `:`, not starting with `__`.
  final String name;

  /// Field path of the primary key.
  final String primaryKey;

  /// Rows inserted without a primary key get the next integer.
  final bool autoIncrement;

  /// Secondary indexes, in declaration order.
  final List<IndexSchema> indexes;

  /// The remote the table synchronizes with (`PROTOCOL.md`, "Sync"), or
  /// `null` for a local table.
  final String? sync;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'name': name,
    'primary_key': primaryKey,
    'auto_increment': autoIncrement,
    'indexes': [for (final index in indexes) index.toJson()],
    if (sync case final String remote) 'sync': remote,
  };

  /// The definition encoded in [json].
  static Result<TableSchema, DbError> decode(Object? json) {
    if (json case {
      'name': final String name,
      'primary_key': final String primaryKey,
    }) {
      final indexes = <IndexSchema>[];

      for (final index in switch (json['indexes']) {
        final List<Object?> list => list,
        _ => const <Object?>[],
      }) {
        switch (IndexSchema.decode(index)) {
          case Ok(:final data):
            indexes.add(data);
          case Err(:final error):
            return Err(error);
        }
      }

      return Ok(
        TableSchema(
          name: name,
          primaryKey: primaryKey,
          autoIncrement: json['auto_increment'] == true,
          indexes: indexes,
          sync: json['sync'] as String?,
        ),
      );
    }

    return Err(
      DbError(
        DbErrorCode.invalidRequest,
        'Not a valid table definition: $json',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TableSchema && JsonValues.equals(toJson(), other.toJson());

  @override
  int get hashCode => JsonValues.canonical(toJson()).hashCode;

  @override
  String toString() => 'TableSchema(${toJson()})';
}

/// A secondary index of a [TableSchema].
final class IndexSchema {
  /// An index named [name] over [fields], rejecting duplicates when
  /// [unique].
  const IndexSchema({
    required this.name,
    required this.fields,
    this.unique = false,
  });

  /// Index name, unique within its table.
  final String name;

  /// Indexed field paths, in order.
  final List<String> fields;

  /// Two rows cannot hold equal values in [fields]; rows with a `null` among
  /// them are exempt, as in SQL.
  final bool unique;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'name': name,
    'fields': fields,
    'unique': unique,
  };

  /// The index encoded in [json].
  static Result<IndexSchema, DbError> decode(Object? json) => switch (json) {
    {'name': final String name, 'fields': final List<Object?> fields}
        when fields.every((field) => field is String) =>
      Ok(
        IndexSchema(
          name: name,
          fields: fields.cast<String>(),
          unique: json['unique'] == true,
        ),
      ),
    _ => Err(
      DbError(
        DbErrorCode.invalidRequest,
        'Not a valid index definition: $json',
      ),
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is IndexSchema && JsonValues.equals(toJson(), other.toJson());

  @override
  int get hashCode => JsonValues.canonical(toJson()).hashCode;
}
