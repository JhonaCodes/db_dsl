import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// A many-to-many relation through a bridge table: links both ways, detach
/// keeps the rows, and the links follow the transaction around them.
void main() {
  late Database db;
  late DbTable<Person> people;
  late DbTable<Skill> skills;
  late Relation<Person, Skill> skillsOf;
  var next = 0;

  const ada = Person(1, 'Ada');
  const linus = Person(2, 'Linus');
  const grace = Person(3, 'Grace');
  const dart = Skill('dart', 'Dart');
  const rust = Skill('rust', 'Rust');
  const sql = Skill('sql', 'SQL');

  setUp(() async {
    db = value(await Database.open(MemoryEngine(), path: 'relation-${next++}'));
    people = DbTable<Person>('people', key: 'id', fromJson: Person.fromJson);
    skills = DbTable<Skill>('skills', key: 'id', fromJson: Skill.fromJson);
    skillsOf = Relation<Person, Skill>(
      'people_skills',
      from: people,
      to: skills,
    );
    value(await people.insert([ada, linus, grace]));
    value(await skills.insert([dart, rust, sql]));
  });

  tearDown(() => db.close());

  test('a link reads both ways', () async {
    expect(value(await skillsOf.attach(ada, dart)), 1);
    expect(value(await skillsOf.attach(ada, rust)), 1);
    expect(value(await skillsOf.attach(linus, rust)), 1);

    expect(value(await skillsOf.targetsOf(ada)), [dart, rust]);
    expect(value(await skillsOf.sourcesOf(rust)), [ada, linus]);
    expect(value(await skillsOf.targetsOf(grace)), isEmpty);
    expect(value(await skillsOf.sourcesOf(sql)), isEmpty);
  });

  test('attaching twice links once', () async {
    expect(value(await skillsOf.attach(ada, dart)), 1);
    expect(value(await skillsOf.attach(ada, dart)), 0);

    expect(value(await skillsOf.links.all().count()), 1);
  });

  test('detach removes the link, never the rows', () async {
    value(await skillsOf.attach(ada, dart));
    value(await skillsOf.attach(ada, rust));

    expect(value(await skillsOf.detach(ada, dart)), 1);
    expect(value(await skillsOf.detach(ada, dart)), 0, reason: 'already gone');

    expect(value(await skillsOf.targetsOf(ada)), [rust]);
    expect(value(await people.find(1)), ada);
    expect(value(await skills.find('dart')), dart);
  });

  test('a row without its key cannot be linked', () async {
    const unsaved = Person(null, 'Nobody');

    final linked = await skillsOf.attach(unsaved, dart);

    expect(code(linked), DbErrorCode.missingPrimaryKey);
    expect(value(await skillsOf.links.all().count()), 0);
  });

  test('links follow the transaction they are written in', () async {
    // The bridge table defines itself before the transaction.
    value(await skillsOf.attach(grace, sql));

    final undone = await db.transaction<int>((tx) async {
      value(await skillsOf.attach(ada, dart));
      return Err(DbError(DbErrorCode.invalidRequest, 'undo it'));
    });

    expect(code(undone), DbErrorCode.invalidRequest);
    expect(value(await skillsOf.targetsOf(ada)), isEmpty);
  });
}

/// The value of an `Ok`; fails the test on an `Err`.
T value<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => data, err: (error) => fail('Err: $error'));

/// The code of an `Err`; fails the test on an `Ok`.
DbErrorCode code<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => fail('Ok: $data'), err: (error) => error.code);

/// A person; [id] is `null` until stored.
final class Person {
  const Person(this.id, this.name);

  factory Person.fromJson(Map<String, Object?> json) =>
      Person(json['id'] as int?, json['name']! as String);

  final int? id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is Person && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'Person($id, $name)';
}

/// A skill, keyed by text.
final class Skill {
  const Skill(this.id, this.name);

  factory Skill.fromJson(Map<String, Object?> json) =>
      Skill(json['id']! as String, json['name']! as String);

  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is Skill && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'Skill($id)';
}
