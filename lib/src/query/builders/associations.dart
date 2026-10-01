part of '../queries.dart';

/// Diesel's associations: load the children of some parents in one query
/// (`belonging_to`), then group them by parent (`grouped_by`).
///
/// ```dart
/// final byAuthor = await users
///     .filter(users.city.eq('Lima'))
///     .flatMap(
///       (authors) => posts
///           .belongingTo(authors.map((user) => user.id), posts.authorId)
///           .map(
///             (children) => Associations.groupedBy(
///               authors,
///               children,
///               parentKey: (user) => user.id,
///               childKey: (post) => post.authorId,
///             ),
///           ),
///     );
/// ```
///
/// Why grouping happens in Dart: the engine already chose and filtered the
/// children; attaching each to its parent only arranges rows that are in
/// memory anyway, without reading anything else.
abstract final class Associations {
  /// [children] grouped under the parent with the same key, in the order of
  /// [parents]; a parent without children gets an empty list.
  static List<(P, List<C>)> groupedBy<P, C, K extends Object>(
    List<P> parents,
    List<C> children, {
    required K Function(P parent) parentKey,
    required K? Function(C child) childKey,
  }) {
    final byKey = <K, List<C>>{};

    for (final child in children) {
      if (childKey(child) case final K key) {
        (byKey[key] ??= []).add(child);
      }
    }

    return [
      for (final parent in parents) (parent, byKey[parentKey(parent)] ?? []),
    ];
  }
}
