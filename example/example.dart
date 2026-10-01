/// A small blog on db_dsl, run on [MemoryEngine]: typed tables, inserts,
/// filters, a group by, a left join, a counter and a transaction with a
/// savepoint.
///
/// ```sh
/// dart run example/example.dart
/// ```
///
/// The same code runs on the native engine: open the database with
/// `LocalDatabase.open` (flutter_local_db) or `DartDb.open` (dart_db)
/// instead of `Database.open(MemoryEngine(), ...)`.
library;

import 'package:db_dsl/db_dsl.dart';
import 'package:logger_rs/logger_rs.dart';

Future<void> main() async {
  switch (await BlogTour.run(MemoryEngine())) {
    case Ok():
      Log.i('Tour finished');
    case Err(:final error):
      Log.e('Tour failed: $error');
  }
}

/// The tour: each step reads or writes the blog and logs what it got.
final class BlogTour {
  BlogTour._(this.db);

  /// The `users` table, from the `User` model: generated keys, a composite
  /// index and a unique one.
  static final DbTable<User> users = DbTable<User>(
    'users',
    key: 'id',
    fromJson: User.fromJson,
    autoIncrement: true,
    indexes: [
      Index(['city', 'age']),
      Index.unique(['email']),
    ],
  );

  /// The `posts` table, from the `Post` model, indexed by author.
  static final DbTable<Post> posts = DbTable<Post>(
    'posts',
    key: 'id',
    fromJson: Post.fromJson,
    indexes: [
      Index(['author_id']),
    ],
  );

  /// The database of the tour.
  final Database db;

  /// Opens a blog on [engine] and runs every step, stopping at the first
  /// error.
  static Future<Result<void, DbError>> run(Engine engine) => Database.open(
    engine,
    path: 'blog',
    tables: [users, posts],
  ).flatMap((db) => BlogTour._(db)._steps());

  Future<Result<void, DbError>> _steps() async {
    for (final step in [_seed, _filter, _group, _join, _count, _transaction]) {
      if (await step() case Err(:final error)) {
        return Err(error);
      }
    }

    return db.close();
  }

  /// `INSERT`: the table generates the user ids.
  Future<Result<void, DbError>> _seed() => users
      .insert(const [
        User(name: 'Ada', city: 'Lima', age: 36, email: 'ada@example.com'),
        User(
          name: 'Grace',
          city: 'Bogotá',
          age: 45,
          email: 'grace@example.com',
        ),
        User(name: 'Linus', city: 'Lima', age: 28),
      ])
      .getResults()
      .flatMap((inserted) => _seedPosts(inserted.first));

  Future<Result<void, DbError>> _seedPosts(User author) => posts
      .insert([
        Post(id: 'p1', authorId: author.id!, title: 'Types'),
        Post(id: 'p2', authorId: author.id!, title: 'Joins'),
      ])
      .map((affected) => Log.i('Inserted $affected posts'));

  /// `SELECT ... WHERE city = 'Lima' AND age > 30 ORDER BY age DESC`.
  Future<Result<void, DbError>> _filter() => users
      .filter(
        users
            .field<String>('city')
            .eq('Lima')
            .and(users.field<int>('age').gt(30)),
      )
      .order(users.field<int>('age').desc())
      .map((rows) => Log.i('Lima, over 30: ${rows.map((u) => u.name)}'));

  /// `SELECT city, COUNT(*), MAX(age) ... GROUP BY city HAVING COUNT(*) >= 2`.
  Future<Result<void, DbError>> _group() {
    const people = Field<int>('people');

    return users
        .groupBy([users.field<String>('city')])
        .count('people')
        .max(users.field<int>('age'), 'oldest')
        .having(people.ge(2))
        .map((groups) => Log.i('Cities with 2+ people: ${groups.length}'));
  }

  /// `SELECT * FROM users LEFT JOIN posts ON posts.author_id = users.id`.
  Future<Result<void, DbError>> _join() => users
      .leftJoin(
        posts,
        on: users.field<int>('id'),
        equals: posts.field<int>('author_id'),
      )
      .order(users.field<String>('name').asc())
      .map((rows) => rows.map(_describe).forEach(Log.i));

  /// One line per combined row; a left join without match has no post.
  String _describe(JoinRow row) => row
      .of(users)
      .flatMap(
        (user) => row
            .maybe(posts)
            .map(
              (post) => switch (post) {
                null => '${user.name} wrote nothing',
                Post(:final title) => '${user.name} wrote $title',
              },
            ),
      )
      .when(ok: (line) => line, err: (error) => '$error');

  /// `UPDATE posts SET views = views + 1`, then `SUM(views)`.
  Future<Result<void, DbError>> _count() => posts
      .update()
      .increment(posts.field<int>('views'), 1)
      .flatMap((_) => posts.all().sum(posts.field<int>('views')))
      .map((views) => Log.i('Total views: $views'));

  /// A transaction whose savepoint fails: only the savepoint is undone.
  /// Queries awaited inside run on the transaction.
  Future<Result<void, DbError>> _transaction() => db
      .transaction<bool>((tx) async {
        final renamed = await posts
            .update()
            .filter(posts.field<String>('id').eq('p1'))
            .set(posts.field<String>('title'), 'Typed tables');

        if (renamed case Err(:final error)) {
          return Err(error);
        }

        // The duplicate key fails the savepoint; the rename stays.
        final duplicate = await tx.savepoint(
          (_) => posts.insert([
            const Post(id: 'p1', authorId: 1, title: 'Duplicate'),
          ]),
        );

        return Ok(duplicate.isErr);
      })
      .flatMap((rolledBack) {
        Log.i('Savepoint rolled back: $rolledBack');
        return posts.find('p1');
      })
      .map((post) => Log.i('p1 is now "${post?.title}"'));
}

/// A user of the blog.
final class User {
  /// A user; [id] is generated on insert.
  const User({
    required this.name,
    required this.city,
    required this.age,
    this.id,
    this.email,
  });

  /// The user stored as [json].
  factory User.fromJson(Map<String, Object?> json) => User(
    id: json['id'] as int?,
    name: json['name']! as String,
    city: json['city']! as String,
    age: json['age']! as int,
    email: json['email'] as String?,
  );

  /// Primary key, generated by the table.
  final int? id;

  /// Display name.
  final String name;

  /// Home city.
  final String city;

  /// Age in years.
  final int age;

  /// Unique when present.
  final String? email;

  /// The stored form.
  Map<String, Object?> toJson() => {
    'id': ?id,
    'name': name,
    'city': city,
    'age': age,
    'email': email,
  };
}

/// A post of the blog.
final class Post {
  /// A post [id] by [authorId].
  const Post({
    required this.id,
    required this.authorId,
    required this.title,
    this.views = 0,
  });

  /// The post stored as [json].
  factory Post.fromJson(Map<String, Object?> json) => Post(
    id: json['id']! as String,
    authorId: json['author_id']! as int,
    title: json['title']! as String,
    views: json['views']! as int,
  );

  /// Primary key.
  final String id;

  /// The `id` of its user.
  final int authorId;

  /// Title.
  final String title;

  /// A counter.
  final int views;

  /// The stored form.
  Map<String, Object?> toJson() => {
    'id': id,
    'author_id': authorId,
    'title': title,
    'views': views,
  };
}
