part of '../queries.dart';

/// A many-to-many relation between rows of [from] and rows of [to], kept in
/// a bridge table of its own ([links]): one row per linked pair.
///
/// ```dart
/// final skillsOf = Relation<Person, Skill>(
///   'people_skills',
///   from: Person.table,
///   to: Skill.table,
/// );
///
/// await skillsOf.attach(ada, dart);
/// final adasSkills = await skillsOf.targetsOf(ada);   // Result<List<Skill>, …>
/// final dartPeople = await skillsOf.sourcesOf(dart);  // Result<List<Person>, …>
/// await skillsOf.detach(ada, dart);                   // the rows stay
/// ```
///
/// Why a bridge table keyed by the pair, with two indexes: a link is
/// written once (its key is the pair, so linking twice is a key conflict
/// that is ignored), and both directions read only the neighbours of a row
/// (an index on `from`, another on `to`, then primary key lookups), never
/// every link. Links are ordinary rows: awaited inside a transaction, they
/// commit or roll back with it, and the bridge table defines itself on
/// first use like any table.
final class Relation<A, B> {
  /// A relation stored in the table [name], from rows of [from] to rows of
  /// [to].
  Relation(String name, {required this.from, required this.to})
    : links = DbTable<RelationLink>(
        name,
        key: 'id',
        fromJson: RelationLink.fromJson,
        indexes: [
          Index(['from']),
          Index(['to']),
        ],
      );

  /// The table of the sources.
  final DbTable<A> from;

  /// The table of the targets.
  final DbTable<B> to;

  /// The bridge table: one [RelationLink] per linked pair.
  final DbTable<RelationLink> links;

  late final Field<Object> _source = links.field<Object>('from');
  late final Field<Object> _target = links.field<Object>('to');

  /// Links [source] to [target]; answers 1, or 0 when they were linked
  /// already. A row without its key (not stored yet) answers
  /// [DbErrorCode.missingPrimaryKey].
  Future<Result<int, DbError>> attach(A source, B target) =>
      Future.value(_pair(source, target)).flatMap(
        (pair) => links.insert([
          RelationLink(from: pair.$1, to: pair.$2),
        ]).onConflictDoNothing(),
      );

  /// Removes the link of [source] to [target], not the rows; answers 1, or
  /// 0 when they were not linked.
  Future<Result<int, DbError>> detach(A source, B target) =>
      Future.value(_pair(source, target)).flatMap(
        (pair) => links.delete().filter(
          links.primaryKey.eq(RelationLink.keyOf(pair.$1, pair.$2)),
        ),
      );

  /// The rows of [to] linked to [source], in primary key order.
  Future<Result<List<B>, DbError>> targetsOf(A source) =>
      Future.value(_RelationKeys.of(from, source)).flatMap(
        (key) => links
            .filter(_source.eq(key))
            .pluck(_target)
            .flatMap((keys) => _RelationKeys.rows(to, keys)),
      );

  /// The rows of [from] linked to [target], in primary key order.
  Future<Result<List<A>, DbError>> sourcesOf(B target) =>
      Future.value(_RelationKeys.of(to, target)).flatMap(
        (key) => links
            .filter(_target.eq(key))
            .pluck(_source)
            .flatMap((keys) => _RelationKeys.rows(from, keys)),
      );

  /// The keys of [source] and [target], or the error of the first that has
  /// none.
  Result<(Object, Object), DbError> _pair(A source, B target) =>
      _RelationKeys.of(from, source).flatMap(
        (sourceKey) => _RelationKeys.of(
          to,
          target,
        ).map((targetKey) => (sourceKey, targetKey)),
      );
}

/// The keys a relation stores, read from the rows as their tables store
/// them.
abstract final class _RelationKeys {
  /// The primary key of [row] in [table], or
  /// [DbErrorCode.missingPrimaryKey] when it has none yet.
  static Result<Object, DbError> of<T>(DbTable<T> table, T row) => table
      .encodeRow(row)
      .flatMap(
        (json) => switch (_at(json, table.primaryKey.name)) {
          final Object key => Ok(key),
          null => Err(
            DbError(
              DbErrorCode.missingPrimaryKey,
              'A row of `${table.tableName}` without its '
              '`${table.primaryKey.name}` cannot be linked: store it first',
            ),
          ),
        },
      );

  /// The rows of [table] with the primary keys [keys]; one point lookup
  /// each on the native engine.
  static Future<Result<List<T>, DbError>> rows<T>(
    DbTable<T> table,
    List<Object?> keys,
  ) async => switch ([for (final key in keys) ?key]) {
    [] => Ok(<T>[]),
    final List<Object> present =>
      await table
          .filter(table.primaryKey.eqAny(present))
          .order(table.primaryKey.asc()),
  };

  /// The value at the dotted [path] of [json].
  static Object? _at(Map<String, Object?> json, String path) => path
      .split('.')
      .fold<Object?>(
        json,
        (value, segment) => switch (value) {
          final Map<String, Object?> map => map[segment],
          _ => null,
        },
      );
}

/// One link of a [Relation]: the keys of a source and of a target.
final class RelationLink {
  /// A link from the row keyed [from] to the row keyed [to].
  const RelationLink({required this.from, required this.to});

  /// The link stored as [json].
  factory RelationLink.fromJson(Map<String, Object?> json) =>
      RelationLink(from: json['from']!, to: json['to']!);

  /// Primary key of the source row.
  final Object from;

  /// Primary key of the target row.
  final Object to;

  /// The key of the link of [from] to [to]: the pair as JSON, so each pair
  /// is one row.
  static String keyOf(Object from, Object to) => jsonEncode([from, to]);

  /// The stored form.
  Map<String, Object?> toJson() => {
    'id': keyOf(from, to),
    'from': from,
    'to': to,
  };
}
