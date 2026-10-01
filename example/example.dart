/// A small blog on db_dsl, run on [MemoryEngine]: models that carry their
/// tables, typed fields, inserts, filters, a group by, a left join, a
/// counter and a transaction with a savepoint.
///
/// ```sh
/// dart run example/example.dart
/// ```
///
/// The same code runs on the native engine: open the database with
/// `LocalDB.init()` (flutter_local_db) or `DartDb.open(path)` (dart_db)
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

  /// The database of the tour.
  final Database db;

  static final DbTable<User> _users = User.table;
  static final DbTable<Post> _posts = Post.table;

  /// Opens a blog on [engine] and runs every step, stopping at the first
  /// error. No table is listed: each defines itself the first time it is
  /// used, on this database (the first one opened).
  static Future<Result<void, DbError>> run(Engine engine) => Database.open(
    engine,
    path: 'blog',
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
  Future<Result<void, DbError>> _seed() => _users
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

  Future<Result<void, DbError>> _seedPosts(User author) => _posts
      .insert([
        Post(id: 'p1', authorId: author.id!, title: 'Types'),
        Post(id: 'p2', authorId: author.id!, title: 'Joins'),
      ])
      .map((affected) => Log.i('Inserted $affected posts'));

  /// `SELECT ... WHERE city = 'Lima' AND age > 30 ORDER BY age DESC`.
  Future<Result<void, DbError>> _filter() => _users
      .filter(_users.city.eq('Lima').and(_users.age.gt(30)))
      .order(_users.age.desc())
      .map((rows) => Log.i('Lima, over 30: ${rows.map((u) => u.name)}'));

  /// `SELECT city, COUNT(*), MAX(age) ... GROUP BY city HAVING COUNT(*) >= 2`.
  Future<Result<void, DbError>> _group() {
    const people = Field<int>('people');

    return _users
        .groupBy([_users.city])
        .count('people')
        .max(_users.age, 'oldest')
        .having(people.ge(2))
        .map((groups) => Log.i('Cities with 2+ people: ${groups.length}'));
  }

  /// `SELECT * FROM users LEFT JOIN posts ON posts.author_id = users.id`.
  Future<Result<void, DbError>> _join() => _users
      .leftJoin(_posts, on: _users.id, equals: _posts.authorId)
      .order(_users.name.asc())
      .map((rows) => rows.map(_describe).forEach(Log.i));

  /// One line per combined row; a left join without match has no post.
  String _describe(JoinRow row) => row
      .of(_users)
      .flatMap(
        (user) => row
            .maybe(_posts)
            .map(
              (post) => switch (post) {
                null => '${user.name} wrote nothing',
                Post(:final title) => '${user.name} wrote $title',
              },
            ),
      )
      .when(ok: (line) => line, err: (error) => '$error');

  /// `UPDATE posts SET views = views + 1`, then `SUM(views)`.
  Future<Result<void, DbError>> _count() => _posts
      .update()
      .increment(_posts.views, 1)
      .flatMap((_) => _posts.all().sum(_posts.views))
      .map((views) => Log.i('Total views: $views'));

  /// A transaction whose savepoint fails: only the savepoint is undone.
  /// Queries awaited inside run on the transaction.
  Future<Result<void, DbError>> _transaction() => db
      .transaction<bool>((tx) async {
        final renamed = await _posts
            .update()
            .filter(_posts.id.eq('p1'))
            .set(_posts.title, 'Typed tables');

        if (renamed case Err(:final error)) {
          return Err(error);
        }

        // The duplicate key fails the savepoint; the rename stays.
        final duplicate = await tx.savepoint(
          (_) => _posts.insert([
            const Post(id: 'p1', authorId: 1, title: 'Duplicate'),
          ]),
        );

        return Ok(duplicate.isErr);
      })
      .flatMap((rolledBack) {
        Log.i('Savepoint rolled back: $rolledBack');
        return _posts.find('p1');
      })
      .map((post) => Log.i('p1 is now "${post?.title}"'));
}

// The `extension <Model>Fields` after each model is not typed by hand: the
// db_dsl_lints plugin warns on a table whose fields are not written yet and
// writes them from the model's `toJson` with one quick fix, again whenever
// the model changes. It is plain code, without generated files.

/// A user of the blog: a plain model that carries its table.
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

  /// The `users` table: generated keys, a composite index and a unique one.
  static final DbTable<User> table = DbTable<User>(
    'users',
    key: 'id',
    fromJson: User.fromJson,
    autoIncrement: true,
    indexes: [
      Index(['city', 'age']),
      Index.unique(['email']),
    ],
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

/// The fields of `User` for queries, read from its `toJson`.
extension UserFields on DbTable<User> {
  /// The stored `id`.
  Field<int> get id => field('id');

  /// The stored `name`.
  Field<String> get name => field('name');

  /// The stored `city`.
  Field<String> get city => field('city');

  /// The stored `age`.
  Field<int> get age => field('age');

  /// The stored `email`.
  Field<String> get email => field('email');
}

/// A post of the blog: a plain model that carries its table.
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

  /// The `posts` table, indexed by author.
  static final DbTable<Post> table = DbTable<Post>(
    'posts',
    key: 'id',
    fromJson: Post.fromJson,
    indexes: [
      Index(['author_id']),
    ],
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

/// The fields of `Post` for queries, read from its `toJson`.
extension PostFields on DbTable<Post> {
  /// The stored `id`.
  Field<String> get id => field('id');

  /// The stored `author_id`.
  Field<int> get authorId => field('author_id');

  /// The stored `title`.
  Field<String> get title => field('title');

  /// The stored `views`.
  Field<int> get views => field('views');
}
